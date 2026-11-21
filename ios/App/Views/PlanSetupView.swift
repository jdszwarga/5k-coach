import SwiftUI
import CoachCore

/// Onboarding, and Plan settings (rebuilding the plan). Completed runs stay checked off.
struct PlanSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var d = Profile(weeks: 8, perWeek: 3)
    @State private var loaded = false
    @State private var building = false
    @State private var buildError: String?
    @State private var confirmReplace: (() -> Void)?
    @State private var coachSetup = false
    @State private var importing = false
    @State private var importError: String?

    private static let REC_WEEKS = ["new": 8, "some": 6, "regular": 4, "strong": 3]

    private var editing: Bool { model.state.plan != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(editing ? "Rebuild your plan. Completed runs stay checked off."
                         : "Answer a few questions and I’ll build a run/walk plan that ends with a non-stop 5K (3.1 miles).")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                if !editing {
                    Section {
                        Button { importing = true } label: {
                            Label("Import from the web app", systemImage: "square.and.arrow.down")
                        }
                    } footer: {
                        Text("Already using 5K Coach in Safari? In the web app go to Settings → Export data, save the file, then import it here to bring over your plan and runs.")
                    }
                }

                Section("Where are you starting?") {
                    ForEach(LEVELS) { L in
                        Button { d.level = L.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L.label).foregroundStyle(.primary)
                                    Text(L.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if d.level == L.id { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.run) }
                            }
                        }
                    }
                }

                Section {
                    Stepper(value: $d.weeks, in: 2...20) {
                        LabeledContent("Weeks to 5K", value: "\(d.weeks) weeks")
                    }
                    Stepper(value: $d.perWeek, in: 2...6) {
                        LabeledContent("Runs per week", value: "\(d.perWeek)")
                    }
                    DatePicker("Start date", selection: Binding(
                        get: { dayFromISO(d.startDate) ?? Date() },
                        set: { d.startDate = localDay($0) }
                    ), displayedComponents: .date)
                } header: { Text("Schedule") } footer: {
                    let rec = PlanSetupView.REC_WEEKS[d.level] ?? 8
                    if d.weeks < rec {
                        Text("Heads up: \(rec)+ weeks is typical from this starting point. A shorter plan has bigger jumps — Claude can tune it, or you can repeat weeks.")
                            .foregroundStyle(Color.warm)
                    } else {
                        Text("Run on any days you like — just aim for a rest day between runs.")
                    }
                }

                Section {
                    Stepper(value: $d.paceMi, in: 7...18, step: 0.25) {
                        LabeledContent("Per mile", value: paceText(d.paceMi))
                    }
                } header: { Text("Easy pace") } footer: {
                    Text("Not sure? Leave it. This sets the final 3.1-mile run at about \(minutes(goalSeconds(d.paceMi))) minutes.")
                }

                if model.hasKey {
                    Section {
                        TextField("Optional — e.g. old knee injury, I walk a lot, I’d like to run a 5K race on Feb 14…",
                                  text: Binding(get: { d.notes ?? "" }, set: { d.notes = $0 }), axis: .vertical)
                            .lineLimit(3...6)
                    } header: { Text("Anything your coach should know?") } footer: {
                        Text("Claude uses this to personalize the plan.")
                    }
                }

                Section {
                    if let buildError {
                        Text(buildError).foregroundStyle(.red).frame(maxWidth: .infinity)
                    }
                    if model.hasKey {
                        Button { replaceThen(buildClaude) } label: {
                            HStack {
                                if building { ProgressView().tint(.white) } else { Image(systemName: "sparkles") }
                                Text(building ? "Claude is building your plan…" : "Build with Claude")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(building)
                        Button("Use the built-in plan instead") { replaceThen(buildLocal) }
                            .frame(maxWidth: .infinity)
                            .disabled(building)
                    } else {
                        Button("Create my plan") { replaceThen(buildLocal) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle(editing ? "Plan settings" : "Your 5K plan")
            .toolbar {
                if editing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.editingPlan = false }.disabled(building)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { coachSetup = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Coach setup")
                }
            }
            .sheet(isPresented: $coachSetup) {
                NavigationStack {
                    CoachSetupView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { coachSetup = false } } }
                }
            }
            .confirmationDialog("Replace your current plan? Completed runs stay in History.",
                                isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } }),
                                titleVisibility: .visible) {
                Button("Replace") { let f = confirmReplace; confirmReplace = nil; f?() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
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
            .alert("Couldn’t import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
        .onAppear {
            if !loaded { d = model.defaultDraft(); loaded = true }
        }
    }

    private func replaceThen(_ action: @escaping () -> Void) {
        buildError = nil
        if editing { confirmReplace = action } else { action() }
    }

    private func buildLocal() {
        model.savePlan(generatePlan(d), profile: d)
    }

    private func buildClaude() {
        building = true
        buildError = nil
        let profile = d
        Task {
            do {
                let plan = try await model.buildWithClaude(profile)
                building = false
                model.savePlan(plan, profile: profile)
            } catch {
                building = false
                buildError = error.localizedDescription
            }
        }
    }
}
