import SwiftUI
import UniformTypeIdentifiers
import CoachCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false
    @State private var confirmReset = false
    @State private var importError: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Countdown beeps", isOn: $model.state.settings.beeps)
                    Toggle("“Halfway there” cue", isOn: $model.state.settings.halfway)
                    Button("Test voice cue") {
                        do { try CuePreview.shared.play() } catch { model.showToast("Couldn’t play: \(error.localizedDescription)") }
                    }
                } header: { Text("Voice cues") } footer: {
                    Text("Cues play over Spotify and podcasts, and keep going with your iPhone locked in your pocket.")
                }

                Section {
                    Toggle("Track distance with GPS", isOn: $model.state.settings.gps)
                } header: { Text("Distance") } footer: {
                    Text("Records distance, pace and a map of your route. iPhone asks for location access on your first run.")
                }

                Section("Coach") {
                    NavigationLink {
                        CoachSetupView()
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.warm.gradient, in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading) {
                                Text("Claude coach")
                                Text(model.hasKey ? "Connected" : "Not set up").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.hasKey {
                        Toggle("Review after each run", isOn: $model.state.settings.autoReview)
                    }
                }

                Section("Plan") {
                    Button("Plan settings") { model.editingPlan = true }
                }

                Section {
                    Button("Import from the web app") { importing = true }
                    ShareLink(item: ExportFile(json: (try? model.state.exportJSON()) ?? Data()),
                              preview: SharePreview("5K Coach data")) {
                        Text("Export data")
                    }
                    Button("Reset everything", role: .destructive) { confirmReset = true }
                } header: { Text("Data") } footer: {
                    Text("Import reads the file from the web app’s Settings → Export data, and replaces what’s on this iPhone.")
                }

                Section {
                } footer: {
                    Text("5K Coach \(version)").frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
                importFile(result)
            }
            .confirmationDialog("Delete your plan, history and settings from this iPhone? (The coach setup is kept.)",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { model.resetAll() }
            }
            .alert("Couldn’t import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try model.importWebData(try Data(contentsOf: url))
        } catch AppState.ImportError.notAnExport {
            importError = "That file isn’t a 5K Coach export."
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// The export as a .json file for the share sheet.
struct ExportFile: Transferable {
    let json: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("5k-coach-\(todayISO()).json")
            try file.json.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

struct CoachSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var typed = ""
    @State private var status = ""
    @State private var ok = false
    @State private var busy = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                Text("One-time setup. Paste a Claude API key and the coach builds the plan and reviews each run. The key stays on this iPhone (in the Keychain) and is only ever sent to Anthropic.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                if model.hasKey {
                    LabeledContent("Current key", value: "••••" + String(model.state.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4)))
                }
                SecureField(model.hasKey ? "Paste a new key to replace it" : "sk-ant-…", text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Model", selection: $model.state.settings.model) {
                    ForEach(Coach.MODELS, id: \.id) { m in Text(m.label).tag(m.id) }
                }
            } header: { Text("Claude API key") } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if !status.isEmpty {
                        Text(status).fontWeight(.semibold).foregroundStyle(ok ? Color.run : Color.red)
                    }
                    Text("Tip: create a separate key for this app at console.anthropic.com and put a monthly spend limit on its workspace. A plan or a run review costs a few cents.")
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if busy { ProgressView().padding(.trailing, 4) }
                        Text(busy ? "Checking…" : "Save & test")
                    }
                }
                .disabled(busy)
            }
            if model.hasKey {
                Section {
                    Button("Remove API key", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .navigationTitle("Coach setup")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove the API key from this iPhone? The coach will stop working until a key is added again.",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.state.settings.apiKey = ""
                model.state.pendingReview = nil
                status = ""
            }
        }
    }

    private func save() async {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { model.state.settings.apiKey = key; typed = "" }
        guard model.hasKey else { status = "Paste a key first."; ok = false; return }
        busy = true; status = ""
        do {
            try await model.testKey()
            ok = true; status = "Connected — the coach is ready."
        } catch {
            ok = false; status = error.localizedDescription
        }
        busy = false
    }
}
