import Foundation

enum JobError: Error { case cancelled, limitReached, message(String) }
extension JobError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .limitReached: return "LimitReached"
        case .message(let m): return m
        }
    }
}

protocol Reporter: AnyObject {
    func log(_ text: String)
    func progress(_ current: Int, _ total: Int, _ text: String)
    func download(_ done: Int, _ total: Int)
}

let imgExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]

struct SiteInfo { let name: String; let engine: String; let hosts: [String] }
let sites: [SiteInfo] = [
    SiteInfo(name: "E-Hentai", engine: "ehentai", hosts: ["e-hentai.org"]),
    SiteInfo(name: "ExHentai", engine: "ehentai", hosts: ["exhentai.org"]),
    SiteInfo(name: "e621", engine: "e621", hosts: ["e621.net"]),
    SiteInfo(name: "Rule34.xyz", engine: "rule34xyz", hosts: ["rule34.xyz"]),
    SiteInfo(name: "nHentai", engine: "nhentai", hosts: ["nhentai.net"]),
    SiteInfo(name: "HentaiFox", engine: "imfamily", hosts: ["hentaifox.com"]),
    SiteInfo(name: "Hitomi.la", engine: "hitomi", hosts: ["hitomi.la"]),
    SiteInfo(name: "HentaiEra", engine: "imfamily", hosts: ["hentaiera.com"]),
]

func detectSite(_ url: String) -> SiteInfo? {
    let low = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !low.hasPrefix("http") || low.count > 600 || low.contains("\n") { return nil }
    if let s = sites.first(where: { s in s.hosts.contains { low.contains($0) } }) { return s }
    // Anything else goes to yt-dlp (the embedded video downloader).
    return SiteInfo(name: "Βίντεο (yt-dlp)", engine: "ytdlp", hosts: [])
}

func safeName(_ n: String) -> String {
    var s = n.replacingOccurrences(of: "[<>:\"/\\\\|?*]", with: "_", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespaces)
    while s.hasSuffix(".") { s.removeLast() }
    if s.count > 120 { s = String(s.prefix(120)) }
    return s.isEmpty ? "gallery" : s
}

func guessId(_ url: String) -> String {
    let path = URL(string: url)?.path ?? url
    let m = regexAll(#"\d{4,}"#, path)
    return m.last?[0] ?? "gallery"
}

func naturalLess(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
}

func listImageNames(_ folder: String) -> [String] {
    let all = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    return all.filter { imgExt.contains(($0 as NSString).pathExtension.lowercased()) }.sorted(by: naturalLess)
}

func alreadyHave(_ folder: String, _ index: Int) -> Bool {
    let prefix = String(format: "%04d.", index)
    let all = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    return all.contains { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") }
}

func stepsFor(_ total: Int, _ mode: String) -> Int {
    var steps = max(total, 1)
    if mode == "pdf" || mode == "both" { steps += total + 1 }
    if mode == "cbz" || mode == "both" { steps += 1 }
    return steps
}

// Regex helpers: each match is an array of groups (index 0 = whole match).
func regexAll(_ pattern: String, _ text: String, dotAll: Bool = false) -> [[String]] {
    var opts: NSRegularExpression.Options = []
    if dotAll { opts.insert(.dotMatchesLineSeparators) }
    guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

func regexFirst(_ pattern: String, _ text: String, dotAll: Bool = false) -> [String]? {
    regexAll(pattern, text, dotAll: dotAll).first
}

func htmlUnescape(_ s: String) -> String {
    var r = s
    for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
        r = r.replacingOccurrences(of: a, with: b)
    }
    return r
}

/// Sleep that throws if the job was cancelled.
func pause(_ seconds: Double) async throws {
    if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    try Task.checkCancellation()
}
