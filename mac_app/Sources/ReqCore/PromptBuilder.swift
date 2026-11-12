import AppKit
import Foundation

public enum PromptBuilder {
    public static let defaultSystemPrompt = """
    You turn business communication (email threads, chat exports, screenshots) into a short task \
    prompt for a coding agent (Claude Code). The agent has the codebase but has never seen these \
    messages. It reads the source code itself, so state WHAT is wrong or wanted and WHERE it shows \
    up; never explain causes or how to implement it.

    Rules:
    - My notes are authoritative and override the sources. Drop every item my notes call expected \
    behaviour, by design, already handled, or not needed, and do not mention dropped items.
    - Use the People list only to judge whose words count. Never name people in the output; say \
    "the customer" or a role only when it matters.
    - Ignore greetings, thanks, signatures, quoted duplicates and replies that only acknowledge.
    - Write in English. Keep UI labels, field names, messages and values verbatim in their original \
    language; add a short English gloss in parentheses for non-English text.
    - Resolve visual references (colours, highlights, arrows, "this part") from the images into the \
    exact element or label meant. If you cannot see it, say so instead of guessing.
    - For bugs, give the concrete values observed versus what the source document shows.
    - Keep the asker's certainty. A polite question from the decision-maker is still a request \
    ("合在一起会更直观？", "是不是直接去掉比较好？", "wouldn't X be better?") → write it as an instruction. \
    Only an explicit "look into whether / consider / maybe also" ("看看是不是加…", "可以考虑", "要不要") \
    stays tentative → write "Consider …".
    - Only what was asked or marked in the images. Do not add follow-on or related changes nobody \
    requested; the agent decides those from the code.
    - When the asker leaves the solution open ("suggest how to show it"), write "Propose a clearer \
    way to …", say what is confusing, and ask for the proposal before changing it.
    - No acceptance criteria, priorities, citations, implementation notes or filler.
    - Screenshots and chat/email exports only describe the request; they are never files to list.

    Output only this Markdown:

    # <short imperative title>

    ## Context
    1-3 sentences: which feature or page, and what kind of change.

    ## Requirements
    Numbered. Bug: "**Location:** <page / modal / column>" then "**Issue:** <observed vs \
    expected, with values>". Change request: one direct sentence quoting the current text or label.

    ## Source files
    Only files needed to test the change, such as a customer PDF the feature processes: its file \
    name, plus its path if it is among the Sources, else " [Should be provided]". Omit the section \
    when there are none.

    Add "## Open questions" at the end only when something blocks implementation.
    """

    public static func title(of brief: String) -> String {
        brief.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "Requirements"
    }

    public struct Built {
        public var messages: [ChatMessage]
        public var imageCount: Int
        public var droppedImages: Int
        /// Text-only rendering of the user message, for previews and dry runs.
        public var preview: String
    }

    public static func build(docs: [SourceDoc], settings: AppSettings, notes: String,
                             sendImages: Bool) -> Built {
        var parts: [ContentPart] = []
        var preview = ""
        func add(_ s: String) { parts.append(.text(s)); preview += s }

        var head = "## People\n"
        for p in settings.people where !p.name.isEmpty {
            head += "- \(p.name)"
            if !p.aliases.isEmpty { head += " (also: \(p.aliases))" }
            head += " - \(p.role)\(p.isMe ? " [this is me]" : "")\n"
        }
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { head += "\n## My notes (authoritative, override the sources)\n\(n)\n" }
        head += "\n## Sources\n"
        head += sendImages ? "Images are attached inline after the text of the source they belong to.\n"
                           : "Images were converted to OCR text (colours and layout are lost).\n"
        add(head)

        var budget = max(0, settings.maxImages)
        var sent = 0, dropped = 0
        for (i, d) in docs.enumerated() {
            let s = "S\(i + 1)"
            var t = "\n### \(s): \(d.kind) - \(d.url.lastPathComponent)\nPath: \(d.url.path)\n"
            t += "\n" + d.text + "\n"
            if !sendImages {
                for im in d.images {
                    if d.kind == "pdf" {
                        if let x = d.extraOCR[im.label] { t += "\n[\(s) \(im.label) - text inside pictures (OCR)]\n\(x)\n" }
                    } else if !im.ocrText.isEmpty {
                        t += "\n[\(s) \(im.label) OCR]\n\(im.ocrText)\n"
                    }
                }
                add(t)
                continue
            }
            add(t)
            for im in d.images {
                guard budget > 0, let url = jpegDataURL(im.image) else { dropped += 1; continue }
                budget -= 1; sent += 1
                add("\n[\(s) \(im.label)]\n")
                parts.append(.imageDataURL(url))
                preview += "<image \(im.image.width)x\(im.image.height)>\n"
            }
        }
        if dropped > 0 { add("\n(\(dropped) more images omitted by the image limit.)\n") }
        add("\nAll sources above belong to ONE requirement. Write exactly one brief now.")

        let sys = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultSystemPrompt : settings.systemPrompt
        return Built(messages: [ChatMessage(role: "system", parts: [.text(sys)]),
                                ChatMessage(role: "user", parts: mergeText(parts))],
                     imageCount: sent, droppedImages: dropped, preview: preview)
    }

    static func mergeText(_ parts: [ContentPart]) -> [ContentPart] {
        var out: [ContentPart] = []
        for p in parts {
            if case .text(let t) = p, let last = out.last, case .text(let prev) = last {
                out[out.count - 1] = .text(prev + t)
            } else { out.append(p) }
        }
        return out
    }

    public static func jpegDataURL(_ img: CGImage, longSide: Int = 1600) -> String? {
        let scale = min(1.0, Double(longSide) / Double(max(img.width, img.height)))
        var src = img
        if scale < 1 {
            let w = Int(Double(img.width) * scale), h = Int(Double(img.height) * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let s = ctx.makeImage() else { return nil }
            src = s
        }
        let rep = NSBitmapImageRep(cgImage: src)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}
