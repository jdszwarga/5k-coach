import SwiftUI
import CoachCore

struct TodayView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text(longDateFormatter.string(from: Date()))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.state.plan != nil {
                        WeekChecklist()
                        Hero()
                    }
                    CoachCard()
                    Stats()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.page)
            .navigationTitle("Today")
        }
    }
}

private struct WeekChecklist: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let st = model.state
        let next = st.nextSession()
        let weeks = st.plan?.weeks ?? []
        let weekNo = next?.week ?? weeks.count
        if let w = weeks.first(where: { $0.week == weekNo }), !w.sessions.isEmpty {
            let n = w.sessions.count
            let doneCount = w.sessions.filter { st.isDone($0.id) }.count
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Eyebrow("Week \(weekNo) of \(weeks.count)")
                        Text(doneCount == n ? "Week complete!" : "\(doneCount) of \(n) runs done").font(.headline)
                    }
                    Spacer()
                    Ring(pct: Double(doneCount) / Double(n), size: 46, stroke: 6)
                }
                HStack(spacing: 8) {
                    ForEach(Array(w.sessions.enumerated()), id: \.element.id) { i, s in
                        let done = st.isDone(s.id)
                        let isNext = next?.id == s.id
                        Button { model.openSetup(s.id) } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle().fill(done ? Color.run : Color.clear)
                                    Circle().stroke(done ? Color.run : isNext ? Color.run : Color(.systemFill), lineWidth: 2.5)
                                    if done { Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.white) }
                                }
                                .frame(width: 28, height: 28)
                                Text(s.title == "5K run" ? "5K" : "Run \(i + 1)").font(.footnote.weight(.semibold))
                                Text("\(minutes(totalSeconds(s.workout))) min").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(isNext ? Color.run.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(s.title)\(done ? ", done" : "")")
                    }
                }
            }
        }
    }
}

private struct Hero: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let st = model.state
        let next = st.nextSession()
        let gap = model.daysSinceLastRun()
        let lastDone = model.lastDonePlanSession()
        let weekCount = model.runsThisWeek()

        Card {
            if let next, let lastDone, let gap, gap > AppModel.comebackDays {
                // Comeback: after a long break, suggest repeating the last plan run before moving on.
                let wk = lastDone.workout
                Eyebrow("Welcome back", color: .walk)
                Text("Ease back in").font(.title.bold())
                Text("It’s been \(gap) days since your last run. Repeat your last plan run before moving on — it’ll feel easier than you think.")
                    .foregroundStyle(.secondary)
                Note(title: model.sessionLabel(lastDone), text: "\(describe(wk)) · \(minutes(totalSeconds(wk))) min")
                startButton("Repeat last run") { model.openRepeat(lastDone) }
                secondaryButton("Continue with \(model.sessionLabel(next))") { model.openSetup(next.id) }
            } else if let next, weekCount >= (st.profile?.perWeek ?? Int.max) {
                // Weekly target reached: steer extra runs to an easy bonus run that doesn't advance the plan.
                let wk = model.bonusWorkout()
                Eyebrow("This week · \(weekCount) run\(weekCount == 1 ? "" : "s")")
                Text("Weekly goal done!").font(.title.bold())
                Text("Rest days are when your legs get stronger. Want to run anyway? Do an easy bonus run — it won’t move your plan ahead.")
                    .foregroundStyle(.secondary)
                Note(title: "Bonus run", text: "\(describe(wk)) · \(minutes(totalSeconds(wk))) min")
                startButton("Bonus easy run") { model.openBonus() }
                secondaryButton("Do \(model.sessionLabel(next)) instead") { model.openSetup(next.id) }
            } else if let next {
                let wk = next.workout
                let total = totalSeconds(wk)
                let runTotal = wk.runSec * wk.repeats
                let intervals = wk.repeats > 1 && wk.walkSec > 0
                Eyebrow("Up next · \(model.sessionLabel(next))")
                Group {
                    if intervals {
                        Text("Run \(dur(wk.runSec))") + Text(" / ").foregroundColor(.secondary) + Text("Walk \(dur(wk.walkSec))")
                    } else {
                        Text("Run \(dur(runTotal))")
                    }
                }
                .font(.title.bold())
                Text("\(intervals ? "\(wk.repeats) rounds · " : "Non-stop · ")\(minutes(total)) min total · \(minutes(runTotal)) min running")
                    .foregroundStyle(.secondary)
                Blocks(wk)
                HStack(spacing: 14) {
                    legend("Run", .run)
                    legend("Walk", .walk)
                }
                if !next.note.isEmpty { Note(title: nil, text: next.note) }
                startButton("Start run") { model.openSetup(next.id) }
                secondaryButton("Custom intervals") { model.openSetup(nil) }
            } else {
                VStack(spacing: 8) {
                    Eyebrow("Plan complete")
                    Text("You did it — 5K!").font(.title.bold())
                    Text("Every session is done. Keep running with custom intervals, or build a new plan.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                startButton("Start a run") { model.openSetup(nil) }
                secondaryButton("Build a new plan") { model.editingPlan = true }
            }
        }
    }

    private func startButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: "play.fill") }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
    }

    private func legend(_ label: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Note: View {
    let title: String?
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title { Text(title).font(.subheadline.weight(.semibold)) }
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Claude's review: in progress, an error, a proposal to apply, or the button to ask for one.
struct CoachCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let st = model.state
        if model.reviewing {
            Card {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Claude is reviewing your runs…").font(.subheadline.weight(.semibold))
                }
            }
        } else if let err = model.reviewError {
            Card {
                head
                Text(err).foregroundStyle(.red).font(.subheadline)
                Button("Try again") { model.runReview() }.buttonStyle(.bordered)
            }
        } else if let r = st.pendingReview {
            Card {
                head
                Text(r.message)
                let all = st.allSessions()
                ForEach(r.changes, id: \.id) { c in
                    if let s = all.first(where: { $0.id == c.id }) {
                        let to = Workout(runSec: c.runSec, walkSec: c.walkSec, repeats: c.repeats)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.sessionLabel(s)).font(.subheadline.weight(.semibold))
                            Text(describe(s.workout)).font(.footnote).strikethrough().foregroundStyle(.secondary)
                            Text(describe(to)).font(.footnote.weight(.semibold)).foregroundStyle(Color.run)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                HStack {
                    if r.changes.isEmpty {
                        Button("Got it") { model.dismissReview() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    } else {
                        Button("Update plan") { model.applyReview() }.buttonStyle(.borderedProminent)
                        Button("Keep plan") { model.dismissReview() }.buttonStyle(.bordered)
                    }
                }
            }
        } else if model.hasKey && !st.history.isEmpty && st.plan != nil {
            Card {
                head
                Text("Ask Claude to look at how your runs went and tune the next few sessions.").foregroundStyle(.secondary)
                Button("Review my runs") { model.runReview() }.buttonStyle(.bordered)
            }
        }
    }

    private var head: some View {
        Label("Coach", systemImage: "sparkles").font(.subheadline.weight(.bold)).foregroundStyle(Color.warm)
    }
}

private struct Stats: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let st = model.state
        let prog = st.progress()
        let longest = st.history.filter(\.completed).reduce(0) { max($0, $1.workout.runSec) }
        let totalMin = minutes(st.history.reduce(0) { $0 + timeOf($1) })
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            tile {
                HStack(spacing: 12) {
                    Ring(pct: prog.total > 0 ? Double(prog.done) / Double(prog.total) : 0, size: 48, stroke: 6)
                    VStack(alignment: .leading) {
                        Text("Plan").font(.caption).foregroundStyle(.secondary)
                        value("\(prog.done)", "/\(prog.total)")
                    }
                }
            }
            tile {
                Text("Longest run").font(.caption).foregroundStyle(.secondary)
                value(longest > 0 ? fmt(longest) : "—", longest > 0 ? " non-stop" : "")
            }
            tile {
                Text("Runs logged").font(.caption).foregroundStyle(.secondary)
                value("\(st.history.count)", "")
            }
            tile {
                Text("Total time").font(.caption).foregroundStyle(.secondary)
                value("\(totalMin)", " min")
            }
        }
    }

    private func tile<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { c() }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func value(_ v: String, _ small: String) -> some View {
        Text(v).font(.title2.weight(.bold)).monospacedDigit() + Text(small).font(.subheadline).foregroundColor(.secondary)
    }
}
