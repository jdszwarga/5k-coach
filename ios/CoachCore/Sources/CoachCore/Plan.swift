import Foundation

// Port of js/plan.js: built-in 5K plan generator and workout helpers.
// Each session is a run/walk interval workout that ends with one continuous 5K run.

public struct Level: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let detail: String
    /// Length of the first run block (s).
    public let s0: Double
    /// Total running in the first session (s).
    public let R0: Double
    /// Walk:run ratio at the start.
    public let ratio0: Double
}

/// The experience levels, in display order.
public let LEVELS: [Level] = [
    Level(id: "new", label: "New to running", detail: "Running for a minute is hard", s0: 90, R0: 12 * 60, ratio0: 1.0),
    Level(id: "some", label: "A little running", detail: "I can run 1–5 minutes", s0: 120, R0: 12 * 60, ratio0: 1.0),
    Level(id: "regular", label: "Some base", detail: "I can run 5–15 minutes", s0: 300, R0: 16 * 60, ratio0: 0.6),
    Level(id: "strong", label: "Comfortable runner", detail: "I can run 15+ minutes", s0: 600, R0: 20 * 60, ratio0: 0.3),
]

/// `LEVELS[level] || LEVELS.new`
public func levelFor(_ id: String?) -> Level {
    LEVELS.first { $0.id == id } ?? LEVELS[0]
}

public let MILES_5K = 3.1

private func roundTo(_ v: Double, _ step: Double) -> Double { jsRound(v / step) * step }

private func roundRun(_ s: Double) -> Double {
    if s < 120 { return roundTo(s, 15) }
    if s < 600 { return roundTo(s, 30) }
    return roundTo(s, 60)
}

/// Seconds to run 5K (3.1 miles) at an easy pace (`paceMi` = minutes per mile), 20–55 min.
public func goalSeconds(_ paceMi: Double = 11.25) -> Int {
    clamp(jsRoundInt(3.107 * paceMi) * 60, 20 * 60, 55 * 60)
}

/// Minutes-per-mile as "m:ss" (11.25 -> "11:15").
public func paceText(_ p: Double) -> String {
    "\(Int(p.rounded(.down))):\(pad2(jsRoundInt(p.truncatingRemainder(dividingBy: 1) * 60)))"
}

/// Every workout: walk, then (run, walk) × repeats. The first and last walks double as
/// the warm-up and cool-down.
public func generatePlan(_ profile: Profile, now: Date = Date()) -> Plan {
    let weeks = profile.weeks, perWeek = profile.perWeek
    let L = levelFor(profile.level)
    let T = Double(goalSeconds(profile.paceMi))
    let S = weeks * perWeek

    var out: [PlanWeek] = []
    var longestBlock = L.s0
    var lastWalk = 90.0
    for w in 0..<max(0, weeks) {
        var sessions: [PlanSession] = []
        for j in 0..<max(0, perWeek) {
            let k = w * perWeek + j
            let p = S <= 1 ? 1 : Double(k) / Double(S - 1)
            var runSec: Double, walkSec: Double, repeats: Double

            if p >= 1 {
                runSec = T; walkSec = lastWalk; repeats = 1
            } else {
                let R = L.R0 + (T * 0.9 - L.R0) * pow(p, 1.3)          // total running this session
                let s = L.s0 * pow(T / L.s0, pow(p, 1.8))              // length of one run block
                runSec = roundRun(min(s, T))
                repeats = max(1, jsRound(R / runSec))
                if repeats == 1 {
                    // Don't let a continuous run jump too far past the longest block so far.
                    runSec = roundRun(min(max(runSec, R), longestBlock * 1.4))
                    walkSec = lastWalk // just the walks before and after
                } else {
                    let ratio = L.ratio0 * (1 - p) + 0.15 * p
                    walkSec = roundTo(clamp(runSec * ratio, 60, 180), 15)
                    lastWalk = walkSec
                }
            }

            longestBlock = max(longestBlock, runSec)
            let last = w == weeks - 1 && j == perWeek - 1
            sessions.append(PlanSession(
                id: "w\(w + 1)s\(j + 1)",
                title: last ? "5K run" : "Run \(j + 1)",
                runSec: Int(runSec), walkSec: Int(walkSec), repeats: Int(repeats),
                note: last
                    ? "Goal day: run the whole 5K (3.1 miles) at an easy, steady pace."
                    : repeats == 1
                        ? "Non-stop run. Keep it slow enough to talk."
                        : "Easy pace — you should be able to talk in short sentences."
            ))
        }
        out.append(PlanWeek(week: w + 1, focus: weekFocus(w, weeks), sessions: sessions))
    }

    return Plan(
        createdAt: isoString(now),
        source: "builtin",
        summary: "\(weeks) weeks · \(perWeek) runs a week · finishing with a \(jsRoundInt(T / 60))-minute 5K (3.1 miles).",
        weeks: out
    )
}

public func weekFocus(_ w: Int, _ weeks: Int) -> String {
    let p = weeks <= 1 ? 1 : Double(w) / Double(weeks - 1)
    if p == 1 { return "Race week" }
    if p < 0.34 { return "Build the habit" }
    if p < 0.67 { return "Longer runs" }
    return "Run non-stop"
}

// MARK: - Workout helpers

public let DEFAULT_WORKOUT = Workout(runSec: 90, walkSec: 90, repeats: 8)

/// A workout is just { runSec, walkSec, repeats }.
public func normWorkout(_ s: PlanSession) -> Workout { s.workout }
public func normWorkout(_ w: Workout) -> Workout { w }
public func workoutFromSession(_ s: PlanSession) -> Workout { s.workout }

public enum SegmentType: String, Codable, Sendable { case walk, run }
public enum SegmentEdge: String, Codable, Sendable { case start, end }

public struct Segment: Codable, Hashable, Sendable {
    public var type: SegmentType
    public var dur: Int
    public var rep: Int?
    public var of: Int?
    /// `.start` = first walk (warm-up), `.end` = last walk (cool-down).
    public var edge: SegmentEdge?
    public var start: Int
    public var end: Int
}

/// Converts a workout into an ordered list of timed segments: walk, (run, walk) × repeats.
public func segmentsFor(_ wk: Workout) -> [Segment] {
    var segs: [Segment] = []
    if wk.walkSec > 0 { segs.append(Segment(type: .walk, dur: wk.walkSec, edge: .start, start: 0, end: 0)) }
    if wk.repeats > 0 {
        for i in 0..<wk.repeats {
            segs.append(Segment(type: .run, dur: wk.runSec, rep: i + 1, of: wk.repeats, start: 0, end: 0))
            let lastRep = i == wk.repeats - 1
            if wk.walkSec > 0 {
                segs.append(Segment(type: .walk, dur: wk.walkSec, rep: i + 1, of: wk.repeats, edge: lastRep ? .end : nil, start: 0, end: 0))
            }
        }
    }
    var t = 0
    for i in segs.indices { segs[i].start = t; t += segs[i].dur; segs[i].end = t }
    return segs
}

public func totalSeconds(_ wk: Workout) -> Int {
    wk.repeats * wk.runSec + (wk.walkSec > 0 ? (wk.repeats + 1) * wk.walkSec : 0)
}

/// "m:ss"
public func fmt(_ sec: Double) -> String {
    let s = Int(max(0, jsRound(sec)))
    return "\(s / 60):\(pad2(s % 60))"
}
public func fmt(_ sec: Int) -> String { fmt(Double(sec)) }

/// Friendly short duration: 90 -> "1:30", 120 -> "2 min", 45 -> "45 sec"
public func dur(_ sec: Int) -> String {
    if sec < 60 { return "\(sec) sec" }
    if sec % 60 == 0 { return "\(sec / 60) min" }
    return fmt(sec)
}

public func describe(_ wk: Workout) -> String {
    if wk.repeats == 1 || wk.walkSec == 0 { return "Run \(dur(wk.runSec * wk.repeats)) non-stop" }
    return "Run \(dur(wk.runSec)) · Walk \(dur(wk.walkSec)) × \(wk.repeats)"
}

public struct Suggestion: Hashable, Sendable {
    public var label: String
    public var wk: Workout
}

/// Suggestions shown before a run.
public func suggestions(_ planned: Workout?, _ last: Workout?) -> [Suggestion] {
    var list: [Suggestion] = []
    if let planned { list.append(Suggestion(label: "Planned", wk: planned)) }
    if let last { list.append(Suggestion(label: "Last run", wk: last)) }
    if let base = planned ?? last {
        if base.repeats > 1 {
            list.append(Suggestion(label: "Easier", wk: Workout(runSec: max(15, base.runSec - 15), walkSec: base.walkSec + 15, repeats: base.repeats)))
            list.append(Suggestion(label: "Harder", wk: Workout(runSec: base.runSec + 15, walkSec: max(15, base.walkSec - 15), repeats: base.repeats)))
        } else {
            list.append(Suggestion(label: "Easier", wk: Workout(runSec: max(60, base.runSec - 120), walkSec: base.walkSec, repeats: base.repeats)))
            list.append(Suggestion(label: "Harder", wk: Workout(runSec: base.runSec + 120, walkSec: base.walkSec, repeats: base.repeats)))
        }
    }
    list.append(Suggestion(label: "1:30 / 1:30", wk: DEFAULT_WORKOUT))
    // De-duplicate identical workouts
    var seen = Set<Workout>()
    return list.filter { seen.insert($0.wk).inserted }
}
public func suggestions(_ planned: PlanSession?, _ last: Workout?) -> [Suggestion] {
    suggestions(planned?.workout, last)
}

// MARK: - Dates

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoFormatterNoFraction = ISO8601DateFormatter()

/// `Date.prototype.toISOString()`: "2026-10-01T12:00:00.000Z"
public func isoString(_ d: Date) -> String { isoFormatter.string(from: d) }

/// Parses the ISO strings the web app stores (with or without milliseconds).
public func parseISODate(_ s: String) -> Date? {
    isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
}
