import SwiftUI
import WebKit

struct FoundVideo: Identifiable, Hashable {
    let url: URL
    var id: String { url.absoluteString }

    var quality: Int {
        let s = url.absoluteString
        if let r = s.range(of: #"(\d{3,4})p"#, options: .regularExpression) {
            let digits = s[r].dropLast()
            return Int(digits) ?? 0
        }
        return 0
    }

    var label: String {
        let name = url.lastPathComponent
        return quality > 0 ? "\(quality)p · \(name)" : name
    }
}

final class DAController: NSObject, ObservableObject, WKNavigationDelegate, URLSessionDownloadDelegate {
    let webView: WKWebView

    @Published var addressText = ""
    @Published var pageTitle = ""
    @Published var isLoading = false
    @Published var found: [FoundVideo] = []
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var status = "Κόλλησε ένα link από το DeviantArt και πάτα Άνοιγμα."
    @Published var saved: [URL] = []
    @Published var autoDownload = true

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var urlObservation: NSKeyValueObservation?
    private var lastURL = ""
    private var pendingName = "video"
    private var pendingExt = "mp4"
    private var pendingSourcePath = ""
    private var autoStartedForPage = false
    private var downloadedPaths = Set<String>()
    private var sawHLS = false

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] web, _ in
            DispatchQueue.main.async { self?.urlChanged(web.url) }
        }
        saved = Self.loadSaved()
    }

    // MARK: - Πλοήγηση

    func open() {
        var text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text) else {
            status = "Μη έγκυρο link."
            return
        }
        found = []
        autoStartedForPage = false
        status = "Φόρτωση σελίδας…"
        webView.load(URLRequest(url: url))
    }

    func pasteAndOpen() {
        if let s = UIPasteboard.general.string, !s.isEmpty {
            addressText = s
            open()
        }
    }

    private func urlChanged(_ url: URL?) {
        guard let s = url?.absoluteString, s != lastURL else { return }
        lastURL = s
        addressText = s
        found = []
        sawHLS = false
        autoStartedForPage = false
        webView.evaluateJavaScript("try{performance.clearResourceTimings()}catch(e){}")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        pageTitle = webView.title ?? ""
        status = "Ψάχνω για video…"
        scan()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        status = "Η σελίδα δεν φόρτωσε: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        status = "Η σελίδα δεν φόρτωσε: \(error.localizedDescription)"
    }

    // MARK: - Εύρεση video

    private static let scanScript = #"""
    (function(){
      var out = [];
      function norm(u){
        return (u||'').replace(/\\u002F/gi,'/').replace(/\\u0026/gi,'&').replace(/\\\//g,'/').replace(/&amp;/g,'&').replace(/\\+$/,'');
      }
      function add(u){
        u = norm(u);
        if (/^https?:\/\//i.test(u) && /\.(mp4|webm|m3u8)(\?|#|$)/i.test(u) && out.indexOf(u) < 0) out.push(u);
      }
      try { document.querySelectorAll('video').forEach(function(v){ add(v.currentSrc); add(v.src); }); } catch(e){}
      try { document.querySelectorAll('source').forEach(function(s){ add(s.src); }); } catch(e){}
      try { performance.getEntriesByType('resource').forEach(function(e){ add(e.name); }); } catch(e){}
      try {
        var html = document.documentElement.innerHTML;
        var re = /https?:(?:\\?\/){2}[^"'\s<>]+?\.(?:mp4|webm|m3u8)[^"'\s<>]*/gi;
        var m; var n = 0;
        while ((m = re.exec(html)) !== null && n < 60) { add(m[0]); n++; }
      } catch(e){}
      return JSON.stringify(out);
    })();
    """#

    func scan() {
        webView.evaluateJavaScript(Self.scanScript) { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let all = try? JSONDecoder().decode([String].self, from: data) else { return }

            let urls = all.compactMap { URL(string: $0) }
            self.sawHLS = urls.contains { $0.pathExtension.lowercased() == "m3u8" }
            let videos = urls.filter { ["mp4", "webm"].contains($0.pathExtension.lowercased()) }

            var changed = false
            for u in videos where !self.found.contains(where: { $0.url.path == u.path }) {
                self.found.append(FoundVideo(url: u))
                changed = true
            }
            if changed {
                self.found.sort { $0.quality > $1.quality }
            }

            if self.found.isEmpty {
                if self.isLoading {
                    self.status = "Φόρτωση σελίδας…"
                } else if self.sawHLS {
                    self.status = "Το video είναι σε μορφή HLS (.m3u8), που δεν υποστηρίζεται ακόμα."
                } else {
                    self.status = "Δεν βρήκα video ακόμα. Αν η σελίδα έχει video, πάτα play και περίμενε λίγο."
                }
            } else if !self.isDownloading, self.saved.isEmpty || changed {
                self.status = "Βρέθηκαν \(self.found.count) video."
            }
            self.autoStartIfNeeded()
        }
    }

    private func autoStartIfNeeded() {
        guard autoDownload, !isDownloading, !autoStartedForPage else { return }
        guard let best = found.first(where: { !downloadedPaths.contains($0.url.path) }) else { return }
        autoStartedForPage = true
        download(best)
    }

    // MARK: - Λήψη

    func download(_ video: FoundVideo) {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        status = "Λήψη…"
        pendingName = Self.cleanName(pageTitle.isEmpty ? video.url.deletingPathExtension().lastPathComponent : pageTitle)
        pendingExt = video.url.pathExtension.lowercased()
        pendingSourcePath = video.url.path

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            var request = URLRequest(url: video.url)
            request.setValue("https://www.deviantart.com/", forHTTPHeaderField: "Referer")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let host = video.url.host ?? ""
            let relevant = cookies.filter { cookie in
                let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == d || host.hasSuffix("." + d)
            }
            for (key, value) in HTTPCookie.requestHeaderFields(with: relevant) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            self.task = self.session.downloadTask(with: request)
            self.task?.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse else {
            status = "Άκυρη απάντηση από τον server."
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            status = "Ο server αρνήθηκε τη λήψη (κωδικός \(http.statusCode))."
            return
        }
        if (http.mimeType ?? "").hasPrefix("text") {
            status = "Ο server δεν επέστρεψε video."
            return
        }
        guard let dir = Self.downloadsDir() else {
            status = "Δεν μπόρεσα να δημιουργήσω τον φάκελο λήψεων."
            return
        }
        let dest = Self.uniqueURL(in: dir, name: pendingName, ext: pendingExt)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            saved.insert(dest, at: 0)
            downloadedPaths.insert(pendingSourcePath)
            status = "Έτοιμο: \(dest.lastPathComponent)"
        } catch {
            status = "Αποτυχία αποθήκευσης: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        isDownloading = false
        if let error, (error as NSError).code != NSURLErrorCancelled {
            status = "Σφάλμα λήψης: \(error.localizedDescription)"
        }
    }

    // MARK: - Βοηθητικά

    static func downloadsDir() -> URL? {
        guard let docs = FolderAccess.appDocumentsURL() else { return nil }
        let dir = docs.appendingPathComponent("DeviantArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func loadSaved() -> [URL] {
        guard let dir = downloadsDir(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let videos = files.filter { ["mp4", "webm"].contains($0.pathExtension.lowercased()) }
        return videos.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    static func cleanName(_ s: String) -> String {
        var t = s.replacingOccurrences(of: " on DeviantArt", with: "")
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        t = t.components(separatedBy: bad).joined(separator: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 80 { t = String(t.prefix(80)) }
        return t.isEmpty ? "deviantart-video" : t
    }

    static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

struct DAWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct DADownloaderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var c = DAController()
    private let timer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            if c.isLoading { ProgressView().progressViewStyle(.linear) }
            DAWebView(webView: c.webView)
            panel
        }
        .background(Color.black.ignoresSafeArea())
        .onReceive(timer) { _ in
            if !c.isLoading { c.scan() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            TextField("Link από DeviantArt", text: $c.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { c.open() }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Button { c.pasteAndOpen() } label: {
                Image(systemName: "doc.on.clipboard").font(.title3)
            }
            Button("Άνοιγμα") { c.open() }
                .font(.subheadline.weight(.semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.status)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.85))

            if c.isDownloading {
                ProgressView(value: c.progress)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(c.found) { video in
                        HStack {
                            Image(systemName: "film")
                            Text(video.label)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button("Κατέβασμα") { c.download(video) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(c.isDownloading)
                        }
                    }
                    if !c.saved.isEmpty {
                        Divider()
                        Text("Αποθηκευμένα (Files → Στο iPhone μου → Comic Reader → DeviantArt)")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                        ForEach(c.saved.prefix(4), id: \.self) { url in
                            ShareLink(item: url) {
                                Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 170)

            Toggle("Αυτόματη λήψη όταν βρεθεί video", isOn: $c.autoDownload)
                .font(.footnote)
        }
        .foregroundColor(.white)
        .padding(12)
        .background(.ultraThinMaterial)
    }
}
