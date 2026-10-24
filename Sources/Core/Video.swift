import Foundation
import AVFoundation
import CommonCrypto

// MARK: - Plain file download with progress
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var cont: CheckedContinuation<Void, Error>?
    private var dest: URL!
    private var onProgress: ((Int64, Int64) -> Void)?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var session: URLSession!

    func download(_ req: URLRequest, to dest: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        self.dest = dest
        self.onProgress = progress
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.cont = c
                let t = self.session.downloadTask(with: req)
                self.task = t
                t.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        if code >= 400 { moveError = JobError.message("HTTP \(code)"); return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = cont else { return }
        cont = nil
        if let e = error {
            if (e as? URLError)?.code == .cancelled { c.resume(throwing: JobError.cancelled) } else { c.resume(throwing: e) }
        } else if let m = moveError {
            c.resume(throwing: m)
        } else {
            c.resume()
        }
    }
}

private func makeRequest(_ url: URL, headers: [String: String]) -> URLRequest {
    var r = URLRequest(url: url)
    r.setValue(Fetcher.ua, forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    return r
}

private func fetchData(_ url: URL, headers: [String: String], retries: Int = 3) async throws -> Data {
    var last: Error = JobError.message("άγνωστο σφάλμα δικτύου")
    for attempt in 0..<retries {
        try Task.checkCancellation()
        do {
            var r = makeRequest(url, headers: headers)
            r.timeoutInterval = 60
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            if code >= 400 { throw JobError.message("HTTP \(code)") }
            return d
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw JobError.cancelled }
            last = error
            if attempt < retries - 1 { try await pause(Double(attempt + 1)) }
        }
    }
    throw last
}

// MARK: - HLS (m3u8) download
enum HLSKind { case ts, fmp4, raw }

private struct HLSSeg { let url: URL; let key: URL?; let iv: Data? }

private func aesDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var outLen = 0
    let outCount = out.count
    let status: CCCryptorStatus = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { d in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count,
                            o.baseAddress, outCount, &outLen)
                }
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    out.removeSubrange(outLen...)
    return out
}

private func attr(_ line: String, _ name: String) -> String? {
    guard let m = regexFirst("(?:^|[:,])" + name + #"=("[^"]*"|[^,]*)"#, line) else { return nil }
    return m[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

/// Downloads every segment of a media playlist into one file. Returns the file and what kind of data it holds.
func downloadHLS(playlistURL: String, headers: [String: String], maxHeight: Int, dst: URL,
                 progress: @escaping (Int, Int) -> Void) async throws -> HLSKind {
    guard var base = URL(string: playlistURL) else { throw JobError.message("Μη έγκυρο m3u8 URL.") }
    var text = String(decoding: try await fetchData(base, headers: headers), as: UTF8.self)

    // Master playlist: choose the best variant that fits the height limit.
    if text.contains("#EXT-X-STREAM-INF") {
        let lines = text.components(separatedBy: .newlines)
        var best: (score: Int, url: URL)? = nil
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.hasPrefix("#EXT-X-STREAM-INF") {
                var j = i + 1
                while j < lines.count && (lines[j].isEmpty || lines[j].hasPrefix("#")) { j += 1 }
                if j < lines.count, let u = URL(string: lines[j].trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL {
                    let bw = Int(attr(l, "BANDWIDTH") ?? "0") ?? 0
                    var h = 0
                    if let r = attr(l, "RESOLUTION"), let hh = r.split(separator: "x").last { h = Int(hh) ?? 0 }
                    let fits = (h == 0 || h <= maxHeight)
                    let score = fits ? 1_000_000_000_000 + bw : -h
                    if best == nil || score > best!.score { best = (score, u) }
                }
                i = j
            }
            i += 1
        }
        guard let b = best else { throw JobError.message("Δεν βρέθηκε ροή στο master m3u8.") }
        base = b.url
        text = String(decoding: try await fetchData(base, headers: headers), as: UTF8.self)
    }

    var segs: [HLSSeg] = []
    var initURL: URL? = nil
    var mediaSeq = 0
    var curKey: URL? = nil
    var curIV: Data? = nil
    var pendingDuration = false
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("#") {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { mediaSeq = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("#EXT-X-BYTERANGE") { throw JobError.message("Το m3u8 με BYTERANGE δεν υποστηρίζεται.") }
            else if line.hasPrefix("#EXT-X-MAP:") {
                if attr(line, "BYTERANGE") != nil { throw JobError.message("Το m3u8 με BYTERANGE δεν υποστηρίζεται.") }
                if let u = attr(line, "URI") { initURL = URL(string: u, relativeTo: base)?.absoluteURL }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attr(line, "METHOD") ?? "NONE"
                if method == "NONE" { curKey = nil; curIV = nil }
                else if method == "AES-128" {
                    if let u = attr(line, "URI") { curKey = URL(string: u, relativeTo: base)?.absoluteURL }
                    if let iv = attr(line, "IV") {
                        var hex = iv.lowercased()
                        if hex.hasPrefix("0x") { hex.removeFirst(2) }
                        while hex.count < 32 { hex = "0" + hex }
                        var d = Data()
                        var idx = hex.startIndex
                        while idx < hex.endIndex {
                            let n = hex.index(idx, offsetBy: 2)
                            d.append(UInt8(hex[idx..<n], radix: 16) ?? 0)
                            idx = n
                        }
                        curIV = d
                    } else { curIV = nil }
                } else { throw JobError.message("Κρυπτογράφηση \(method) δεν υποστηρίζεται.") }
            } else if line.hasPrefix("#EXTINF") { pendingDuration = true }
            continue
        }
        do {
            guard let u = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            var iv = curIV
            if curKey != nil && iv == nil {
                var d = Data(count: 12)
                let seq = UInt32(truncatingIfNeeded: mediaSeq + segs.count)
                d.append(contentsOf: [UInt8(seq >> 24), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)])
                iv = d
            }
            segs.append(HLSSeg(url: u, key: curKey, iv: iv))
            pendingDuration = false
        }
    }
    if segs.isEmpty { throw JobError.message("Το m3u8 δεν έχει τμήματα.") }

    // keys
    var keys: [URL: Data] = [:]
    for s in segs { if let k = s.key, keys[k] == nil { keys[k] = try await fetchData(k, headers: headers) } }

    try? FileManager.default.removeItem(at: dst)
    FileManager.default.createFile(atPath: dst.path, contents: nil)
    let out = try FileHandle(forWritingTo: dst)
    defer { try? out.close() }

    var initData: Data? = nil
    if let iu = initURL {
        let d = try await fetchData(iu, headers: headers)
        out.write(d)
        initData = d
    }

    var kind: HLSKind = initData != nil ? .fmp4 : .ts
    var determined = initData != nil
    let total = segs.count
    var done = 0
    let batch = 6
    var start = 0
    while start < total {
        try Task.checkCancellation()
        let end = min(start + batch, total)
        let results: [Int: Data] = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for idx in start..<end {
                let seg = segs[idx]
                let keyData = seg.key.flatMap { keys[$0] }
                group.addTask {
                    var data = try await fetchData(seg.url, headers: headers, retries: 4)
                    if let k = keyData, let iv = seg.iv {
                        guard let dec = aesDecrypt(data, key: k, iv: iv) else { throw JobError.message("Αποτυχία αποκρυπτογράφησης τμήματος.") }
                        data = dec
                    }
                    return (idx, data)
                }
            }
            var r: [Int: Data] = [:]
            for try await (i, d) in group { r[i] = d }
            return r
        }
        for idx in start..<end {
            guard let d = results[idx] else { continue }
            if !determined {
                determined = true
                if d.first == 0x47 { kind = .ts }
                else if d.count > 8, d.subdata(in: 4..<8) == Data("ftyp".utf8) || d.subdata(in: 4..<8) == Data("moof".utf8) || d.subdata(in: 4..<8) == Data("styp".utf8) { kind = .fmp4 }
                else { kind = .raw }
            }
            out.write(d)
            done += 1
            progress(done, total)
        }
        start = end
    }
    return kind
}

// MARK: - Muxing with AVFoundation
private func exportComposition(_ comp: AVAsset, to dst: URL) async throws {
    try? FileManager.default.removeItem(at: dst)
    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
        throw JobError.message("Δεν δημιουργήθηκε export session.")
    }
    ex.outputURL = dst
    ex.outputFileType = .mp4
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        ex.exportAsynchronously { c.resume() }
    }
    if ex.status != .completed { throw ex.error ?? JobError.message("Η δημιουργία MP4 απέτυχε.") }
}

/// Combines a video file (and optionally a separate audio file) into one MP4 without re-encoding.
func muxToMP4(video: URL, audio: URL?, dst: URL) async throws {
    let comp = AVMutableComposition()
    let vAsset = AVURLAsset(url: video)
    let vTracks = try await vAsset.loadTracks(withMediaType: .video)
    guard let vt = vTracks.first else { throw JobError.message("Το iOS δεν μπορεί να διαβάσει αυτό το βίντεο (μορφή/codec).") }
    let vDur = try await vAsset.load(.duration)
    guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw JobError.message("Σφάλμα composition.")
    }
    try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vt, at: .zero)
    cv.preferredTransform = try await vt.load(.preferredTransform)

    if let au = audio {
        let aAsset = AVURLAsset(url: au)
        let aTracks = try await aAsset.loadTracks(withMediaType: .audio)
        guard let at = aTracks.first else { throw JobError.message("Το iOS δεν μπορεί να διαβάσει τον ήχο (μορφή/codec).") }
        let aDur = try await aAsset.load(.duration)
        guard let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw JobError.message("Σφάλμα composition.")
        }
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: min(aDur, vDur.seconds > 0 ? vDur : aDur)), of: at, at: .zero)
    } else if let at = try await vAsset.loadTracks(withMediaType: .audio).first,
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: at, at: .zero)
    }
    try await exportComposition(comp, to: dst)
}

// MARK: - Video engine (yt-dlp finds the links, Swift downloads + muxes)
final class VideoEngine {
    func run(url: String, nameIn: String, outDir: String, workRoot: String, maxHeight: Int, cb: Reporter) async throws -> [String] {
        let fm = FileManager.default
        let jobDir = (workRoot as NSString).appendingPathComponent("video_" + UUID().uuidString)
        try fm.createDirectory(atPath: jobDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: jobDir) }

        cb.log("== Ανάγνωση βίντεο (yt-dlp) ==")
        cb.progress(0, 0, "Ανάγνωση βίντεο (yt-dlp)...")
        let info = try await extractVideoInfo(url: url, maxHeight: maxHeight, workDir: jobDir, cb: cb)
        let name = safeName(nameIn.isEmpty ? info.title : nameIn)
        cb.log("Τίτλος: \(info.title) | Site: \(info.extractor) | Ροές: \(info.streams.count)")
        for s in info.streams {
            cb.log(" • \(s.proto) \(s.ext) \(s.height > 0 ? "\(s.height)p" : "") v=\(s.vcodec) a=\(s.acodec)")
        }

        let steps = 1000
        let n = info.streams.count
        let dlShare = 880
        var pieces: [(url: URL, ext: String, export: Bool)] = []

        for (idx, s) in info.streams.enumerated() {
            try Task.checkCancellation()
            if s.hasFragments && !s.proto.hasPrefix("m3u8") {
                throw JobError.message("Αυτή η ροή (DASH/fragments) δεν υποστηρίζεται ακόμα. Δοκίμασε άλλη ποιότητα.")
            }
            guard let u = URL(string: s.url) else { throw JobError.message("Μη έγκυρο URL ροής.") }
            let base = idx * dlShare / n
            let share = dlShare / n
            let label = n > 1 ? (idx == 0 ? "βίντεο" : "ήχος") : "αρχείο"
            let rawPath = URL(fileURLWithPath: jobDir).appendingPathComponent("part\(idx)")

            if s.proto.hasPrefix("m3u8") {
                cb.log("Λήψη \(label) (HLS)...")
                let kind = try await downloadHLS(playlistURL: s.url, headers: s.headers, maxHeight: maxHeight,
                                                 dst: rawPath.appendingPathExtension("hls")) { done, total in
                    cb.progress(base + share * done / max(total, 1), steps, "Λήψη \(label) \(done)/\(total)")
                    cb.download(done, total)
                }
                let hls = rawPath.appendingPathExtension("hls")
                switch kind {
                case .ts:
                    cb.log("Μετατροπή MPEG-TS σε MP4...")
                    cb.progress(base + share, steps, "Μετατροπή \(label)...")
                    let mp4 = rawPath.appendingPathExtension("mp4")
                    let tmp = URL(fileURLWithPath: jobDir).appendingPathComponent("tsr\(idx)")
                    try await Task.detached(priority: .userInitiated) {
                        try TSRemuxer.remux(src: hls, dst: mp4, tmpDir: tmp, log: { cb.log($0) })
                    }.value
                    try? fm.removeItem(at: hls)
                    try? fm.removeItem(at: tmp)
                    pieces.append((mp4, "mp4", false))
                case .fmp4:
                    let mp4 = rawPath.appendingPathExtension("mp4")
                    try fm.moveItem(at: hls, to: mp4)
                    pieces.append((mp4, "mp4", true))
                case .raw:
                    let aac = rawPath.appendingPathExtension("aac")
                    try fm.moveItem(at: hls, to: aac)
                    pieces.append((aac, "aac", false))
                }
            } else {
                var ext = s.ext.lowercased()
                if ext.isEmpty || ext.count > 5 { ext = "mp4" }
                let dst = rawPath.appendingPathExtension(ext)
                cb.log("Λήψη \(label)...")
                try await FileDownloader().download(makeRequest(u, headers: s.headers), to: dst) { got, exp in
                    let frac = exp > 0 ? Double(got) / Double(exp) : 0
                    let mb = Double(got) / 1_048_576
                    cb.progress(base + Int(Double(share) * frac), exp > 0 ? steps : 0,
                                exp > 0 ? "Λήψη \(label) \(Int(frac * 100))% (\(Int(mb)) MB)" : "Λήψη \(label) \(Int(mb)) MB")
                }
                pieces.append((dst, ext, false))
            }
        }

        try Task.checkCancellation()
        cb.progress(dlShare, steps, "Δημιουργία MP4...")
        cb.log("== Δημιουργία τελικού αρχείου ==")
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let finalURL = URL(fileURLWithPath: outDir).appendingPathComponent(name + ".mp4")
        let native: Set<String> = ["mp4", "m4v", "mov", "m4a", "aac"]
        var outputs: [String] = []

        do {
            guard pieces.allSatisfy({ native.contains($0.ext) }) else {
                throw JobError.message("Μορφή \(pieces.map { $0.ext }.joined(separator: "+")) (όχι MP4/H.264).")
            }
            if pieces.count == 1, pieces[0].ext == "mp4", !pieces[0].export {
                // Already a plain MP4 (or a remuxed one). Make sure iOS can read it; move it as is.
                try? fm.removeItem(at: finalURL)
                try fm.moveItem(at: pieces[0].url, to: finalURL)
            } else if pieces.count == 1 {
                try await muxToMP4(video: pieces[0].url, audio: nil, dst: finalURL)
            } else {
                let video = pieces[0].url
                let audio = pieces.count > 1 ? pieces[1].url : nil
                try await muxToMP4(video: video, audio: audio, dst: finalURL)
            }
            outputs = [finalURL.path]
            cb.log("Έτοιμο MP4.")
        } catch JobError.cancelled {
            throw JobError.cancelled
        } catch {
            // Could not mux: keep the downloaded files so nothing is lost.
            cb.log("Δεν έγινε συνένωση σε MP4 (\(error.localizedDescription)). Αποθηκεύω τα αρχεία ξεχωριστά.")
            for (i, p) in pieces.enumerated() {
                let suffix = pieces.count > 1 ? (i == 0 ? "_video" : "_audio") : ""
                let dst = URL(fileURLWithPath: outDir).appendingPathComponent(name + suffix + "." + p.ext)
                try? fm.removeItem(at: dst)
                try fm.moveItem(at: p.url, to: dst)
                outputs.append(dst.path)
            }
        }
        cb.progress(steps, steps, "Έτοιμο ✔")
        return outputs
    }
}
