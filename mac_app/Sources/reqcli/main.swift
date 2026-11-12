import Foundation
import ReqCore

// Headless version of the app's pipeline, sharing its settings file.
// usage: reqcli [--provider NAME] [--model ID] [--images|--ocr] [--notes TEXT] [--dry-run]
//               [--extra JSON] [--system FILE] [--image-side PX] FILE...

var args = Array(CommandLine.arguments.dropFirst())
var settings = AppSettings.load()
var providerName: String?, model: String?, vision: VisionMode?, notes = "", dryRun = false
var extra: String?, systemFile: String?
var files: [URL] = [], demoFiles: [URL] = []
var caseIDs: [String] = [], demoRun: String?, strict = false, casesOnly = false, caseEvents = false
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func value(_ option: String) -> String {
    guard !args.isEmpty, !args[0].hasPrefix("--") else { err("missing value for \(option)"); exit(2) }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--case": caseIDs.append(value(a))
    case "--demo-run": demoRun = value(a)
    case "--demo-file": demoFiles.append(URL(fileURLWithPath: (value(a) as NSString).expandingTildeInPath))
    case "--cases-url": settings.casesBaseURL = value(a)
    case "--strict": strict = true
    case "--cases-only": casesOnly = true
    case "--case-events": caseEvents = true
    case "--provider": providerName = value(a)
    case "--model": model = value(a)
    case "--images": vision = .images
    case "--ocr": vision = .ocr
    case "--notes": notes = value(a)
    case "--dry-run": dryRun = true
    case "--extra": extra = value(a)          // JSON merged into the request, e.g. {"temperature":0.3}
    case "--system": systemFile = value(a)    // system prompt file (A/B tests)
    case "--print-system": print(PromptBuilder.defaultSystemPrompt); exit(0)
    case "--image-side": PromptBuilder.imageLongSide = Int(value(a)) ?? 1600
    case "-h", "--help":
        print("usage: reqcli [--provider NAME] [--model ID] [--images|--ocr] [--notes TEXT] [--dry-run] [--extra JSON] [--system FILE] [--image-side PX] FILE...")
        print("cases: [--case DEMO/ID]... [--demo-run DEMO --demo-file FILE ...] [--cases-url URL] [--strict] [--cases-only] [--case-events]")
        print("--cases-only prints reports without calling a model; --dry-run runs cases and previews the prompt.")
        print("providers: " + settings.providers.map(\.name).joined(separator: ", "))
        exit(0)
    default:
        if a.hasPrefix("--") { err("unknown option: \(a)"); exit(2) }
        files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
    }
}

let hasCases = !caseIDs.isEmpty || demoRun != nil
if casesOnly && !hasCases { err("--cases-only needs --case or --demo-run"); exit(2) }
if !demoFiles.isEmpty && demoRun == nil { err("--demo-file needs --demo-run"); exit(2) }
var docs: [SourceDoc] = []
for u in Extractor.expand(files) {
    do { docs.append(try Extractor.extract(u)); err("extracted \(u.lastPathComponent): \(docs.last!.text.count) chars, \(docs.last!.images.count) images") }
    catch { err("skip \(u.lastPathComponent): \(error.localizedDescription)") }
}
var reports: [CaseReport] = []
do {
    if hasCases {
        let api = try CasesAPI(baseURL: settings.casesBaseURL)
        for key in caseIDs {
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CasesError.inputs("--case must be DEMO/ID") }
            let report = try await api.run(demo: String(parts[0]), id: String(parts[1]), strict: strict, includeEvents: caseEvents) { err("\(key): \($0)") }
            guard !report.inputsIncomplete else { throw CasesError.inputs(report.verdict) }
            reports.append(report)
        }
        if let demoRun {
            let report = try await api.run(demo: demoRun, files: demoFiles, includeEvents: caseEvents) { err("\(demoRun): \($0)") }
            guard !report.inputsIncomplete else { throw CasesError.inputs(report.verdict) }
            reports.append(report)
        }
    }
    if casesOnly {
        for report in reports { print(report.raw.pretty) }
        exit(reports.contains { $0.status != "passed" } ? 1 : 0)
    }
    docs += reports.enumerated().map { i, report in
        report.source(files: i == caseIDs.count && demoRun != nil ? demoFiles : [])
    }
} catch { err(error.localizedDescription); exit(1) }
guard !docs.isEmpty else { err("no readable inputs"); exit(2) }

if hasCases && providerName == nil {
    guard let local = settings.providers.first(where: AppSettings.isLocal) else {
        err("Choose --provider explicitly for case reports; no local provider is configured."); exit(2)
    }
    settings.selectedProviderID = local.id
}
if let name = providerName, !settings.providers.contains(where: { $0.name.lowercased().hasPrefix(name.lowercased()) }) {
    err("unknown provider"); exit(2)
}
guard var provider = providerName.map({ n in settings.providers.first { $0.name.lowercased().hasPrefix(n.lowercased()) } })
        ?? settings.selectedProvider else { err("unknown provider"); exit(2) }
if let model { provider.model = model }
if let vision { provider.vision = vision }
if let extra { provider.extraBody = extra }
if let systemFile {
    guard let t = try? String(contentsOfFile: systemFile, encoding: .utf8) else { err("cannot read \(systemFile)"); exit(2) }
    settings.systemPrompt = t
}

let client = LLMClient(provider: provider, apiKey: APIKeys.resolve(for: provider))
let sendImages = await client.resolveVision()
let built = PromptBuilder.build(docs: docs, settings: settings, notes: notes, sendImages: sendImages)
err("provider=\(provider.name) model=\(provider.model) images=\(sendImages ? "\(built.imageCount) sent" : "OCR")")
if dryRun { print(built.preview); exit(0) }

// All inputs on the command line form one requirement -> one brief.
let t0 = Date()
var thinking = 0
do {
    let out = try await client.complete(built.messages) { _, r in thinking += r.count }
    print(out)
    if !reports.isEmpty {
        print("\n## Case runs\n" + reports.map { "- \($0.label): run `\($0.run)` — \($0.verdict)" }.joined(separator: "\n"))
    }
    err(String(format: "done in %.1fs (reasoning chars: %d)", Date().timeIntervalSince(t0), thinking))
} catch {
    err("error: \(error.localizedDescription)"); exit(1)
}
