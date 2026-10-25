import Foundation

final class Fetcher: NSObject, URLSessionTaskDelegate {
    let session: URLSession
    /// Cookies are attached by hand as a "Cookie" header, only for the domain they belong to (so login cookies are never
    /// sent to other servers, e.g. after a redirect to an image server).
    private var jar: [(name: String, value: String, domain: String)] = []
    var extraHeaders: [String: String] = [:]
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    override init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg)
        super.init()
    }

    func setCookie(name: String, value: String, domain: String) {
        let d = domain.lowercased()
        jar.removeAll { $0.name == name && $0.domain == d }
        jar.append((name, value, d))
    }

    private func cookieHeader(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let items = jar.filter { host == $0.domain || host.hasSuffix("." + $0.domain) }
        return items.isEmpty ? nil : items.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // Keep the Cookie header only while we stay on a domain the cookies belong to.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        if let u = r.url { r.setValue(cookieHeader(for: u), forHTTPHeaderField: "Cookie") }
        completionHandler(r)
    }

    private func makeRequest(_ url: String, referer: String?) throws -> URLRequest {
        guard let u = URL(string: url) else { throw JobError.message("Μη έγκυρο URL: \(url)") }
        var r = URLRequest(url: u)
        r.setValue(Fetcher.ua, forHTTPHeaderField: "User-Agent")
        r.httpShouldHandleCookies = false
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        if let c = cookieHeader(for: u) { r.setValue(c, forHTTPHeaderField: "Cookie") }
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
                let (d, resp) = try await session.data(for: try makeRequest(url, referer: referer), delegate: self)
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
                let (tmp, resp) = try await session.download(for: try makeRequest(url, referer: referer), delegate: self)
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
