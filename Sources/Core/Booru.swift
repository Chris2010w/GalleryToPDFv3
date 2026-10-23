import Foundation

// MARK: - e621 (single posts and pools, via the public JSON API)
final class E621Engine {
    let f = Fetcher()

    init() {
        // e621 requires a descriptive User-Agent.
        f.extraHeaders["User-Agent"] = "GalleryToPDF-iOS/1.0 (personal use)"
    }

    private func jsonObject(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    /// Returns (url, ext) of the post's full file, or throws a readable error.
    private func fileInfo(_ post: [String: Any]) throws -> (String, String) {
        let id = post["id"] ?? "?"
        guard let file = post["file"] as? [String: Any], let ext = (file["ext"] as? String)?.lowercased() else {
            throw JobError.message("Το post \(id) δεν έχει αρχείο.")
        }
        if !imgExt.contains(ext) {
            throw JobError.message("Το post \(id) είναι \(ext) (βίντεο/flash). Υποστηρίζονται μόνο εικόνες.")
        }
        guard let url = file["url"] as? String, !url.isEmpty else {
            throw JobError.message("Το post \(id) είναι κρυμμένο/μπλοκαρισμένο (χρειάζεται σύνδεση στο e621).")
        }
        return (url, ext)
    }

    func run(url: String, nameIn: String, outDir: String, workRoot: String, mode: String, delay: Double, cb: Reporter) async throws -> [String] {
        cb.log("== Ανάγνωση e621 ==")
        cb.progress(0, 0, "Ανάγνωση...")
        var items: [DLItem] = []
        var title = ""

        if let m = regexFirst(#"e621\.net/pools/(\d+)"#, url) {
            let pid = m[1]
            guard let pool = jsonObject(try await f.text("https://e621.net/pools/\(pid).json")),
                  let ids = pool["post_ids"] as? [Int], !ids.isEmpty else {
                throw JobError.message("Δεν βρέθηκε το pool \(pid).")
            }
            title = (pool["name"] as? String)?.replacingOccurrences(of: "_", with: " ") ?? "e621_pool_\(pid)"
            cb.log("Pool: \(title) | Εικόνες: \(ids.count)")
            var byId: [Int: [String: Any]] = [:]
            var page = 1
            while byId.count < ids.count && page <= 50 {
                try Task.checkCancellation()
                let t = try await f.text("https://e621.net/posts.json?tags=pool:\(pid)&limit=320&page=\(page)")
                guard let posts = jsonObject(t)?["posts"] as? [[String: Any]], !posts.isEmpty else { break }
                for p in posts { if let i = p["id"] as? Int { byId[i] = p } }
                page += 1
                try await pause(max(delay, 0.6))
            }
            var n = 0
            for id in ids {
                guard let p = byId[id] else { cb.log("Παράλειψη post \(id) (δεν επέστρεψε το API)"); continue }
                do { let (u, _) = try fileInfo(p); n += 1; items.append(DLItem(index: n, candidates: [u])) }
                catch { cb.log(error.localizedDescription) }
            }
        } else if let m = regexFirst(#"e621\.net/posts/(\d+)"#, url) {
            let id = m[1]
            guard let post = jsonObject(try await f.text("https://e621.net/posts/\(id).json"))?["post"] as? [String: Any] else {
                throw JobError.message("Δεν βρέθηκε το post \(id).")
            }
            let (u, _) = try fileInfo(post)
            items = [DLItem(index: 1, candidates: [u])]
            title = "e621_\(id)"
        } else {
            throw JobError.message("Βάλε link από ένα post (e621.net/posts/123) ή pool (e621.net/pools/123).")
        }
        if items.isEmpty { throw JobError.message("Δεν βρέθηκαν εικόνες για λήψη.") }
        let name = safeName(nameIn.isEmpty ? title : nameIn)
        return try await downloadItems(items, f: f, name: name, title: name, outDir: outDir, workRoot: workRoot,
                                       referer: "https://e621.net/", mode: mode, delay: delay, cb: cb)
    }
}

// MARK: - Rule34.xyz (single post; the site is a JS app, so we read the pre-rendered image URL)
final class Rule34XYZEngine {
    let f = Fetcher()

    func run(url: String, nameIn: String, outDir: String, workRoot: String, mode: String, delay: Double, cb: Reporter) async throws -> [String] {
        guard let m = regexFirst(#"rule34\.xyz/post/(\d+)"#, url) else {
            throw JobError.message("Βάλε link από ένα post (rule34.xyz/post/123).")
        }
        let id = m[1]
        cb.log("== Ανάγνωση Rule34.xyz ==")
        cb.progress(0, 0, "Ανάγνωση...")
        let idNum = Int(id) ?? 0
        let dir = "https://rule34xyz.b-cdn.net/posts/\(idNum / 1000)/\(id)/\(id)"
        var candidates: [String] = []

        if let html = try? await f.text(url, referer: "https://rule34.xyz/", retries: 2) {
            for mm in regexAll(#"https://rule34xyz\.b-cdn\.net/posts/[^"'\s<>]+?\.pic\.(?:jpg|jpeg|png|webp|gif)"#, html) where !candidates.contains(mm[0]) {
                candidates.append(mm[0])
            }
            if candidates.isEmpty, regexFirst(#"\.(?:mp4|webm)"#, html) != nil, regexFirst(#"\.pic\."#, html) == nil {
                cb.log("Σημείωση: το post μοιάζει με βίντεο.")
            }
        } else {
            cb.log("Η σελίδα δεν άνοιξε· δοκιμάζω απευθείας το CDN.")
        }
        for ext in ["jpg", "png", "webp", "jpeg", "gif"] {
            let u = "\(dir).pic.\(ext)"
            if !candidates.contains(u) { candidates.append(u) }
        }
        let name = safeName(nameIn.isEmpty ? "rule34xyz_\(id)" : nameIn)
        return try await downloadItems([DLItem(index: 1, candidates: candidates)], f: f, name: name, title: name,
                                       outDir: outDir, workRoot: workRoot, referer: "https://rule34.xyz/",
                                       mode: mode, delay: delay, cb: cb)
    }
}
