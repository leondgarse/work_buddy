import AppKit
import Foundation
import ReqCore

struct Brief: Identifiable {
    let id = UUID()
    var text: String
    var sourceIDs: [SourceDoc.ID]
    var title: String { PromptBuilder.title(of: text) }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var settings = AppSettings.load() { didSet { settings.save() } }
    @Published var sources: [SourceDoc] = []
    /// Sources ticked for the next brief. New files come in ticked.
    @Published var checked: Set<SourceDoc.ID> = []
    @Published var notes = ""
    /// Streaming text of the request in flight.
    @Published var output = ""
    /// Generated briefs, one per requirement, newest last.
    @Published var briefs: [Brief] = []
    @Published var selectedBrief: Brief.ID?
    @Published var status = "Drop emails (.rtfd / .eml), Lark chat PDFs, screenshots or folders."
    @Published var busy = false
    @Published var extracting = 0
    @Published var reasoningChars = 0
    private var task: Task<Void, Never>?

    var provider: Provider? { settings.selectedProvider }
    var checkedSources: [SourceDoc] { sources.filter { checked.contains($0.id) } }

    func add(_ urls: [URL]) {
        let files = Extractor.expand(urls).filter { u in !sources.contains { $0.url == u } }
        guard !files.isEmpty else {
            if !urls.isEmpty { status = "Nothing new or readable in what was dropped." }
            return
        }
        extracting += files.count
        for u in files {
            Task.detached(priority: .userInitiated) {
                let r = Result { try Extractor.extract(u) }
                await MainActor.run {
                    self.extracting -= 1
                    switch r {
                    case .success(let d):
                        self.sources.append(d)
                        self.checked.insert(d.id)
                    case .failure(let e): self.status = e.localizedDescription
                    }
                    if self.extracting == 0 { self.status = self.summary }
                }
            }
        }
    }

    /// Accepts newline-separated paths (with ~ expansion and optional quotes).
    func addPaths(_ text: String) {
        let urls = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        add(urls)
    }

    var summary: String {
        let c = checkedSources
        return "\(c.count) of \(sources.count) source(s) selected, \(c.reduce(0) { $0 + $1.images.count }) image(s)."
    }

    func toggle(_ id: SourceDoc.ID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
        status = summary
    }

    func setAll(_ on: Bool) { checked = on ? Set(sources.map(\.id)) : []; status = summary }

    func remove(_ id: SourceDoc.ID) { sources.removeAll { $0.id == id }; checked.remove(id); status = summary }
    func clear() { sources.removeAll(); checked.removeAll(); status = summary }

    /// 1-based numbers of the briefs a source went into.
    func usedIn(_ id: SourceDoc.ID) -> [Int] {
        briefs.enumerated().filter { $0.element.sourceIDs.contains(id) }.map { $0.offset + 1 }
    }

    func previewPrompt() async -> String {
        guard let p = provider else { return "" }
        let client = LLMClient(provider: p, apiKey: APIKeys.resolve(for: p))
        let vision = await client.resolveVision()
        let b = PromptBuilder.build(docs: checkedSources, settings: settings, notes: notes, sendImages: vision)
        let sys = settings.systemPrompt.isEmpty ? PromptBuilder.defaultSystemPrompt : settings.systemPrompt
        return "### SYSTEM\n\(sys)\n\n### USER\n\(b.preview)"
    }

    /// One request for the ticked sources -> one new brief tab.
    func generate() {
        let docs = checkedSources
        guard let p = provider, !docs.isEmpty, !busy else { return }
        busy = true
        output = ""
        reasoningChars = 0
        status = "Preparing…"
        let settings = settings, notes = notes
        task = Task {
            defer { busy = false }
            let key = await Task.detached { APIKeys.resolve(for: p) }.value
            if key == nil && !p.baseURL.contains("localhost") && !p.baseURL.contains("127.0.0.1") {
                status = LLMError.noKey(p.name).localizedDescription
                return
            }
            let client = LLMClient(provider: p, apiKey: key)
            let vision = await client.resolveVision()
            let built = await Task.detached {
                PromptBuilder.build(docs: docs, settings: settings, notes: notes, sendImages: vision)
            }.value
            let mode = vision ? "\(built.imageCount) image(s)" : "OCR text"
            status = "Asking \(p.model) with \(docs.count) source(s), \(mode)…"
            let t0 = Date()
            var text = ""
            do {
                text = try await client.complete(built.messages) { c, r in
                    Task { @MainActor in
                        self.output += c
                        self.reasoningChars += r.count
                        if !r.isEmpty && self.output.isEmpty { self.status = "Thinking… (\(self.reasoningChars) chars)" }
                        else if !c.isEmpty { self.status = "Writing…" }
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)  // let queued deltas land first
                status = String(format: "Brief %d done in %.0fs with %@ via %@.", briefs.count + 1,
                                Date().timeIntervalSince(t0), mode, p.name)
                if built.droppedImages > 0 { status += " \(built.droppedImages) image(s) over the limit were skipped." }
            } catch is CancellationError {
                text = output; status = "Stopped."
            } catch {
                text = output; status = error.localizedDescription
            }
            output = ""
            if !text.isEmpty {
                let b = Brief(text: text, sourceIDs: docs.map(\.id))
                briefs.append(b)
                selectedBrief = b.id
            }
        }
    }

    func stop() { task?.cancel() }

    var currentIndex: Int? { briefs.firstIndex { $0.id == selectedBrief } }
    var currentBrief: String { currentIndex.map { briefs[$0].text } ?? "" }

    func closeBrief(_ id: Brief.ID) {
        briefs.removeAll { $0.id == id }
        if selectedBrief == id { selectedBrief = briefs.last?.id }
    }

    func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentBrief, forType: .string)
        status = "Copied “\(PromptBuilder.title(of: currentBrief))”."
    }

    func saveOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = String(PromptBuilder.title(of: currentBrief)
            .replacingOccurrences(of: "/", with: "-").prefix(80)) + ".md"
        if panel.runModal() == .OK, let u = panel.url {
            do { try currentBrief.write(to: u, atomically: true, encoding: .utf8); status = "Saved \(u.path)" }
            catch { status = error.localizedDescription }
        }
    }

    static var pastedDir: URL {
        let d = AppSettings.fileURL.deletingLastPathComponent().appendingPathComponent("Pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Saves image data as a PNG file (so the coding agent gets a real path) and adds it as a source.
    func addImageData(_ data: Data) {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else {
            status = "Clipboard image could not be read."
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Pasted \(f.string(from: Date()))"
        var url = Self.pastedDir.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.pastedDir.appendingPathComponent("\(base) \(n).png"); n += 1
        }
        do { try png.write(to: url); add([url]) } catch { status = error.localizedDescription }
    }

    /// ⌘V: files or an image on the clipboard become sources. Returns false for anything else,
    /// so normal text paste keeps working.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls)
            return true
        }
        for t in [NSPasteboard.PasteboardType.png, .tiff] {
            if let d = pb.data(forType: t) { addImageData(d); return true }
        }
        return false
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }
}
