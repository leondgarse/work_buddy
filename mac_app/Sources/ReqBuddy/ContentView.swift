import AppKit
import ReqCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var targeted = false
    @State private var pathText = ""
    @State private var promptPreview: String?

    var body: some View {
        HSplitView {
            inputPane.frame(minWidth: 340, idealWidth: 400, maxWidth: 560)
            outputPane.frame(minWidth: 420)
        }
        .onAppear { PasteMonitor.install(store) }
        .sheet(item: Binding(get: { promptPreview.map(PreviewText.init) }, set: { promptPreview = $0?.text })) { p in
            VStack(alignment: .leading) {
                Text("Prompt preview").font(.headline)
                ScrollView { Text(p.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { promptPreview = nil }.keyboardShortcut(.cancelAction) }
            }.padding().frame(width: 760, height: 600)
        }
    }

    // MARK: input

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            dropZone
            HStack {
                TextField("…or paste file / folder paths", text: $pathText)
                    .onSubmit { store.addPaths(pathText); pathText = "" }
                Button("Add") { store.addPaths(pathText); pathText = "" }.disabled(pathText.isEmpty)
            }
            Text("My notes (override the sources, e.g. \"2 is by design\")").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $store.notes)
                .font(.body).frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Divider()
            HStack {
                Picker("Model", selection: Binding(
                    get: { store.settings.selectedProviderID ?? store.settings.providers.first?.id },
                    set: { store.settings.selectedProviderID = $0 })) {
                    ForEach(store.settings.providers) { p in Text(p.name).tag(Optional(p.id)) }
                }
                SettingsLink { Image(systemName: "gearshape") }.help("Providers, people & prompt")
            }
            if let p = store.provider {
                Text("\(p.model) · \(p.vision.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Button("Preview prompt") { Task { promptPreview = await store.previewPrompt() } }
                    .disabled(store.checkedSources.isEmpty)
                Spacer()
                if store.busy {
                    Button("Stop", role: .cancel) { store.stop() }
                } else {
                    let n = store.checkedSources.count
                    Button(n == store.sources.count || n == 0 ? "Generate brief" : "Generate brief from \(n)") { store.generate() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(n == 0 || store.extracting > 0)
                        .help("One requirement brief from the ticked sources")
                }
            }
        }
        .padding(12)
    }

    private var dropZone: some View {
        VStack(spacing: 0) {
            if store.sources.isEmpty && store.extracting == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Drop emails, Lark chat PDFs, screenshots or folders").multilineTextAlignment(.center)
                    Text("or press ⌘V to paste a screenshot").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose Files…") { store.openFiles() }
                        Button("Paste") { if !store.pasteFromClipboard() { store.status = "No image or files on the clipboard." } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(store.sources) { d in
                            SourceRow(doc: d, checked: store.checked.contains(d.id), usedIn: store.usedIn(d.id),
                                      onToggle: { store.toggle(d.id) }, onRemove: { store.remove(d.id) })
                        }
                    } header: {
                        HStack {
                            Text("Tick the files that make up one requirement")
                            Spacer()
                            Button("All") { store.setAll(true) }.buttonStyle(.link)
                            Button("None") { store.setAll(false) }.buttonStyle(.link)
                        }.font(.caption)
                    }
                    if store.extracting > 0 {
                        HStack { ProgressView().controlSize(.small); Text("Reading \(store.extracting) file(s)…") }
                    }
                }
                .listStyle(.inset)
                HStack {
                    Button("Add…") { store.openFiles() }
                    Button("Paste") { if !store.pasteFromClipboard() { store.status = "No image or files on the clipboard." } }
                        .help("Add a screenshot or files from the clipboard (⌘V)")
                    Spacer()
                    Button("Clear") { store.clear() }
                }.padding(6)
            }
        }
        .frame(minHeight: 220)
        .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(targeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $targeted, perform: handleDrop)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in store.add([url]) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data { Task { @MainActor in store.addImageData(data) } }
                }
            } else {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    if let s { Task { @MainActor in store.addPaths(s) } }
                }
            }
        }
        return true
    }

    // MARK: output

    private var outputPane: some View {
        VStack(spacing: 0) {
            HStack {
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.status).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Spacer()
                let none = store.currentBrief.isEmpty || store.busy
                Button { store.copyOutput() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(none).keyboardShortcut("c", modifiers: [.command, .shift])
                Button { store.saveOutput() } label: { Label("Save .md", systemImage: "square.and.arrow.down") }
                    .disabled(none).keyboardShortcut("s")
            }
            .padding(10)
            if !store.briefs.isEmpty { briefTabs }
            Divider()
            TextEditor(text: editorText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .overlay {
                    if store.output.isEmpty && store.currentBrief.isEmpty && !store.busy {
                        Text("The requirements brief appears here. It stays editable, so tweak it before copying it into Claude Code.")
                            .foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(40)
                    }
                }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Live stream while generating, otherwise the selected brief (editable).
    private var editorText: Binding<String> {
        Binding(
            get: { store.busy ? store.output : store.currentBrief },
            set: { v in
                if store.busy { store.output = v }
                else if let i = store.currentIndex { store.briefs[i].text = v }
            })
    }

    private var briefTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(store.briefs.enumerated()), id: \.element.id) { i, b in
                    let on = b.id == store.selectedBrief && !store.busy
                    HStack(spacing: 4) {
                        Text("\(i + 1). \(b.title)").lineLimit(1).frame(maxWidth: 220)
                        Button { store.closeBrief(b.id) } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.borderless).help("Close this brief")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedBrief = b.id }
                    .help(b.title)
                }
                if store.busy {
                    Text("\(store.briefs.count + 1). generating…").foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)))
                }
            }.padding(.horizontal, 10)
        }
        .font(.callout)
        .padding(.bottom, 8)
    }
}

private struct PreviewText: Identifiable { let text: String; var id: String { text } }

struct SourceRow: View {
    let doc: SourceDoc
    let checked: Bool
    let usedIn: [Int]
    let onToggle: () -> Void
    let onRemove: () -> Void

    var icon: String {
        switch doc.kind {
        case "email": return "envelope"
        case "pdf": return "doc.richtext"
        case "image": return "photo"
        default: return "doc.text"
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(get: { checked }, set: { _ in onToggle() })).labelsHidden()
            Image(systemName: icon).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(doc.kind) · \(doc.text.count) chars · \(doc.images.count) image(s)")
                    if !usedIn.isEmpty {
                        Text("→ brief " + usedIn.map(String.init).joined(separator: ", "))
                            .foregroundStyle(Color.accentColor)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
        }
        .opacity(checked ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(doc.url.path)
    }
}

/// App-wide ⌘V hook: a screenshot or copied files on the clipboard become sources, wherever focus is.
/// Plain text falls through to the focused field as usual.
@MainActor
enum PasteMonitor {
    private static var installed = false
    static func install(_ store: AppStore) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers == "v",
                  e.window?.identifier?.rawValue.contains("Settings") != true,
                  let store, store.pasteFromClipboard() else { return e }
            return nil
        }
    }
}
