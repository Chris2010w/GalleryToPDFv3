import Foundation

final class EHentaiEngine {
    var base = "https://e-hentai.org"
    var host = "e-hentai.org"
    let f = Fetcher()
    let cookie: String
    let original: Bool
    var useOriginal = false
    var loggedIn = false
    var needNote = false
    var debugText = ""
    init(cookie: String = "", original: Bool = false) { self.cookie = cookie; self.original = original; self.useOriginal = original }
    var cache: [String: String] = [:]

    private func parseURL(_ url: String) throws -> (String, String) {
        guard let m = regexFirst(#"https?://(?:www\.)?(e-hentai|exhentai)\.org/g/(\d+)/([0-9a-f]+)"#, url) else {
            throw JobError.message("Το link δεν μοιάζει με gallery του e-hentai.org")
        }
        let pairs = cookiePairs(cookie)
        let names = pairs.map { $0.0 }
        let hasLogin = names.contains("ipb_member_id") && names.contains("ipb_pass_hash")
        if m[1] == "exhentai" {
            host = "exhentai.org"; base = "https://exhentai.org"
            if !hasLogin {
                throw JobError.message("Το ExHentai θέλει σύνδεση. Βάλε τα cookies (ipb_member_id, ipb_pass_hash, igneous) στο πεδίο «Cookies».")
            }
        }
        if hasLogin {
            loggedIn = true
            for (k, v) in pairs { f.setCookie(name: k, value: v, domain: host) }
        }
        return (m[2], m[3])
    }

    private func findNext(_ txt: String) -> String? {
        if let m = regexFirst(#"<a[^>]*id="next"[^>]*href="([^"]+)""#, txt) { return htmlUnescape(m[1]) }
        if let m = regexFirst(#"<a[^>]*href="([^"]+)"[^>]*id="next""#, txt) { return htmlUnescape(m[1]) }
        return nil
    }

    private func collectLinks(_ gid: String, _ token: String, _ cb: Reporter, _ delay: Double) async throws -> (String?, [String]) {
        var links: [String] = []
        var seen = Set<String>()
        var total: Int? = nil
        var title: String? = nil
        var page = 0
        while true {
            let url = "\(base)/g/\(gid)/\(token)/?p=\(page)"
            let txt = try await f.text(url)
            if page == 0 {
                if let m = regexFirst(#"<h1 id="gn">(.*?)</h1>"#, txt, dotAll: true) {
                    title = htmlUnescape(m[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let m = regexFirst(#"Length:</td>\s*<td[^>]*>\s*(\d+)\s*pages"#, txt) { total = Int(m[1]) }
            }
            var new = 0
            for m in regexAll("https://" + NSRegularExpression.escapedPattern(for: host) + #"/s/[0-9a-f]+/\d+-\d+"#, txt) {
                let link = m[0]
                if !seen.contains(link) { seen.insert(link); links.append(link); new += 1 }
            }
            cb.log("Σελίδα previews \(page + 1): βρέθηκαν \(links.count)" + (total != nil ? "/\(total!)" : ""))
            if new == 0 || (total != nil && links.count >= total!) { break }
            page += 1
            try await pause(delay)
        }
        if links.isEmpty {
            throw JobError.message(host == "exhentai.org"
                ? "Δεν βρέθηκαν εικόνες. Τα cookies του ExHentai μάλλον λείπουν/έληξαν (χρειάζεται και το igneous)."
                : "Δεν βρέθηκαν εικόνες. Έλεγξε το link (ή το gallery έχει διαγραφεί).")
        }
        if let t = total, links.count < t {
            cb.log("Τα previews σταμάτησαν νωρίτερα. Συνεχίζω ακολουθώντας το «επόμενο» κάθε εικόνας...")
            var url = links[links.count - 1]
            while links.count < t {
                let txt = try await f.text(url)
                cache[url] = txt
                guard let nxt = findNext(txt), !seen.contains(nxt) else { break }
                seen.insert(nxt)
                links.append(nxt)
                url = nxt
                cb.log("Βρέθηκαν \(links.count)/\(t)")
                try await pause(delay)
            }
        }
        return (title, links)
    }

    private func downloadPage(_ pageURL: String, _ index: Int, _ folder: String, useCache: Bool) async throws {
        var txt: String? = useCache ? cache.removeValue(forKey: pageURL) : nil
        if txt == nil { txt = try await f.text(pageURL) }
        let t = txt!
        // "Download original": the full-size file, instead of the resized one shown on the page.
        if useOriginal, let om = regexFirst(#"<a href="([^"]+)"[^>]*>\s*Download original"#, t) {
            let osrc = htmlUnescape(om[1])
            let oname = URL(string: osrc)?.lastPathComponent ?? ""
            var oext = (oname as NSString).pathExtension.lowercased()
            if !imgExt.contains(oext) { oext = "jpg" }
            let odst = (folder as NSString).appendingPathComponent(String(format: "%04d.%@", index, oext))
            try await f.download(osrc, to: odst, referer: pageURL)
            var gotHTML = false
            if let fh = FileHandle(forReadingAtPath: odst) {
                let head = fh.readData(ofLength: 30000)
                try? fh.close()
                if head.first == 0x3C {          // an HTML page instead of an image
                    gotHTML = true
                    let rawText = String(decoding: head, as: UTF8.self)
                    let low = rawText.lowercased()
                    var plain = rawText.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
                    plain = plain.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                    plain = plain.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    debugText = String(plain.trimmingCharacters(in: .whitespaces).prefix(300))
                    try? FileManager.default.removeItem(atPath: odst)
                    if low.contains("exceeded") || low.contains("viewing limit") || low.contains("image limit") {
                        throw JobError.limitReached
                    }
                    // Probably a login page: the original needs an account. Use the normal image from now on.
                    useOriginal = false
                    needNote = true
                }
            }
            if !gotHTML { return }
        }
        let m = regexFirst(#"<img[^>]*id="img"[^>]*src="([^"]+)""#, t) ?? regexFirst(#"<img[^>]*src="([^"]+)"[^>]*id="img""#, t)
        guard let mm = m else { throw JobError.message("δεν βρέθηκε η εικόνα στη σελίδα") }
        let src = htmlUnescape(mm[1])
        let name = URL(string: src)?.lastPathComponent ?? ""
        if name == "509.gif" || name == "509s.gif" { throw JobError.limitReached }
        var ext = (name as NSString).pathExtension.lowercased()
        if !imgExt.contains(ext) { ext = "jpg" }
        let dst = (folder as NSString).appendingPathComponent(String(format: "%04d.%@", index, ext))
        try await f.download(src, to: dst, referer: pageURL)
    }

    func run(url: String, nameIn: String, outDir: String, workRoot: String, mode: String, delay: Double, cb: Reporter) async throws -> [String] {
        let (gid, token) = try parseURL(url)
        f.setCookie(name: "nw", value: "1", domain: host)
        if original && !loggedIn {
            cb.log("Για «original» το E-Hentai θέλει σύνδεση (cookies ipb_member_id + ipb_pass_hash). Χωρίς αυτά κατεβαίνει η κανονική ποιότητα.")
            useOriginal = false
        }

        cb.log("== Ανάγνωση gallery ==")
        cb.progress(0, 0, "Ανάγνωση gallery...")
        let (title, links) = try await collectLinks(gid, token, cb, delay)
        let total = links.count
        let name = safeName(nameIn.isEmpty ? (title ?? "gallery_\(gid)") : nameIn)
        cb.log("Τίτλος: \(title ?? "-") | Σελίδες: \(total)")

        // Images stay in the work folder: if the download stops, the next run resumes from there.
        let imgDir = (workRoot as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: imgDir, withIntermediateDirectories: true)
        let steps = stepsFor(total, mode)

        cb.log("== Λήψη εικόνων μία-μία ==")
        var failed: [Int] = []
        for (idx, link) in links.enumerated() {
            let i = idx + 1
            try Task.checkCancellation()
            if alreadyHave(imgDir, i) {
                cb.log("\(i)/\(total): υπάρχει ήδη, το προσπερνάω")
            } else {
                do {
                    try await downloadPage(link, i, imgDir, useCache: true)
                    cb.log("\(i)/\(total): OK")
                    if needNote {
                        needNote = false
                        cb.log("Το «Download original» δεν δούλεψε. Συνεχίζω με κανονική ποιότητα.")
                        cb.log("Απάντηση του site: \(debugText.isEmpty ? "(κενή)" : debugText)")
                        cb.log("Cookies που στάλθηκαν: \(loggedIn ? "ναι (ipb_member_id + ipb_pass_hash)" : "όχι")")
                    }
                } catch JobError.limitReached {
                    throw JobError.limitReached
                } catch JobError.cancelled {
                    throw JobError.cancelled
                } catch {
                    failed.append(i)
                    cb.log("\(i)/\(total): ΑΠΟΤΥΧΙΑ (\(error.localizedDescription))")
                }
                try await pause(delay)
            }
            cb.progress(i, steps, "Λήψη \(i)/\(total)")
            cb.download(i, total)
        }

        if !failed.isEmpty {
            cb.log("== Δεύτερη προσπάθεια για \(failed.count) σελίδες ==")
            var still: [Int] = []
            for i in failed {
                try Task.checkCancellation()
                try await pause(max(delay, 1.0) * 2)
                do {
                    try await downloadPage(links[i - 1], i, imgDir, useCache: false)
                    cb.log("\(i)/\(total): OK (2η προσπάθεια)")
                } catch JobError.limitReached {
                    throw JobError.limitReached
                } catch JobError.cancelled {
                    throw JobError.cancelled
                } catch {
                    still.append(i)
                    cb.log("\(i)/\(total): ξανά ΑΠΟΤΥΧΙΑ (\(error.localizedDescription))")
                }
            }
            failed = still
        }
        return try finishJob(imgDir: imgDir, name: name, title: title ?? name, outDir: outDir, workRoot: workRoot,
                             total: total, failed: failed, mode: mode, cb: cb)
    }
}

/// Parses "a=b; c=d" (or lines / "a=b,c=d") into name/value pairs.
func cookiePairs(_ raw: String) -> [(String, String)] {
    raw.components(separatedBy: CharacterSet(charactersIn: ";,\n\r"))
        .compactMap { part in
            let t = part.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { return nil }
            let k = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return k.isEmpty || v.isEmpty ? nil : (k, v)
        }
}
