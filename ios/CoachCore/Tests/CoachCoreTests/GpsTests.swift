import XCTest
@testable import CoachCore

final class GpsTests: XCTestCase {
    /// Replays the scripted fake run (junk fixes, a jump, a gap, a pause, a jump reset)
    /// through the tracker and checks it against the JS tracker at each checkpoint.
    func testScriptedTrackMatchesJS() throws {
        let fx = try XCTUnwrap(try Fixture.json("gps-track.json") as? [String: Any])
        let fixes = try XCTUnwrap(fx["fixes"] as? [[String: Any]])
        let checkpoints = try XCTUnwrap(fx["checkpoints"] as? [[String: Any]])

        var nowMs = 0.0
        var workoutSec = 0.0
        let tracker = GpsTracker(clock: { workoutSec }, now: { nowMs })
        tracker.start()
        XCTAssertEqual(tracker.status, .searching)

        var cpIndex = 0
        func check(after n: Int) {
            while cpIndex < checkpoints.count, (checkpoints[cpIndex]["after"] as? Int) == n {
                let cp = checkpoints[cpIndex]
                let where_ = "checkpoint after \(n) fixes"
                XCTAssertTrue(close(tracker.distM, num(cp["distM"]), rel: 1e-9), "\(where_): distM \(tracker.distM) vs \(cp["distM"]!)")
                XCTAssertEqual(tracker.sec, num(cp["sec"]), where_)
                XCTAssertEqual(tracker.pts.count, cp["points"] as? Int, where_)
                XCTAssertTrue(close(tracker.currentPace(), num(cp["currentPace"]), rel: 1e-8), "\(where_): currentPace \(String(describing: tracker.currentPace())) vs \(cp["currentPace"]!)")
                XCTAssertTrue(close(tracker.avgPace(), num(cp["avgPace"]), rel: 1e-8), "\(where_): avgPace")
                XCTAssertEqual(tracker.status.rawValue, cp["status"] as? String, where_)
                cpIndex += 1
            }
        }

        for (i, f) in fixes.enumerated() {
            if let p = f["pause"] as? Bool {
                tracker.setPaused(p)
            } else {
                nowMs = try XCTUnwrap(num(f["now"]))
                workoutSec = try XCTUnwrap(num(f["clock"]))
                if f["timestamp"] != nil {
                    tracker.onFix(GpsFix(lat: num(f["lat"]) ?? .nan, lng: num(f["lng"]) ?? .nan,
                                         accuracy: num(f["accuracy"]), timestamp: num(f["timestamp"])))
                }
            }
            check(after: i + 1)
        }
        XCTAssertEqual(cpIndex, checkpoints.count, "all checkpoints visited")

        let final = try XCTUnwrap(fx["final"] as? [String: Any])
        XCTAssertTrue(close(tracker.distM, num(final["distM"])), "distM \(tracker.distM) vs \(final["distM"]!)")
        XCTAssertEqual(tracker.sec, num(final["sec"]))
        XCTAssertEqual(tracker.hasGaps, final["hasGaps"] as? Bool)
        XCTAssertEqual(tracker.pts.map(\.kind.rawValue), final["kinds"] as? [String])

        // Fixes stopped a while ago: no current pace.
        nowMs += 25_000
        XCTAssertNil(tracker.currentPace())
        XCTAssertTrue(fx["stalePace"] is NSNull)

        // Stored summary + drawn pieces
        let summary = try XCTUnwrap(tracker.summary())
        let want = try XCTUnwrap(fx["summary"] as? [String: Any])
        XCTAssertEqual(summary.distM, want["distM"] as? Int)
        XCTAssertEqual(summary.gpsSec, want["gpsSec"] as? Int)
        let wantTrack = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: want["track"]!))
        XCTAssertEqual(summary.track, wantTrack)
        XCTAssertFalse(wantTrack.gap.isEmpty)
        XCTAssertEqual(wantTrack.brk.count, 2)

        let wantPieces = try XCTUnwrap(fx["pieces"] as? [[String: Any]])
        assertPieces(pieces(summary.track), wantPieces)
    }

    private func assertPieces(_ got: [TrackPiece], _ want: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "piece count", file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.dashed, w["dashed"] as? Bool, file: file, line: line)
            let pts = (w["line"] as? [[Any]] ?? []).map { LatLng(num($0[0]) ?? .nan, num($0[1]) ?? .nan) }
            XCTAssertEqual(g.line, pts, file: file, line: line)
        }
    }

    func testMiscMatchesJS() throws {
        let fx = try XCTUnwrap(try Fixture.json("gps-misc.json") as? [String: Any])

        for c in try XCTUnwrap(fx["haversine"] as? [[String: Any]]) {
            let a = (c["in"] as! [Any]).map { num($0)! }
            let got = haversine(a[0], a[1], a[2], a[3])
            XCTAssertTrue(close(got, num(c["out"]), rel: 1e-12), "haversine\(a): \(got) vs \(c["out"]!)")
        }
        for c in try XCTUnwrap(fx["paceSec"] as? [[String: Any]]) {
            let got = paceSec(num(c["m"]), num(c["sec"]))
            XCTAssertTrue(close(got, num(c["out"]), rel: 1e-12), "paceSec(\(c["m"]!), \(c["sec"]!))")
        }

        let packCase = try XCTUnwrap(fx["pack"] as? [String: Any])
        let input = (packCase["in"] as! [[String: Any]]).map {
            TrackPoint(lat: num($0["lat"])!, lng: num($0["lng"])!, t: num($0["t"])!, ts: 0,
                       kind: TrackKind(rawValue: $0["kind"] as! String)!)
        }
        let wantPack = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: packCase["out"]!))
        XCTAssertEqual(pack(input), wantPack)

        for c in try XCTUnwrap(fx["pieces"] as? [[String: Any]]) {
            var track: Track? = nil
            if let t = c["in"], !(t is NSNull) {
                track = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: t))
            }
            assertPieces(pieces(track), c["out"] as! [[String: Any]])
        }
    }

    func testTrackerBasics() {
        var now = 1_000_000.0
        var clock = 0.0
        let g = GpsTracker(clock: { clock }, now: { now })
        var changes = 0
        g.onchange = { changes += 1 }
        g.start()
        XCTAssertEqual(g.status, .searching)
        g.onFix(GpsFix(lat: 40, lng: -75, accuracy: 5, timestamp: nil)) // timestamp falls back to now
        XCTAssertEqual(g.status, .ok)
        XCTAssertEqual(g.pts.first?.ts, now)
        now += 10_000; clock += 10
        g.onFix(GpsFix(lat: 40.0003, lng: -75, accuracy: 5, timestamp: now))
        XCTAssertEqual(g.pts.count, 2)
        XCTAssertGreaterThan(g.distM, 30)
        XCTAssertNotNil(g.summary())
        g.onError(denied: false)
        XCTAssertEqual(g.status, .ok)
        g.onError(denied: true)
        XCTAssertEqual(g.status, .denied)
        XCTAssertGreaterThan(changes, 3)
        XCTAssertEqual(miText(1609.344 * 1.234), "1.23")
        XCTAssertNil(GpsTracker(clock: { 0 }).summary())
        XCTAssertEqual(pack([]), Track())
    }
}
