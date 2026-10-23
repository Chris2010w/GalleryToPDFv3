import Foundation

final class Fetcher {
    let session: URLSession
    let cookies = HTTPCookieStorage()
    var extraHeaders: [String: String] = [:]
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = cookies
        cfg.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: cfg)
    }

    func setCookie(name: String, value: String, domain: String) {
        if let c = HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"]) {
            cookies.setCookie(c)
        }
    }

    private func makeRequest(_ url: String, referer: String?) throws -> URLRequest {
        guard let u = URL(string: url) else { throw JobError.message("Μη έγκυρο URL: \(url)") }
        var r = URLRequest(url: u)
        r.setValue(Fetcher.ua, forHTTPHeaderField: "User-Agent")
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        if let ref = referer { r.setValue(ref, forHTTPHeaderField: "Referer") }
        return r
    }

    private func isCancel(_ e: Error) -> Bool {
        if e is CancellationError { return true }
        if let u = e as? URLError, u.code == .cancelled { return true }
        return false
    }

    func data(_ url: String, referer: String? = nil, retries: Int = 3) async throws -> Data {
        var last: Error = JobError.message("άγνωστο σφάλμα δικτύου")
        for attempt in 0..<retries {
            if Task.isCancelled { throw JobError.cancelled }
            do {
                let (d, resp) = try await session.data(for: try makeRequest(url, referer: referer))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 400 { throw JobError.message("HTTP \(code)") }
                return d
            } catch {
                if isCancel(error) { throw JobError.cancelled }
                last = error
                if attempt < retries - 1 { try await pause(Double(2 * (attempt + 1))) }
            }
        }
        throw last
    }

    func text(_ url: String, referer: String? = nil, retries: Int = 3) async throws -> String {
        String(decoding: try await data(url, referer: referer, retries: retries), as: UTF8.self)
    }

    /// Downloads to dst atomically (.part file, then rename). A 404 fails immediately (no retries).
    func download(_ url: String, to dst: String, referer: String? = nil, retries: Int = 3) async throws {
        var last: Error = JobError.message("άγνωστο σφάλμα δικτύου")
        for attempt in 0..<retries {
            if Task.isCancelled { throw JobError.cancelled }
            do {
                let (tmp, resp) = try await session.download(for: try makeRequest(url, referer: referer))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 400 {
                    try? FileManager.default.removeItem(at: tmp)
                    throw JobError.message("HTTP \(code)")
                }
                let part = dst + ".part"
                try? FileManager.default.removeItem(atPath: part)
                try? FileManager.default.removeItem(atPath: dst)
                try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: part))
                try FileManager.default.moveItem(atPath: part, toPath: dst)
                return
            } catch {
                if isCancel(error) { throw JobError.cancelled }
                last = error
                if case JobError.message(let m) = error, m == "HTTP 404" { throw error }
                if attempt < retries - 1 { try await pause(Double(2 * (attempt + 1))) }
            }
        }
        throw last
    }
}
