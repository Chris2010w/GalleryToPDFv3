import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

struct PageImage { let path: String; let w: Int; let h: Int; let gray: Bool }

// MARK: - JPEG header parsing (so plain JPEGs go into the PDF untouched, like the Android version)
func jpegInfo(_ path: String) -> (w: Int, h: Int, comps: Int)? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let head = try? fh.read(upToCount: 1 << 20), head.count > 4 else { return nil }
    let b = [UInt8](head)
    guard b[0] == 0xFF, b[1] == 0xD8 else { return nil }
    var p = 2
    while p + 4 < b.count {
        if b[p] != 0xFF { p += 1; continue }
        while p < b.count && b[p] == 0xFF { p += 1 }
        if p >= b.count { return nil }
        let marker = b[p]; p += 1
        if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { continue }
        if p + 2 > b.count { return nil }
        let len = Int(b[p]) << 8 | Int(b[p + 1])
        if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
            guard p + 8 < b.count else { return nil }
            let h = Int(b[p + 3]) << 8 | Int(b[p + 4])
            let w = Int(b[p + 5]) << 8 | Int(b[p + 6])
            let comps = Int(b[p + 7])
            return (w, h, comps)
        }
        if marker == 0xDA { return nil }
        p += len
    }
    return nil
}

/// Decodes any image ImageIO understands (including WebP) and saves it as JPEG on a white background.
func convertToJPEG(src: String, dst: String) throws -> (Int, Int) {
    var result: (Int, Int)? = nil
    var err: String? = nil
    autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            err = "το iOS δεν μπόρεσε να διαβάσει το αρχείο"
            return
        }
        let w = img.width, h = img.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            err = "αποτυχία δημιουργίας εικόνας"
            return
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            err = "αποτυχία αποθήκευσης JPEG"
            return
        }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        if CGImageDestinationFinalize(dest) { result = (w, h) } else { err = "η αποθήκευση σε JPEG απέτυχε" }
    }
    if let r = result { return r }
    throw JobError.message(err ?? "άγνωστο σφάλμα εικόνας")
}

func prepareImages(folder: String, tmp: String, cb: Reporter, step: (Int, Int) -> Void) -> [PageImage] {
    let files = listImageNames(folder)
    var out: [PageImage] = []
    for (i, f) in files.enumerated() {
        let src = (folder as NSString).appendingPathComponent(f)
        let ext = (f as NSString).pathExtension.lowercased()
        let dst = (tmp as NSString).appendingPathComponent((f as NSString).deletingPathExtension + ".jpg")
        if ext == "jpg" || ext == "jpeg", let info = jpegInfo(src), info.comps == 1 || info.comps == 3 {
            out.append(PageImage(path: src, w: info.w, h: info.h, gray: info.comps == 1))
        } else {
            do {
                let (w, h) = try convertToJPEG(src: src, dst: dst)
                out.append(PageImage(path: dst, w: w, h: h, gray: false))
            } catch {
                cb.log("Παράλειψη \(f): \(error.localizedDescription)")
            }
        }
        step(i + 1, files.count)
    }
    return out
}

// MARK: - PDF writer (one page per image, JPEG data embedded as-is)
final class OutFile {
    let fh: FileHandle
    var pos: UInt64 = 0
    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { throw JobError.message("Δεν μπόρεσα να γράψω το αρχείο.") }
        fh = h
    }
    func write(_ d: Data) { fh.write(d); pos += UInt64(d.count) }
    func write(_ s: String) { write(Data(s.utf8)) }
    func close() { try? fh.close() }
}

func buildPDF(pages: [PageImage], path: String, title: String?) throws {
    let n = pages.count
    let f = try OutFile(path: path)
    defer { f.close() }
    var offsets: [Int: UInt64] = [:]

    func obj(_ num: Int, _ body: String) {
        offsets[num] = f.pos
        f.write("\(num) 0 obj\n\(body)\nendobj\n")
    }

    f.write(Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
    let kids = (0..<n).map { "\(4 + 3 * $0) 0 R" }.joined(separator: " ")
    obj(2, "<< /Type /Pages /Kids [\(kids)] /Count \(n) >>")
    if let t = title, !t.isEmpty {
        let hex = "FEFF" + t.utf16.map { String(format: "%04X", $0) }.joined()
        obj(3, "<< /Title <\(hex)> /Producer (GalleryToPDF) >>")
    } else {
        obj(3, "<< /Producer (GalleryToPDF) >>")
    }

    for (i, p) in pages.enumerated() {
        let pageN = 4 + 3 * i, imgN = 5 + 3 * i, contN = 6 + 3 * i
        let pw = Double(p.w) * 0.75, ph = Double(p.h) * 0.75
        obj(pageN, String(format: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] /Resources << /XObject << /Im0 %d 0 R >> >> /Contents %d 0 R >>",
                          pw, ph, imgN, contN))
        guard let data = FileManager.default.contents(atPath: p.path) else { throw JobError.message("Δεν διαβάστηκε η εικόνα \(p.path)") }
        let cs = p.gray ? "/DeviceGray" : "/DeviceRGB"
        offsets[imgN] = f.pos
        f.write("\(imgN) 0 obj\n<< /Type /XObject /Subtype /Image /Width \(p.w) /Height \(p.h) /ColorSpace \(cs) /BitsPerComponent 8 /Filter /DCTDecode /Length \(data.count) >>\nstream\n")
        f.write(data)
        f.write("\nendstream\nendobj\n")
        let content = String(format: "q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q", pw, ph)
        obj(contN, "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
    }

    let totalObjs = 3 + 3 * n
    let xrefPos = f.pos
    var xref = "xref\n0 \(totalObjs + 1)\n0000000000 65535 f \n"
    for num in 1...totalObjs { xref += String(format: "%010llu 00000 n \n", offsets[num] ?? 0) }
    xref += "trailer\n<< /Size \(totalObjs + 1) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
    f.write(xref)
}

// MARK: - CBZ (ZIP, stored / no compression)
private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
    return c
}
func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

func buildCBZ(folder: String, path: String) throws -> Int {
    let files = listImageNames(folder)
    let part = path + ".part"
    let f = try OutFile(path: part)
    struct Entry { let name: Data; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    var entries: [Entry] = []

    func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

    for name in files {
        guard let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(name)) else { continue }
        let nameData = Data(name.utf8)
        let crc = crc32(data)
        let e = Entry(name: nameData, crc: crc, size: UInt32(data.count), offset: UInt32(f.pos))
        entries.append(e)
        var h = Data()
        h += le32(0x04034B50); h += le16(20); h += le16(0x0800); h += le16(0)
        h += le16(0); h += le16(0x21)
        h += le32(crc); h += le32(e.size); h += le32(e.size)
        h += le16(UInt16(nameData.count)); h += le16(0)
        f.write(h); f.write(nameData); f.write(data)
    }
    let cdStart = f.pos
    for e in entries {
        var h = Data()
        h += le32(0x02014B50); h += le16(20); h += le16(20); h += le16(0x0800); h += le16(0)
        h += le16(0); h += le16(0x21)
        h += le32(e.crc); h += le32(e.size); h += le32(e.size)
        h += le16(UInt16(e.name.count)); h += le16(0); h += le16(0); h += le16(0); h += le16(0)
        h += le32(0); h += le32(e.offset)
        f.write(h); f.write(e.name)
    }
    let cdSize = f.pos - cdStart
    var end = Data()
    end += le32(0x06054B50); end += le16(0); end += le16(0)
    end += le16(UInt16(entries.count)); end += le16(UInt16(entries.count))
    end += le32(UInt32(cdSize)); end += le32(UInt32(cdStart)); end += le16(0)
    f.write(end)
    f.close()
    try? FileManager.default.removeItem(atPath: path)
    try FileManager.default.moveItem(atPath: part, toPath: path)
    return entries.count
}

// MARK: - finish (port of finish() in gallery_core.py)
func finishJob(imgDir: String, name: String, title: String, outDir: String, workRoot: String,
               total: Int, failed: [Int], mode: String, cb: Reporter) throws -> [String] {
    let count = listImageNames(imgDir).count
    if count == 0 { throw JobError.message("Δεν κατέβηκε καμία εικόνα.") }
    let steps = stepsFor(total, mode)
    var pos = max(total, 1)
    var outputs: [String] = []
    let fm = FileManager.default
    let conv = (workRoot as NSString).appendingPathComponent("conv_" + UUID().uuidString)
    try fm.createDirectory(atPath: conv, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: conv) }
    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    if mode == "pdf" || mode == "both" {
        cb.log("== Προετοιμασία εικόνων ==")
        let base = pos
        let pages = prepareImages(folder: imgDir, tmp: conv, cb: cb) { n, t in
            cb.progress(base + n, steps, "Προετοιμασία \(n)/\(t)")
        }
        if pages.isEmpty { throw JobError.message("Δεν κατέβηκε καμία εικόνα.") }
        pos += total
        cb.progress(pos, steps, "Δημιουργία PDF...")
        let pdfPath = (outDir as NSString).appendingPathComponent(name + ".pdf")
        try buildPDF(pages: pages, path: pdfPath, title: title)
        pos += 1
        outputs.append(pdfPath)
        cb.log("Έτοιμο PDF (\(pages.count) σελίδες)")
    }
    if mode == "cbz" || mode == "both" {
        cb.progress(pos, steps, "Δημιουργία CBZ...")
        let cbzPath = (outDir as NSString).appendingPathComponent(name + ".cbz")
        let n = try buildCBZ(folder: imgDir, path: cbzPath)
        pos += 1
        outputs.append(cbzPath)
        cb.log("Έτοιμο CBZ (\(n) σελίδες)")
    }
    if !failed.isEmpty {
        cb.log("Προσοχή: απέτυχαν οι σελίδες \(failed). Πάτα ξανά «Κατέβασε» με το ίδιο link: όσες κατέβηκαν δεν θα ξανακατέβουν.")
    } else {
        try? fm.removeItem(atPath: imgDir)
    }
    cb.progress(steps, steps, "Έτοιμο ✔  (\(count) σελίδες)")
    return outputs
}
