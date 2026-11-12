import ReqCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersTab().tabItem { Label("Models", systemImage: "cpu") }
            PeopleTab().tabItem { Label("People", systemImage: "person.2") }
            CasesSettingsTab().tabItem { Label("Cases", systemImage: "checklist") }
            PromptTab().tabItem { Label("Prompt", systemImage: "text.quote") }
        }
        .frame(width: 720, height: 500)
    }
}

// MARK: - Providers

struct ProvidersTab: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: Provider.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.settings.providers) { p in Text(p.name).tag(p.id) }
                }
                HStack {
                    Button { addProvider() } label: { Image(systemName: "plus") }
                    Button { removeProvider() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || store.settings.providers.count <= 1)
                    Spacer()
                }.buttonStyle(.borderless).padding(6)
            }.frame(minWidth: 180, maxWidth: 220)

            if let i = store.settings.providers.firstIndex(where: { $0.id == selection }) {
                ProviderForm(provider: $store.settings.providers[i]).id(store.settings.providers[i].id)
            } else {
                Text("Select a model provider").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? store.settings.selectedProviderID ?? store.settings.providers.first?.id }
    }

    func addProvider() {
        let p = Provider(name: "New provider", baseURL: "https://api.example.com/v1", model: "")
        store.settings.providers.append(p)
        selection = p.id
    }

    func removeProvider() {
        store.settings.providers.removeAll { $0.id == selection }
        if store.settings.selectedProviderID == selection { store.settings.selectedProviderID = store.settings.providers.first?.id }
        selection = store.settings.providers.first?.id
    }
}

struct ProviderForm: View {
    @Binding var provider: Provider
    @State private var key = ""
    @State private var models: [ModelInfo] = []
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            TextField("Name", text: $provider.name)
            TextField("Base URL", text: $provider.baseURL, prompt: Text("http://localhost:8080/v1"))
            HStack {
                TextField("Model", text: $provider.model)
                Menu("Pick") {
                    ForEach(models) { m in
                        Button(m.id + (m.acceptsImages == true ? "  👁" : "")) { provider.model = m.id }
                    }
                }
                .frame(width: 70).disabled(models.isEmpty)
            }
            SecureField("API key (Keychain)", text: $key, prompt: Text("leave empty for local / env var"))
                .onSubmit { APIKeys.keychainSet(provider.id.uuidString, key) }
            TextField("…or env var", text: $provider.apiKeyEnv, prompt: Text("e.g. GEMINI_API_KEY"))
            Picker("Images", selection: $provider.vision) {
                ForEach(VisionMode.allCases) { Text($0.label).tag($0) }
            }
            TextField("Extra request JSON", text: $provider.extraBody, prompt: Text("{\"temperature\": 0.3}"))
            HStack {
                Button("Save key") { APIKeys.keychainSet(provider.id.uuidString, key); testResult = key.isEmpty ? "Key removed." : "Key saved to Keychain." }
                Button("Test & list models") { Task { await test() } }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
            }
            if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .onAppear { key = APIKeys.keychainGet(provider.id.uuidString) ?? "" }
    }

    func test() async {
        testing = true
        defer { testing = false }
        let p = provider
        let k = await Task.detached { APIKeys.resolve(for: p) }.value
        let c = LLMClient(provider: p, apiKey: k)
        do {
            models = try await c.listModels()
            let vision = await c.resolveVision()
            let found = models.contains { $0.id == p.model }
            testResult = "OK: \(models.count) models. \(p.model.isEmpty ? "" : found ? "'\(p.model)' found" : "'\(p.model)' not in list")"
                + (provider.vision == .auto ? " · images: \(vision ? "yes" : "no (OCR)")" : "")
        } catch {
            testResult = error.localizedDescription
        }
    }
}

// MARK: - People

struct PeopleTab: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading) {
            Text("Tell the model who is who: whose words are decisions, who is the customer, and which one is you.")
                .font(.callout).foregroundStyle(.secondary)
            Table($store.settings.people) {
                TableColumn("Name") { $p in TextField("", text: $p.name) }.width(min: 100, ideal: 130)
                TableColumn("Emails / aliases") { $p in TextField("", text: $p.aliases) }.width(min: 120, ideal: 180)
                TableColumn("Role") { $p in TextField("", text: $p.role) }
                TableColumn("Me") { $p in
                    Toggle("", isOn: Binding(get: { p.isMe }, set: { v in
                        if v { for i in store.settings.people.indices { store.settings.people[i].isMe = false } }
                        p.isMe = v
                    })).labelsHidden()
                }.width(30)
                TableColumn("") { $p in
                    Button { store.settings.people.removeAll { $0.id == p.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }.width(24)
            }
            HStack {
                Button("Add person") { store.settings.people.append(Person(name: "", role: "")) }
                Spacer()
                Stepper("Max images per request: \(store.settings.maxImages)", value: $store.settings.maxImages, in: 0...64)
            }
        }
        .padding()
    }
}

// MARK: - Prompt

struct PromptTab: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading) {
            Text("System prompt. Leave unchanged to keep using the built-in default as it improves.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { store.settings.systemPrompt.isEmpty ? PromptBuilder.defaultSystemPrompt : store.settings.systemPrompt },
                set: { store.settings.systemPrompt = $0 == PromptBuilder.defaultSystemPrompt ? "" : $0 }))
                .font(.system(.callout, design: .monospaced))
            HStack {
                Text(store.settings.systemPrompt.isEmpty ? "Using default" : "Customized").font(.caption)
                Spacer()
                Button("Reset to default") { store.settings.systemPrompt = "" }.disabled(store.settings.systemPrompt.isEmpty)
            }
        }
        .padding()
    }
}

struct CasesSettingsTab: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Form {
            TextField("Cases API base URL", text: $store.settings.casesBaseURL)
            Text("Default: http://127.0.0.1:8110. Forward this port when the API runs on another machine. Files are uploaded with their names; local paths are never sent as server paths.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Refresh cases") { Task { await store.refreshCases() } }
        }.padding()
    }
}
