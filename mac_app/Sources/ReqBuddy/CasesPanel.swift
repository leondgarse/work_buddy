import AppKit
import ReqCore
import SwiftUI
import UniformTypeIdentifiers

struct CasesPanel: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("2. Test a related case").font(.headline)
                Text("Optional").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.refreshCases() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh availability").disabled(store.loadingCases || store.runningCase != nil)
                if store.loadingCases { ProgressView().controlSize(.small) }
            }
            Text("Select the case that fits the issue. Upload its files, run it, then confirm the output for your brief.")
                .font(.caption).foregroundStyle(.secondary)
            if !store.casesMessage.isEmpty {
                Text(store.casesMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(DemoInputs.supported, id: \.demo) { spec in
                CaseCard(spec: spec)
            }
        }
        .disabled(store.busy)
        .task { await store.refreshCases() }
    }
}

private struct CaseCard: View {
    @EnvironmentObject var store: AppStore
    let spec: DemoInputs
    @State private var fullReport = false
    private var selected: Bool { store.selectedDemos.contains(spec.demo) }
    private var live: Bool { store.caseHealth?.demos[spec.demo]?.live == true }
    private var review: CaseReview { store.caseReviews[spec.demo] ?? CaseReview(demo: spec.demo) }
    private var running: Bool { store.runningCase == spec.demo }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Toggle(isOn: Binding(get: { selected }, set: { store.toggleDemo(spec.demo, on: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.displayName).font(.callout.bold())
                        Text(spec.demo).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(store.runningCase != nil)
                Spacer()
                Text(live ? "Available" : "Offline").font(.caption).foregroundStyle(.secondary)
            }
            if selected {
                Text(spec.purpose).font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(Array(spec.labels.enumerated()), id: \.offset) { i, label in
                        slot(i, label: label)
                    }
                }.disabled(store.runningCase != nil)
                HStack {
                    if running {
                        ProgressView().controlSize(.small)
                        Button("Stop run") { store.stopCase() }
                    } else {
                        Button(review.report == nil ? "Run case" : "Run again") { store.runCase(spec.demo) }
                            .disabled(!live || !review.canRun || store.runningCase != nil)
                    }
                    Spacer()
                    if review.confirmed {
                        Label("Confirmed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    }
                }
                if let message = store.caseMessages[spec.demo] {
                    Text(message).font(.caption).textSelection(.enabled)
                }
                if let report = review.report {
                    Divider()
                    HStack {
                        Text("Output").font(.subheadline.bold())
                        Spacer()
                        Button("Full report…") { fullReport = true }.font(.caption)
                    }
                    Text(report.verdict).font(.caption).textSelection(.enabled)
                    ScrollView {
                        Text(report.source(files: review.orderedFiles).text)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 210)
                    Toggle("Reviewed — use this result in the brief", isOn: Binding(
                        get: { review.confirmed }, set: { store.confirmCase(spec.demo, on: $0) }))
                        .toggleStyle(.checkbox)
                        .disabled(!review.canConfirm || store.runningCase != nil)
                } else {
                    Text("Fill the required slots to run. Changing any input requires a new run and confirmation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor.opacity(0.4) : Color.clear))
        .sheet(isPresented: $fullReport) {
            VStack(alignment: .leading) {
                Text("\(spec.displayName) — full report").font(.headline)
                ScrollView {
                    Text(review.report?.raw.pretty ?? "The inputs have changed. Run again to get a new report.")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Close") { fullReport = false }.keyboardShortcut(.cancelAction) }
            }.padding().frame(width: 760, height: 580)
        }
    }

    private func slot(_ i: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label + (i < spec.minimum ? " (required)" : " (optional)"))
                .font(.caption.bold())
            Text(review.files[i]?.lastPathComponent ?? "Drop a file here")
                .font(.caption).lineLimit(1).help(review.files[i]?.path ?? "")
            HStack(spacing: 8) {
                Button("Choose…") { store.pickSlot(i, demo: spec.demo) }
                Button("Paste file") { store.pasteSlot(i, demo: spec.demo) }
                Menu("From sources") {
                    ForEach(store.inputSources.filter { !$0.isConversation }) { doc in
                        Button(doc.url.lastPathComponent) { store.setSlot(i, demo: spec.demo, url: doc.url) }
                    }
                }.disabled(store.inputSources.allSatisfy(\.isConversation))
                if review.files[i] != nil {
                    Button { store.setSlot(i, demo: spec.demo, url: nil) } label: { Image(systemName: "xmark.circle") }
                        .help("Remove file")
                }
            }.font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard store.runningCase == nil, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.setSlot(i, demo: spec.demo, url: url) } }
            }
            return true
        }
    }
}

private extension DemoInputs {
    var displayName: String {
        switch demo {
        case "pdf_match": return "Customer PO verification"
        case "packing": return "Packing document checks"
        case "logistics": return "RFQ matching"
        case "office": return "Office document questions"
        case "email": return "Email processing"
        default: return demo
        }
    }
    var purpose: String {
        switch demo {
        case "pdf_match": return "Compare two PDFs. A is our quotation (the reference); B is the customer's PO."
        case "packing": return "Check 1–8 shipment documents for disagreements."
        case "logistics": return "Run matching on one RFQ document."
        case "office": return "Run the document pipeline on one file."
        case "email": return "Run the email pipeline on one email file."
        default: return "Upload the files related to this issue."
        }
    }
}
