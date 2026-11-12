import Foundation

/// The report approved for a brief, with the exact upload order that produced it.
public struct CaseEvidence {
    public let demo: String
    public let files: [URL]
    public let report: CaseReport
    public let includeEvents: Bool
    public var source: SourceDoc { report.source(files: files) }
}

/// Upload → run → review → confirm. Editing inputs or starting another run revokes confirmation.
public struct CaseReview {
    public let demo: String
    public private(set) var files: [Int: URL] = [:]
    public private(set) var includeEvents: Bool
    public private(set) var report: CaseReport?
    public private(set) var confirmed = false
    public private(set) var revision = UUID()

    public init(demo: String) { self.demo = demo; includeEvents = demo == "pdf_match" }
    public mutating func setIncludeEvents(_ on: Bool) {
        guard on != includeEvents else { return }
        includeEvents = on; invalidate()
    }
    public var orderedFiles: [URL] { files.sorted { $0.key < $1.key }.map(\.value) }
    public var canRun: Bool {
        guard let spec = DemoInputs.spec(demo),
              (0..<spec.minimum).allSatisfy({ files[$0] != nil }) else { return false }
        return (try? spec.validate(orderedFiles)) != nil
    }
    public var canConfirm: Bool { canRun && report?.terminal == true && report?.inputsIncomplete == false }
    public var evidence: CaseEvidence? {
        guard confirmed, canConfirm, let report else { return nil }
        return CaseEvidence(demo: demo, files: orderedFiles, report: report, includeEvents: includeEvents)
    }
    public mutating func invalidate() {
        report = nil; confirmed = false; revision = UUID()
    }
    public mutating func setFile(_ url: URL?, at slot: Int) {
        guard let spec = DemoInputs.spec(demo), spec.labels.indices.contains(slot) else { return }
        files[slot] = url
        invalidate()
    }
    @discardableResult
    public mutating func beginRun() -> UUID { invalidate(); return revision }
    @discardableResult
    public mutating func receive(_ report: CaseReport, revision: UUID) -> Bool {
        guard revision == self.revision, report.demo == demo, report.terminal else { return false }
        self.report = report; confirmed = false
        return true
    }
    public mutating func confirm(_ on: Bool) { confirmed = on && canConfirm }
}
