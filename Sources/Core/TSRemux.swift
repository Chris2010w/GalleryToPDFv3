import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Converts an MPEG-TS file (H.264 + AAC, what most HLS sites serve) into a normal MP4
/// without re-encoding. iOS has no ffmpeg, so we demux the TS ourselves and let
/// AVAssetWriter write the MP4 from the compressed samples.
final class TSRemuxer {
    private struct VSample { var off: Int; var size: Int; var dts: Int64; var pts: Int64; var sync: Bool }
    private struct ASample { var off: Int; var size: Int; var pts: Int64 }

    private static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    // elementary stream state
    private var vSamples: [VSample] = []
    private var aSamples: [ASample] = []
    private var vOut: FileHandle!
    private var aOut: FileHandle!
    private var vPos = 0
    private var aPos = 0
    private var sps: [UInt8]? = nil
    private var pps: [UInt8]? = nil
    private var aacProfile = 1, aacFreqIdx = 4, aacChannels = 2
    private var haveAAC = false
    private var lastDTS: Int64? = nil
    private var lastAPTS: Int64? = nil
    private var nextAPTS: Int64? = nil

    private func ptsAt(_ b: [UInt8], _ o: Int) -> Int64 {
        let a = Int64((b[o] >> 1) & 7) << 30
        let c = Int64(b[o + 1]) << 22
        let d = Int64(b[o + 2] >> 1) << 15
        let e = Int64(b[o + 3]) << 7
        let f = Int64(b[o + 4] >> 1)
        return a | c | d | e | f
    }

    /// Keeps a 33-bit 90 kHz timestamp counting upwards across wrap-arounds.
    private func unwrap(_ v: Int64, _ last: Int64?) -> Int64 {
        guard let l = last else { return v }
        let span: Int64 = 1 << 33
        var x = v + (l / span) * span
        if x < l - span / 2 { x += span } else if x > l + span / 2 { x -= span }
        return x
    }

    // MARK: PES handling
    private func handlePES(_ b: [UInt8], isVideo: Bool) {
        if b.count < 9 || b[0] != 0 || b[1] != 0 || b[2] != 1 { return }
        let flags = b[7] >> 6
        let hl = Int(b[8])
        var pts: Int64? = nil, dts: Int64? = nil
        if flags & 2 != 0, b.count >= 14 { pts = ptsAt(b, 9) }
        if flags == 3, b.count >= 19 { dts = ptsAt(b, 14) }
        let plen = (Int(b[4]) << 8) | Int(b[5])
        let end = plen == 0 ? b.count : min(b.count, 6 + plen)
        let start = 9 + hl
        if start >= end { return }
        if isVideo { handleVideo(b, start, end, pts, dts) } else { handleAudio(b, start, end, pts) }
    }

    private func handleVideo(_ b: [UInt8], _ start: Int, _ end: Int, _ ptsIn: Int64?, _ dtsIn: Int64?) {
        // find Annex-B start codes
        var starts: [Int] = []
        var j = start
        while j + 2 < end {
            if b[j] == 0 && b[j + 1] == 0 && b[j + 2] == 1 { starts.append(j + 3); j += 3 } else { j += 1 }
        }
        if starts.isEmpty { return }
        var out = [UInt8]()
        out.reserveCapacity(end - start)
        var sync = false
        var hasSlice = false
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : end
            while e > s && b[e - 1] == 0 { e -= 1 }
            if e <= s { continue }
            let type = b[s] & 0x1F
            switch type {
            case 7: if sps == nil { sps = Array(b[s..<e]) }
            case 8: if pps == nil { pps = Array(b[s..<e]) }
            case 9, 12: break              // access unit delimiter, filler
            default:
                if type == 5 { sync = true; hasSlice = true }
                if type == 1 { hasSlice = true }
                let n = e - s
                out.append(UInt8((n >> 24) & 0xFF)); out.append(UInt8((n >> 16) & 0xFF))
                out.append(UInt8((n >> 8) & 0xFF)); out.append(UInt8(n & 0xFF))
                out.append(contentsOf: b[s..<e])
            }
        }
        if !hasSlice || out.isEmpty { return }
        guard let pts0 = ptsIn ?? dtsIn else { return }
        let dts0 = dtsIn ?? pts0
        let dts = unwrap(dts0, lastDTS)
        lastDTS = dts
        var diff = pts0 - dts0
        let span: Int64 = 1 << 33
        if diff > span / 2 { diff -= span } else if diff < -span / 2 { diff += span }
        vOut.write(Data(out))
        vSamples.append(VSample(off: vPos, size: out.count, dts: dts, pts: dts + diff, sync: sync))
        vPos += out.count
    }

    private func handleAudio(_ b: [UInt8], _ start: Int, _ end: Int, _ ptsIn: Int64?) {
        let pts: Int64
        if let p = ptsIn { pts = unwrap(p, lastAPTS) } else if let n = nextAPTS { pts = n } else { return }
        var i = start
        var k: Int64 = 0
        var rate: Int64 = 44100
        while i + 7 <= end {
            if !(b[i] == 0xFF && (b[i + 1] & 0xF0) == 0xF0) { break }
            let prot = b[i + 1] & 1
            let profile = Int((b[i + 2] >> 6) & 3)
            let sfi = Int((b[i + 2] >> 2) & 0xF)
            let ch = Int(((b[i + 2] & 1) << 2) | (b[i + 3] >> 6))
            let flen = (Int(b[i + 3] & 3) << 11) | (Int(b[i + 4]) << 3) | Int(b[i + 5] >> 5)
            let hdr = prot == 1 ? 7 : 9
            if flen <= hdr || i + flen > end || sfi >= Self.sampleRates.count { break }
            if !haveAAC { aacProfile = profile; aacFreqIdx = sfi; aacChannels = max(ch, 1); haveAAC = true }
            rate = Int64(Self.sampleRates[aacFreqIdx])
            let t = pts + k * 1024 * 90000 / rate
            let raw = Array(b[(i + hdr)..<(i + flen)])
            aOut.write(Data(raw))
            aSamples.append(ASample(off: aPos, size: raw.count, pts: t))
            aPos += raw.count
            k += 1
            i += flen
        }
        if k > 0 {
            lastAPTS = pts
            nextAPTS = pts + k * 1024 * 90000 / rate
        }
    }

    // MARK: demux
    private func demux(_ src: URL) throws {
        let data = try Data(contentsOf: src, options: .alwaysMapped)
        let n = data.count
        var pos = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            while pos + 376 < n && !(p[pos] == 0x47 && p[pos + 188] == 0x47 && p[pos + 376] == 0x47) { pos += 1 }
        }
        if pos + 376 >= n { throw JobError.message("Το αρχείο δεν είναι έγκυρο MPEG-TS.") }

        var pmtPID = -1, vPID = -1, aPID = -1
        var unsupportedVideo = false
        var bufs: [Int: [UInt8]] = [:]

        func flush(_ pid: Int) {
            guard let b = bufs[pid], !b.isEmpty else { return }
            handlePES(b, isVideo: pid == vPID)
            bufs[pid] = []
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var off = pos
            while off + 188 <= n {
                defer { off += 188 }
                if p[off] != 0x47 { continue }
                let pusi = (p[off + 1] >> 6) & 1 == 1
                let pid = (Int(p[off + 1] & 0x1F) << 8) | Int(p[off + 2])
                let afc = (p[off + 3] >> 4) & 3
                var i = off + 4
                if afc & 2 != 0 { i += 1 + Int(p[off + 4]) }
                if afc & 1 == 0 || i >= off + 188 { continue }
                let end = off + 188

                if pid == 0 && pusi {
                    let t = i + 1 + Int(p[i])
                    if t + 12 < end {
                        // first program entry that is not the network PID
                        var q = t + 8
                        let sectionEnd = min(end, t + 3 + (((Int(p[t + 1]) & 0xF) << 8) | Int(p[t + 2])) - 4)
                        while q + 4 <= sectionEnd {
                            let prog = (Int(p[q]) << 8) | Int(p[q + 1])
                            if prog != 0 { pmtPID = ((Int(p[q + 2]) & 0x1F) << 8) | Int(p[q + 3]); break }
                            q += 4
                        }
                    }
                } else if pid == pmtPID && pusi && vPID < 0 {
                    let t = i + 1 + Int(p[i])
                    if t + 12 < end {
                        let sl = ((Int(p[t + 1]) & 0xF) << 8) | Int(p[t + 2])
                        let pil = ((Int(p[t + 10]) & 0xF) << 8) | Int(p[t + 11])
                        var q = t + 12 + pil
                        let sectionEnd = min(end, t + 3 + sl - 4)
                        while q + 5 <= sectionEnd {
                            let st = p[q]
                            let ep = ((Int(p[q + 1]) & 0x1F) << 8) | Int(p[q + 2])
                            let el = ((Int(p[q + 3]) & 0xF) << 8) | Int(p[q + 4])
                            if st == 0x1B && vPID < 0 { vPID = ep }
                            if st == 0x24 && vPID < 0 { unsupportedVideo = true }
                            if st == 0x0F && aPID < 0 { aPID = ep }
                            q += 5 + el
                        }
                    }
                } else if pid == vPID || pid == aPID {
                    if pusi { flush(pid) }
                    bufs[pid, default: []].append(contentsOf: UnsafeBufferPointer(start: p.baseAddress! + i, count: end - i))
                }
            }
        }
        flush(vPID); flush(aPID)
        if vSamples.isEmpty {
            throw JobError.message(unsupportedVideo
                ? "Το βίντεο είναι HEVC/H.265 σε MPEG-TS. Δεν υποστηρίζεται ακόμα."
                : "Δεν βρέθηκε βίντεο H.264 μέσα στο MPEG-TS.")
        }
    }

    // MARK: format descriptions
    private func videoDesc() throws -> CMVideoFormatDescription {
        guard let s = sps, let p = pps else { throw JobError.message("Λείπουν τα SPS/PPS του βίντεο.") }
        var desc: CMVideoFormatDescription?
        var status: OSStatus = -1
        s.withUnsafeBufferPointer { sb in
            p.withUnsafeBufferPointer { pb in
                let ptrs: [UnsafePointer<UInt8>] = [sb.baseAddress!, pb.baseAddress!]
                let sizes = [s.count, p.count]
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let d = desc else { throw JobError.message("Αποτυχία δημιουργίας περιγραφής βίντεο (\(status)).") }
        return d
    }

    private func audioDesc() throws -> CMAudioFormatDescription {
        let rate = Self.sampleRates[aacFreqIdx]
        let ot = aacProfile + 1
        let asc: [UInt8] = [UInt8((ot << 3) | (aacFreqIdx >> 1)), UInt8(((aacFreqIdx & 1) << 7) | (aacChannels << 3))]
        let dsi: [UInt8] = [0x05, 0x02] + asc
        let dcd: [UInt8] = [0x04, UInt8(13 + dsi.count), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + dsi
        let sl: [UInt8] = [0x06, 0x01, 0x02]
        let esds: [UInt8] = [0x03, UInt8(3 + dcd.count + sl.count), 0, 0, 0] + dcd + sl
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(ot),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(aacChannels), mBitsPerChannel: 0, mReserved: 0)
        var desc: CMAudioFormatDescription?
        let status = esds.withUnsafeBufferPointer { cp in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cp.count, magicCookie: cp.baseAddress,
                                           extensions: nil, formatDescriptionOut: &desc)
        }
        guard status == noErr, let d = desc else { throw JobError.message("Αποτυχία δημιουργίας περιγραφής ήχου (\(status)).") }
        return d
    }

    private func makeSample(_ data: Data, _ desc: CMFormatDescription, pts: CMTime, dts: CMTime,
                            dur: CMTime, sync: Bool) -> CMSampleBuffer? {
        let len = data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: len, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let b = block else { return nil }
        let rep: OSStatus = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: len)
        }
        if rep != kCMBlockBufferNoErr { return nil }
        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var size = len
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: b, formatDescription: desc,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        guard st == noErr, let buf = sb else { return nil }
        if !sync, let arr = CMSampleBufferGetSampleAttachmentsArray(buf, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buf
    }

    // MARK: public entry
    /// Blocking. Run it from a background thread.
    static func remux(src: URL, dst: URL, tmpDir: URL, log: @escaping (String) -> Void = { _ in }) throws {
        let r = TSRemuxer()
        try r.run(src: src, dst: dst, tmpDir: tmpDir, log: log)
    }

    private func run(src: URL, dst: URL, tmpDir: URL, log: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let vURL = tmpDir.appendingPathComponent("v.es"), aURL = tmpDir.appendingPathComponent("a.es")
        fm.createFile(atPath: vURL.path, contents: nil)
        fm.createFile(atPath: aURL.path, contents: nil)
        vOut = try FileHandle(forWritingTo: vURL)
        aOut = try FileHandle(forWritingTo: aURL)
        defer { try? vOut.close(); try? aOut.close() }

        log("MPEG-TS: ανάγνωση...")
        try demux(src)
        log("MPEG-TS: \(vSamples.count) καρέ βίντεο, \(aSamples.count) πακέτα ήχου")

        let vDesc = try videoDesc()
        var aDesc: CMAudioFormatDescription? = nil
        if haveAAC && !aSamples.isEmpty { aDesc = try audioDesc() }

        // shift everything so the timeline starts at zero
        var base = vSamples.map { min($0.dts, $0.pts) }.min() ?? 0
        if aDesc != nil, let a = aSamples.first { base = min(base, a.pts) }
        let rate = Int64(Self.sampleRates[aacFreqIdx])

        try? fm.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vDesc)
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput? = nil
        if let ad = aDesc {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: ad)
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aIn = i
        }
        guard writer.startWriting() else { throw writer.error ?? JobError.message("Δεν ξεκίνησε η εγγραφή MP4.") }
        writer.startSession(atSourceTime: .zero)

        let vRead = try FileHandle(forReadingFrom: vURL)
        let aRead = try FileHandle(forReadingFrom: aURL)
        defer { try? vRead.close(); try? aRead.close() }

        var vi = 0, ai = 0
        let vCount = vSamples.count, aCount = aSamples.count
        var lastProgress = Date()
        var lastLogged = -1

        /// Appends the next video sample. Returns false if the writer is not ready for it yet.
        func feedVideo() throws -> Bool {
            guard vIn.isReadyForMoreMediaData else { return false }
            let s = vSamples[vi]
            let nextDTS = vi + 1 < vCount ? vSamples[vi + 1].dts : s.dts + (vi > 0 ? s.dts - vSamples[vi - 1].dts : 3000)
            let dur = max(nextDTS - s.dts, 1)
            try vRead.seek(toOffset: UInt64(s.off))
            let d = try vRead.read(upToCount: s.size) ?? Data()
            if d.count == s.size, let sb = makeSample(d, vDesc, pts: CMTime(value: s.pts - base, timescale: 90000),
                                                      dts: CMTime(value: s.dts - base, timescale: 90000),
                                                      dur: CMTime(value: dur, timescale: 90000), sync: s.sync) {
                if !vIn.append(sb) { throw writer.error ?? JobError.message("Σφάλμα εγγραφής βίντεο.") }
            }
            vi += 1
            return true
        }
        func feedAudio() throws -> Bool {
            guard let input = aIn, let ad = aDesc, input.isReadyForMoreMediaData else { return false }
            let s = aSamples[ai]
            try aRead.seek(toOffset: UInt64(s.off))
            let d = try aRead.read(upToCount: s.size) ?? Data()
            let ptsT = CMTime(value: (s.pts - base) * rate / 90000, timescale: CMTimeScale(rate))
            if d.count == s.size, let sb = makeSample(d, ad, pts: ptsT, dts: .invalid,
                                                      dur: CMTime(value: 1024, timescale: CMTimeScale(rate)), sync: true) {
                if !input.append(sb) { throw writer.error ?? JobError.message("Σφάλμα εγγραφής ήχου.") }
            }
            ai += 1
            return true
        }

        while vi < vCount || (aIn != nil && ai < aCount) {
            if writer.status == .failed { throw writer.error ?? JobError.message("Σφάλμα εγγραφής MP4.") }
            let haveV = vi < vCount
            let haveA = aIn != nil && ai < aCount
            let vTime = haveV ? Double(vSamples[vi].dts - base) / 90000.0 : Double.infinity
            let aTime = haveA ? Double(aSamples[ai].pts - base) / 90000.0 : Double.infinity
            var did = false
            // Prefer the earlier sample, but if that input is blocked, feed the other one so the
            // writer's interleaving never deadlocks.
            if vTime <= aTime {
                did = try feedVideo()
                if !did && haveA { did = try feedAudio() }
            } else {
                did = try feedAudio()
                if !did && haveV { did = try feedVideo() }
            }
            if did {
                lastProgress = Date()
                let pct = (vi * 100) / max(vCount, 1)
                if pct / 10 != lastLogged { lastLogged = pct / 10; log("MP4: \(pct)%") }
            } else {
                if Date().timeIntervalSince(lastProgress) > 60 {
                    throw JobError.message("Η εγγραφή MP4 κόλλησε (το iOS δεν δέχεται δεδομένα).")
                }
                Thread.sleep(forTimeInterval: 0.003)
            }
        }
        vIn.markAsFinished()
        aIn?.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? JobError.message("Η δημιουργία MP4 απέτυχε.") }
    }
}
