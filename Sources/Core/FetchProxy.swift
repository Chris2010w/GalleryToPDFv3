import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that lets the embedded Python (yt-dlp) make its web requests through
/// iOS's own networking (URLSession). To websites this looks like a normal iPhone connection, so sites
/// that reject Python's TLS fingerprint (e.g. with "410 Gone" or 403) work again.
/// Protocol: POST /fetch with JSON {url, method, headers, body(base64)} -> JSON {status, url, headers, set_cookies, body(base64)}.
final class FetchProxy {
    static let shared = FetchProxy()
    private var listener: NWListener?
    private var portValue: UInt16 = 0
    private let q = DispatchQueue(label: "fetchproxy.queue")
    private let lock = NSLock()

    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 45
        return URLSession(configuration: cfg)
    }()

    /// Starts the server (once) and returns its port, or 0 if it could not start.
    func start() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        if listener != nil { return portValue }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let l = try NWListener(using: params)
            let sem = DispatchSemaphore(value: 0)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled: sem.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: q)
            _ = sem.wait(timeout: .now() + 3)
            guard let p = l.port?.rawValue, p != 0 else { l.cancel(); return 0 }
            listener = l
            portValue = p
            return p
        } catch {
            return 0
        }
    }

    // MARK: connection handling
    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isDone, err in
            guard let self = self else { return }
            var buf = acc
            if let d = data, !d.isEmpty { buf.append(d) }
            if let body = self.completeBody(buf) {
                self.handle(body, c)
                return
            }
            if err != nil || isDone { c.cancel(); return }
            self.receive(c, buf)
        }
    }

    /// Returns the request body once the whole HTTP request has arrived.
    private func completeBody(_ buf: Data) -> Data? {
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self).lowercased()
        var len = 0
        for line in head.components(separatedBy: "\r\n") where line.hasPrefix("content-length:") {
            len = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = r.upperBound
        if buf.count - (bodyStart - buf.startIndex) < len { return nil }
        return Data(buf[bodyStart..<(bodyStart + len)])
    }

    private func handle(_ body: Data, _ c: NWConnection) {
        Task {
            var out: [String: Any]
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                out = await fetch(obj)
            } else {
                out = ["error": "bad request"]
            }
            let json = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{\"error\":\"encode\"}".utf8)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
            resp.append(json)
            c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    // MARK: the actual fetch
    private func fetch(_ req: [String: Any]) async -> [String: Any] {
        guard let us = req["url"] as? String, let url = URL(string: us) else { return ["error": "invalid url"] }
        var r = URLRequest(url: url)
        r.httpMethod = (req["method"] as? String) ?? "GET"
        r.httpShouldHandleCookies = false
        if let t = req["timeout"] as? Double { r.timeoutInterval = max(t, 10) }
        let skip: Set<String> = ["accept-encoding", "connection", "host", "content-length", "user-agent",
                                 "sec-fetch-mode", "sec-fetch-site", "sec-fetch-dest", "sec-fetch-user", "sec-ch-ua",
                                 "sec-ch-ua-mobile", "sec-ch-ua-platform"]
        if let hs = req["headers"] as? [String: Any] {
            for (k, v) in hs {
                if let s = v as? String, !skip.contains(k.lowercased()) { r.setValue(s, forHTTPHeaderField: k) }
            }
        }
        r.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        if let b = req["body"] as? String, !b.isEmpty, let d = Data(base64Encoded: b) { r.httpBody = d }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let h = resp as? HTTPURLResponse else { return ["error": "no http response"] }
            let drop: Set<String> = ["content-encoding", "content-length", "transfer-encoding", "set-cookie", "connection"]
            var headers: [String: String] = [:]
            var fields: [String: String] = [:]
            for (k, v) in h.allHeaderFields {
                guard let ks = k as? String, let vs = v as? String else { continue }
                fields[ks] = vs
                if !drop.contains(ks.lowercased()) { headers[ks] = vs }
            }
            var cookies: [String] = []
            if let u = h.url {
                for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: u) {
                    var s = "\(c.name)=\(c.value); Path=\(c.path)"
                    if !c.domain.isEmpty { s += "; Domain=\(c.domain)" }
                    if c.isSecure { s += "; Secure" }
                    cookies.append(s)
                }
            }
            return ["status": h.statusCode, "url": h.url?.absoluteString ?? us, "headers": headers,
                    "set_cookies": cookies, "body": data.base64EncodedString()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
}
