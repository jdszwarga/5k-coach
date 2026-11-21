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

    @Published private(set) var ready = false
    @Published private(set) var loadError: String?
    @Published private(set) var paused = true
    @Published private(set) var result: FinishedRun?

    private(set) var segs: [Segment] = []
    private(set) var end = 0
    private(set) var gps: GpsTracker?
    private var location: LocationFeed?
    private var player: AVAudioPlayer?
    private let delegate = PlayerDelegate()
    private var interruptObs: NSObjectProtocol?
    private var resumeAfterInterruption = false

    init(config: RunConfig, options: CueOptions, gps useGps: Bool) {
        self.config = config
        self.options = options
        if useGps {
            gps = GpsTracker(clock: { [weak self] in self?.currentTime ?? 0 })
            location = LocationFeed()
        }
    }

    /// Seconds into the workout (pauses don't count).
    var currentTime: Double {
        if let r = result { return r.doneSec }
        return min(player?.currentTime ?? 0, Double(end))
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
                MainActor.assumeIsolated { self?.finish(reachedEnd: true) }
            }
            p.delegate = delegate
            p.prepareToPlay()
            player = p
            observeInterruptions()
            ready = true
            resume()
            startGps()
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
        guard !finished else { return }
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
        guard !finished else { return }
        player?.pause()
        paused = true
        gps?.setPaused(true)
    }

    func resume() {
        guard !finished, let player else { return }
        try? AudioRender.activateSession()
        player.play()
        paused = false
        gps?.setPaused(false)
    }

    func finish(reachedEnd: Bool) {
        guard result == nil, ready else { return }
        let doneSec = reachedEnd ? Double(end) : currentTime
        player?.stop()
        location?.stop()
        if let o = interruptObs { NotificationCenter.default.removeObserver(o) }
        AudioRender.deactivateSession()

        let runs = segs.filter { $0.type == .run }
        let mainDone = runs.last.map { doneSec >= Double($0.end) - 3 } ?? (doneSec >= Double(end) - 3)
        paused = true
        result = FinishedRun(
            config: config, startedAt: startedAt, end: end, doneSec: doneSec, gps: gps?.summary(),
            mainDone: mainDone, completedDefault: mainDone || doneSec >= Double(end) * 0.75)
    }

    /// Closing the run screen without a result (e.g. the cues failed to load).
    func abandon() {
        player?.stop()
        location?.stop()
        if let o = interruptObs { NotificationCenter.default.removeObserver(o) }
        AudioRender.deactivateSession()
    }
}
