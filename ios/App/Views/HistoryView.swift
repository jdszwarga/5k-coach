import SwiftUI
import CoachCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            let list = Array(model.state.history.reversed())
            Group {
                if list.isEmpty {
                    ContentUnavailableView("No runs yet", systemImage: "figure.run",
                                           description: Text("Your completed runs will show up here."))
                } else {
                    List {
                        Section {
                            ForEach(list, id: \.id) { h in
                                NavigationLink(value: HistoryRoute(id: h.id)) { HistoryRow(h: h) }
                            }
                        } header: {
                            let mins = minutes(list.reduce(0) { $0 + timeOf($1) })
                            let dist = distOf(list)
                            Text("\(list.count) run\(list.count == 1 ? "" : "s") · \(mins) minutes\(dist > 0 ? " · \(miText(Double(dist))) miles" : "")")
                                .textCase(nil)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: HistoryRoute.self) { r in HistoryDetailView(id: r.id) }
        }
    }
}

private struct HistoryRow: View {
    let h: HistoryEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                (Text(shortDate(h.date)).fontWeight(.semibold)
                 + Text(h.sessionLabel.map { " · \($0)" } ?? "").foregroundColor(.secondary))
                Text("\(describe(h.workout)) · \(fmt(h.doneSec))\(extraBit(h))\(distBit(h))\(h.completed ? "" : " (partial)")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            FeelPill(feel: h.feel)
        }
    }
}

struct HistoryDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var confirmDelete = false

    var body: some View {
        if let h = model.state.history.first(where: { $0.id == id }) {
            form(h)
                .navigationTitle(shortDate(h.date))
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Run deleted", systemImage: "trash")
        }
    }

    private func form(_ h: HistoryEntry) -> some View {
        let st = model.state
        // Any run can be assigned to a plan session (e.g. a run started from "Custom intervals").
        let doneElsewhere = Set(st.history.filter { $0.id != h.id && $0.completed }.compactMap(\.sessionId))
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(h.sessionLabel ?? "Custom run").foregroundStyle(.secondary)
                    (Text(fmt(h.doneSec)).font(.largeTitle.bold()).monospacedDigit()
                     + Text(" / \(fmt(h.totalSec))").font(.title3).foregroundColor(.secondary))
                    if let x = h.extraSec, x > 0 {
                        Text("+\(fmt(x)) extra after the workout").font(.subheadline.weight(.semibold)).foregroundStyle(Color.warm)
                    }
                    Text(describe(h.workout)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if let d = h.distM, d > 0 {
                Section { GpsBlock(distM: d, pace: runPace(h), track: h.track).padding(.vertical, 4) }
            }
            Section {
                Picker("Plan session", selection: Binding(
                    get: { h.sessionId ?? "" },
                    set: { model.assign(h.id, to: $0.isEmpty ? nil : $0) }
                )) {
                    Text("None (extra run)").tag("")
                    ForEach(st.allSessions(), id: \.id) { s in
                        Text(model.sessionLabel(s) + (doneElsewhere.contains(s.id) ? " ✓" : "")).tag(s.id)
                    }
                }
                if let sid = h.sessionId, !sid.isEmpty {
                    Toggle("Counted as done", isOn: Binding(
                        get: { h.completed },
                        set: { v in model.updateHistory(h.id) { $0.completed = v } }
                    ))
                }
                Picker("How it felt", selection: Binding(
                    get: { h.feel ?? "" },
                    set: { v in model.updateHistory(h.id) { $0.feel = v.isEmpty ? nil : v } }
                )) {
                    Text("—").tag("")
                    ForEach(FEELS, id: \.id) { f in Text(f.label).tag(f.id) }
                }
            } footer: {
                Text("Choose the plan session this run was for; it then counts toward your plan. ✓ = already checked off by another run.")
            }
            Section("Notes") {
                TextField("Add a note about this run", text: Binding(
                    get: { h.notes },
                    set: { v in model.updateHistory(h.id) { $0.notes = v } }
                ), axis: .vertical)
                .lineLimit(3...8)
            }
            Section {
                Button("Delete run", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete this run?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                model.deleteRun(h.id)
            }
        }
    }
}
