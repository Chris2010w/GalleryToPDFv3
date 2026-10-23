import Foundation

/// One image to download: candidate URLs are tried in order (a 404 moves on to the next one).
struct DLItem { let index: Int; let candidates: [String] }

/// Shared download loop for the sites that give us a full list of image URLs up front.
func downloadItems(_ items: [DLItem], f: Fetcher, name: String, title: String, outDir: String, workRoot: String,
                   referer: String?, mode: String, delay: Double, cb: Reporter) async throws -> [String] {
    let total = items.count
    let imgDir = (workRoot as NSString).appendingPathComponent(name)
    try FileManager.default.createDirectory(atPath: imgDir, withIntermediateDirectories: true)
    let steps = stepsFor(total, mode)
    var failed: [Int] = []
    var firstError = ""

    func fetchOne(_ it: DLItem) async throws {
        var last: Error = JobError.message("δεν βρέθηκε η εικόνα")
        for url in it.candidates {
            try Task.checkCancellation()
            var ext = ((URL(string: url)?.lastPathComponent ?? "") as NSString).pathExtension.lowercased()
            if !imgExt.contains(ext) { ext = "jpg" }
            let dst = (imgDir as NSString).appendingPathComponent(String(format: "%04d.%@", it.index, ext))
            do {
                try await f.download(url, to: dst, referer: referer)
                return
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                last = error
            }
        }
        throw last
    }

    cb.log("== Λήψη εικόνων ==")
    for it in items {
        try Task.checkCancellation()
        if alreadyHave(imgDir, it.index) {
            cb.log("\(it.index)/\(total): υπάρχει ήδη, το προσπερνάω")
        } else {
            do {
                try await fetchOne(it)
                cb.log("\(it.index)/\(total): OK")
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                failed.append(it.index)
                if firstError.isEmpty { firstError = error.localizedDescription }
                cb.log("\(it.index)/\(total): ΑΠΟΤΥΧΙΑ (\(error.localizedDescription))")
            }
            try await pause(delay)
        }
        cb.progress(it.index, steps, "Λήψη \(it.index)/\(total)")
        cb.download(it.index, total)
    }

    if !failed.isEmpty {
        cb.log("== Δεύτερη προσπάθεια για \(failed.count) σελίδες ==")
        var still: [Int] = []
        for i in failed {
            try Task.checkCancellation()
            try await pause(max(delay, 1.0) * 2)
            do {
                try await fetchOne(items[i - 1])
                cb.log("\(i)/\(total): OK (2η προσπάθεια)")
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                still.append(i)
                cb.log("\(i)/\(total): ξανά ΑΠΟΤΥΧΙΑ (\(error.localizedDescription))")
            }
        }
        failed = still
    }

    if listImageNames(imgDir).isEmpty {
        if firstError.contains("403") || firstError.lowercased().contains("cloudflare") {
            throw JobError.message("Το site μπλόκαρε το αίτημα (Cloudflare / 403). Δοκίμασε αργότερα.")
        }
        throw JobError.message("Δεν κατέβηκε καμία εικόνα. Δες το κείμενο παραπάνω για το λόγο.")
    }
    return try finishJob(imgDir: imgDir, name: name, title: title, outDir: outDir, workRoot: workRoot,
                         total: total, failed: failed, mode: mode, cb: cb)
}

private let letterExt: [String: String] = ["j": "jpg", "p": "png", "g": "gif", "w": "webp", "a": "avif"]

// MARK: - nHentai
final class NHentaiEngine {
    let f = Fetcher()

    func run(url: String, nameIn: String, outDir: String, workRoot: String, mode: String, delay: Double, cb: Reporter) async throws -> [String] {
        guard let m = regexFirst(#"nhentai\.net/g/(\d+)"#, url) else {
            throw JobError.message("Το link δεν μοιάζει με gallery του nhentai.net")
        }
        let gid = m[1]
        cb.log("== Ανάγνωση gallery ==")
        cb.progress(0, 0, "Ανάγνωση gallery...")
        let data: Data
        do { data = try await f.data("https://nhentai.net/api/gallery/\(gid)", referer: "https://nhentai.net/") }
        catch JobError.cancelled { throw JobError.cancelled }
        catch {
            let msg = error.localizedDescription
            if msg.contains("403") || msg.contains("503") {
                throw JobError.message("Το site μπλόκαρε το αίτημα (Cloudflare / 403). Δοκίμασε αργότερα.")
            }
            throw JobError.message("Δεν μπόρεσα να διαβάσω το gallery (\(msg)).")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = obj["media_id"] as? String ?? (obj["media_id"] as? Int).map(String.init),
              let images = obj["images"] as? [String: Any],
              let pages = images["pages"] as? [[String: Any]], !pages.isEmpty else {
            throw JobError.message("Το nhentai δεν επέστρεψε τα δεδομένα του gallery.")
        }
        let name = safeName(nameIn.isEmpty ? "nHentai_\(gid)" : nameIn)
        cb.log("Σελίδες: \(pages.count)")
        let hosts = ["i.nhentai.net", "i1.nhentai.net", "i2.nhentai.net", "i3.nhentai.net", "i4.nhentai.net", "i5.nhentai.net", "i7.nhentai.net"]
        var items: [DLItem] = []
        for (i, p) in pages.enumerated() {
            let n = i + 1
            let ext = letterExt[(p["t"] as? String) ?? "j"] ?? "jpg"
            items.append(DLItem(index: n, candidates: hosts.map { "https://\($0)/galleries/\(media)/\(n).\(ext)" }))
        }
        return try await downloadItems(items, f: f, name: name, title: name, outDir: outDir, workRoot: workRoot,
                                       referer: "https://nhentai.net/", mode: mode, delay: delay, cb: cb)
    }
}

// MARK: - HentaiFox / HentaiEra (same site engine)
final class ImFamilyEngine {
    let f = Fetcher()

    private func inputValue(_ id: String, _ html: String) -> String? {
        let pats = [#"id="\#(id)"[^>]*value="([^"]*)""#, #"name="\#(id)"[^>]*value="([^"]*)""#, #"value="([^"]*)"[^>]*id="\#(id)""#]
        for p in pats { if let m = regexFirst(p, html), !m[1].isEmpty { return m[1] } }
        return nil
    }

    func run(site: SiteInfo, url: String, nameIn: String, outDir: String, workRoot: String, mode: String, delay: Double, cb: Reporter) async throws -> [String] {
        let domain = site.hosts[0]
        guard let m = regexFirst(#"/gallery/(\d+)"#, url) else { throw JobError.message("Το link δεν μοιάζει με gallery του \(site.name).") }
        let gid = m[1]
        cb.log("== Ανάγνωση gallery ==")
        cb.progress(0, 0, "Ανάγνωση gallery...")
        let html: String
        do { html = try await f.text("https://\(domain)/gallery/\(gid)/", referer: "https://\(domain)/") }
        catch JobError.cancelled { throw JobError.cancelled }
        catch {
            let msg = error.localizedDescription
            if msg.contains("403") || msg.contains("503") {
                throw JobError.message("Το site μπλόκαρε το αίτημα (Cloudflare / 403). Δοκίμασε αργότερα.")
            }
            throw JobError.message("Δεν μπόρεσα να ανοίξω το gallery (\(msg)).")
        }

        // Per-page extension letters: g_th = {"1":"j,1280,1810", ...}
        var exts: [Int: String] = [:]
        if let g = regexFirst(#"parseJSON\('(\{.*?\})'\)"#, html, dotAll: true),
           let d = g[1].data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            for (k, v) in dict { if let n = Int(k), let l = v.split(separator: ",").first { exts[n] = letterExt[String(l)] ?? "jpg" } }
        }
        var dir = inputValue("load_dir", html)
        var id = inputValue("load_id", html)
        let server = inputValue("load_server", html)
        var pageCount = Int(inputValue("load_pages", html) ?? "") ?? exts.count
        var thumbHost: String? = nil
        var thumbExt = "jpg"
        if dir == nil || id == nil || pageCount == 0 {
            // Fallback: read the thumbnail URLs, e.g. //i.hentaifox.com/001/12345/1t.jpg
            if let t = regexFirst(#"//([a-z0-9.]+)/(\w+)/(\d+)/1t\.(\w+)"#, html) {
                thumbHost = t[1]; dir = t[2]; id = t[3]; thumbExt = t[4]
            }
            if pageCount == 0 {
                pageCount = Set(regexAll(#"/\#(id ?? gid)/(\d+)t\.\w+"#, html).map { $0[1] }).count
            }
        }
        guard let d = dir, let i = id, pageCount > 0 else {
            throw JobError.message("Δεν βρέθηκαν εικόνες. Η σελίδα του \(site.name) άλλαξε μορφή ή το gallery δεν υπάρχει.")
        }
        let name = safeName(nameIn.isEmpty ? "\(site.name)_\(gid)" : nameIn)
        cb.log("Σελίδες: \(pageCount)")

        var hosts: [String] = []
        if let s = server { hosts.append("m\(s).\(domain)") }
        if let th = thumbHost { hosts.append(th) }
        hosts += ["i.\(domain)", "i2.\(domain)", "i3.\(domain)"]
        var seenH = Set<String>()
        hosts = hosts.filter { seenH.insert($0).inserted }

        var items: [DLItem] = []
        for n in 1...pageCount {
            var order = [exts[n] ?? thumbExt]
            for e in ["jpg", "webp", "png", "gif"] where !order.contains(e) { order.append(e) }
            var c: [String] = []
            for e in order { for h in hosts.prefix(2) { c.append("https://\(h)/\(d)/\(i)/\(n).\(e)") } }
            items.append(DLItem(index: n, candidates: c))
        }
        return try await downloadItems(items, f: f, name: name, title: name, outDir: outDir, workRoot: workRoot,
                                       referer: "https://\(domain)/", mode: mode, delay: delay, cb: cb)
    }
}

// MARK: - Hitomi.la
final class HitomiEngine {
    let f = Fetcher()

    private struct GG { var b: String; var base: Int; var setVal: Int; var cases: Set<Int> }

    private func parseGG(_ js: String) -> GG {
        let b = regexFirst(#"b:\s*'(\d+)/?'"#, js)?[1] ?? regexFirst(#"gg\.b\s*=\s*'(\d+)/?'"#, js)?[1] ?? ""
        let base = Int(regexFirst(#"var o = (\d)"#, js)?[1] ?? "0") ?? 0
        let setVal = Int(regexFirst(#"o = (\d);\s*break"#, js)?[1] ?? "1") ?? 1
        let cases = Set(regexAll(#"case (\d+):"#, js).compactMap { Int($0[1]) })
        return GG(b: b, base: base, setVal: setVal, cases: cases)
    }

    func run(url: String, nameIn: String, outDir: String, workRoot: String, mode: String, delay: Double, cb: Reporter) async throws -> [String] {
        guard let m = regexFirst(#"(\d+)\.html"#, url) ?? regexFirst(#"/(\d+)(?:[/?#]|$)"#, url) else {
            throw JobError.message("Δεν βρήκα αριθμό gallery στο link του Hitomi.")
        }
        let gid = m[1]
        cb.log("== Ανάγνωση gallery ==")
        cb.progress(0, 0, "Ανάγνωση gallery...")
        f.extraHeaders["Origin"] = "https://hitomi.la"

        var infoText: String? = nil
        for host in ["ltn.gold-usergeneratedcontent.net", "ltn.hitomi.la"] {
            do { infoText = try await f.text("https://\(host)/galleries/\(gid).js", referer: "https://hitomi.la/", retries: 2); break }
            catch JobError.cancelled { throw JobError.cancelled }
            catch { cb.log("\(host): \(error.localizedDescription)") }
        }
        guard let txt = infoText, let brace = txt.firstIndex(of: "{"),
              let jd = String(txt[brace...]).data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
              let files = info["files"] as? [[String: Any]], !files.isEmpty else {
            throw JobError.message("Δεν μπόρεσα να διαβάσω τα δεδομένα του gallery από το Hitomi.")
        }
        var ggText: String? = nil
        for host in ["ltn.gold-usergeneratedcontent.net", "ltn.hitomi.la"] {
            if let t = try? await f.text("https://\(host)/gg.js", referer: "https://hitomi.la/", retries: 2) { ggText = t; break }
        }
        guard let ggJS = ggText else { throw JobError.message("Δεν μπόρεσα να διαβάσω το gg.js του Hitomi.") }
        let gg = parseGG(ggJS)
        if gg.b.isEmpty { throw JobError.message("Το Hitomi άλλαξε μορφή (gg.js). Χρειάζεται ενημέρωση της εφαρμογής.") }

        let name = safeName(nameIn.isEmpty ? "Hitomi.la_\(gid)" : nameIn)
        cb.log("Σελίδες: \(files.count)")
        var items: [DLItem] = []
        for (idx, file) in files.enumerated() {
            guard let hash = file["hash"] as? String, hash.count >= 3 else { continue }
            let last = String(hash.suffix(1)), mid = String(hash.suffix(3).prefix(2))
            let g = Int(last + mid, radix: 16) ?? 0
            let o = gg.cases.contains(g) ? gg.setVal : gg.base
            let n = idx + 1
            let c = [
                "https://w\(1 + o).gold-usergeneratedcontent.net/\(gg.b)/\(g)/\(hash).webp",
                "https://\(o == 0 ? "a" : "b")a.hitomi.la/webp/\(gg.b)/\(g)/\(hash).webp",
            ]
            items.append(DLItem(index: n, candidates: c))
        }
        return try await downloadItems(items, f: f, name: name, title: name, outDir: outDir, workRoot: workRoot,
                                       referer: "https://hitomi.la/", mode: mode, delay: delay, cb: cb)
    }
}

// MARK: - Entry point (port of run_job)
func runJob(url rawURL: String, name: String, outDir: String, workRoot: String, mode: String, delay: Double, cookie: String = "", quality: Int = 1080, cb: Reporter) async throws -> [String] {
    let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let site = detectSite(url) else { throw JobError.message("Δεν αναγνώρισα το site αυτού του link.") }
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: workRoot, withIntermediateDirectories: true)
    do {
        switch site.engine {
        case "ehentai":
            return try await EHentaiEngine(cookie: cookie).run(url: url, nameIn: name, outDir: outDir, workRoot: workRoot, mode: mode, delay: delay, cb: cb)
        case "nhentai":
            return try await NHentaiEngine().run(url: url, nameIn: name, outDir: outDir, workRoot: workRoot, mode: mode, delay: delay, cb: cb)
        case "ytdlp":
            return try await VideoEngine().run(url: url, nameIn: name, outDir: outDir, workRoot: workRoot, maxHeight: quality, cb: cb)
        case "e621":
            return try await E621Engine().run(url: url, nameIn: name, outDir: outDir, workRoot: workRoot, mode: mode, delay: delay, cb: cb)
        case "rule34xyz":
            return try await Rule34XYZEngine().run(url: url, nameIn: name, outDir: outDir, workRoot: workRoot, mode: mode, delay: delay, cb: cb)
        case "hitomi":
            return try await HitomiEngine().run(url: url, nameIn: name, outDir: outDir, workRoot: workRoot, mode: mode, delay: delay, cb: cb)
        default:
            return try await ImFamilyEngine().run(site: site, url: url, nameIn: name, outDir: outDir, workRoot: workRoot, mode: mode, delay: delay, cb: cb)
        }
    } catch is CancellationError {
        throw JobError.cancelled
    }
}
