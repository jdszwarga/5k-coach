import AVFoundation
import CoreLocation
import SwiftUI
import CoachCore

/// Renders cue tracks from the bundled clips (`audio/*.wav`, the same voice as the web app).
enum AudioRender {
    private static var cache: [CueKind: [Int16]]?
    private static let lock = NSLock()

    static func clips() throws -> [CueKind: [Int16]] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var wavs: [CueKind: Data] = [:]
        for k in WorkoutAudio.CUE_NAMES {
            guard let url = Bundle.main.url(forResource: k.rawValue, withExtension: "wav")
                    ?? Bundle.main.url(forResource: k.rawValue, withExtension: "wav", subdirectory: "audio")
            else { throw WorkoutAudio.AudioError.missingClip(k) }
            wavs[k] = try Data(contentsOf: url)
        }
        let c = try WorkoutAudio.loadClips(wavs)
        cache = c
        return c
    }

    struct Prepared: Sendable {
        let url: URL
        let segs: [Segment]
        let end: Int
    }

    /// The whole workout as one WAV file: silence plus cues and beeps at exact times.
    static func renderWorkout(_ wk: Workout, _ opts: CueOptions) throws -> Prepared {
        let r = try WorkoutAudio.render(wk, opts, clips: clips())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workout.wav")
        try r.wav.write(to: url, options: .atomic)
        return Prepared(url: url, segs: r.segs, end: r.end)
    }

    static func testCueURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-cue.wav")
        try WorkoutAudio.wavData(WorkoutAudio.testCue(clips: clips())).write(to: url, options: .atomic)
        return url
    }

    /// Cues mix over Spotify/podcasts and keep playing with the phone locked.
    static func activateSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try s.setActive(true)
    }

    static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Settings → "Test voice cue".
@MainActor
final class CuePreview {
    static let shared = CuePreview()
    private var player: AVAudioPlayer?

    func play() throws {
        try AudioRender.activateSession()
        let p = try AVAudioPlayer(contentsOf: AudioRender.testCueURL())
        player = p
        p.play()
    }
}

/// Forwards AVAudioPlayer's delegate calls to a closure.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((Bool) -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?(flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish?(false) }
}

/// Location fixes for the GPS tracker. Started while the app is in front, it keeps going with
/// the phone locked (location background mode), so there are no locked-screen gaps.
final class LocationFeed: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var wanted = false
    var onFix: ((CLLocation) -> Void)?
    var onDenied: (() -> Void)?
    var onError: (() -> Void)?

    func start() {
        wanted = true
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: onDenied?()
        default: manager.startUpdatingLocation()
        }
    }

    func stop() {
        wanted = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard wanted else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.startUpdatingLocation()
        case .denied, .restricted: onDenied?()
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wanted else { return }
        for l in locations { onFix?(l) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { onDenied?() } else { onError?() }
    }
}

/// One run: plays the pre-rendered cue track (its playback position is the workout clock) and
/// feeds GPS fixes to the tracker.
@MainActor
final class RunEngine: ObservableObject, Identifiable {
    let id = UUID()
    let config: RunConfig
    let options: CueOptions
    let startedAt = Date()
    /// After the workout ends, keep recording GPS until Finish ("keep tracking").
    let keepTracking: Bool

    @Published private(set) var ready = false
    @Published private(set) var loadError: String?
    @Published private(set) var paused = true
    @Published private(set) var result: FinishedRun?
    /// The workout is over and GPS keeps recording the extra.
    @Published private(set) var overtime = false
    private var otBase = 0.0
    private var otResumedAt: Date?
    private var pausedAt: Date?

    /// Keep-tracking stops by itself after this long without moving, paused, or in total.
    static let STILL_STOP = 5.0 * 60
    static let PAUSED_STOP = 10.0 * 60
    static let MAX_EXTRA = 90.0 * 60

    private(set) var segs: [Segment] = []
    private(set) var end = 0
    private(set) var gps: GpsTracker?
    private var location: LocationFeed?
    private var player: AVAudioPlayer?
    private let delegate = PlayerDelegate()
    private var interruptObs: NSObjectProtocol?
    private var resumeAfterInterruption = false
    private var checkpointTimer: Timer?

    /// Called once when the run ends, with the result (saved to History straight away).
    var onFinish: ((FinishedRun) -> Void)?
    /// Called when the workout part ends and keep-tracking starts (saved straight away too).
    var onWorkoutDone: ((FinishedRun) -> Void)?
    /// Called every few seconds during the run with the run so far, so it survives the app
    /// being closed by iOS.
    var onCheckpoint: ((FinishedRun) -> Void)?

    init(config: RunConfig, options: CueOptions, gps useGps: Bool, keepTracking: Bool) {
        self.config = config
        self.options = options
        self.keepTracking = useGps && keepTracking
        if useGps {
            gps = GpsTracker(clock: { [weak self] in self?.currentTime ?? 0 })
            location = LocationFeed()
        }
    }

    /// Seconds into the workout (pauses don't count).
    var currentTime: Double {
        if let r = result { return r.doneSec + r.extraSec }
        if overtime { return Double(end) + extraTime }
        return min(player?.currentTime ?? 0, Double(end))
    }

    /// Seconds tracked since the workout ended (pauses don't count).
    var extraTime: Double {
        otBase + (otResumedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var finished: Bool { result != nil }

    func prepare() async {
        guard !ready, loadError == nil else { return }
        let wk = config.wk, opts = options
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try AudioRender.renderWorkout(wk, opts)
            }.value
            segs = prepared.segs
            end = prepared.end
            try AudioRender.activateSession()
            let p = try AVAudioPlayer(contentsOf: prepared.url)
            delegate.onFinish = { [weak self] _ in
                MainActor.assumeIsolated { self?.workoutEnded() }
            }
            p.delegate = delegate
            p.prepareToPlay()
            player = p
            observeInterruptions()
            ready = true
            resume()
            startGps()
            checkpointTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkpoint() }
            }
        } catch {
            loadError = "Couldn’t prepare the voice cues: \(error.localizedDescription)"
        }
    }

    private func startGps() {
        guard let gps, let location else { return }
        location.onFix = { [weak self] l in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                self.gps?.onFix(GpsFix(
                    lat: l.coordinate.latitude, lng: l.coordinate.longitude,
                    accuracy: l.horizontalAccuracy >= 0 ? l.horizontalAccuracy : nil,
                    timestamp: l.timestamp.timeIntervalSince1970 * 1000))
            }
        }
        location.onDenied = { [weak self] in MainActor.assumeIsolated { self?.gps?.onError(denied: true) } }
        location.onError = { [weak self] in MainActor.assumeIsolated { self?.gps?.onError(denied: false) } }
        gps.start()
        location.start()
    }

    private func observeInterruptions() {
        interruptObs = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.handleInterruption(AVAudioSession.InterruptionType(rawValue: raw),
                                         AVAudioSession.InterruptionOptions(rawValue: optRaw))
            }
        }
    }

    /// A phone call (or similar) stops the audio: pause the workout, and carry on afterwards.
    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, _ opts: AVAudioSession.InterruptionOptions) {
        guard !finished, !overtime else { return }
        if type == .began {
            resumeAfterInterruption = !paused
            pause()
        } else if type == .ended, resumeAfterInterruption, opts.contains(.shouldResume) {
            resumeAfterInterruption = false
            resume()
        }
    }

    func toggle() { paused ? resume() : pause() }

    func pause() {
        guard !finished, !paused else { return }
        if overtime {
            otBase = extraTime
            otResumedAt = nil
        } else {
            player?.pause()
        }
        pausedAt = Date()
        paused = true
        gps?.setPaused(true)
        checkpoint()
    }

    func resume() {
        guard !finished else { return }
        if overtime {
            otResumedAt = Date()
        } else {
            guard let player else { return }
            try? AudioRender.activateSession()
            player.play()
        }
        pausedAt = nil
        paused = false
        gps?.setPaused(false)
    }

    /// The run as it stands, `doneSec` seconds in.
    private func snapshot(_ doneSec: Double) -> FinishedRun {
        let runs = segs.filter { $0.type == .run }
        let mainDone = runs.last.map { doneSec >= Double($0.end) - 3 } ?? (doneSec >= Double(end) - 3)
        return FinishedRun(
            historyId: id.uuidString, config: config, startedAt: startedAt, end: end, doneSec: doneSec,
            extraSec: overtime ? extraTime : 0, gps: gps?.summary(), mainDone: mainDone, completedDefault: mainDone || doneSec >= Double(end) * 0.75)
    }

    private func checkpoint() {
        guard ready, !finished, currentTime >= 1 else { return }
        if overtime && autoStop() { return }
        onCheckpoint?(snapshot(overtime ? Double(end) : currentTime))
    }

    /// The cue track has played to the end: keep tracking, or finish.
    private func workoutEnded() {
        guard ready, !finished, !overtime else { return }
        let status = gps?.status
        guard keepTracking, status != .denied, status != .unavailable else { finish(reachedEnd: true); return }
        // The track runs a little past the workout (the final message): count that as extra.
        otBase = max(0, (player?.duration ?? Double(end)) - Double(end))
        otResumedAt = paused ? nil : Date()
        player?.stop()
        player = nil
        if let o = interruptObs { NotificationCenter.default.removeObserver(o) }
        interruptObs = nil
        AudioRender.deactivateSession() // location updates keep the app running from here
        overtime = true
        onWorkoutDone?(snapshot(Double(end)))
    }

    /// Ends keep-tracking by itself: standing still for a while (she's home), paused for
    /// long, or very long overall. Standing-still time at the end isn't counted.
    private func autoStop() -> Bool {
        if paused {
            if let p = pausedAt, Date().timeIntervalSince(p) > RunEngine.PAUSED_STOP {
                finish(reachedEnd: true)
                return true
            }
            return false
        }
        let lastMove = max(gps?.pts.last?.t ?? 0, Double(end))
        let still = currentTime - lastMove
        guard still > RunEngine.STILL_STOP || extraTime > RunEngine.MAX_EXTRA else { return false }
        if still > RunEngine.STILL_STOP {
            otBase = max(0, lastMove - Double(end))
            otResumedAt = nil
        }
        finish(reachedEnd: true)
        return true
    }

    func finish(reachedEnd: Bool) {
        guard result == nil, ready else { return }
        let doneSec = reachedEnd || overtime ? Double(end) : currentTime
        stopEverything()
        paused = true
        let r = snapshot(doneSec)
        result = r
        onFinish?(r)
    }

    private func stopEverything() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        player?.stop()
        location?.stop()
        if let o = interruptObs { NotificationCenter.default.removeObserver(o) }
        interruptObs = nil
        AudioRender.deactivateSession()
    }

    /// Closing the run screen without a result (e.g. the cues failed to load).
    func abandon() { stopEverything() }
}
