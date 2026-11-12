import Foundation

public enum ContentPart {
    case text(String)
    case imageDataURL(String)

    var json: [String: Any] {
        switch self {
        case .text(let t): return ["type": "text", "text": t]
        case .imageDataURL(let u): return ["type": "image_url", "image_url": ["url": u]]
        }
    }
}

public struct ChatMessage {
    public var role: String
    public var parts: [ContentPart]
    public init(role: String, parts: [ContentPart]) { self.role = role; self.parts = parts }

    var json: [String: Any] {
        // Plain string for text-only messages: some servers reject the array form without vision.
        if parts.count == 1, case .text(let t) = parts[0] { return ["role": role, "content": t] }
        return ["role": role, "content": parts.map(\.json)]
    }
}

public struct ModelInfo: Identifiable, Hashable {
    public var id: String
    /// nil when the server doesn't say.
    public var acceptsImages: Bool?
}

public enum LLMError: LocalizedError {
    case badURL, http(Int, String), noKey(String), emptyAnswer(Int)
    public var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid base URL"
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(800))"
        case .noKey(let p): return "No API key for \(p). Set one in Settings or its env var."
        case .emptyAnswer(let r): return "The model returned no answer (only \(r) characters of reasoning). Try again, or use another model."
        }
    }
}

public struct LLMClient {
    public let provider: Provider
    public let apiKey: String?

    public init(provider: Provider, apiKey: String?) { self.provider = provider; self.apiKey = apiKey }

    func request(_ path: String) throws -> URLRequest {
        let base = provider.baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { throw LLMError.badURL }
        var r = URLRequest(url: url)
        r.timeoutInterval = 900
        if let k = apiKey, !k.isEmpty { r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public func listModels() async throws -> [ModelInfo] {
        var r = try request("/models")
        r.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(decoding: data, as: UTF8.self)) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = obj?["data"] as? [[String: Any]] ?? []
        // A standalone llama-server lists capabilities in an Ollama-style "models" array instead.
        var multimodal: [String: Bool] = [:]
        for m in obj?["models"] as? [[String: Any]] ?? [] {
            if let n = m["model"] as? String ?? m["name"] as? String, let caps = m["capabilities"] as? [String] {
                multimodal[n] = caps.contains("multimodal") || caps.contains("vision")
            }
        }
        return arr.compactMap { m in
            guard var id = m["id"] as? String else { return nil }
            if id.hasPrefix("models/") { id.removeFirst(7) }  // Gemini
            let mods = ((m["architecture"] as? [String: Any])?["input_modalities"] ?? m["input_modalities"]) as? [String]
            return ModelInfo(id: id, acceptsImages: mods.map { $0.contains("image") } ?? multimodal[id])
        }.sorted { $0.id < $1.id }
    }

    /// Decide whether to send images for this provider/model.
    public func resolveVision() async -> Bool {
        switch provider.vision {
        case .images: return true
        case .ocr: return false
        case .auto:
            if let models = try? await listModels(),
               let m = models.first(where: { $0.id == provider.model }), let v = m.acceptsImages { return v }
            let n = provider.model.lowercased()
            return ["vl", "vision", "gemini", "gpt-4o", "gpt-4.1", "gpt-5", "claude", "omni", "pixtral"]
                .contains { n.contains($0) }
        }
    }

    /// Streams the completion. `onDelta(content, reasoning)` gets each new chunk.
    public func complete(_ messages: [ChatMessage],
                         onDelta: @escaping (String, String) -> Void) async throws -> String {
        var r = try request("/chat/completions")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": provider.model, "messages": messages.map(\.json), "stream": true]
        if let d = provider.extraBody.data(using: .utf8), !provider.extraBody.trimmingCharacters(in: .whitespaces).isEmpty,
           let extra = try JSONSerialization.jsonObject(with: d) as? [String: Any] {
            body.merge(extra) { _, new in new }
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var err = ""
            for try await line in bytes.lines { err += line + "\n"; if err.count > 4000 { break } }
            throw LLMError.http(code, err)
        }
        var out = "", reasoning = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let e = obj["error"] { throw LLMError.http(code, "\(e)") }
            guard let delta = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            let c = delta["content"] as? String ?? ""
            let rc = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
            if !c.isEmpty { out += c }
            reasoning += rc.count
            if !c.isEmpty || !rc.isEmpty { onDelta(c, rc) }
        }
        let answer = Self.stripThinking(out)
        if answer.isEmpty { throw LLMError.emptyAnswer(reasoning) }
        return answer
    }

    public static func stripThinking(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        if let r = t.range(of: "</think>") { t = String(t[r.upperBound...]) }  // opening tag sent in the template
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
