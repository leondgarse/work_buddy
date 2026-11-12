import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

public struct ExtractedImage {
    /// e.g. "Image 3" or "Page 2"
    public var label: String
    /// Original file on disk, when the image is a standalone file (lets the coding agent open it).
    public var path: String?
    public var image: CGImage
    public var ocrText: String
}

public struct SourceDoc: Identifiable {
    public let id = UUID()
    public var url: URL
    public var kind: String
    public var text: String
    public var images: [ExtractedImage]
    /// Text found by OCR in page renders that the PDF text layer doesn't contain (PDF only).
    public var extraOCR: [String: String] = [:]
}

public enum ExtractError: LocalizedError {
    case unsupported(String), unreadable(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Unsupported file: \(s)"
        case .unreadable(let s): return "Could not read: \(s)"
        }
    }
}

public enum Extractor {
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp"]
    static let richExts: Set<String> = ["rtf", "doc", "docx", "html", "htm", "odt", "webarchive"]
    static let plainExts: Set<String> = ["txt", "md", "markdown", "eml", "emlx", "log", "csv", "json"]

    /// Expands folders (but not `.rtfd` packages) into the files we know how to read.
    public static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && u.pathExtension.lowercased() != "rtfd" {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])) ?? []
                out += expand(items.sorted { $0.lastPathComponent < $1.lastPathComponent })
            } else if isSupported(u) {
                out.append(u)
            }
        }
        return out
    }

    public static func isSupported(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        return e == "rtfd" || e == "pdf" || imageExts.contains(e) || richExts.contains(e) || plainExts.contains(e)
    }

    public static func extract(_ url: URL) throws -> SourceDoc {
        let e = url.pathExtension.lowercased()
        if e == "rtfd" { return try rtfd(url) }
        if e == "pdf" { return try pdf(url) }
        if imageExts.contains(e) {
            guard let img = loadCGImage(url) else { throw ExtractError.unreadable(url.path) }
            return SourceDoc(url: url, kind: "image", text: "",
                             images: [ExtractedImage(label: "Image 1", path: url.path, image: img, ocrText: ocr(img))])
        }
        if richExts.contains(e) {
            let a = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return SourceDoc(url: url, kind: e, text: clean(a.string), images: [])
        }
        if plainExts.contains(e) {
            var s = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            if e == "eml" || e == "emlx" { s = EML.readable(s) }
            return SourceDoc(url: url, kind: e == "eml" || e == "emlx" ? "email" : "text", text: clean(s), images: [])
        }
        throw ExtractError.unsupported(url.lastPathComponent)
    }

    // MARK: rtfd (Mail "Save As… Rich Text Format with attachments")

    static func rtfd(_ url: URL) throws -> SourceDoc {
        let attr = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                          documentAttributes: nil)
        let ns = attr.string as NSString
        var text = ""
        var images: [ExtractedImage] = []
        var seen: [Data] = []
        // Mail renames attachments on disk ("1__#$!@%!#__unknown.png"); map preferred names to real files.
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            guard let att = value as? NSTextAttachment else {
                text += ns.substring(with: range)
                return
            }
            let fw = att.fileWrapper
            guard let data = fw?.regularFileContents else { return }
            // Quoted replies repeat the same attachments; point back to the first copy.
            if let i = seen.firstIndex(of: data) {
                text += "\n[same as Image \(i + 1)]\n"
                return
            }
            guard let img = cgImage(data), img.width >= 48, img.height >= 48 else { return }  // separators / icons
            seen.append(data)
            let label = "Image \(images.count + 1)"
            var path: String?
            if let name = fw?.filename ?? fw?.preferredFilename {
                if onDisk.contains(name) { path = url.appendingPathComponent(name).path }
            }
            if path == nil {  // find by identical bytes
                path = onDisk.first { (try? Data(contentsOf: url.appendingPathComponent($0))) == data }
                    .map { url.appendingPathComponent($0).path }
            }
            text += "\n[\(label)]\n"
            images.append(ExtractedImage(label: label, path: path, image: img, ocrText: ocr(img)))
        }
        return SourceDoc(url: url, kind: "email", text: clean(text), images: images)
    }

    // MARK: PDF (e.g. Lark chat export)

    static func pdf(_ url: URL, maxPages: Int = 30) throws -> SourceDoc {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.unreadable(url.path) }
        var text = ""
        var images: [ExtractedImage] = []
        var extra: [String: String] = [:]
        for i in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: i) else { continue }
            let label = "Page \(i + 1)"
            let pageText = pageLines(page)
            text += "\n--- \(label) ---\n" + pageText + "\n"
            guard let img = render(page) else { continue }
            let o = ocr(img)
            // Keep only OCR lines the text layer doesn't already have: that's the text inside pictures.
            let known = normalize(pageText)
            let novel = o.split(whereSeparator: \.isNewline).map(String.init)
                .filter { let n = normalize($0); return n.count >= 2 && !known.contains(n) }
            if !novel.isEmpty { extra[label] = novel.joined(separator: "\n") }
            images.append(ExtractedImage(label: label, path: nil, image: img, ocrText: o))
        }
        if doc.pageCount > maxPages { text += "\n[... \(doc.pageCount - maxPages) more pages omitted]\n" }
        return SourceDoc(url: url, kind: "pdf", text: clean(text), images: images, extraOCR: extra)
    }

    /// Rebuild text lines from positioned fragments. Some exporters (Lark) split words at kerning
    /// pairs, so `page.string` comes out as "Ch\na\nt b\netween".
    static func pageLines(_ page: PDFPage) -> String {
        guard let all = page.selection(for: page.bounds(for: .mediaBox)) else { return page.string ?? "" }
        let frags = all.selectionsByLine().compactMap { s -> (String, CGRect)? in
            guard let t = s.string, !t.isEmpty else { return nil }
            return (t.replacingOccurrences(of: "\n", with: " "), s.bounds(for: page))
        }
        guard !frags.isEmpty else { return page.string ?? "" }
        var rows: [[(String, CGRect)]] = []
        for f in frags.sorted(by: { $0.1.midY > $1.1.midY }) {
            if let last = rows.last?.first, abs(last.1.midY - f.1.midY) < min(last.1.height, f.1.height) * 0.5 {
                rows[rows.count - 1].append(f)
            } else { rows.append([f]) }
        }
        return rows.map { row in
            var line = "", prevEnd: CGFloat? = nil
            for (t, r) in row.sorted(by: { $0.1.minX < $1.1.minX }) {
                if t == "\u{FFFC}" { line += "[picture]"; prevEnd = r.maxX; continue }
                if let p = prevEnd, r.minX - p > r.height * 0.15, !line.hasSuffix(" "), !t.hasPrefix(" ") { line += " " }
                line += t
                prevEnd = r.maxX
            }
            return line
        }.joined(separator: "\n")
    }

    static func render(_ page: PDFPage, longSide: CGFloat = 2400) -> CGImage? {
        let b = page.bounds(for: .mediaBox)
        let scale = min(3.0, longSide / max(b.width, b.height))
        let w = Int(b.width * scale), h = Int(b.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: helpers

    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func ocr(_ img: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// Collapse whitespace noise from Mail/Lark exports and trim separator lines.
    static func clean(_ s: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.count > 20, Set(line).count == 1 { line = String(line.prefix(20)) }  // ===== bars
            if line.isEmpty { blank += 1; if blank > 1 { continue } } else { blank = 0 }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Minimal .eml reader: headers + text/plain parts (quoted-printable / base64 decoded).
enum EML {
    static func readable(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "\r\n\r\n").count > 1 ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        guard let split = parts.range(of: "\n\n") else { return raw }
        let header = String(parts[..<split.lowerBound])
        let keep = header.replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
            .split(separator: "\n").filter {
                let l = $0.lowercased()
                return ["from:", "to:", "cc:", "date:", "subject:"].contains { l.hasPrefix($0) }
            }.joined(separator: "\n")
        let body = String(parts[split.upperBound...])
        var texts: [String] = []
        let blocks = body.components(separatedBy: "\n--")
        for b in blocks where b.lowercased().contains("content-type: text/plain") || blocks.count == 1 {
            guard let r = b.range(of: "\n\n") else { if blocks.count == 1 { texts.append(b) }; continue }
            let h = b[..<r.lowerBound].lowercased()
            var t = String(b[r.upperBound...])
            if h.contains("quoted-printable") { t = qp(t) }
            if h.contains("base64"), let d = Data(base64Encoded: t.replacingOccurrences(of: "\n", with: "")),
               let s = String(data: d, encoding: .utf8) { t = s }
            texts.append(t)
        }
        return keep + "\n\n" + (texts.isEmpty ? body : texts.joined(separator: "\n"))
    }

    static func qp(_ s: String) -> String {
        var bytes: [UInt8] = []
        let u = Array(s.replacingOccurrences(of: "=\n", with: "").utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "="), i + 2 < u.count,
               let v = UInt8(String(bytes: u[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(v); i += 3
            } else { bytes.append(u[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
