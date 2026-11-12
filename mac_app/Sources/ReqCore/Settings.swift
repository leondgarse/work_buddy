import Foundation
import Security

public struct Person: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    /// Comma-separated emails / handles / other spellings (e.g. "jane@example.com, Jane").
    public var aliases: String
    public var role: String
    public var isMe: Bool

    public init(name: String, aliases: String = "", role: String, isMe: Bool = false) {
        self.name = name; self.aliases = aliases; self.role = role; self.isMe = isMe
    }
}

public enum VisionMode: String, Codable, CaseIterable, Identifiable {
    /// Ask the server (`/v1/models` input_modalities), fall back to a model-name guess.
    case auto
    /// Send images to the model.
    case images
    /// Send on-device OCR text of the images instead.
    case ocr
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .images: return "Send images"
        case .ocr: return "OCR text only"
        }
    }
}

public struct Provider: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    /// OpenAI-compatible base URL, ending before `/chat/completions`.
    public var baseURL: String
    public var model: String
    /// Env var to read the key from when none is stored in the Keychain.
    public var apiKeyEnv: String
    public var vision: VisionMode
    /// Optional JSON object merged into the request body (e.g. {"temperature": 0.3}).
    public var extraBody: String

    public init(name: String, baseURL: String, model: String, apiKeyEnv: String = "",
                vision: VisionMode = .auto, extraBody: String = "") {
        self.name = name; self.baseURL = baseURL; self.model = model
        self.apiKeyEnv = apiKeyEnv; self.vision = vision; self.extraBody = extraBody
    }
}

public struct AppSettings: Codable {
    public var providers: [Provider]
    public var selectedProviderID: UUID?
    public var people: [Person]
    /// Empty = use `PromptBuilder.defaultSystemPrompt`.
    public var systemPrompt: String
    public var maxImages: Int

    public var selectedProvider: Provider? {
        providers.first { $0.id == selectedProviderID } ?? providers.first
    }

    /// Local models wander at their default temperature (~1.0): 0.3 scored higher and ran ~3x faster
    /// in the ReqBuddy benchmark.
    public static let localSampling = #"{"temperature": 0.3}"#

    public static var defaults: AppSettings {
        // The 35B lives on its own llama-server (:18010, sleeps when idle); the router serves the rest.
        // Never ask the router for a 35B while :18010 holds it: two copies don't fit and OOM the box.
        let local = Provider(name: "MICL Qwen3.6 :18010", baseURL: "http://localhost:18010/v1",
                             model: "Qwen3.6-35B-A3B-Q8_0", apiKeyEnv: "QWEN36_API_KEY", vision: .auto,
                             extraBody: localSampling)
        return AppSettings(
            providers: [
                local,
                Provider(name: "MICL llama-router", baseURL: "http://localhost:8080/v1",
                         model: "DavidAU/Qwen3.6-27B-Fable-Fus-711", vision: .auto,
                         extraBody: localSampling),
                Provider(name: "Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                         model: "gemini-3.8-flash", apiKeyEnv: "GEMINI_API_KEY", vision: .images),
                Provider(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
                         model: "deepseek-flash", apiKeyEnv: "DEEPSEEK_API_KEY", vision: .auto),
            ],
            selectedProviderID: local.id,
            people: [
                Person(name: "Jane Doe", aliases: "jane@example.com", role: "CTO of our company; her decisions are final"),
                Person(name: "Your Name", aliases: "you@example.com", role: "Me - the developer who will implement this", isMe: true),
            ],
            systemPrompt: "",
            maxImages: 16
        )
    }

    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReqBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .defaults }
        return s
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}

// MARK: - API keys

public enum APIKeys {
    private static let service = "ReqBuddy"
    private static var shellCache: [String: String] = [:]

    public static func keychainGet(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    public static func keychainSet(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Keychain first, then the process env, then the user's login shell env
    /// (apps started from Finder don't inherit variables exported in ~/.zshrc).
    public static func resolve(for p: Provider) -> String? {
        if let k = keychainGet(p.id.uuidString) { return k }
        let name = p.apiKeyEnv.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        if let v = shellCache[name] { return v }
        let v = shellEnv(name)
        if let v { shellCache[name] = v }
        return v
    }

    static func shellEnv(_ name: String) -> String? {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '%s' \"$\(name)\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? nil : s
    }
}

