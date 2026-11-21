import Foundation

// Port of js/gps.js: distance, pace and a route track, from plain location fixes.
//
// The app feeds fixes from Core Location into `GpsTracker.onFix`. When a fix arrives after
// a long silence it is joined to the last one with a straight line: it counts toward
// distance (a straight line is the shortest route, so this undercounts) and is marked as a
// gap so the map draws it dashed.

public let M_PER_MI = 1609.344

public enum Gps {
    /// m: ignore fixes worse than this (cell/wifi guesses, cold starts)
    public static let MAX_ACC = 35.0
    /// m/s (~3:20/mi): anything faster is a GPS jump, not the runner
    public static let MAX_SPEED = 8.0
    /// s without a fix = a gap (normal rate is ~1 per second)
    public static let GAP_SEC = 20.0
    /// after this many "impossible" fixes in a row, trust the new spot
    public static let JUMP_RESET = 3
    /// s of recent track used for current pace
    public static let PACE_WINDOW = 30.0
    /// Douglas-Peucker tolerance (m) for the stored track
    public static let EPS = 3.0
}

private let R_EARTH = 6371008.8
@inline(__always) private func rad(_ d: Double) -> Double { d * Double.pi / 180 }

/// Great-circle distance in metres.
public func haversine(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
    let dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1)
    let sLat = sin(dLat / 2), sLng = sin(dLng / 2)
    let a = sLat * sLat + cos(rad(lat1)) * cos(rad(lat2)) * sLng * sLng
    return 2 * R_EARTH * asin(min(1, a.squareRoot()))
}

public func miles(_ m: Double) -> Double { m / M_PER_MI }
/// Miles with two decimals, e.g. "1.86".
public func miText(_ m: Double) -> String { jsToFixed(miles(m), 2) }

/// Seconds per mile, or nil when there isn't enough to say.
public func paceSec(_ m: Double?, _ sec: Double?) -> Double? {
    guard let m, let sec, m != 0, !m.isNaN, m >= 40, sec != 0, !sec.isNaN else { return nil }
    let p = sec / miles(m)
    return p > 0 && p < 60 * 60 ? p : nil
}

/// One location fix, as the platform reports it.
public struct GpsFix: Hashable, Sendable {
    public var lat: Double
    public var lng: Double
    /// Horizontal accuracy in metres; nil/NaN = unknown (rejected).
    public var accuracy: Double?
    /// Milliseconds since 1970 (like `position.timestamp`); nil/0 = use the clock's now.
    public var timestamp: Double?
    public init(lat: Double, lng: Double, accuracy: Double?, timestamp: Double?) {
        self.lat = lat; self.lng = lng; self.accuracy = accuracy; self.timestamp = timestamp
    }
}

public enum TrackKind: String, Codable, Sendable {
    case start, line, gap
    case `break`
}

public struct TrackPoint: Hashable, Sendable {
    public var lat: Double
    public var lng: Double
    /// Seconds into the workout (pauses excluded).
    public var t: Double
    /// Fix time, ms since 1970.
    public var ts: Double
    public var kind: TrackKind
    public init(lat: Double, lng: Double, t: Double, ts: Double, kind: TrackKind) {
        self.lat = lat; self.lng = lng; self.t = t; self.ts = ts; self.kind = kind
    }
}

public enum GpsStatus: String, Sendable { case off, searching, ok, denied, unavailable }

public struct GpsSummary: Hashable, Sendable {
    public var distM: Int
    public var gpsSec: Int
    public var track: Track
}

public final class GpsTracker {
    /// Seconds into the workout (pauses don't count), used to timestamp points.
    public let clock: () -> Double
    /// Wall clock in ms since 1970 (`Date.now()`).
    public let now: () -> Double

    public private(set) var pts: [TrackPoint] = []
    public private(set) var distM = 0.0
    /// Workout seconds covered by the track (excludes breaks).
    public private(set) var sec = 0.0
    public private(set) var status: GpsStatus = .off
    public private(set) var paused = false
    private var needBreak = false
    private var rejects = 0
    public private(set) var lastFixAt = 0.0
    public var onchange: (() -> Void)?

    public init(clock: @escaping () -> Double, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.clock = clock
        self.now = now
    }

    /// Call when location updates start (`start()` in the JS).
    public func start() { set(.searching) }

    /// While the workout is paused fixes are ignored; the next one after resuming starts a new
    /// piece of track instead of being joined up.
    public func setPaused(_ p: Bool) {
        if p && !paused { needBreak = true }
        paused = p
    }

    public func set(_ status: GpsStatus) {
        if self.status == status { return }
        self.status = status
        onchange?()
    }

    /// A location error. `denied` = permission refused (stop updates); anything else keeps watching.
    public func onError(denied: Bool) {
        if denied { set(.denied); return }
        if status != .ok { set(.searching) }
    }

    public func onFix(_ fix: GpsFix) {
        let lat = fix.lat, lng = fix.lng
        var ts = fix.timestamp ?? 0
        if ts == 0 || ts.isNaN { ts = now() } // `pos.timestamp || Date.now()`
        if paused || !lat.isFinite || !lng.isFinite { return }
        guard let accuracy = fix.accuracy, accuracy <= Gps.MAX_ACC else {
            if status != .ok { set(.searching) }
            return
        }
        lastFixAt = now()
        let t = max(0, clock())
        guard let prev = pts.last else { add(TrackPoint(lat: lat, lng: lng, t: t, ts: ts, kind: .start)); return }
        if needBreak {
            needBreak = false; rejects = 0
            add(TrackPoint(lat: lat, lng: lng, t: t, ts: ts, kind: .break))
            return
        }

        let dt = (ts - prev.ts) / 1000
        if dt <= 0 { return }
        let d = haversine(prev.lat, prev.lng, lat, lng)
        if d / dt > Gps.MAX_SPEED {
            // A jump. If it keeps happening the last point was the bad one (or she really moved):
            // start a fresh piece from here without counting the jump.
            rejects += 1
            if rejects >= Gps.JUMP_RESET { rejects = 0; add(TrackPoint(lat: lat, lng: lng, t: t, ts: ts, kind: .break)) }
            return
        }
        rejects = 0
        let gap = dt > Gps.GAP_SEC
        // Standing still, GPS wanders a few meters: wait until she's clearly moved.
        if !gap && d < max(4, accuracy * 0.6) { return }
        distM += d
        sec += max(0, t - prev.t)
        add(TrackPoint(lat: lat, lng: lng, t: t, ts: ts, kind: gap ? .gap : .line))
    }

    private func add(_ p: TrackPoint) {
        pts.append(p)
        set(.ok)
        onchange?()
    }

    /// Seconds per mile over the last ~30 s of continuous track (not across gaps or breaks).
    public func currentPace() -> Double? {
        guard let last = pts.last, now() - lastFixAt <= Gps.GAP_SEC * 1000 else { return nil }
        var d = 0.0, i = pts.count - 1
        while i > 0 && pts[i].kind == .line && last.t - pts[i - 1].t <= Gps.PACE_WINDOW {
            d += haversine(pts[i - 1].lat, pts[i - 1].lng, pts[i].lat, pts[i].lng)
            i -= 1
        }
        let span = last.t - pts[i].t
        if d < 15 || span <= 0 { return nil }
        let p = span / miles(d)
        return p < 60 * 60 ? p : nil
    }

    public func avgPace() -> Double? { paceSec(distM, sec) }
    public var hasGaps: Bool { pts.contains { $0.kind == .gap } }

    /// What gets stored with the run, or nil if nothing was recorded.
    public func summary() -> GpsSummary? {
        if pts.count < 2 || distM < 10 { return nil }
        return GpsSummary(distM: jsRoundInt(distM), gpsSec: jsRoundInt(sec), track: pack(pts))
    }
}

// MARK: - Storage format
// track = { v: 1, pts: [[lat, lng, t], ...], gap: [i, ...], brk: [i, ...] }
//   lat/lng rounded to 5 decimals (~1 m), t = whole seconds into the workout.
//   gap: point i was reached after a GPS gap (line i-1 -> i is a straight-line guess, drawn dashed).
//   brk: point i starts a new piece (after a pause); no line from i-1 and not counted.
// The live track is thinned with Douglas-Peucker (3 m) so a 5K is a few hundred points.

public struct Track: Codable, Hashable, Sendable {
    public var v: Int
    /// [lat, lng, t]
    public var pts: [[Double]]
    public var gap: [Int]
    public var brk: [Int]

    public init(v: Int = 1, pts: [[Double]] = [], gap: [Int] = [], brk: [Int] = []) {
        self.v = v; self.pts = pts; self.gap = gap; self.brk = brk
    }

    enum CodingKeys: String, CodingKey { case v, pts, gap, brk }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.flexInt(.v) ?? 1
        pts = (try? c.decodeIfPresent([[Double]].self, forKey: .pts)) ?? []
        gap = (try? c.decodeIfPresent([Int].self, forKey: .gap)) ?? []
        brk = (try? c.decodeIfPresent([Int].self, forKey: .brk)) ?? []
    }
}

public func pack(_ pts: [TrackPoint]) -> Track {
    guard !pts.isEmpty else { return Track() }
    var keep: Set<Int> = [0, pts.count - 1]
    var s = 0
    for i in 1...pts.count {
        if i == pts.count || pts[i].kind != .line {
            // pts[s..i-1] is one continuous solid piece
            rdp(pts, s, i - 1, &keep)
            if i < pts.count { keep.insert(i - 1); keep.insert(i) }
            s = i
        }
    }
    var out = Track()
    for (j, k) in keep.sorted().enumerated() {
        let p = pts[k]
        out.pts.append([jsToFixedNumber(p.lat, 5), jsToFixedNumber(p.lng, 5), jsRound(p.t)])
        if p.kind == .gap { out.gap.append(j) }
        if p.kind == .break { out.brk.append(j) }
    }
    return out
}

private func rdp(_ pts: [TrackPoint], _ a: Int, _ b: Int, _ keep: inout Set<Int>) {
    if b - a < 2 { return }
    let k = cos(rad(pts[a].lat)) * 111320, ky = 110540.0
    let ax = pts[a].lng * k, ay = pts[a].lat * ky, bx = pts[b].lng * k, by = pts[b].lat * ky
    let len = hypot(bx - ax, by - ay)
    var best = -1, far = 0.0
    for i in (a + 1)..<b {
        let px = pts[i].lng * k, py = pts[i].lat * ky
        let dist = len < 1e-6 ? hypot(px - ax, py - ay) : abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len
        if dist > far { far = dist; best = i }
    }
    if far > Gps.EPS { keep.insert(best); rdp(pts, a, best, &keep); rdp(pts, best, b, &keep) }
}

public struct LatLng: Hashable, Sendable {
    public var lat: Double
    public var lng: Double
    public init(_ lat: Double, _ lng: Double) { self.lat = lat; self.lng = lng }
}

public struct TrackPiece: Hashable, Sendable {
    public var line: [LatLng]
    public var dashed: Bool
}

/// Pieces to draw: solid runs of track, plus dashed straight lines across GPS gaps.
public func pieces(_ track: Track?) -> [TrackPiece] {
    guard let track, !track.pts.isEmpty else { return [] }
    let gap = Set(track.gap), brk = Set(track.brk)
    func ll(_ i: Int) -> LatLng {
        let p = track.pts[i]
        return LatLng(p.count > 0 ? p[0] : .nan, p.count > 1 ? p[1] : .nan)
    }
    var out: [TrackPiece] = []
    var cur = TrackPiece(line: [ll(0)], dashed: false)
    for i in 1..<max(1, track.pts.count) {
        let p = ll(i)
        if brk.contains(i) || gap.contains(i) {
            if cur.line.count > 1 { out.append(cur) }
            if gap.contains(i) { out.append(TrackPiece(line: [ll(i - 1), p], dashed: true)) }
            cur = TrackPiece(line: [p], dashed: false)
        } else {
            cur.line.append(p)
        }
    }
    if cur.line.count > 1 { out.append(cur) }
    return out
}
