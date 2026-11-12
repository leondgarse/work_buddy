import Foundation
import ReqCore

// Headless version of the app's pipeline, sharing its settings file.
// usage: reqcli [--provider NAME] [--model ID] [--images|--ocr] [--notes TEXT] [--dry-run]
//               [--extra JSON] [--system FILE] [--image-side PX] FILE...

var args = Array(CommandLine.arguments.dropFirst())
var settings = AppSettings.load()
var providerName: String?, model: String?, vision: VisionMode?, notes = "", dryRun = false
var extra: String?, systemFile: String?
var files: [URL] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--provider": providerName = args.removeFirst()
    case "--model": model = args.removeFirst()
    case "--images": vision = .images
    case "--ocr": vision = .ocr
    case "--notes": notes = args.removeFirst()
    case "--dry-run": dryRun = true
    case "--extra": extra = args.removeFirst()          // JSON merged into the request, e.g. {"temperature":0.3}
    case "--system": systemFile = args.removeFirst()    // system prompt file (A/B tests)
    case "--print-system": print(PromptBuilder.defaultSystemPrompt); exit(0)
    case "--image-side": PromptBuilder.imageLongSide = Int(args.removeFirst()) ?? 1600
    case "-h", "--help":
        print("usage: reqcli [--provider NAME] [--model ID] [--images|--ocr] [--notes TEXT] [--dry-run] [--extra JSON] [--system FILE] [--image-side PX] FILE...")
        print("providers: " + settings.providers.map(\.name).joined(separator: ", "))
        exit(0)
    default: files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
    }
}

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

guard var provider = providerName.map({ n in settings.providers.first { $0.name.lowercased().hasPrefix(n.lowercased()) } })
        ?? settings.selectedProvider else { err("unknown provider"); exit(2) }
if let model { provider.model = model }
if let vision { provider.vision = vision }
if let extra { provider.extraBody = extra }
if let systemFile {
    guard let t = try? String(contentsOfFile: systemFile, encoding: .utf8) else { err("cannot read \(systemFile)"); exit(2) }
    settings.systemPrompt = t
}

var docs: [SourceDoc] = []
for u in Extractor.expand(files) {
    do { docs.append(try Extractor.extract(u)); err("extracted \(u.lastPathComponent): \(docs.last!.text.count) chars, \(docs.last!.images.count) images") }
    catch { err("skip \(u.lastPathComponent): \(error.localizedDescription)") }
}
guard !docs.isEmpty else { err("no readable inputs"); exit(2) }

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
    err(String(format: "done in %.1fs (reasoning chars: %d)", Date().timeIntervalSince(t0), thinking))
} catch {
    err("error: \(error.localizedDescription)"); exit(1)
}
