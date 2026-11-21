import SwiftUI
import UIKit
import CoachCore

/// What a run is: the intervals, and which plan session (if any) it's for.
struct RunConfig: Hashable {
    var wk: Workout
    var session: WeekSession?
    /// "plan" | "custom" | "repeat" | "bonus"
    var kind: String
    var label: String
}

/// A run that just ended, waiting for Save / Don't save.
struct FinishedRun {
    var config: RunConfig
    var startedAt: Date
    var end: Int
    var doneSec: Double
    var gps: GpsSummary?
    var mainDone: Bool
    var completedDefault: Bool
}

/// Opens the run setup sheet. `extra` is for runs that don't advance the plan.
struct SetupRequest: Identifiable {
    struct Extra { var kind: String; var wk: Workout; var label: String }
    let id = UUID()
    var sessionId: String?
    var extra: Extra?
}

/// Everything the run setup sheet needs, worked out when it opens.
struct SetupInfo {
    var title: String
    var session: WeekSession?
    var draftKey: String
    var kind: String
    var sugg: [Suggestion]
    var wk: Workout
    var canMark: Bool
}

/// The app's state and the actions on it. Saved to a JSON file on every change; the
/// Claude API key lives in the Keychain instead.
@MainActor
final class AppModel: ObservableObject {
    enum Tab: Hashable { case today, plan, history, settings }

    @Published var state: AppState {
        didSet { if state != oldValue { persist(old: oldValue) } }
    }
    @Published var tab: Tab = .today
    @Published var editingPlan = false
    @Published var setup: SetupRequest?
    @Published var run: RunEngine?
    @Published var reviewing = false
    @Published var reviewError: String?
    @Published var toast: String?

    private var pendingRun: RunConfig?
    private var toastTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "state-save")

    init() {
        state = AppModel.load()
    }

    // MARK: Persistence

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("state.json")
    }

    private static func load() -> AppState {
        var s = AppState()
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            s = decoded
        }
        s.settings.apiKey = Keychain.read()
        return s
    }

    private func persist(old: AppState) {
        var copy = state
        copy.settings.apiKey = ""
        if let data = try? JSONEncoder().encode(copy) {
            let url = AppModel.fileURL
            saveQueue.async {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        if old.settings.apiKey != state.settings.apiKey { Keychain.write(state.settings.apiKey) }
    }

    // MARK: Small helpers

    var hasKey: Bool { !state.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func showToast(_ msg: String) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { toast = msg }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    /// "Week 2 · Run 1 of 3" or "Week 8 · 5K run"
    func sessionLabel(_ s: WeekSession) -> String {
        let per = state.plan?.weeks.first { $0.week == s.week }?.sessions.count ?? 0
        let n = s.id.split(separator: "s").last.map(String.init) ?? ""
        return "Week \(s.week) · \(s.title == "5K run" ? "5K run" : "Run \(n) of \(per)")"
    }

    func session(_ id: String?) -> WeekSession? {
        guard let id, !id.isEmpty else { return nil }
        return state.allSessions().first { $0.id == id }
    }

    static let comebackDays = 7

    /// Whole calendar days since the most recent run, or nil with no runs.
    func daysSinceLastRun() -> Int? {
        let dates = state.history.compactMap(\.dateValue)
        guard let last = dates.max() else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: last), to: cal.startOfDay(for: Date())).day
    }

    /// Runs logged since Sunday (US calendar week), of any kind.
    func runsThisWeek() -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        guard let sunday = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        return state.history.filter { ($0.dateValue ?? .distantPast) >= sunday }.count
    }

    func lastDonePlanSession() -> WeekSession? {
        state.allSessions().filter { state.isDone($0.id) }.last
    }

    /// A bonus run repeats the most recent completed plan run (it's already been earned).
    func bonusWorkout() -> Workout {
        lastDonePlanSession()?.workout ?? state.lastWorkout ?? DEFAULT_WORKOUT
    }

    // MARK: Plan

    func defaultDraft() -> Profile {
        state.profile ?? Profile(weeks: 8, perWeek: 3, level: "new", paceMi: 11.25, startDate: todayISO(), notes: "")
    }

    func savePlan(_ plan: Plan, profile: Profile) {
        var s = state
        s.profile = profile
        s.plan = plan
        s.pendingReview = nil
        state = s
        editingPlan = false
        tab = .today
        showToast(plan.source == "claude" ? "Claude built your plan" : "Plan ready")
    }

    func buildWithClaude(_ profile: Profile) async throws -> Plan {
        let bg = BackgroundTask()
        defer { bg.end() }
        return try await coach().buildPlan(profile)
    }

    private func coach() -> Coach {
        Coach(apiKey: state.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), model: state.settings.model)
    }

    // MARK: Coach review

    func runReview() {
        guard !reviewing, hasKey, state.profile != nil else { return }
        reviewing = true
        reviewError = nil
        let snapshot = state
        let c = coach()
        Task {
            let bg = BackgroundTask()
            defer { bg.end() }
            do {
                let r = try await c.reviewRuns(snapshot)
                state.pendingReview = r
            } catch {
                reviewError = error.localizedDescription
            }
            reviewing = false
        }
    }

    func applyReview() {
        guard let r = state.pendingReview, var plan = state.plan else { return }
        for w in plan.weeks.indices {
            for j in plan.weeks[w].sessions.indices {
                if let c = r.changes.first(where: { $0.id == plan.weeks[w].sessions[j].id }) {
                    plan.weeks[w].sessions[j].runSec = c.runSec
                    plan.weeks[w].sessions[j].walkSec = c.walkSec
                    plan.weeks[w].sessions[j].repeats = c.repeats
                    plan.weeks[w].sessions[j].note = c.note
                }
            }
        }
        var s = state
        s.plan = plan
        s.pendingReview = nil
        state = s
        showToast("Plan updated")
    }

    func dismissReview() { state.pendingReview = nil }

    func testKey() async throws {
        try await coach().testKey()
    }

    // MARK: Run setup

    private struct SetupDraft: Codable { var key: String; var wk: Workout; var at: Double }
    private static let draftDefaultsKey = "setupDraft"

    /// Interval edits are remembered per session for a day, so closing the sheet or an
    /// interrupted run doesn't reset them to the plan.
    private func savedDraft(_ key: String) -> Workout? {
        guard let data = UserDefaults.standard.data(forKey: AppModel.draftDefaultsKey),
              let d = try? JSONDecoder().decode(SetupDraft.self, from: data),
              d.key == key, Date().timeIntervalSince1970 - d.at < 86_400 else { return nil }
        return d.wk
    }

    func rememberDraft(_ key: String, _ wk: Workout) {
        let d = SetupDraft(key: key, wk: wk, at: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: AppModel.draftDefaultsKey) }
    }

    func openSetup(_ sessionId: String? = nil) { setup = SetupRequest(sessionId: sessionId) }

    func openRepeat(_ s: WeekSession) {
        setup = SetupRequest(extra: .init(kind: "repeat", wk: s.workout, label: "\(sessionLabel(s)) (repeat)"))
    }

    func openBonus() {
        setup = SetupRequest(extra: .init(kind: "bonus", wk: bonusWorkout(), label: "Bonus run"))
    }

    func setupInfo(_ req: SetupRequest) -> SetupInfo {
        let session = req.extra == nil ? self.session(req.sessionId) : nil
        let planned = session ?? state.nextSession()
        let draftKey = req.extra.map { "\($0.kind):\($0.label)" } ?? session?.id ?? "custom"
        let wk = savedDraft(draftKey)
            ?? req.extra?.wk
            ?? session?.workout
            ?? state.lastWorkout
            ?? planned?.workout
            ?? DEFAULT_WORKOUT
        let sugg: [Suggestion]
        if let x = req.extra {
            sugg = [Suggestion(label: x.kind == "repeat" ? "Repeat" : "Bonus", wk: x.wk)]
                + suggestions(Optional<Workout>.none, state.lastWorkout)
        } else {
            sugg = suggestions(planned?.workout, state.lastWorkout)
        }
        return SetupInfo(
            title: req.extra?.label ?? session.map(sessionLabel) ?? "Custom run",
            session: session,
            draftKey: draftKey,
            kind: req.extra?.kind ?? (session != nil ? "plan" : "custom"),
            sugg: sugg,
            wk: wk,
            canMark: session.map { !state.isDone($0.id) } ?? false
        )
    }

    /// Called by the setup sheet's Start button; the run screen opens once the sheet is gone.
    func requestStart(_ config: RunConfig) {
        pendingRun = config
        setup = nil
    }

    func launchPendingRun() {
        guard let config = pendingRun else { return }
        pendingRun = nil
        let s = state.settings
        run = RunEngine(config: config, options: CueOptions(beeps: s.beeps, halfway: s.halfway), gps: s.gps)
    }

    /// An earlier unfinished try at this session, which "check off" can count instead.
    func earlierPartial(_ sessionId: String) -> HistoryEntry? {
        state.history.last { $0.sessionId == sessionId && !$0.completed }
    }

    func countEarlier(_ historyId: String) {
        guard let i = state.history.firstIndex(where: { $0.id == historyId }) else { return }
        state.history[i].completed = true
        showToast("Checked off ✓")
    }

    /// Lets a run done without the app (treadmill, forgot phone…) still count toward the week.
    func checkOff(_ s: WeekSession, _ wk: Workout) {
        let total = totalSeconds(wk)
        state.history.append(HistoryEntry(
            id: UUID().uuidString, date: isoString(Date()), sessionId: s.id, sessionLabel: sessionLabel(s), kind: "plan",
            workout: wk, totalSec: total, doneSec: total, completed: true, notes: "Checked off without the timer", manual: true))
        showToast("Checked off ✓")
    }

    // MARK: Finishing a run

    func saveRun(_ r: FinishedRun, feel: String?, notes: String, completed: Bool) {
        let entry = HistoryEntry(
            id: UUID().uuidString,
            date: isoString(r.startedAt),
            sessionId: r.config.session?.id,
            sessionLabel: r.config.kind == "custom" ? nil : r.config.label,
            kind: r.config.kind,
            workout: r.config.wk,
            totalSec: r.end,
            doneSec: jsRoundInt(r.doneSec),
            completed: r.config.session != nil ? completed : r.doneSec >= Double(r.end) - 3,
            feel: feel,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            distM: r.gps?.distM, gpsSec: r.gps?.gpsSec, track: r.gps?.track)
        var s = state
        s.history.append(entry)
        s.lastWorkout = r.config.wk
        state = s
        run = nil
        tab = .today
        showToast("Run saved")
        if hasKey && state.settings.autoReview && state.nextSession() != nil { runReview() }
    }

    func discardRun() { run = nil }

    // MARK: History edits

    func updateHistory(_ id: String, _ change: (inout HistoryEntry) -> Void) {
        guard let i = state.history.firstIndex(where: { $0.id == id }) else { return }
        var h = state.history[i]
        change(&h)
        state.history[i] = h
    }

    /// Assigns a run to a plan session (it then counts toward the plan), or to none.
    func assign(_ id: String, to sessionId: String?) {
        if let s = session(sessionId) {
            updateHistory(id) { h in
                h.sessionId = s.id; h.sessionLabel = self.sessionLabel(s); h.kind = "plan"; h.completed = true
            }
            showToast("Counted as \(sessionLabel(s))")
        } else {
            updateHistory(id) { h in
                h.sessionId = nil; h.sessionLabel = nil; h.kind = "custom"; h.completed = h.doneSec >= h.totalSec - 3
            }
            showToast("Removed from plan")
        }
    }

    func deleteRun(_ id: String) { state.history.removeAll { $0.id == id } }

    // MARK: Data

    /// Brings in the web app's Settings → Export file. Keeps this phone's API key when the
    /// file has none (the export never includes it).
    func importWebData(_ data: Data) throws {
        var s = try AppState.importPWA(data)
        if s.settings.apiKey.isEmpty { s.settings.apiKey = state.settings.apiKey }
        state = s
        editingPlan = false
        tab = .today
        showToast("Imported \(s.history.count) run\(s.history.count == 1 ? "" : "s")")
    }

    func resetAll() {
        state.reset()
        editingPlan = false
        tab = .today
    }
}

/// Asks iOS for a little time to finish a Claude request if the phone gets locked.
@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "coach") { [weak self] in self?.end() }
    }
    func end() {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
    }
}

// MARK: - Formatting

private let usLocale = Locale(identifier: "en_US")

func formatter(_ template: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = usLocale
    f.setLocalizedDateFormatFromTemplate(template)
    return f
}

let shortDateFormatter = formatter("EEEMMMd")
let longDateFormatter = formatter("EEEEMMMMd")
let timeFormatter = formatter("jmm")

/// "Sat, Nov 21"
func shortDate(_ iso: String) -> String {
    parseISODate(iso).map { shortDateFormatter.string(from: $0) } ?? ""
}

/// Today as "YYYY-MM-DD" in local time.
func todayISO() -> String { localDay(Date()) }

func localDay(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func dayFromISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let p = s.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
}

func minutes(_ sec: Int) -> Int { jsRoundInt(Double(sec) / 60) }

func paceFmt(_ p: Double?) -> String { p.map { "\(fmt($0)) /mi" } ?? "—" }

func runPace(_ h: HistoryEntry) -> Double? {
    let sec = (h.gpsSec ?? 0) != 0 ? (h.gpsSec ?? 0) : h.doneSec
    return paceSec(h.distM.map { Double($0) }, Double(sec))
}

/// " · 1.42 mi" for runs that recorded distance; runs without GPS show nothing.
func distBit(_ h: HistoryEntry) -> String {
    if let d = h.distM, d > 0 { return " · \(miText(Double(d))) mi" }
    return ""
}

func distOf(_ list: [HistoryEntry]) -> Int { list.reduce(0) { $0 + ($1.distM ?? 0) } }

let FEELS: [(id: String, label: String)] = [("easy", "Easy"), ("right", "Just right"), ("hard", "Hard"), ("stopped", "Had to stop")]

func feelLabel(_ id: String?) -> String? { FEELS.first { $0.id == id }?.label }
