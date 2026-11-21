import SwiftUI
import CoachCore

/// Opens a run's detail page from the Plan or History list.
struct HistoryRoute: Hashable { let id: String }

struct PlanView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let plan = model.state.plan {
                    header(plan)
                    weeks(plan)
                    Section {
                        if model.hasKey {
                            Button {
                                model.tab = .today
                                model.runReview()
                            } label: { Label("Review with Claude", systemImage: "sparkles") }
                        }
                        Button("Plan settings") { model.editingPlan = true }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Plan")
            .navigationDestination(for: HistoryRoute.self) { r in HistoryDetailView(id: r.id) }
        }
    }

    private func header(_ plan: Plan) -> some View {
        let prog = model.state.progress()
        let frac = Double(prog.done) / Double(max(1, prog.total))
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(plan.summary + (plan.source == "claude" ? " · Made with Claude" : ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    (Text("\(prog.done)").bold() + Text(" of \(prog.total) runs done"))
                    Spacer()
                    Text("\(jsRoundInt(frac * 100))%").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                ProgressView(value: frac).tint(Color.run)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func weeks(_ plan: Plan) -> some View {
        let st = model.state
        let next = st.nextSession()
        // The run that checked off each session (latest wins), and unfinished tries.
        let grouped = runsBySession(st.history)
        let doneRun = grouped.0
        let tries = grouped.1
        ForEach(plan.weeks, id: \.week) { w in
            let nDone = w.sessions.filter { st.isDone($0.id) }.count
            let ids = Set(w.sessions.map(\.id))
            let wkDist = distOf(st.history.filter { ids.contains($0.sessionId ?? "") })
            Section {
                ForEach(w.sessions, id: \.id) { s in
                    if let run = doneRun[s.id] {
                        NavigationLink(value: HistoryRoute(id: run.id)) {
                            HStack(spacing: 12) {
                                StatusDot(state: .done)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.body.weight(.semibold))
                                    Text("\(shortDate(run.date)) · \(run.manual == true ? "Checked off" : "\(describe(run.workout)) · \(fmt(run.doneSec))\(distBit(run))")")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                FeelPill(feel: run.feel)
                            }
                        }
                    } else {
                        Button { model.openSetup(s.id) } label: {
                            HStack(spacing: 12) {
                                StatusDot(state: next?.id == s.id ? .next : .todo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(describe(s.workout)).font(.footnote).foregroundStyle(.secondary)
                                    if let tried = tries[s.id]?.last {
                                        Text("Tried \(shortDate(tried.date)) · \(fmt(tried.doneSec)) of \(fmt(tried.totalSec))")
                                            .font(.footnote).foregroundStyle(Color.warm)
                                    }
                                }
                                Spacer()
                                Text("\(minutes(totalSeconds(s.workout))) min").font(.subheadline).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                        }
                        .listRowBackground(next?.id == s.id ? Color.run.opacity(0.08) : Color.card)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Week \(w.week)")
                        if nDone == w.sessions.count {
                            Label("Done", systemImage: "checkmark").foregroundStyle(Color.run)
                        } else {
                            Text("\(nDone) of \(w.sessions.count)")
                        }
                        if wkDist > 0 { Text("\(miText(Double(wkDist))) mi") }
                    }
                    if !w.focus.isEmpty {
                        Text(w.focus).textCase(nil).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func runsBySession(_ history: [HistoryEntry]) -> ([String: HistoryEntry], [String: [HistoryEntry]]) {
        var done: [String: HistoryEntry] = [:], tries: [String: [HistoryEntry]] = [:]
        for h in history {
            guard let id = h.sessionId, !id.isEmpty else { continue }
            if h.completed { done[id] = h } else { tries[id, default: []].append(h) }
        }
        return (done, tries)
    }
}

struct StatusDot: View {
    enum Kind { case done, next, todo }
    let state: Kind
    var body: some View {
        ZStack {
            Circle().fill(state == .done ? Color.run : Color.clear)
            Circle().stroke(state == .todo ? Color(.systemFill) : Color.run, lineWidth: 2.5)
            if state == .done { Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(.white) }
        }
        .frame(width: 24, height: 24)
    }
}
