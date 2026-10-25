import SwiftUI
import UserNotifications
import UIKit

final class UIReporter: Reporter {
    weak var vm: JobViewModel?
    init(_ vm: JobViewModel) { self.vm = vm }
    func log(_ text: String) { Task { @MainActor in self.vm?.appendLog(text) } }
    func progress(_ current: Int, _ total: Int, _ text: String) { Task { @MainActor in self.vm?.setProgress(current, total, text) } }
    func download(_ done: Int, _ total: Int) { Task { @MainActor in self.vm?.setCounts(done, total) } }
}

@MainActor
final class JobViewModel: ObservableObject {
    static let delays: [Double] = [0, 0.5, 1, 1.5, 2]
    static let delayLabels = ["0 δευτ. (γρήγορο, ρίσκο μπλοκαρίσματος)", "0.5 δευτ.", "1 δευτ. (προτεινόμενο)", "1.5 δευτ.", "2 δευτ. (πιο ασφαλές)"]

    @Published var url = ""
    @Published var name = ""
    @Published var cookie: String = UserDefaults.standard.string(forKey: "exCookie") ?? "" {
        didSet { UserDefaults.standard.set(cookie, forKey: "exCookie") }
    }
    @Published var mode = "pdf"
    @Published var delayIndex = 2
    @Published var qualityIndex = 1
    @Published var original: Bool = UserDefaults.standard.bool(forKey: "ehOriginal") {
        didSet { UserDefaults.standard.set(original, forKey: "ehOriginal") }
    }
    static let qualities: [Int] = [2160, 1080, 720, 480]
    static let qualityLabels = ["Έως 4K", "Έως 1080p (προτεινόμενο)", "Έως 720p", "Έως 480p"]
    var isVideo: Bool { detectSite(url.trimmingCharacters(in: .whitespacesAndNewlines))?.engine == "ytdlp" }
    @Published var running = false
    @Published var status = "Βάλε ένα link για να ξεκινήσεις."
    @Published var log = ""
    @Published var percent = ""
    @Published var counter = ""
    @Published var fraction: Double? = nil   // nil = indeterminate
    @Published var lastFile: URL? = nil
    @Published var previewURL: URL? = nil
    @Published var shareURL: URL? = nil

    private var task: Task<Void, Never>?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var pct = 0, dlDone = 0, dlTotal = 0
    private var indeterminate = true
    private var curStatus = ""
    private var lastNotify = Date.distantPast
    var lastClip = ""

    var siteHint: (String, Color) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = detectSite(u) { return ("✔ Αναγνωρίστηκε: \(s.name)", Color(red: 0.10, green: 0.50, blue: 0.22)) }
        if !u.isEmpty { return ("✖ Άγνωστο site", Color(red: 0.78, green: 0.16, blue: 0.16)) }
        return ("Galleries (E-Hentai, nHentai, …) ή οποιοδήποτε βίντεο (yt-dlp)", .gray)
    }

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: clipboard
    func paste() {
        if let t = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { url = t }
        else { status = "Δεν υπάρχει τίποτα αντιγραμμένο." }
    }
    func autoPasteIfUseful() {
        guard !running, url.isEmpty, UIPasteboard.general.hasURLs else { return }
        guard let t = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if t != lastClip, detectSite(t) != nil { lastClip = t; url = t }
    }

    // MARK: progress callbacks
    func appendLog(_ t: String) { log += t + "\n" }
    func counterText() -> String {
        if dlTotal > 0 { return "Κατέβηκαν \(dlDone) · Απομένουν \(max(dlTotal - dlDone, 0))" }
        if dlDone > 0 { return "Κατέβηκαν \(dlDone)" }
        return ""
    }
    func setCounts(_ done: Int, _ total: Int) {
        dlDone = done; dlTotal = total
        counter = counterText()
        pushNotification(force: false)
    }
    func setProgress(_ cur: Int, _ total: Int, _ text: String) {
        indeterminate = total <= 0
        pct = total > 0 ? min(max(cur * 100 / total, 0), 100) : 0
        curStatus = text
        fraction = total > 0 ? Double(cur) / Double(total) : nil
        percent = total > 0 ? "\(pct)%" : ""
        status = text
        let frequent = text.hasPrefix("Λήψη") || text.hasPrefix("Προετοιμασία")
        pushNotification(force: !frequent)
    }

    // MARK: notifications
    private func notify(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
    private func pushNotification(force: Bool) {
        guard UIApplication.shared.applicationState != .active else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastNotify) < 3 { return }
        lastNotify = now
        let title = indeterminate ? "Gallery → PDF" : "Gallery → PDF · \(pct)%"
        let counts = counterText()
        let body = (!counts.isEmpty && curStatus.hasPrefix("Λήψη")) ? counts : (curStatus.isEmpty ? "Σε εξέλιξη..." : curStatus)
        notify(id: "progress", title: title, body: body)
    }

    // MARK: start / cancel
    func start() {
        guard !running else { return }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard detectSite(u) != nil else { status = "Βάλε link από υποστηριζόμενο site."; return }
        let fm = FileManager.default
        let outDir = fm.temporaryDirectory.appendingPathComponent("out").path
        try? fm.removeItem(atPath: outDir)
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workDir = support.appendingPathComponent("work").path
        try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        running = true
        log = ""; percent = ""; counter = ""; fraction = nil
        pct = 0; indeterminate = true; dlDone = 0; dlTotal = 0; curStatus = ""
        lastFile = nil
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
        }
        let reporter = UIReporter(self)
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = mode, d = Self.delays[delayIndex], ck = cookie, ql = Self.qualities[qualityIndex], orig = original

        task = Task {
            var finalMsg: String? = nil
            do {
                let files = try await runJob(url: u, name: nm, outDir: outDir, workRoot: workDir, mode: m, delay: d, cookie: ck, quality: ql, original: orig, cb: reporter)
                var shown: URL? = nil
                for f in files {
                    let dest = try saveToDocuments(URL(fileURLWithPath: f))
                    if shown == nil || ["pdf", "mp4"].contains(dest.pathExtension.lowercased()) { shown = dest }
                    appendLog("Αποθηκεύτηκε: Αρχεία/Gallery → PDF/GalleryToPDF/\(dest.lastPathComponent)")
                }
                lastFile = shown
                status = "Έτοιμο ✔  Το αρχείο είναι στο Αρχεία › Στο iPhone μου › Gallery → PDF › GalleryToPDF"
                finalMsg = "Έτοιμο ✔  Το αρχείο είναι στην εφαρμογή Αρχεία."
            } catch {
                let msg = error.localizedDescription
                if error is CancellationError || msg.contains("Cancelled") {
                    appendLog("Ακυρώθηκε."); status = "Ακυρώθηκε."
                } else if msg.contains("LimitReached") {
                    appendLog("Το e-hentai επέστρεψε μήνυμα ορίου εικόνων (509). Περίμενε λίγο και ξαναδοκίμασε· όσες εικόνες κατέβηκαν δεν θα ξανακατέβουν.")
                    status = "Όριο εικόνων."
                    finalMsg = "Όριο εικόνων. Περίμενε λίγο και ξαναδοκίμασε."
                } else {
                    appendLog("Σφάλμα: \(msg)"); status = "Σφάλμα."
                    finalMsg = "Σφάλμα. Άνοιξε την εφαρμογή για λεπτομέρειες."
                }
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["progress"])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["progress"])
            if let m = finalMsg { notify(id: "done", title: "Gallery → PDF", body: m) }
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }
    }

    func cancel() {
        status = "Ακύρωση..."
        task?.cancel()
    }

    private func saveToDocuments(_ file: URL) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("GalleryToPDF")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let dest = docs.appendingPathComponent(file.lastPathComponent)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: file, to: dest)
        return dest
    }

    func openLast() {
        guard let f = lastFile else { return }
        if ["pdf", "mp4", "mov", "m4v"].contains(f.pathExtension.lowercased()) { previewURL = f } else { shareURL = f }
    }
}
