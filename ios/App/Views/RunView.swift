import SwiftUI
import CoachCore

/// The full-screen run: getting the cues ready, the run itself, then the post-run summary.
struct RunFlowView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: RunEngine

    var body: some View {
        Group {
            if let r = engine.result {
                FinishView(result: r)
            } else if engine.ready {
                RunView(engine: engine)
            } else if let err = engine.loadError {
                VStack(spacing: 16) {
                    Image(systemName: "speaker.slash").font(.largeTitle)
                    Text(err).multilineTextAlignment(.center)
                    Button("Close") { engine.abandon(); model.discardRun(nil) }.buttonStyle(.borderedProminent)
                }
                .padding(32)
            } else {
                ProgressView("Getting your cues ready…")
            }
        }
        .task { await engine.prepare() }
    }
}

private let PHASE_NAMES: [SegmentType: String] = [.run: "RUN", .walk: "WALK"]

struct RunView: View {
    @ObservedObject var engine: RunEngine
    @State private var confirmEnd = false
    @State private var wasPlaying = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let t = engine.currentTime
            let segs = engine.segs
            let end = Double(engine.end)
            let i = segs.firstIndex { t < Double($0.end) } ?? max(0, segs.count - 1)
            let seg: Segment? = t >= end || segs.isEmpty ? nil : segs[i]
            let color = seg.map { $0.type == .run ? Color.run : Color.walk } ?? Color.warm
            let remSeg = seg.map { Double($0.end) - t } ?? 0
            let frac = seg.map { (t - Double($0.start)) / Double(max(1, $0.dur)) } ?? 1
            let nx: Segment? = seg != nil && i + 1 < segs.count ? segs[i + 1] : nil
            let ot = engine.overtime
            let extra = engine.extraTime

            VStack(spacing: 0) {
                HStack {
                    Spacer().frame(width: 44)
                    Spacer()
                    Text(engine.config.label).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Spacer()
                    Button { askEnd() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .accessibilityLabel("End run")
                }
                .padding(.horizontal, 16)

                VStack(spacing: 4) {
                    Text(ot ? "EXTRA" : seg.flatMap { PHASE_NAMES[$0.type] } ?? "DONE")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                    Text(ot ? "Workout done — keep going!" : repText(seg)).font(.headline).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 24)

                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 14)
                    Circle().trim(from: 0, to: max(0, min(1, frac)))
                        .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 6) {
                        Text(ot ? "+\(fmt(extra))" : fmt(ceil(remSeg - 0.05)))
                            .font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(ot ? "Tap Finish when you’re done" : nextText(seg, nx)).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 270, height: 270)
                .padding(.vertical, 28)

                Blocks(segs: segs, height: 12, done: end > 0 ? t / end : 0)
                    .padding(.horizontal, 24)

                HStack {
                    stat("Elapsed", fmt(t))
                    if let g = engine.gps {
                        stat("Miles", g.distM > 0 || g.status == .ok || g.status == .searching ? miText(g.distM) : "—")
                    }
                    if ot { stat("Extra", fmt(extra)) } else { stat("Remaining", fmt(end - t)) }
                }
                .padding(.top, 20)
                .padding(.horizontal, 16)

                if let g = engine.gps {
                    Text(gpsLine(g)).font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
                }

                Spacer()

                if ot {
                    // Keep tracking: Finish is the big button, pause the small one.
                    HStack(spacing: 40) {
                        Button { engine.toggle() } label: {
                            Image(systemName: engine.paused ? "play.fill" : "pause.fill").font(.title2).frame(width: 64, height: 64)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        .accessibilityLabel(engine.paused ? "Resume" : "Pause")
                        Button { engine.finish(reachedEnd: true) } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "flag.checkered").font(.system(size: 30, weight: .semibold))
                                Text("Finish").font(.caption.weight(.bold))
                            }
                            .frame(width: 88, height: 88)
                            .foregroundStyle(.black)
                            .background(color, in: Circle())
                        }
                        Spacer().frame(width: 64, height: 64)
                    }
                } else {
                    HStack(spacing: 40) {
                        Button { askEnd() } label: {
                            Image(systemName: "stop.fill").font(.title2).frame(width: 64, height: 64)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        .accessibilityLabel("End run")
                        Button { engine.toggle() } label: {
                            Image(systemName: engine.paused ? "play.fill" : "pause.fill").font(.system(size: 34)).frame(width: 88, height: 88)
                                .foregroundStyle(.black)
                                .background(color, in: Circle())
                        }
                        .accessibilityLabel(engine.paused ? "Resume" : "Pause")
                        Spacer().frame(width: 64, height: 64)
                    }
                }

                Text(ot ? "Tracking your extra distance. It stops by itself after 5 minutes standing still."
                     : engine.keepTracking ? "Lock your iPhone anytime. When the workout ends, GPS keeps tracking until you tap Finish."
                     : "Lock your iPhone anytime — cues and GPS keep going.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .font(.footnote).foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 14).padding(.bottom, 8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: [color.opacity(0.35), .black], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            )
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("End this run?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End run", role: .destructive) { engine.finish(reachedEnd: false) }
            Button("Keep going", role: .cancel) { if wasPlaying { engine.resume() } }
        }
    }

    private func askEnd() {
        if engine.overtime { engine.finish(reachedEnd: true); return }
        wasPlaying = !engine.paused
        engine.pause()
        confirmEnd = true
    }

    private func repText(_ seg: Segment?) -> String {
        guard let seg else { return "" }
        if seg.edge == .start { return "Warm-up" }
        if seg.edge == .end { return "Cool-down" }
        if let of = seg.of, of > 1, let rep = seg.rep { return "\(rep) of \(of)" }
        return ""
    }

    private func nextText(_ seg: Segment?, _ nx: Segment?) -> String {
        if let nx { return "Next: \(nx.type == .run ? "Run" : "Walk") \(fmt(nx.dur))" }
        return seg != nil ? "Last stretch" : "Great job!"
    }

    private func gpsLine(_ g: GpsTracker) -> String {
        switch g.status {
        case .denied: return "Location access is off — no distance this run"
        case .unavailable: return "GPS isn’t available — no distance this run"
        case .ok: return "Pace \(paceFmt(g.currentPace())) · Avg \(paceFmt(g.avgPace()))"
        default: return "Finding GPS…"
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(k.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
            Text(v).font(.title2.weight(.bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

/// After the run: how it felt, notes, whether it counts, then Save / Don't save.
struct FinishView: View {
    @EnvironmentObject var model: AppModel
    let result: FinishedRun
    @State private var feel: String?
    @State private var notes = ""
    @State private var completed: Bool
    @State private var confirmDiscard = false

    init(result: FinishedRun) {
        self.result = result
        _completed = State(initialValue: result.completedDefault)
    }

    var body: some View {
        let r = result
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Ring(pct: r.end > 0 ? r.doneSec / Double(r.end) : 0, size: 96, stroke: 10)
                        Text(fmt(r.doneSec)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        if r.extraSec >= 1 {
                            Text("+\(fmt(r.extraSec)) extra after the workout").font(.subheadline.weight(.semibold)).foregroundStyle(Color.warm)
                        }
                        Text(describe(r.config.wk) + (r.config.kind != "custom" ? " · \(r.config.label)" : ""))
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } footer: {
                    Label("Saved to History", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                if let g = r.gps {
                    Section {
                        GpsBlock(distM: g.distM, pace: paceSec(Double(g.distM), Double(g.gpsSec != 0 ? g.gpsSec : jsRoundInt(r.doneSec + r.extraSec))),
                                 track: g.track)
                            .padding(.vertical, 4)
                    }
                }
                Section("How did it feel?") {
                    Picker("How did it feel?", selection: Binding(get: { feel ?? "" }, set: { feel = $0.isEmpty ? nil : $0 })) {
                        ForEach(FEELS, id: \.id) { f in Text(f.label).tag(f.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if r.config.session != nil {
                    Section {
                        Toggle("Count session as done", isOn: $completed)
                    } footer: {
                        Text("On moves you to the next session; off repeats this one. You can change it later in History.")
                    }
                }
                Section("Notes") {
                    TextField("Optional — e.g. calves tight, felt strong on the last run", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(r.mainDone ? "Nice work!" : "Run ended")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button("Save") { model.saveRun(r, feel: feel, notes: notes, completed: completed) }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Don’t save") { confirmDiscard = true }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        .frame(minHeight: 36)
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                .background(.bar)
            }
            .confirmationDialog("Discard this run?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.discardRun(r) }
            }
        }
    }
}
