import SwiftUI
import CoachCore

/// The sheet before a run: suggestions, interval steppers, total and finish time.
struct RunSetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let info: SetupInfo
    @State private var wk: Workout
    @State private var confirmMark = false
    @State private var pickDay = false
    @State private var day = Date()
    @State private var checkedOff = false

    private static let LIMITS: [WritableKeyPath<Workout, Int>: ClosedRange<Int>] = [
        \Workout.runSec: 15...3600, \Workout.walkSec: 0...900, \Workout.repeats: 1...30,
    ]

    init(info: SetupInfo) {
        self.info = info
        _wk = State(initialValue: info.wk)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Suggestions") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(info.sugg.enumerated()), id: \.offset) { _, x in
                                let on = x.wk == wk
                                Button { set(x.wk) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(x.label).font(.subheadline.weight(.semibold))
                                        Text(describe(x.wk)).font(.caption).foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .background(on ? Color.run : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                Section {
                    row(\.runSec, Text("Run").foregroundColor(.run).fontWeight(.semibold), fmt(wk.runSec))
                    row(\.walkSec, Text("Walk").foregroundColor(.walk).fontWeight(.semibold), wk.walkSec > 0 ? fmt(wk.walkSec) : "None")
                    row(\.repeats, Text("Repeats"), "× \(wk.repeats)")
                } header: { Text("Intervals") } footer: {
                    Text("Starts and ends with a walk — those are the warm-up and cool-down."
                         + (info.kind == "repeat" || info.kind == "bonus" ? " This run won’t move your plan ahead." : ""))
                }

                Section {
                    let total = totalSeconds(wk)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Total").font(.subheadline).foregroundStyle(.secondary)
                        Text(fmt(total)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("\(dur(wk.runSec * wk.repeats)) running · finishes around \(timeFormatter.string(from: Date().addingTimeInterval(Double(total))))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Blocks(wk).padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button {
                        model.requestStart(RunConfig(wk: wk, session: info.session, kind: info.kind, label: info.title))
                    } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    if info.canMark {
                        Button("Check off without the timer") { if earlier != nil { confirmMark = true } else { pickDay = true } }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 36)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                .background(.bar)
            }
            .confirmationDialog(markMessage, isPresented: $confirmMark, titleVisibility: .visible) {
                Button("Count it") { markDone() }
                Button("Log a different run") { pickDay = true }
            }
            .sheet(isPresented: $pickDay, onDismiss: { if checkedOff { dismiss() } }) {
                NavigationStack {
                    Form {
                        Section {
                            DatePicker("Day you ran", selection: $day, in: ...Date(), displayedComponents: .date)
                                .datePickerStyle(.graphical)
                        } footer: {
                            Text("Counts \(info.session.map(model.sessionLabel) ?? "this run") as done on that day, without distance or a route.")
                        }
                    }
                    .navigationTitle("Check off")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickDay = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Check off") {
                                if let s = info.session { model.checkOff(s, wk, on: day) }
                                checkedOff = true
                                pickDay = false
                            }
                        }
                    }
                }
                .presentationDetents([.large])
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var earlier: HistoryEntry? { info.session.flatMap { model.earlierPartial($0.id) } }

    private var markMessage: String {
        guard let s = info.session else { return "" }
        if let e = earlier {
            return "Count your run from \(shortDate(e.date)) (\(describe(e.workout)), \(fmt(e.doneSec))) as \(model.sessionLabel(s))?"
        }
        return "Check off \(model.sessionLabel(s))?"
    }

    private func markDone() {
        guard let e = earlier else { return }
        model.countEarlier(e.id)
        dismiss()
    }

    private func set(_ w: Workout) {
        wk = w
        model.rememberDraft(info.draftKey, w)
    }

    private func stepFor(_ k: WritableKeyPath<Workout, Int>, _ v: Int, _ d: Int) -> Int {
        if k == \Workout.repeats { return 1 }
        if k == \Workout.walkSec { return 15 }
        let base = d < 0 ? v - 1 : v
        return base < 300 ? 15 : base < 600 ? 30 : 60
    }

    private func step(_ k: WritableKeyPath<Workout, Int>, _ d: Int) {
        let lim = RunSetupView.LIMITS[k] ?? 0...Int.max
        var w = wk
        w[keyPath: k] = max(lim.lowerBound, min(lim.upperBound, w[keyPath: k] + d * stepFor(k, w[keyPath: k], d)))
        set(w)
    }

    private func row(_ k: WritableKeyPath<Workout, Int>, _ label: Text, _ value: String) -> some View {
        let lim = RunSetupView.LIMITS[k] ?? 0...Int.max
        let v = wk[keyPath: k]
        return Stepper(onIncrement: { if v < lim.upperBound { step(k, 1) } },
                       onDecrement: { if v > lim.lowerBound { step(k, -1) } }) {
            HStack {
                label
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
