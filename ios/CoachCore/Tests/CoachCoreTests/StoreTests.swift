import XCTest
@testable import CoachCore

final class StoreTests: XCTestCase {
    /// Fields the JS keeps from old exports that the Swift model deliberately drops.
    let dropped: Set<String> = ["days", "pace", "warmupSec"]

    private func jsonObject<T: Encodable>(_ v: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(v))
    }

    func testImportMatchesJSLoad() throws {
        let cases = try XCTUnwrap(try Fixture.json("store.json") as? [[String: Any]])
        XCTAssertEqual(cases.map { $0["name"] as? String }, ["current", "old", "empty", "broken"])
        for c in cases {
            let name = c["name"] as! String
            var state = AppState()
            if let raw = c["raw"] as? String {
                if name == "broken" {
                    XCTAssertThrowsError(try AppState.importPWA(Data(raw.utf8))) { XCTAssertEqual($0 as? AppState.ImportError, .notAnExport) }
                } else {
                    state = try AppState.importPWA(Data(raw.utf8))
                }
            }

            // The whole state, as the JS load() + exportJSON() sees it. The raw state still has
            // the real key (the export file has "(removed)"), so leave the key out here.
            let exported = try XCTUnwrap(c["exported"] as? [String: Any])
            var expected = exported
            var settings = try XCTUnwrap(expected["settings"] as? [String: Any])
            settings.removeValue(forKey: "apiKey")
            expected["settings"] = settings
            var failures: [String] = []
            compareJSON(expected, try jsonObject(state), dropped: dropped, failures: &failures)
            XCTAssertEqual(failures, [], "\(name) (raw state)")

            // The real flow: import the JS export file itself. Its "(removed)" key comes back as no key.
            let fromExport = try AppState.importPWA(JSONSerialization.data(withJSONObject: exported))
            XCTAssertEqual(fromExport.settings.apiKey, "", name)
            settings["apiKey"] = ""
            expected["settings"] = settings
            failures = []
            compareJSON(expected, try jsonObject(fromExport), dropped: dropped, failures: &failures)
            XCTAssertEqual(failures, [], "\(name) (export file)")
            var sameButKey = state
            sameButKey.settings.apiKey = ""
            XCTAssertEqual(fromExport, sameButKey, name)

            // Plan helpers
            let wantAll = try XCTUnwrap(c["allSessions"] as? [[String: Any]])
            let all = state.allSessions()
            XCTAssertEqual(all.map(\.id), wantAll.map { $0["id"] as! String }, name)
            XCTAssertEqual(all.map(\.week), wantAll.map { $0["week"] as! Int }, name)
            XCTAssertEqual(all.map { $0.workout }, try wantAll.map {
                try JSONDecoder().decode(Workout.self, from: JSONSerialization.data(withJSONObject: $0))
            }, name)
            let wantDone = try XCTUnwrap(c["isDone"] as? [String: Bool])
            for s in all { XCTAssertEqual(state.isDone(s.id), wantDone[s.id], "\(name) isDone(\(s.id))") }
            let next = c["nextSession"] as? [String: Any]
            XCTAssertEqual(state.nextSession()?.id, next?["id"] as? String, name)
            XCTAssertEqual(state.nextSession()?.week, next?["week"] as? Int, name)
            let prog = try XCTUnwrap(c["progress"] as? [String: Int])
            XCTAssertEqual(state.progress(), PlanProgress(done: prog["done"]!, total: prog["total"]!), name)
        }
    }

    func testCurrentExportDetails() throws {
        let cases = try XCTUnwrap(try Fixture.json("store.json") as? [[String: Any]])
        let raw = try XCTUnwrap(cases.first { $0["name"] as? String == "current" }?["raw"] as? String)
        let s = try AppState.importPWA(Data(raw.utf8))
        XCTAssertEqual(s.settings.audioMode, "locked")
        XCTAssertFalse(s.settings.beeps)
        XCTAssertEqual(s.profile?.paceMi, 12)
        XCTAssertEqual(s.history.count, 6)
        let gpsRun = try XCTUnwrap(s.history.first { $0.track != nil })
        XCTAssertNotNil(gpsRun.distM)
        XCTAssertNotNil(gpsRun.gpsSec)
        XCTAssertFalse(pieces(gpsRun.track).isEmpty)
        XCTAssertEqual(s.history.filter { $0.manual == true }.count, 1)
        XCTAssertNotNil(s.history[0].dateValue)
        XCTAssertEqual(s.pendingReview?.changes.first?.id, "w2s1")
        XCTAssertEqual(s.lastWorkout, s.plan?.weeks[0].sessions[2].workout)

        // Export -> import round trip keeps everything but the key.
        let back = try AppState.importPWA(s.exportJSON())
        var expect = s
        expect.settings.apiKey = ""
        XCTAssertEqual(back, expect)
    }

    func testOldExportMigration() throws {
        let cases = try XCTUnwrap(try Fixture.json("store.json") as? [[String: Any]])
        let raw = try XCTUnwrap(cases.first { $0["name"] as? String == "old" }?["raw"] as? String)
        let s = try AppState.importPWA(Data(raw.utf8))
        XCTAssertEqual(s.profile?.perWeek, 3)      // from 3 run days
        XCTAssertEqual(s.profile?.paceMi, 11.25)   // 7 min/km
        XCTAssertEqual(s.settings.model, "claude-opus-4-1")
        XCTAssertTrue(s.settings.gps)
        XCTAssertEqual(s.history[1].workout, Workout(runSec: 60, walkSec: 0, repeats: 7))
        XCTAssertEqual(s.history[2].workout, Workout(runSec: 600, walkSec: 0, repeats: 1))
        XCTAssertNil(s.history[2].sessionId)
        XCTAssertNil(s.history[0].distM)
    }

    func testTolerantImport() throws {
        let json = """
        {"profile": {"weeks": "6", "perWeek": 2.0, "paceMi": "12.5"},
         "history": [
           {"id": 17, "date": "2026-01-01T00:00:00.000Z", "workout": {"runSec": 90.0, "walkSec": 60, "repeats": 5},
            "totalSec": 1110.4, "doneSec": 1110, "completed": true, "distM": 2010.6},
           "garbage",
           {"id": "x", "workout": null, "completed": 1}
         ],
         "plan": {"weeks": [{"week": 1, "sessions": [{"id": "w1s1", "runSec": 60}, 5]}]},
         "settings": {"beeps": false, "unknown": 1}}
        """
        let s = try AppState.importPWA(Data(json.utf8))
        XCTAssertEqual(s.profile, Profile(weeks: 6, perWeek: 2, level: "new", paceMi: 12.5))
        XCTAssertEqual(s.history.count, 2)
        XCTAssertEqual(s.history[0].id, "17")
        XCTAssertEqual(s.history[0].totalSec, 1110)
        XCTAssertEqual(s.history[0].distM, 2011)
        XCTAssertEqual(s.history[0].workout, Workout(runSec: 90, walkSec: 60, repeats: 5))
        XCTAssertTrue(s.history[1].completed)
        XCTAssertEqual(s.plan?.weeks.first?.sessions.count, 1)
        XCTAssertEqual(s.plan?.weeks.first?.sessions.first?.workout, Workout(runSec: 60))
        XCTAssertFalse(s.settings.beeps)
        XCTAssertTrue(s.settings.halfway)
        XCTAssertEqual(s.nextSession()?.id, "w1s1")

        XCTAssertThrowsError(try AppState.importPWA(Data("[1,2]".utf8)))
        XCTAssertThrowsError(try AppState.importPWA(Data("{\"foo\": 1}".utf8)))
    }

    func testReset() {
        var s = AppState()
        s.settings.apiKey = "k"; s.settings.model = "m"; s.settings.beeps = false
        s.history = [HistoryEntry(id: "1", date: "", workout: DEFAULT_WORKOUT, totalSec: 1, doneSec: 1, completed: true)]
        s.reset()
        XCTAssertEqual(s.settings.apiKey, "k")
        XCTAssertEqual(s.settings.model, "m")
        XCTAssertTrue(s.settings.beeps)
        XCTAssertTrue(s.history.isEmpty)
    }
}
