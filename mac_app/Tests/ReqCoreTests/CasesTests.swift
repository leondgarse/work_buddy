import Foundation
import XCTest
@testable import ReqCore

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
                                                                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CasesTests: XCTestCase {
    func api() throws -> CasesAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return try CasesAPI(baseURL: "http://localhost:8110", session: URLSession(configuration: config))
    }
    func report(_ json: String) throws -> CaseReport { try JSONDecoder().decode(CaseReport.self, from: Data(json.utf8)) }

    func testOldSettingsPreservePeopleProvidersAndSelection() throws {
        var original = AppSettings.defaults
        original.people = [Person(name: "Example", role: "Tester")]
        original.systemPrompt = "Customized"
        original.maxImages = 7
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "casesBaseURL")
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.providers, original.providers)
        XCTAssertEqual(migrated.people, original.people)
        XCTAssertEqual(migrated.selectedProviderID, original.selectedProviderID)
        XCTAssertEqual(migrated.systemPrompt, "Customized")
        XCTAssertEqual(migrated.maxImages, 7)
        XCTAssertEqual(migrated.casesBaseURL, "http://127.0.0.1:8110")
    }

    func testAsyncRecordedRunPollsLocationAndUsesStrict() async throws {
        var polls = 0
        StubProtocol.handler = { req in
            if req.httpMethod == "POST" {
                XCTAssertEqual(req.url?.path, "/api/cases/pdf_match/issues/run")
                let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertTrue(query.contains(URLQueryItem(name: "wait", value: "0")))
                XCTAssertTrue(query.contains(URLQueryItem(name: "strict", value: "1")))
                return (202, ["Location": "/api/runs/test-run"], Data())
            }
            polls += 1
            XCTAssertEqual(req.url?.path, "/api/runs/test-run")
            return (200, [:], Data("{\"run\":\"test-run\",\"demo\":\"pdf_match\",\"case\":\"issues\",\"status\":\"\(polls == 1 ? "running" : "passed")\",\"matches_recording\":true,\"summary\":{\"differences\":[\"expected difference\"]}}".utf8))
        }
        let result = try await api().run(demo: "pdf_match", id: "issues", strict: true, pollInterval: 1)
        XCTAssertEqual(polls, 2)
        XCTAssertTrue(result.verdict.contains("matches recording"))
        XCTAssertTrue(result.source().text.contains("expected difference"))
        XCTAssertFalse(result.inputsIncomplete)
    }

    func testUploadContainsNamesBase64AndOrderedFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [dir.appendingPathComponent("A.pdf"), dir.appendingPathComponent("B.pdf")]
        try Data("quote".utf8).write(to: files[0]); try Data("order".utf8).write(to: files[1])
        StubProtocol.handler = { req in
            if req.httpMethod == "POST" {
                XCTAssertEqual(req.url?.path, "/api/demos/pdf_match/run")
                XCTAssertEqual(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.query, "wait=0")
                var data = req.httpBody ?? Data()
                if let stream = req.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let n = stream.read(&buffer, maxLength: buffer.count)
                        if n <= 0 { break }; data.append(buffer, count: n)
                    }
                }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let uploads = body["files"] as! [[String: String]]
                XCTAssertEqual(uploads.map { $0["name"]! }, ["A.pdf", "B.pdf"])
                XCTAssertEqual(uploads.map { $0["base64"]! }, [Data("quote".utf8).base64EncodedString(), Data("order".utf8).base64EncodedString()])
                XCTAssertNil(uploads[0]["path"])
                return (202, [:], Data("{\"run\":\"custom\"}".utf8))
            }
            return (200, [:], Data("{\"run\":\"custom\",\"demo\":\"pdf_match\",\"status\":\"passed\"}".utf8))
        }
        _ = try await api().run(demo: "pdf_match", files: files)
    }

    func testEventsRequestedOnPostAndPollingAcrossFileDemosAndRecordedCases() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A.pdf"), b = dir.appendingPathComponent("B.pdf")
        try Data("reference".utf8).write(to: a); try Data("order".utf8).write(to: b)
        for demo in DemoInputs.supported.map(\.demo) {
            var posts = 0, polls = 0
            StubProtocol.handler = { req in
                let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                XCTAssertTrue(query.contains(URLQueryItem(name: "events", value: "1")))
                if req.httpMethod == "POST" {
                    posts += 1
                    XCTAssertTrue(query.contains(URLQueryItem(name: "wait", value: "0")))
                    return (202, [:], Data(#"{"run":"events-run"}"#.utf8))
                }
                polls += 1
                return (200, [:], Data("{\"run\":\"events-run\",\"demo\":\"\(demo)\",\"status\":\"passed\",\"events\":[{\"type\":\"transcribed\",\"text\":\"Example text\"}]}".utf8))
            }
            let result = try await api().run(demo: demo, files: demo == "pdf_match" ? [a, b] : [a], includeEvents: true)
            XCTAssertEqual(result.events.count, 1)
            XCTAssertTrue(result.source().text.contains("Example text"))
            XCTAssertTrue(result.source().text.contains("artifact paths belong to the server"))
            XCTAssertEqual(posts, 1); XCTAssertEqual(polls, 1)
            let recorded = try await api().run(demo: demo, id: "example", includeEvents: true)
            XCTAssertEqual(recorded.events.count, 1)
            XCTAssertEqual(posts, 2); XCTAssertEqual(polls, 2)
        }
    }

    func testInputsAndReportFraming() throws {
        let bad = try report(#"{"run":"r","demo":"pdf_match","status":"failed","problems":[{"kind":"bad_input"}]}"#)
        XCTAssertTrue(bad.inputsIncomplete)
        XCTAssertTrue(try report(#"{"run":"r","demo":"pdf_match","status":"error"}"#).inputsIncomplete)
        XCTAssertThrowsError(try DemoInputs.spec("pdf_match")!.validate([URL(fileURLWithPath: "/A.pdf")]))
        let observed = try report(#"{"run":"r","demo":"pdf_match","case":"issues","status":"passed","matches_recording":true}"#)
        var settings = AppSettings.defaults; settings.systemPrompt = "Custom prompt"
        let built = PromptBuilder.build(docs: [observed.source()], settings: settings, notes: "", sendImages: false)
        XCTAssertTrue(built.preview.contains("Actual result (case `pdf_match/issues`)"))
        XCTAssertFalse(built.preview.contains("Path: /case-runs"))
        if case .text(let system) = built.messages[0].parts[0] {
            XCTAssertTrue(system.contains("Custom prompt"))
            XCTAssertTrue(system.contains(PromptBuilder.caseReportRule))
        } else { XCTFail("Missing system prompt") }
    }

    func testDiscoveryHTTPFailureAndTimeout() async throws {
        StubProtocol.handler = { req in
            if req.url?.path == "/api/health" {
                return (200, [:], Data(#"{"demos":{"pdf_match":{"live":false}}}"#.utf8))
            }
            if req.url?.path == "/api/cases" {
                return (200, [:], Data(#"{"cases":[{"demo":"pdf_match","id":"issues","title":"Deliberate differences","live":false}]}"#.utf8))
            }
            return (503, [:], Data("Unavailable".utf8))
        }
        let client = try api()
        let health = try await client.health()
        XCTAssertEqual(health.demos["pdf_match"]?.live, false)
        let cases = try await client.cases()
        XCTAssertEqual(cases.first?.key, "pdf_match/issues")
        do { _ = try await client.report("missing"); XCTFail("Expected HTTP error") }
        catch CasesError.http(let status, _) { XCTAssertEqual(status, 503) }
        StubProtocol.handler = { _ in
            (200, [:], Data(#"{"run":"r","demo":"pdf_match","status":"queued"}"#.utf8))
        }
        do { _ = try await client.run(demo: "pdf_match", id: "agree", timeout: -1); XCTFail("Expected timeout") }
        catch CasesError.timeout { }
    }

    func testCancellationStopsPolling() async throws {
        StubProtocol.handler = { _ in
            (200, [:], Data("{\"run\":\"r\",\"demo\":\"pdf_match\",\"status\":\"running\"}".utf8))
        }
        let client = try api()
        let task = Task { try await client.run(demo: "pdf_match", id: "agree", pollInterval: 10_000_000_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}
