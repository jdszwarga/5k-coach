import XCTest
@testable import CoachCore

final class PlanTests: XCTestCase {
    struct PlanCase: Decodable { let profile: Profile; let plan: Plan }

    func testGeneratePlanMatchesJS() throws {
        let cases = try Fixture.decode([PlanCase].self, "plans.json")
        XCTAssertGreaterThan(cases.count, 100)
        for c in cases {
            var got = generatePlan(c.profile)
            XCTAssertFalse(got.createdAt.isEmpty)
            got.createdAt = c.plan.createdAt // not in the fixture
            let label = "\(c.profile.level) \(c.profile.weeks)w×\(c.profile.perWeek) @\(c.profile.paceMi)"
            XCTAssertEqual(got.summary, c.plan.summary, label)
            XCTAssertEqual(got.source, c.plan.source, label)
            XCTAssertEqual(got.weeks.count, c.plan.weeks.count, label)
            for (g, e) in zip(got.weeks, c.plan.weeks) {
                XCTAssertEqual(g.week, e.week, label)
                XCTAssertEqual(g.focus, e.focus, "\(label) week \(e.week)")
                XCTAssertEqual(g.sessions, e.sessions, "\(label) week \(e.week)")
            }
        }
    }

    struct Helpers: Decodable {
        struct G: Decodable { let paceMi: Double; let out: Int }
        struct P: Decodable { let p: Double; let out: String }
        struct F: Decodable { let sec: Double; let out: String }
        struct D: Decodable { let sec: Int; let out: String }
        struct W: Decodable { let wk: Workout; let segs: [Segment]; let total: Int; let describe: String }
        struct N: Decodable {
            let input: Workout; let out: Workout
            enum CodingKeys: String, CodingKey { case input = "in", out }
        }
        struct S: Decodable {
            struct Item: Decodable { let label: String; let wk: Workout }
            let planned: Workout?; let last: Workout?; let out: [Item]
        }
        let goalSeconds: [G]; let paceText: [P]; let fmt: [F]; let dur: [D]
        let workouts: [W]; let normWorkout: [N]; let suggestions: [S]
    }

    func testHelpersMatchJS() throws {
        let h = try Fixture.decode(Helpers.self, "plan-helpers.json")
        for c in h.goalSeconds { XCTAssertEqual(goalSeconds(c.paceMi), c.out, "goalSeconds(\(c.paceMi))") }
        for c in h.paceText { XCTAssertEqual(paceText(c.p), c.out, "paceText(\(c.p))") }
        for c in h.fmt { XCTAssertEqual(fmt(c.sec), c.out, "fmt(\(c.sec))") }
        for c in h.dur { XCTAssertEqual(dur(c.sec), c.out, "dur(\(c.sec))") }
        for c in h.workouts {
            XCTAssertEqual(segmentsFor(c.wk), c.segs, "segmentsFor(\(c.wk))")
            XCTAssertEqual(totalSeconds(c.wk), c.total, "totalSeconds(\(c.wk))")
            XCTAssertEqual(describe(c.wk), c.describe, "describe(\(c.wk))")
        }
        for c in h.normWorkout { XCTAssertEqual(normWorkout(c.input), c.out) }
        for c in h.suggestions {
            let got = suggestions(c.planned, c.last)
            XCTAssertEqual(got.map(\.label), c.out.map(\.label), "suggestions(\(String(describing: c.planned)), \(String(describing: c.last)))")
            XCTAssertEqual(got.map(\.wk), c.out.map(\.wk))
        }
    }

    func testLevelsAndDefaults() {
        XCTAssertEqual(LEVELS.map(\.id), ["new", "some", "regular", "strong"])
        XCTAssertEqual(levelFor("nope").id, "new")
        XCTAssertEqual(levelFor(nil).id, "new")
        XCTAssertEqual(DEFAULT_WORKOUT, Workout(runSec: 90, walkSec: 90, repeats: 8))
        XCTAssertEqual(weekFocus(0, 1), "Race week")
    }

    func testJSNumberHelpers() {
        XCTAssertEqual(jsRound(2.5), 3)
        XCTAssertEqual(jsRound(-2.5), -2)
        XCTAssertEqual(jsRound(0.49999999999999994), 0)
        XCTAssertEqual(jsToFixed(42.015625, 5), "42.01563")   // exact tie: away from zero
        XCTAssertEqual(jsToFixed(-87.015625, 5), "-87.01563")
        XCTAssertEqual(jsToFixed(1.005, 2), "1.00")            // 1.005 is really 1.00499…
        XCTAssertEqual(jsToFixed(0.5, 0), "1")
        XCTAssertEqual(jsToFixed(9.999995, 5), "10.00000")
        XCTAssertEqual(jsToFixed(-0.001, 2), "-0.00")
        XCTAssertEqual(isoString(Date(timeIntervalSince1970: 1_790_000_000.25)), "2026-09-21T14:13:20.250Z")
        XCTAssertNotNil(parseISODate("2026-10-02T07:00:00.000Z"))
        XCTAssertNotNil(parseISODate("2026-10-02T07:00:00Z"))
    }
}
