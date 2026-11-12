import AppKit
import Foundation
import ReqCore

struct Brief: Identifiable {
    let id = UUID()
    var text: String
    var sourceIDs: [SourceDoc.ID]
    var caseEvidence: [CaseEvidence] = []
    var caseRuns: [CaseReport] { caseEvidence.map(\.report) }
    var casesBaseURL: String = ""
    var verification = ""
    var verificationVerdict = ""
    var title: String { PromptBuilder.title(of: text) }
}

@MainActor
final class AppStore: ObservableObject {
    private let persistSettings: Bool
    init(settings: AppSettings = .load(), persistSettings: Bool = true) {
        self.settings = settings; self.persistSettings = persistSettings
    }
    @Published var settings: AppSettings {
        didSet {
            if persistSettings { settings.save() }
            if oldValue.casesBaseURL != settings.casesBaseURL {
                caseTask?.cancel()
                for demo in caseReviews.keys { caseReviews[demo]?.invalidate() }
                caseHealth = nil
                casesMessage = "API address changed. Refresh, rerun and confirm the results."
            }
        }
    }
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
    @Published var verifying = false
    private var task: Task<Void, Never>?
    @Published var caseHealth: CasesHealth?
    @Published var selectedDemos: Set<String> = []
    @Published var caseReviews: [String: CaseReview] = [:]
    @Published var caseMessages: [String: String] = [:]
    @Published var casesMessage = ""
    @Published var loadingCases = false
    @Published var caseProviderChosen = false
    @Published var runningCase: String?
    private var caseTask: Task<Void, Never>?
    var hasCases: Bool { !selectedDemos.isEmpty }
    var confirmedEvidence: [CaseEvidence] {
        selectedDemos.sorted().compactMap { caseReviews[$0]?.evidence }
    }
    var briefSources: [SourceDoc] { checkedSources + confirmedEvidence.map(\.source) }
    var canGenerate: Bool {
        guard !busy, runningCase == nil, extracting == 0, !checkedSources.isEmpty else { return false }
        return !hasCases || (caseProviderChosen && selectedDemos.count == confirmedEvidence.count)
    }
    var generationHint: String {
        if checkedSources.isEmpty { return "Add and select the email or chat files for this issue." }
        if runningCase != nil { return "Wait for the case result, then review and confirm it." }
        if hasCases && selectedDemos.count != confirmedEvidence.count {
            return "Run each selected case and confirm its output, or uncheck it to skip."
        }
        if hasCases && !caseProviderChosen { return "Choose the model that will receive the confirmed results." }
        return hasCases ? "The brief will use the confirmed results. It will not rerun the cases." : "Cases are optional. Generate from your selected sources."
    }

    func preferLocalForCases() {
        if let p = settings.providers.first(where: AppSettings.isLocal) {
            settings.selectedProviderID = p.id; caseProviderChosen = true
        } else {
            caseProviderChosen = false
            casesMessage = "No local model configured. Choose a model explicitly to send confirmed results."
        }
    }

    func toggleDemo(_ demo: String, on: Bool) {
        guard runningCase == nil, !busy else { return }
        let wasEmpty = !hasCases
        if on {
            selectedDemos.insert(demo)
            if caseReviews[demo] == nil { caseReviews[demo] = CaseReview(demo: demo) }
            if wasEmpty { preferLocalForCases() }
        } else {
            selectedDemos.remove(demo)
            caseReviews[demo]?.confirm(false)
        }
    }

    func refreshCases() async {
        guard !loadingCases else { return }
        loadingCases = true
        defer { loadingCases = false }
        let address = settings.casesBaseURL
        do {
            let health = try await CasesAPI(baseURL: address).health()
            guard address == settings.casesBaseURL else { return }
            caseHealth = health; casesMessage = ""
        } catch {
            guard address == settings.casesBaseURL else { return }
            caseHealth = nil; casesMessage = error.localizedDescription
        }
    }

    func setSlot(_ i: Int, demo: String, url: URL?) {
        guard runningCase == nil, !busy else { return }
        caseReviews[demo]?.setFile(url, at: i)
        caseMessages[demo] = "Inputs changed. Run the case and review the new output."
    }

    func pickSlot(_ i: Int, demo: String) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if demo == "pdf_match" { panel.allowedContentTypes = [.pdf] }
        if panel.runModal() == .OK, let url = panel.url { setSlot(i, demo: demo, url: url) }
    }

    @discardableResult
    func pasteSlot(_ i: Int, demo: String) -> Bool {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first { setSlot(i, demo: demo, url: url); return true }
        if let text = NSPasteboard.general.string(forType: .string) {
            let path = (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { setSlot(i, demo: demo, url: URL(fileURLWithPath: path)); return true }
        }
        return false
    }

    func confirmCase(_ demo: String, on: Bool) { caseReviews[demo]?.confirm(on) }

    func runCase(_ demo: String) {
        guard !busy, runningCase == nil, selectedDemos.contains(demo),
              caseHealth?.demos[demo]?.live == true, caseReviews[demo]?.canRun == true,
              let revision = caseReviews[demo]?.beginRun() else { return }
        let files = caseReviews[demo]!.orderedFiles, address = settings.casesBaseURL
        runningCase = demo; caseMessages[demo] = "Uploading and running…"
        caseTask = Task {
            defer { runningCase = nil }
            do {
                let report = try await CasesAPI(baseURL: address).run(demo: demo, files: files) {
                    self.caseMessages[demo] = $0
                }
                try Task.checkCancellation()
                guard address == settings.casesBaseURL,
                      caseReviews[demo]?.receive(report, revision: revision) == true else { return }
                caseMessages[demo] = report.inputsIncomplete ? report.verdict : "Run complete. Review the output below."
            } catch {
                caseMessages[demo] = Task.isCancelled ? "Stopped polling. You can run again; the server may still finish." : error.localizedDescription
            }
        }
    }

    func stopCase() { caseTask?.cancel() }

    func verifyCurrentBrief() {
        guard let i = currentIndex, !busy, runningCase == nil else { return }
        let brief = briefs[i]
        guard !brief.caseRuns.isEmpty else { return }
        busy = true; verifying = true
        task = Task {
            defer { busy = false; verifying = false }
            do {
                let api = try CasesAPI(baseURL: brief.casesBaseURL)
                var results: [CaseReport] = []
                for evidence in brief.caseEvidence {
                    status = "Verifying \(evidence.demo) uploads…"
                    results.append(try await api.run(demo: evidence.demo, files: evidence.files))
                }
                if let index = briefs.firstIndex(where: { $0.id == brief.id }) {
                    briefs[index].verificationVerdict = results.contains { $0.inputsIncomplete } ? "inputs incomplete"
                        : results.allSatisfy { $0.status == "passed" } ? "passed" : "failed"
                    briefs[index].verification = results.map { "\($0.label): \($0.verdict)" }.joined(separator: "\n")
                    let observations = results.enumerated().filter { !$0.element.inputsIncomplete }.map { $0.element.source(files: brief.caseEvidence[$0.offset].files) }
                    sources.append(contentsOf: observations)
                    briefs[index].sourceIDs += observations.map(\.id)
                    briefs[index].text += "\n\n## Verification runs\n" + results.map { "- \($0.label): \($0.verdict)" }.joined(separator: "\n")
                }
                status = "Verification finished."
            } catch {
                status = Task.isCancelled ? "Verification stopped. The server run may still finish." : error.localizedDescription
                if let index = briefs.firstIndex(where: { $0.id == brief.id }) {
                    briefs[index].verification = status
                    briefs[index].verificationVerdict = Task.isCancelled ? "stopped" : "error"
                }
            }
        }
    }

    var provider: Provider? { settings.selectedProvider }
    var inputSources: [SourceDoc] { sources.filter { $0.kind != "case report" } }
    var checkedSources: [SourceDoc] { inputSources.filter { checked.contains($0.id) } }

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
        return "\(c.count) of \(inputSources.count) source(s) selected, \(c.reduce(0) { $0 + $1.images.count }) image(s)."
    }

    func toggle(_ id: SourceDoc.ID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
        status = summary
    }

    func setAll(_ on: Bool) { checked = on ? Set(inputSources.map(\.id)) : []; status = summary }

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
        let b = PromptBuilder.build(docs: briefSources, settings: settings, notes: notes, sendImages: vision)
        let sys = b.messages.first?.parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined() ?? ""
        return "### SYSTEM\n\(sys)\n\n### USER\n\(b.preview)"
    }

    /// One request for the ticked sources -> one new brief tab.
    func generate() {
        guard let p = provider, canGenerate else { return }
        let evidence = confirmedEvidence
        let reports = evidence.map(\.report)
        let reportDocs = evidence.map(\.source)
        let docs = checkedSources + reportDocs
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
                if !reports.isEmpty {
                    text += "\n\n## Case runs\n" + reports.map { "- \($0.label): run `\($0.run)` — \($0.verdict)" }.joined(separator: "\n")
                }
                sources.append(contentsOf: reportDocs)
                let b = Brief(text: text, sourceIDs: docs.map(\.id), caseEvidence: evidence,
                              casesBaseURL: settings.casesBaseURL)
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
