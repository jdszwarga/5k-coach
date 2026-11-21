import Foundation

// Port of the pure parts of js/audio.js: the cue schedule and the whole-workout render.
//
// The whole workout is rendered up front into ONE mono 16-bit track (silence + spoken cues
// + countdown beeps at exact timestamps). No audio APIs here: the app plays the result.

public enum CueKind: String, Codable, CaseIterable, Sendable {
    case warmup, run, walk, lastrun, halfway, oneminute, cooldown, done
    case beep
}

public struct CueEvent: Codable, Hashable, Sendable {
    /// Seconds into the workout.
    public var t: Double
    public var kind: CueKind
    public init(t: Double, kind: CueKind) { self.t = t; self.kind = kind }
}

public struct CueOptions: Hashable, Sendable {
    public var beeps: Bool
    public var halfway: Bool
    public init(beeps: Bool = true, halfway: Bool = true) { self.beeps = beeps; self.halfway = halfway }
}

public struct CueSchedule: Hashable, Sendable {
    public var segs: [Segment]
    public var events: [CueEvent]
    /// Workout length in seconds (end of the last segment).
    public var end: Int
}

/// Builds the cue schedule for a workout.
public func cueEvents(_ wk: Workout, _ opts: CueOptions = CueOptions()) -> CueSchedule {
    let segs = segmentsFor(wk)
    var ev: [CueEvent] = []
    let runs = segs.indices.filter { segs[$0].type == .run }
    let lastRun = runs.last

    for (i, s) in segs.enumerated() {
        var cue: CueKind = s.type == .run ? .run : .walk
        if s.type == .run && i == lastRun && runs.count > 1 { cue = .lastrun }
        if s.edge == .start { cue = .warmup }    // first walk: "Warm up. Start with a brisk walk."
        if s.edge == .end { cue = .cooldown }    // last walk: "Cool down. Nice easy walk."
        if opts.beeps && i > 0 && segs[i - 1].dur >= 6 {
            for d in [3, 2, 1] { ev.append(CueEvent(t: Double(s.start - d), kind: .beep)) }
        }
        ev.append(CueEvent(t: Double(s.start), kind: cue))
        if s.type == .run && s.dur >= 180 { ev.append(CueEvent(t: Double(s.end - 60), kind: .oneminute)) }
    }

    if opts.halfway, let first = runs.first, let last = lastRun {
        let mid = Double(segs[first].start + segs[last].end) / 2
        let clash = ev.contains { $0.kind != .beep && abs($0.t - mid) < 6 }
            || ev.contains { $0.kind == .beep && abs($0.t - mid) < 4 }
        if !clash && Double(segs[first].start) < mid { ev.append(CueEvent(t: mid, kind: .halfway)) }
    }

    let end = segs.last?.end ?? 0
    ev.append(CueEvent(t: Double(end), kind: .done))
    // Stable sort by time, like Array.prototype.sort.
    ev = ev.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
    return CueSchedule(segs: segs, events: ev, end: end)
}

public enum WorkoutAudio {
    /// Sample rate; matches the cue clips (~22 KB per second of workout).
    public static let SR = 11025
    /// The spoken clips, `audio/<name>.wav`.
    public static let CUE_NAMES: [CueKind] = [.warmup, .run, .walk, .lastrun, .halfway, .oneminute, .cooldown, .done]

    public enum AudioError: Error, Equatable {
        case badWav
        case missingClip(CueKind)
    }

    /// The 16-bit mono samples of a WAV file's `data` chunk.
    public static func parseWav(_ data: Data) throws -> [Int16] {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int {
            Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        var off = 12
        while off + 8 <= bytes.count {
            let id = String(decoding: bytes[off..<off + 4], as: UTF8.self)
            let size = u32(off + 4)
            if id == "data" {
                let n = min(size, bytes.count - off - 8) / 2
                var out = [Int16](repeating: 0, count: n)
                let base = off + 8
                for i in 0..<n {
                    out[i] = Int16(bitPattern: UInt16(bytes[base + 2 * i]) | UInt16(bytes[base + 2 * i + 1]) << 8)
                }
                return out
            }
            off += 8 + size + (size & 1)
        }
        throw AudioError.badWav
    }

    /// Trim silence and normalise loudness so cues cut through music.
    public static func prepare(_ pcm: [Int16]) -> [Int16] {
        let thr = 400
        var a = 0, b = pcm.count - 1
        while a < b && abs(Int(pcm[a])) < thr { a += 1 }
        while b > a && abs(Int(pcm[b])) < thr { b -= 1 }
        a = max(0, a - jsRoundInt(Double(SR) * 0.02))
        b = min(pcm.count - 1, b + jsRoundInt(Double(SR) * 0.08))
        guard b >= a else { return [] }
        var peak = 1
        for i in a...b { peak = max(peak, abs(Int(pcm[i]))) }
        let g = (32767 * 0.97) / Double(peak)
        return pcm[a...b].map { Int16(clamp(jsRound(Double($0) * g), -32768, 32767)) }
    }

    public static func tone(_ freq: Double, _ secs: Double, _ amp: Double = 0.55) -> [Int16] {
        let sr = Double(SR)
        let n = jsRoundInt(sr * secs)
        let fade = Double(jsRoundInt(sr * 0.012))
        var out = [Int16](repeating: 0, count: max(0, n))
        for i in 0..<max(0, n) {
            let x = Double(i)
            let env = min(1, x / fade, (Double(n - 1) - x) / fade)
            out[i] = Int16(truncatingIfNeeded: jsRoundInt(sin(2 * Double.pi * freq * x / sr) * env * amp * 32767))
        }
        return out
    }

    /// The countdown beep.
    public static let BEEP = tone(880, 0.11)

    public static func wavHeader(_ numSamples: Int) -> Data {
        var h = Data(capacity: 44)
        func str(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { h.append(contentsOf: $0) } }
        let dataBytes = numSamples * 2
        str("RIFF"); u32(36 + dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(SR); u32(SR * 2); u16(2); u16(16)
        str("data"); u32(dataBytes)
        return h
    }

    /// A complete WAV file for the samples.
    public static func wavData(_ samples: [Int16]) -> Data {
        var d = wavHeader(samples.count)
        #if _endian(big)
        let le = samples.map { $0.littleEndian }
        le.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        #else
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        #endif
        return d
    }

    public struct Rendered: Sendable {
        public var samples: [Int16]
        public var segs: [Segment]
        public var events: [CueEvent]
        public var end: Int
        /// Track length in seconds (the workout plus a tail for the final message).
        public var duration: Double
        public var wav: Data { WorkoutAudio.wavData(samples) }
    }

    /// Renders the workout. `clips` are the prepared cue clips (see `prepare`), keyed by cue.
    public static func render(_ wk: Workout, _ opts: CueOptions = CueOptions(), clips: [CueKind: [Int16]]) throws -> Rendered {
        let sched = cueEvents(wk, opts)
        guard let done = clips[.done] else { throw AudioError.missingClip(.done) }
        let totalSamples = sched.end * SR + done.count + SR // tail for the final message
        var out = [Int16](repeating: 0, count: totalSamples)
        var cursor = 0
        for e in sched.events {
            let pcm: [Int16]
            if e.kind == .beep { pcm = BEEP } else {
                guard let c = clips[e.kind] else { throw AudioError.missingClip(e.kind) }
                pcm = c
            }
            let at = max(cursor, jsRoundInt(e.t * Double(SR)))
            if at + pcm.count > totalSamples { continue }
            out.replaceSubrange(at..<at + pcm.count, with: pcm)
            cursor = at + pcm.count
        }
        return Rendered(samples: out, segs: sched.segs, events: sched.events, end: sched.end,
                        duration: Double(totalSamples) / Double(SR))
    }

    /// Loads and prepares the clips from WAV data keyed by cue (e.g. read from the app bundle).
    public static func loadClips(_ wavs: [CueKind: Data]) throws -> [CueKind: [Int16]] {
        var out: [CueKind: [Int16]] = [:]
        for name in CUE_NAMES {
            guard let d = wavs[name] else { throw AudioError.missingClip(name) }
            out[name] = prepare(try parseWav(d))
        }
        return out
    }

    /// The Settings "Test voice" sequence: three beeps then "Run".
    public static func testCue(clips: [CueKind: [Int16]]) -> [Int16] {
        let gap = [Int16](repeating: 0, count: jsRoundInt(Double(SR) * 0.9))
        var out: [Int16] = []
        for _ in 0..<3 { out += BEEP; out += gap }
        out += clips[.run] ?? []
        out += [Int16](repeating: 0, count: jsRoundInt(Double(SR) * 0.5))
        return out
    }
}
