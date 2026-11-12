import AppKit
import ReqCore
import SwiftUI
import UniformTypeIdentifiers

struct CasesPanel: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        DisclosureGroup("Cases") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Refresh") { Task { await store.refreshCases() } }.disabled(store.loadingCases)
                    if store.loadingCases { ProgressView().controlSize(.small) }
                    Text("Runs go only to the selected model.").font(.caption).foregroundStyle(.secondary)
                }
                if !store.casesMessage.isEmpty { Text(store.casesMessage).font(.caption).textSelection(.enabled) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(Set(store.availableCases.map(\.demo))).sorted(), id: \.self) { demo in
                            Text(demo).font(.headline)
                            ForEach(store.availableCases.filter { $0.demo == demo }, id: \.key) { c in
                                VStack(alignment: .leading) {
                                    Toggle(c.id + " — " + c.title, isOn: Binding(
                                        get: { store.selectedCases.contains(c.key) },
                                        set: { store.toggleCase(c, on: $0) }))
                                        .disabled((!store.caseIsLive(c) && !store.selectedCases.contains(c.key)) || store.busy)
                                    Text(store.caseBlurbs[c.key] ?? c.title).font(.caption).foregroundStyle(.secondary)
                                    if let status = store.caseStatuses[c.key] { Text(status).font(.caption).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 160)
                Picker("Run my files", selection: Binding(get: { store.selectedDemo }, set: store.chooseDemo)) {
                    Text("None").tag("")
                    ForEach(DemoInputs.supported, id: \.demo) { spec in
                        Text(spec.demo + (store.caseHealth?.demos[spec.demo]?.live == true ? "" : " (offline)"))
                            .tag(spec.demo)
                    }
                }.disabled(store.busy)
                if let spec = DemoInputs.spec(store.selectedDemo) {
                    Text(spec.demo == "pdf_match" ? "A is the reference quotation; B is checked against it. Both PDFs are required." : "Provide \(spec.minimum)–\(spec.labels.count) file(s).")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(spec.labels.enumerated()), id: \.offset) { i, label in
                                slot(i, label: label)
                            }
                        }
                    }.frame(maxHeight: 145)
                    if let status = store.caseStatuses[spec.demo] { Text(status).font(.caption).textSelection(.enabled) }
                }
            }.padding(.top, 6)
        }
        .disabled(store.busy)
        .task { await store.refreshCases() }
    }

    private func slot(_ i: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.bold())
                Spacer()
                Button("Choose…") { store.pickSlot(i) }
                Button("Paste") { store.pasteSlot(i) }
                if store.demoFiles[i] != nil {
                    Button { store.demoFiles.removeValue(forKey: i) } label: { Image(systemName: "xmark.circle") }
                }
            }
            Text(store.demoFiles[i]?.lastPathComponent ?? "Drop a file here")
                .font(.caption).lineLimit(1).help(store.demoFiles[i]?.path ?? "")
            Menu("Use a source file") {
                ForEach(store.sources.filter { !$0.isConversation && $0.kind != "case report" }) { doc in
                    Button(doc.url.lastPathComponent) { store.setSlot(i, url: doc.url) }
                }
            }.font(.caption)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(store.activeSlot == i ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05)))
        .onTapGesture { store.activeSlot = i }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.setSlot(i, url: url) } }
            }
            return true
        }
    }
}
