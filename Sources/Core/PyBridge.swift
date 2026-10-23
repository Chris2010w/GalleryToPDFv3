import Foundation
import Darwin

/// Embedded CPython (BeeWare "Python-Apple-support"), loaded at runtime with dlopen so the
/// project compiles without any Python headers. The CI workflow copies Python.framework,
/// the standard library and yt-dlp into the .app bundle.
final class PyRuntime {
    static let shared = PyRuntime()
    private let lock = NSLock()
    private var started = false
    private var startError: String? = nil
    private var fRun: (@convention(c) (UnsafePointer<CChar>) -> Int32)?
    private var fEnsure: (@convention(c) () -> Int32)?
    private var fRelease: (@convention(c) (Int32) -> Void)?

    static var bundlePath: String { Bundle.main.bundlePath }
    static var ytdlpPath: String { bundlePath + "/extras/yt-dlp" }
    static var available: Bool {
        FileManager.default.fileExists(atPath: bundlePath + "/Frameworks/Python.framework/Python")
            && FileManager.default.fileExists(atPath: bundlePath + "/python/lib")
            && FileManager.default.fileExists(atPath: ytdlpPath)
    }

    private func start() throws {
        lock.lock(); defer { lock.unlock() }
        if started { return }
        if let e = startError { throw JobError.message(e) }
        func fail(_ m: String) -> JobError { startError = m; return JobError.message(m) }

        let b = Self.bundlePath
        guard Self.available else {
            throw fail("Η εφαρμογή δεν περιέχει Python/yt-dlp. Χτίσε την ξανά με το νέο build-ipa.yml.")
        }
        setenv("PYTHONHOME", b + "/python", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONIOENCODING", "utf-8", 1)
        setenv("SSL_CERT_FILE", b + "/extras/cacert.pem", 1)
        setenv("REQUESTS_CA_BUNDLE", b + "/extras/cacert.pem", 1)
        if getenv("HOME") == nil { setenv("HOME", NSHomeDirectory(), 1) }

        guard let h = dlopen(b + "/Frameworks/Python.framework/Python", RTLD_NOW | RTLD_GLOBAL) else {
            let e = dlerror().map { String(cString: $0) } ?? "?"
            throw fail("Δεν φορτώθηκε η Python: \(e)")
        }
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }
        guard let pInit = sym("Py_Initialize"), let pRun = sym("PyRun_SimpleString"),
              let pEnsure = sym("PyGILState_Ensure"), let pRelease = sym("PyGILState_Release"),
              let pSave = sym("PyEval_SaveThread") else {
            throw fail("Η Python δεν έχει τις αναμενόμενες συναρτήσεις.")
        }
        // sys.executable must sit in the app bundle root: Python finds the converted extension
        // modules (Frameworks/*.framework) relative to it.
        if let pName = sym("Py_SetProgramName"), let exe = Bundle.main.executablePath {
            let setName = unsafeBitCast(pName, to: (@convention(c) (UnsafePointer<Int32>) -> Void).self)
            let scalars = exe.unicodeScalars.map { Int32($0.value) } + [0]
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: scalars.count)   // intentionally never freed
            buf.initialize(from: scalars, count: scalars.count)
            setName(UnsafePointer(buf))
        }
        let initFn = unsafeBitCast(pInit, to: (@convention(c) () -> Void).self)
        let saveFn = unsafeBitCast(pSave, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        fRun = unsafeBitCast(pRun, to: (@convention(c) (UnsafePointer<CChar>) -> Int32).self)
        fEnsure = unsafeBitCast(pEnsure, to: (@convention(c) () -> Int32).self)
        fRelease = unsafeBitCast(pRelease, to: (@convention(c) (Int32) -> Void).self)

        initFn()
        _ = saveFn()          // release the GIL so any thread can use PyGILState_Ensure
        started = true
    }

    /// Runs Python source. Blocking: call from a background thread.
    func run(_ code: String) throws {
        try start()
        let s = fEnsure!()
        let rc = code.withCString { fRun!($0) }
        fRelease!(s)
        if rc != 0 { throw JobError.message("Σφάλμα στην Python (δες το αρχείο αποτελέσματος).") }
    }
}

struct VStream {
    let url: String
    let ext: String
    let proto: String
    let vcodec: String
    let acodec: String
    let height: Int
    let headers: [String: String]
    let hasFragments: Bool
}
struct VInfo { let title: String; let id: String; let extractor: String; let streams: [VStream] }

private let extractScript = #"""
import sys, os, json, re, traceback

job = json.load(open(sys.argv[1]))
out = {}
try:
    sys.path.insert(0, job["ytdlp"])
    import yt_dlp
    h = int(job.get("maxheight", 1080))
    opts = {
        "quiet": True, "no_warnings": True, "noplaylist": True, "skip_download": True,
        "format": "bv*+ba/b",
        "format_sort": ["res:%d" % h, "vcodec:h264", "acodec:aac", "proto", "ext"],
        "socket_timeout": 30, "retries": 3, "extractor_retries": 2,
        "color": "never", "cachedir": False, "check_formats": False,
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(job["url"], download=False)
        if info is None:
            raise Exception("Δεν βρέθηκε βίντεο.")
        if info.get("entries"):
            first = None
            for e in info["entries"]:
                if e:
                    first = e
                    break
            if first is None:
                raise Exception("Η λίστα είναι άδεια.")
            if not first.get("formats") and not first.get("url"):
                first = ydl.extract_info(first.get("webpage_url") or first.get("url"), download=False)
            info = first
        info = ydl.sanitize_info(info)
    reqs = info.get("requested_formats") or [info]
    streams = []
    for f in reqs:
        streams.append({
            "url": f.get("url"), "ext": f.get("ext"), "protocol": f.get("protocol"),
            "vcodec": f.get("vcodec"), "acodec": f.get("acodec"),
            "height": f.get("height"), "format_id": f.get("format_id"),
            "headers": f.get("http_headers") or {},
            "has_fragments": bool(f.get("fragments")),
        })
    out = {"title": info.get("title"), "id": info.get("id"),
           "extractor": info.get("extractor_key") or info.get("extractor"),
           "streams": streams}
except BaseException as e:
    msg = re.sub(r"\x1b\[[0-9;]*m", "", str(e)) or e.__class__.__name__
    out = {"error": msg, "trace": traceback.format_exc()[-1500:]}
with open(job["out"], "w") as fh:
    json.dump(out, fh)
"""#

/// Asks yt-dlp (inside the embedded Python) for the title and the best direct stream URLs.
func extractVideoInfo(url: String, maxHeight: Int, workDir: String, cb: Reporter) async throws -> VInfo {
    let fm = FileManager.default
    try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    let scriptPath = workDir + "/extract.py"
    let jobPath = workDir + "/job.json"
    let outPath = workDir + "/out.json"
    try? fm.removeItem(atPath: outPath)
    try extractScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    let job: [String: Any] = ["url": url, "ytdlp": PyRuntime.ytdlpPath, "maxheight": maxHeight, "out": outPath]
    try JSONSerialization.data(withJSONObject: job).write(to: URL(fileURLWithPath: jobPath))

    func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
    let code = "import runpy, sys\nsys.argv = ['x', \(q(jobPath))]\nrunpy.run_path(\(q(scriptPath)), run_name='__main__')\n"

    let runErr: String? = await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            do { try PyRuntime.shared.run(code); cont.resume(returning: nil) }
            catch { cont.resume(returning: error.localizedDescription) }
        }
    }
    try Task.checkCancellation()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: outPath)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw JobError.message(runErr ?? "Η yt-dlp δεν επέστρεψε αποτέλεσμα.")
    }
    if let e = obj["error"] as? String {
        if let t = obj["trace"] as? String { cb.log(t) }
        throw JobError.message(e)
    }
    let arr = (obj["streams"] as? [[String: Any]]) ?? []
    let streams: [VStream] = arr.compactMap { s in
        guard let u = s["url"] as? String, !u.isEmpty else { return nil }
        var hdrs: [String: String] = [:]
        for (k, v) in (s["headers"] as? [String: Any]) ?? [:] { if let sv = v as? String { hdrs[k] = sv } }
        return VStream(url: u, ext: (s["ext"] as? String) ?? "mp4", proto: (s["protocol"] as? String) ?? "https",
                       vcodec: (s["vcodec"] as? String) ?? "", acodec: (s["acodec"] as? String) ?? "",
                       height: (s["height"] as? Int) ?? 0, headers: hdrs,
                       hasFragments: (s["has_fragments"] as? Bool) ?? false)
    }
    if streams.isEmpty { throw JobError.message("Η yt-dlp δεν βρήκε ροή βίντεο.") }
    return VInfo(title: (obj["title"] as? String) ?? "video", id: (obj["id"] as? String) ?? "",
                 extractor: (obj["extractor"] as? String) ?? "", streams: streams)
}
