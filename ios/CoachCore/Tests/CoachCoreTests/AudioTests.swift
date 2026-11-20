import XCTest
@testable import CoachCore

final class AudioTests: XCTestCase {
    struct Opts: Decodable { let beeps: Bool?; let halfway: Bool? }
    struct CueCase: Decodable { let wk: Workout; let opts: Opts; let events: [CueEvent]; let end: Int }

    private func options(_ o: Opts) -> CueOptions { CueOptions(beeps: o.beeps ?? true, halfway: o.halfway ?? true) }

    func testCueEventsMatchJS() throws {
        let cases = try Fixture.decode([CueCase].self, "cues.json")
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let got = cueEvents(c.wk, options(c.opts))
            XCTAssertEqual(got.end, c.end, "\(c.wk) \(c.opts)")
            XCTAssertEqual(got.events, c.events, "\(c.wk) \(c.opts)")
        }
    }

    struct RenderFixture: Decodable {
        struct R: Decodable {
            let wk: Workout; let opts: Opts; let duration: Double; let end: Int
            let bytes: Int; let fnv: UInt32; let header: [UInt8]
        }
        struct Clip: Decodable { let length: Int; let fnv: UInt32 }
        let renders: [R]
        let clips: [String: Clip]
    }

    /// The real cue clips from the web app (audio/*.wav), prepared like the JS does.
    private func loadRepoClips() throws -> [CueKind: [Int16]] {
        var wavs: [CueKind: Data] = [:]
        for k in WorkoutAudio.CUE_NAMES {
            wavs[k] = try Data(contentsOf: Fixture.repoRoot.appendingPathComponent("audio/\(k.rawValue).wav"))
        }
        return try WorkoutAudio.loadClips(wavs)
    }

    func testPreparedClipsMatchJS() throws {
        let fx = try Fixture.decode(RenderFixture.self, "render.json")
        let clips = try loadRepoClips()
        XCTAssertEqual(Set(fx.clips.keys), Set(WorkoutAudio.CUE_NAMES.map(\.rawValue)))
        for (name, want) in fx.clips {
            let got = try XCTUnwrap(clips[CueKind(rawValue: name)!])
            XCTAssertEqual(got.count, want.length, name)
            XCTAssertEqual(fnv(got), want.fnv, name)
        }
    }

    func testRenderMatchesJS() throws {
        let fx = try Fixture.decode(RenderFixture.self, "render.json")
        let clips = try loadRepoClips()
        for r in fx.renders {
            let out = try WorkoutAudio.render(r.wk, options(r.opts), clips: clips)
            let wav = out.wav
            XCTAssertEqual(out.end, r.end, "\(r.wk)")
            XCTAssertEqual(out.duration, r.duration, accuracy: 1e-9, "\(r.wk)")
            XCTAssertEqual(wav.count, r.bytes, "\(r.wk)")
            XCTAssertEqual([UInt8](wav.prefix(44)), r.header, "\(r.wk)")
            XCTAssertEqual(fnv(wav), r.fnv, "\(r.wk) — WAV bytes differ from the JS render")
        }
    }

    func testBeepAndWavRoundTrip() throws {
        XCTAssertEqual(WorkoutAudio.BEEP.count, 1213)
        XCTAssertEqual(WorkoutAudio.BEEP.first, 0)
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        let wav = WorkoutAudio.wavData(samples)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(try WorkoutAudio.parseWav(wav), samples)
        XCTAssertThrowsError(try WorkoutAudio.parseWav(Data(repeating: 0, count: 20)))
        XCTAssertEqual(WorkoutAudio.prepare([]), [])
    }

    func testRenderNeedsClips() {
        XCTAssertThrowsError(try WorkoutAudio.render(DEFAULT_WORKOUT, clips: [:]))
        XCTAssertThrowsError(try WorkoutAudio.render(DEFAULT_WORKOUT, clips: [.done: [1, 2, 3]]))
    }
}
