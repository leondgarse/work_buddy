import Foundation
import XCTest
import ReqCore
@testable import ReqBuddy

final class CaseWorkflowTests: XCTestCase {
    @MainActor
    func storeWithIssue() -> AppStore {
        let store = AppStore(settings: .defaults, persistSettings: false)
        let issue = SourceDoc(url: URL(fileURLWithPath: "/example/issue.eml"), kind: "email", text: "The PO verification result is incorrect.")
        store.sources = [issue]; store.checked.insert(issue.id)
        return store
    }
    func result(demo: String = "pdf_match", status: String = "passed", problems: String = "[]") throws -> CaseReport {
        try JSONDecoder().decode(CaseReport.self, from: Data("{\"run\":\"review-run\",\"demo\":\"\(demo)\",\"status\":\"\(status)\",\"problems\":\(problems),\"summary\":{\"differences\":[\"Example mismatch\"]}}".utf8))
    }
    @MainActor
    func fillInputs(_ store: AppStore) {
        store.toggleDemo("pdf_match", on: true)
        store.setSlot(0, demo: "pdf_match", url: URL(fileURLWithPath: "/example/A.pdf"))
        store.setSlot(1, demo: "pdf_match", url: URL(fileURLWithPath: "/example/B.pdf"))
    }
    @MainActor
    func finishRun(_ store: AppStore, result: CaseReport) {
        let revision = store.caseReviews["pdf_match"]!.beginRun()
        XCTAssertTrue(store.caseReviews["pdf_match"]!.receive(result, revision: revision))
    }

    @MainActor
    func testCasesAreOptionalAndGenerateWaitsForConfirmation() async throws {
        let store = storeWithIssue()
        XCTAssertTrue(store.canGenerate)
        fillInputs(store)
        XCTAssertTrue(store.caseReviews["pdf_match"]!.canRun)
        XCTAssertFalse(store.canGenerate)
        store.generate()
        XCTAssertFalse(store.busy, "Generate must not start a case API request")
        finishRun(store, result: try result())
        XCTAssertFalse(store.canGenerate, "Finished output still needs review")
        XCTAssertEqual(store.briefSources.count, 1)
        store.confirmCase("pdf_match", on: true)
        XCTAssertTrue(store.canGenerate)
        XCTAssertEqual(store.briefSources.filter { $0.kind == "case report" }.count, 1)
        XCTAssertEqual(store.confirmedEvidence.first?.report.run, "review-run")
        // A later API outage must not prevent generation from an already confirmed report.
        store.caseHealth = nil
        XCTAssertTrue(store.canGenerate)
        store.toggleDemo("pdf_match", on: false)
        XCTAssertTrue(store.canGenerate)
        XCTAssertEqual(store.briefSources.count, 1)
    }

    @MainActor
    func testReuploadAndRerunRevokeConfirmationAndRejectStaleOutput() async throws {
        let store = storeWithIssue()
        fillInputs(store)
        finishRun(store, result: try result())
        store.confirmCase("pdf_match", on: true)
        let oldRevision = store.caseReviews["pdf_match"]!.revision
        store.setSlot(1, demo: "pdf_match", url: URL(fileURLWithPath: "/example/replacement.pdf"))
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.caseReviews["pdf_match"]!.report)
        XCTAssertFalse(store.caseReviews["pdf_match"]!.receive(try result(), revision: oldRevision))
        finishRun(store, result: try result())
        store.confirmCase("pdf_match", on: true)
        XCTAssertTrue(store.canGenerate)
        let evidence = store.confirmedEvidence[0]
        XCTAssertEqual(evidence.files.map(\.lastPathComponent), ["A.pdf", "replacement.pdf"])
        _ = store.caseReviews["pdf_match"]!.beginRun()
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.caseReviews["pdf_match"]!.evidence)
    }

    @MainActor
    func testBadInputsCannotBeConfirmedButRealFailuresCan() async throws {
        let store = storeWithIssue()
        fillInputs(store)
        finishRun(store, result: try result(status: "failed", problems: #"[{"kind":"bad_input"}]"#))
        store.confirmCase("pdf_match", on: true)
        XCTAssertFalse(store.canGenerate)
        XCTAssertTrue(store.confirmedEvidence.isEmpty)
        finishRun(store, result: try result(status: "failed"))
        store.confirmCase("pdf_match", on: true)
        XCTAssertTrue(store.canGenerate, "A real failing result is evidence of the reported issue")
    }

    @MainActor
    func testEndpointChangeAndDeselectRequireNewConfirmation() async throws {
        let store = storeWithIssue()
        fillInputs(store)
        finishRun(store, result: try result())
        store.confirmCase("pdf_match", on: true)
        store.toggleDemo("pdf_match", on: false)
        store.toggleDemo("pdf_match", on: true)
        XCTAssertFalse(store.canGenerate)
        store.confirmCase("pdf_match", on: true)
        XCTAssertTrue(store.canGenerate)
        store.settings.casesBaseURL = "http://localhost:8111"
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.caseReviews["pdf_match"]!.report)
    }

    @MainActor
    func testMissingInputAndHistoricalReportsCannotBypassReview() async throws {
        let store = storeWithIssue()
        fillInputs(store)
        store.setSlot(0, demo: "pdf_match", url: nil)
        XCTAssertFalse(store.caseReviews["pdf_match"]!.canRun)
        store.confirmCase("pdf_match", on: true)
        XCTAssertFalse(store.canGenerate)
        let historical = try result().source()
        store.sources.append(historical)
        store.setAll(true)
        XCTAssertEqual(store.checkedSources.count, 1)
        XCTAssertEqual(store.briefSources.count, 1)
    }
    @MainActor
    func testSwitchingCasesKeepsOnlyOneSelectionAndRevokesOldConfirmation() async throws {
        let store = storeWithIssue()
        fillInputs(store)
        finishRun(store, result: try result())
        store.confirmCase("pdf_match", on: true)
        store.toggleDemo("packing", on: true)
        XCTAssertEqual(store.selectedDemo, "packing")
        XCTAssertFalse(store.caseReviews["pdf_match"]!.confirmed)
        XCTAssertTrue(store.confirmedEvidence.isEmpty)
        store.setSlot(0, demo: "packing", url: URL(fileURLWithPath: "/example/packing.pdf"))
        let revision = store.caseReviews["packing"]!.beginRun()
        XCTAssertFalse(store.caseReviews["packing"]!.receive(try result(), revision: revision))
        XCTAssertTrue(store.caseReviews["packing"]!.receive(try result(demo: "packing"), revision: revision))
        store.confirmCase("packing", on: true)
        XCTAssertTrue(store.canGenerate)
        XCTAssertEqual(store.confirmedEvidence.map(\.demo), ["packing"])
        store.toggleDemo("pdf_match", on: true)
        XCTAssertEqual(store.selectedDemo, "pdf_match")
        XCTAssertFalse(store.canGenerate)
        XCTAssertFalse(store.caseReviews["packing"]!.confirmed)
        store.clearCaseSelection()
        XCTAssertNil(store.selectedDemo)
        XCTAssertTrue(store.canGenerate)
    }

    @MainActor
    func testEventOptionRevokesConfirmationAndIsSavedInEvidence() async throws {
        let store = storeWithIssue()
        fillInputs(store)
        XCTAssertTrue(store.caseReviews["pdf_match"]!.includeEvents)
        finishRun(store, result: try result())
        store.confirmCase("pdf_match", on: true)
        XCTAssertTrue(store.confirmedEvidence[0].includeEvents)
        store.setCaseEvents("pdf_match", on: false)
        XCTAssertFalse(store.canGenerate)
        XCTAssertNil(store.caseReviews["pdf_match"]!.report)
        finishRun(store, result: try result())
        store.confirmCase("pdf_match", on: true)
        XCTAssertFalse(store.confirmedEvidence[0].includeEvents)
    }

    @MainActor
    func testLivePDFUploadReviewAndRerun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let a = env["REQBUDDY_LIVE_PDF_A"], let b = env["REQBUDDY_LIVE_PDF_B"] else {
            throw XCTSkip("Set REQBUDDY_LIVE_PDF_A and REQBUDDY_LIVE_PDF_B to test a live API upload.")
        }
        let store = storeWithIssue()
        if let address = env["REQBUDDY_LIVE_CASES_URL"] { store.settings.casesBaseURL = address }
        await store.refreshCases()
        XCTAssertEqual(store.caseHealth?.demos["pdf_match"]?.live, true)
        store.toggleDemo("pdf_match", on: true)
        store.setSlot(0, demo: "pdf_match", url: URL(fileURLWithPath: a))
        store.setSlot(1, demo: "pdf_match", url: URL(fileURLWithPath: b))
        defer { store.stopCase() }
        var runIDs: [String] = []
        for _ in 0..<2 {
            store.runCase("pdf_match")
            XCTAssertEqual(store.runningCase, "pdf_match")
            let deadline = Date().addingTimeInterval(180)
            while store.runningCase != nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertNil(store.runningCase, "Live run did not finish in time")
            let review = try XCTUnwrap(store.caseReviews["pdf_match"])
            let report = try XCTUnwrap(review.report, store.caseMessages["pdf_match"] ?? "No report")
            XCTAssertFalse(report.inputsIncomplete)
            XCTAssertFalse(report.events.isEmpty, "The live PDF report must include intermediate stages")
            XCTAssertFalse(store.canGenerate, "Even a live result needs explicit review")
            store.confirmCase("pdf_match", on: true)
            XCTAssertTrue(store.canGenerate)
            let built = PromptBuilder.build(docs: store.briefSources, settings: store.settings, notes: "", sendImages: false)
            XCTAssertTrue(built.preview.contains(report.run))
            XCTAssertEqual(store.confirmedEvidence.first?.report.run, report.run)
            runIDs.append(report.run)
            store.setSlot(1, demo: "pdf_match", url: URL(fileURLWithPath: b))
            XCTAssertFalse(store.canGenerate, "Reuploading must revoke confirmation")
        }
        XCTAssertNotEqual(runIDs[0], runIDs[1])
    }

}
