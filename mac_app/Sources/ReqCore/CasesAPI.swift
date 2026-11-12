import Foundation

/// Preserve evolving report fields without baking customer document schemas into the client.
public enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? {
        if case .object(let v) = self { return v[key] }; return nil
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var pretty: String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? "null"
    }
}

public struct RecordedCase: Decodable, Identifiable {
    public let demo: String
    public let id: String
    public let title: String
    public let live: Bool
    public var key: String { "\(demo)/\(id)" }
}
public struct CasesHealth: Decodable {
    public struct Demo: Decodable { public let live: Bool }
    public let demos: [String: Demo]
}

public struct CaseReport: Decodable {
    public let run: String
    public let demo: String
    public let status: String
    public let raw: JSONValue
    public init(from decoder: Decoder) throws {
        raw = try JSONValue(from: decoder)
        guard let r = raw["run"]?.string, let d = raw["demo"]?.string,
              let s = raw["status"]?.string else { throw CasesError.invalidResponse }
        run = r; demo = d; status = s
    }
    public var events: [JSONValue] {
        if case .array(let events) = raw["events"] { return events }; return []
    }
    public var terminal: Bool { ["passed", "failed", "error"].contains(status) }
    public var inputsIncomplete: Bool {
        if status == "error" { return true }
        if case .array(let problems) = raw["problems"] {
            return problems.contains { $0["kind"]?.string == "bad_input" }
        }
        return false
    }
    public var label: String { "\(demo)/\(raw["case"]?.string ?? "custom")" }
    public var verdict: String {
        if inputsIncomplete { return "Inputs incomplete — check the files and their order, then retry. \(raw["problems"]?.pretty ?? "")" }
        let match = raw["matches_recording"]
        let baseline = match == .bool(true) ? "matches recording" : match == .bool(false) ? "differs from recording" : "custom inputs"
        let differences: String
        if case .array(let values) = raw["summary"]?["differences"] { differences = " · \(values.count) difference(s)" }
        else if case .array(let values) = raw["summary"]?["failing"] { differences = " · \(values.count) failing check(s)" }
        else { differences = "" }
        return "\(status) · \(baseline)\(differences) · run \(run)"
    }
    public func source(files: [URL] = []) -> SourceDoc {
        // A virtual source, not a document the coding agent needs to obtain.
        SourceDoc(url: URL(fileURLWithPath: "/case-runs/\(run)"), kind: "case report", text: """
        Actual result (case `\(label)`): \(verdict)
        This is an observation from our own system. Use it to assess whether the reported problem reproduces.
        Deliberate negative cases can match their recording while reporting differences. Do not infer a bug from status alone.
        Run id: \(run)
        Status: \(status)
        Summary: \(raw["summary"]?.pretty ?? "null")
        Diff against recording: \(raw["diff"]?.pretty ?? "null")
        Problems: \(raw["problems"]?.pretty ?? "null")
        \(events.isEmpty ? "" : "Intermediate stages (artifact paths belong to the server, not this Mac):\n" + JSONValue.array(events).pretty)
        \(files.isEmpty ? "" : "Test inputs available on this Mac (in upload order):\n" + files.map { "- \($0.lastPathComponent): \($0.path)" }.joined(separator: "\n"))
        """)
    }
}

public enum CasesError: LocalizedError {
    case invalidURL, invalidResponse, http(Int, String), timeout, inputs(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Cases API URL or case identifier."
        case .invalidResponse: return "The Cases API returned an invalid response."
        case .http(let code, let message): return "Cases API HTTP \(code): \(message)"
        case .timeout: return "Case polling timed out; the server run may still be running."
        case .inputs(let message): return "Inputs incomplete: \(message)"
        }
    }
}

public struct DemoInputs {
    public let demo: String
    public let labels: [String]
    public let minimum: Int
    public static let supported = [
        DemoInputs(demo: "pdf_match", labels: ["A: our quotation", "B: customer's PO"], minimum: 2),
        DemoInputs(demo: "packing", labels: (1...8).map { "Document \($0)" }, minimum: 1),
        DemoInputs(demo: "logistics", labels: ["RFQ"], minimum: 1),
        DemoInputs(demo: "office", labels: ["Document"], minimum: 1),
        DemoInputs(demo: "email", labels: ["Email"], minimum: 1),
    ]
    public static func spec(_ demo: String) -> DemoInputs? { supported.first { $0.demo == demo } }
    public func validate(_ files: [URL]) throws {
        guard (minimum...labels.count).contains(files.count) else {
            throw CasesError.inputs("\(demo) requires \(minimum)–\(labels.count) file(s), in slot order.")
        }
        guard Set(files.map { $0.standardizedFileURL }).count == files.count else {
            throw CasesError.inputs("Choose a different file for each slot.")
        }
        if demo == "pdf_match", files.contains(where: { $0.pathExtension.lowercased() != "pdf" }) {
            throw CasesError.inputs("A and B must both be PDFs; A is the quotation and B is the PO.")
        }
    }
}

public struct CasesAPI {
    private let base: URL
    private let session: URLSession
    public init(baseURL: String, session: URLSession = .shared) throws {
        guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme), url.host != nil,
              url.query == nil, url.fragment == nil else { throw CasesError.invalidURL }
        base = url; self.session = session
    }
    private func request(_ components: [String], method: String = "GET", query: [URLQueryItem] = [],
                         body: Data? = nil) async throws -> JSONValue {
        try Task.checkCancellation()
        guard components.allSatisfy({ !$0.isEmpty && $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }) else {
            throw CasesError.invalidURL
        }
        var url = base
        for component in ["api"] + components { url.appendPathComponent(component) }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: c.url!); req.httpMethod = method; req.httpBody = body
        req.timeoutInterval = 60
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CasesError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw CasesError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "No details")
        }
        // Some servers return an empty 202 with only Location.
        if data.isEmpty, let location = http.value(forHTTPHeaderField: "Location"),
           let id = URL(string: location)?.lastPathComponent {
            return .object(["run": .string(id)])
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private func decode<T: Decodable>(_ value: JSONValue, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    public func health() async throws -> CasesHealth { try decode(await request(["health"]), as: CasesHealth.self) }
    public func cases() async throws -> [RecordedCase] {
        struct Listing: Decodable { let cases: [RecordedCase] }
        return try decode(await request(["cases"]), as: Listing.self).cases
    }
    public func blurb(demo: String, id: String) async throws -> String {
        let detail = try await request(["cases", demo, id])
        return detail["blurb"]?.string ?? detail["case"]?["blurb"]?.string ?? ""
    }
    public func report(_ run: String, includeEvents: Bool = false) async throws -> CaseReport {
        try decode(await request(["runs", run], query: includeEvents ? [URLQueryItem(name: "events", value: "1")] : []), as: CaseReport.self)
    }
    private func finish(_ initial: JSONValue, includeEvents: Bool, pollInterval: UInt64, timeout: TimeInterval,
                        progress: @MainActor (String) -> Void) async throws -> CaseReport {
        guard let id = initial["run"]?.string else { throw CasesError.invalidResponse }
        let deadline = Date().addingTimeInterval(timeout)
        var lastStatus = ""
        while true {
            try Task.checkCancellation()
            let result = try await report(id, includeEvents: includeEvents)
            if result.status != lastStatus {
                await progress("\(result.status) · run \(id)")
                lastStatus = result.status
            }
            if result.terminal { return result }
            guard Date() < deadline else { throw CasesError.timeout }
            try await Task.sleep(nanoseconds: pollInterval)
        }
    }
    public func run(demo: String, id: String, strict: Bool = false, includeEvents: Bool = false, pollInterval: UInt64 = 1_000_000_000,
                    timeout: TimeInterval = 1800, progress: @MainActor (String) -> Void = { _ in }) async throws -> CaseReport {
        let initial = try await request(["cases", demo, id, "run"], method: "POST", query: [
            URLQueryItem(name: "wait", value: "0"), URLQueryItem(name: "strict", value: strict ? "1" : "0")] + (includeEvents ? [URLQueryItem(name: "events", value: "1")] : []), body: Data("{}".utf8))
        return try await finish(initial, includeEvents: includeEvents, pollInterval: pollInterval, timeout: timeout, progress: progress)
    }
    public func run(demo: String, files: [URL], includeEvents: Bool = false, pollInterval: UInt64 = 1_000_000_000,
                    timeout: TimeInterval = 1800, progress: @MainActor (String) -> Void = { _ in }) async throws -> CaseReport {
        guard let spec = DemoInputs.spec(demo) else { throw CasesError.inputs("Unsupported file demo: \(demo)") }
        try spec.validate(files)
        let uploads = try files.map { file -> [String: String] in
            ["name": file.lastPathComponent, "base64": try Data(contentsOf: file).base64EncodedString()]
        }
        let body = try JSONEncoder().encode(["files": uploads])
        let initial = try await request(["demos", demo, "run"], method: "POST",
                                        query: [URLQueryItem(name: "wait", value: "0")] + (includeEvents ? [URLQueryItem(name: "events", value: "1")] : []), body: body)
        return try await finish(initial, includeEvents: includeEvents, pollInterval: pollInterval, timeout: timeout, progress: progress)
    }
}
