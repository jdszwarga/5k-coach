import Foundation

// Port of js/store.js: the saved state and its plan helpers, plus an importer for the
// web app's Settings → Export file (`exportJSON()`).
//
// Decoding is tolerant on purpose: exports from older web app versions have missing fields,
// numbers where strings are expected (or the reverse) and extra fields. Missing values get
// the web app's defaults; unknown fields are dropped; one bad history entry is skipped
// rather than failing the whole import.

// MARK: - Model

public struct Workout: Codable, Hashable, Sendable {
    public var runSec: Int
    public var walkSec: Int
    public var repeats: Int
    public init(runSec: Int, walkSec: Int = 0, repeats: Int = 1) {
        self.runSec = runSec; self.walkSec = walkSec; self.repeats = repeats
    }
    enum CodingKeys: String, CodingKey { case runSec, walkSec, repeats }
    /// `normWorkout`: walkSec defaults to 0 and repeats to 1; extra fields are dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runSec = c.flexInt(.runSec) ?? 0
        walkSec = c.flexInt(.walkSec) ?? 0
        repeats = c.flexInt(.repeats) ?? 1
    }
}

public struct PlanSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var runSec: Int
    public var walkSec: Int
    public var repeats: Int
    public var note: String
    public init(id: String, title: String, runSec: Int, walkSec: Int, repeats: Int, note: String) {
        self.id = id; self.title = title; self.runSec = runSec; self.walkSec = walkSec; self.repeats = repeats; self.note = note
    }
    public var workout: Workout { Workout(runSec: runSec, walkSec: walkSec, repeats: repeats) }

    enum CodingKeys: String, CodingKey { case id, title, runSec, walkSec, repeats, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? ""
        title = c.flexString(.title) ?? "Run"
        runSec = c.flexInt(.runSec) ?? 0
        walkSec = c.flexInt(.walkSec) ?? 0
        repeats = c.flexInt(.repeats) ?? 1
        note = c.flexString(.note) ?? ""
    }
}

public struct PlanWeek: Codable, Hashable, Sendable {
    public var week: Int
    public var focus: String
    public var sessions: [PlanSession]
    public init(week: Int, focus: String, sessions: [PlanSession]) {
        self.week = week; self.focus = focus; self.sessions = sessions
    }
    enum CodingKeys: String, CodingKey { case week, focus, sessions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = c.flexInt(.week) ?? 0
        focus = c.flexString(.focus) ?? ""
        sessions = c.lenientArray(.sessions) ?? []
    }
}

public struct Plan: Codable, Hashable, Sendable {
    /// ISO date string.
    public var createdAt: String
    /// "builtin" or "claude"
    public var source: String
    public var summary: String
    public var weeks: [PlanWeek]
    public init(createdAt: String, source: String, summary: String, weeks: [PlanWeek]) {
        self.createdAt = createdAt; self.source = source; self.summary = summary; self.weeks = weeks
    }
    enum CodingKeys: String, CodingKey { case createdAt, source, summary, weeks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = c.flexString(.createdAt) ?? ""
        source = c.flexString(.source) ?? "builtin"
        summary = c.flexString(.summary) ?? ""
        weeks = c.lenientArray(.weeks) ?? []
    }
}

public struct Profile: Codable, Hashable, Sendable {
    public var weeks: Int
    public var perWeek: Int
    /// A `LEVELS` id.
    public var level: String
    /// Easy pace, minutes per mile.
    public var paceMi: Double
    /// "YYYY-MM-DD"
    public var startDate: String?
    public var notes: String?
    public init(weeks: Int, perWeek: Int, level: String = "new", paceMi: Double = 11.25, startDate: String? = nil, notes: String? = nil) {
        self.weeks = weeks; self.perWeek = perWeek; self.level = level; self.paceMi = paceMi
        self.startDate = startDate; self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case weeks, perWeek, level, paceMi, startDate, notes, days, pace }
    /// Includes store.js's migration of older profiles: run days -> runs per week, min/km -> min/mile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weeks = c.flexInt(.weeks) ?? 8
        var pw = c.flexInt(.perWeek)
        if pw == nil || pw == 0, let days = try? c.nestedUnkeyedContainer(forKey: .days) {
            pw = days.count ?? 0
        }
        perWeek = pw ?? 3
        level = c.flexString(.level) ?? "new"
        if let p = c.flexDouble(.paceMi) {
            paceMi = p
        } else if let kmPace = c.flexDouble(.pace) {
            paceMi = jsRound(kmPace * 1.609 * 4) / 4
        } else {
            paceMi = 11.25
        }
        startDate = c.flexString(.startDate)
        notes = c.flexString(.notes)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weeks, forKey: .weeks)
        try c.encode(perWeek, forKey: .perWeek)
        try c.encode(level, forKey: .level)
        try c.encode(paceMi, forKey: .paceMi)
        try c.encodeIfPresent(startDate, forKey: .startDate)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

public struct Settings: Codable, Hashable, Sendable {
    public var apiKey = ""
    public var model = "claude-opus-5-5"
    /// Web app only: 'mix' | 'locked'. Kept so an import round-trips; the native app has one mode.
    public var audioMode = "mix"
    public var beeps = true
    public var halfway = true
    public var autoReview = true
    /// Record distance/pace/route during runs.
    public var gps = true
    /// Native app: keep recording GPS after the workout ends, until Finish (or standing still).
    public var keepTracking = true
    public init() {}

    enum CodingKeys: String, CodingKey { case apiKey, model, audioMode, beeps, halfway, autoReview, gps, keepTracking }
    /// `{ ...DEFAULTS.settings, ...parsed.settings }`
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        apiKey = c.flexString(.apiKey) ?? d.apiKey
        model = c.flexString(.model) ?? d.model
        audioMode = c.flexString(.audioMode) ?? d.audioMode
        beeps = c.flexBool(.beeps) ?? d.beeps
        halfway = c.flexBool(.halfway) ?? d.halfway
        autoReview = c.flexBool(.autoReview) ?? d.autoReview
        gps = c.flexBool(.gps) ?? d.gps
        keepTracking = c.flexBool(.keepTracking) ?? d.keepTracking
    }
}

/// One session change proposed by the Claude review.
public struct PlanChange: Codable, Hashable, Sendable {
    public var id: String
    public var runSec: Int
    public var walkSec: Int
    public var repeats: Int
    public var note: String
    public init(id: String, runSec: Int, walkSec: Int, repeats: Int, note: String) {
        self.id = id; self.runSec = runSec; self.walkSec = walkSec; self.repeats = repeats; self.note = note
    }
    enum CodingKeys: String, CodingKey { case id, runSec, walkSec, repeats, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? ""
        runSec = c.flexInt(.runSec) ?? 0
        walkSec = c.flexInt(.walkSec) ?? 0
        repeats = c.flexInt(.repeats) ?? 1
        note = c.flexString(.note) ?? ""
    }
}

/// The last Claude review waiting for Apply / Keep.
public struct PendingReview: Codable, Hashable, Sendable {
    public var message: String
    public var changes: [PlanChange]
    public var at: String?
    public init(message: String, changes: [PlanChange], at: String? = nil) {
        self.message = message; self.changes = changes; self.at = at
    }
    enum CodingKeys: String, CodingKey { case message, changes, at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = c.flexString(.message) ?? ""
        changes = c.lenientArray(.changes) ?? []
        at = c.flexString(.at)
    }
}

/// A logged run.
public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// ISO date string of the start.
    public var date: String
    public var sessionId: String?
    public var sessionLabel: String?
    /// "plan" | "custom" | "repeat" | "bonus" (older runs have none)
    public var kind: String?
    public var workout: Workout
    public var totalSec: Int
    public var doneSec: Int
    public var completed: Bool
    /// "easy" | "right" | "hard"
    public var feel: String?
    public var notes: String
    /// Checked off without the timer.
    public var manual: Bool?
    // GPS fields: only on runs that recorded a track.
    public var distM: Int?
    public var gpsSec: Int?
    public var track: Track?
    /// Native app: seconds tracked after the workout ended ("keep tracking").
    public var extraSec: Int?

    public init(id: String, date: String, sessionId: String? = nil, sessionLabel: String? = nil, kind: String? = nil,
                workout: Workout, totalSec: Int, doneSec: Int, completed: Bool, feel: String? = nil, notes: String = "",
                manual: Bool? = nil, distM: Int? = nil, gpsSec: Int? = nil, track: Track? = nil, extraSec: Int? = nil) {
        self.id = id; self.date = date; self.sessionId = sessionId; self.sessionLabel = sessionLabel; self.kind = kind
        self.workout = workout; self.totalSec = totalSec; self.doneSec = doneSec; self.completed = completed
        self.feel = feel; self.notes = notes; self.manual = manual
        self.distM = distM; self.gpsSec = gpsSec; self.track = track; self.extraSec = extraSec
    }

    public var dateValue: Date? { parseISODate(date) }

    enum CodingKeys: String, CodingKey {
        case id, date, sessionId, sessionLabel, kind, workout, totalSec, doneSec, completed, feel, notes, manual, distM, gpsSec, track, extraSec
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        date = c.flexString(.date) ?? ""
        sessionId = c.flexString(.sessionId)
        sessionLabel = c.flexString(.sessionLabel)
        kind = c.flexString(.kind)
        let wk = (try? c.decodeIfPresent(Workout.self, forKey: .workout)) ?? Workout(runSec: 0)
        workout = wk
        totalSec = c.flexInt(.totalSec) ?? totalSeconds(wk)
        doneSec = c.flexInt(.doneSec) ?? 0
        completed = c.flexBool(.completed) ?? false
        feel = c.flexString(.feel)
        notes = c.flexString(.notes) ?? ""
        manual = c.flexBool(.manual)
        distM = c.flexInt(.distM)
        gpsSec = c.flexInt(.gpsSec)
        track = try? c.decodeIfPresent(Track.self, forKey: .track)
        extraSec = c.flexInt(.extraSec)
    }
}

/// A plan session together with its week number (`{ ...s, week }` in the JS).
@dynamicMemberLookup
public struct WeekSession: Hashable, Sendable, Identifiable {
    public var session: PlanSession
    public var week: Int
    public var id: String { session.id }
    public subscript<T>(dynamicMember kp: KeyPath<PlanSession, T>) -> T { session[keyPath: kp] }
}

public struct PlanProgress: Hashable, Sendable {
    public var done: Int
    public var total: Int
}

/// Everything the app saves.
public struct AppState: Codable, Hashable, Sendable {
    public var settings = Settings()
    public var pendingReview: PendingReview?
    public var profile: Profile?
    public var plan: Plan?
    public var history: [HistoryEntry] = []
    public var lastWorkout: Workout?
    public init() {}

    enum CodingKeys: String, CodingKey { case settings, pendingReview, profile, plan, history, lastWorkout }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
        pendingReview = try? c.decodeIfPresent(PendingReview.self, forKey: .pendingReview)
        profile = try? c.decodeIfPresent(Profile.self, forKey: .profile)
        plan = try? c.decodeIfPresent(Plan.self, forKey: .plan)
        history = c.lenientArray(.history) ?? []
        lastWorkout = try? c.decodeIfPresent(Workout.self, forKey: .lastWorkout)
    }

    // MARK: Plan helpers

    public func allSessions() -> [WeekSession] { CoachCore.allSessions(plan) }

    public func isDone(_ sessionId: String) -> Bool {
        history.contains { $0.sessionId == sessionId && $0.completed }
    }

    public func nextSession() -> WeekSession? {
        allSessions().first { !isDone($0.id) }
    }

    public func progress() -> PlanProgress {
        let all = allSessions()
        return PlanProgress(done: all.filter { isDone($0.id) }.count, total: all.count)
    }

    // MARK: Import / export

    public enum ImportError: Error, Equatable {
        /// The file isn't JSON, or isn't a 5K Coach export.
        case notAnExport
    }

    /// Reads the web app's Settings → Export file. The export replaces the API key with
    /// "(removed)", which comes back as no key.
    public static func importPWA(_ data: Data) throws -> AppState {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              !Set(dict.keys).isDisjoint(with: ["settings", "profile", "plan", "history", "lastWorkout", "pendingReview"])
        else { throw ImportError.notAnExport }
        var s = try JSONDecoder().decode(AppState.self, from: data)
        if s.settings.apiKey == "(removed)" { s.settings.apiKey = "" }
        return s
    }

    /// Same shape as the web app's `exportJSON()` (API key replaced by "(removed)").
    public func exportJSON() throws -> Data {
        var copy = self
        copy.settings.apiKey = copy.settings.apiKey.isEmpty ? "" : "(removed)"
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(copy)
    }

    /// Wipes plan, history and preferences, but keeps the coach setup (API key + model).
    public mutating func reset() {
        let apiKey = settings.apiKey, model = settings.model
        self = AppState()
        settings.apiKey = apiKey
        settings.model = model
    }
}

public func allSessions(_ plan: Plan?) -> [WeekSession] {
    guard let plan else { return [] }
    return plan.weeks.flatMap { w in w.sessions.map { WeekSession(session: $0, week: w.week) } }
}

public func isDone(_ sessionId: String, history: [HistoryEntry]) -> Bool {
    history.contains { $0.sessionId == sessionId && $0.completed }
}

// MARK: - Tolerant decoding

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func flexDouble(_ k: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: k),
           let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        return nil
    }

    func flexInt(_ k: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i }
        if let d = flexDouble(k), d.isFinite, abs(d) < 1e15 { return jsRoundInt(d) }
        return nil
    }

    func flexString(_ k: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return String(d) }
        return nil
    }

    func flexBool(_ k: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: k) { return b }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return d != 0 }
        return nil
    }

    /// An array where entries that don't decode are skipped.
    func lenientArray<T: Decodable>(_ k: Key) -> [T]? {
        guard let arr = try? decodeIfPresent([Lenient<T>].self, forKey: k) else { return nil }
        return arr.compactMap(\.value)
    }
}
