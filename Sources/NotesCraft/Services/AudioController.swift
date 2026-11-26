import AVFoundation
import Foundation
import NotesCraftCore
import Observation
import UIKit

/// Records lectures into the open notebook and plays them back.
@Observable
final class AudioController: NSObject {
    enum RecordState: Equatable { case idle, recording, paused }

    private(set) var recordState: RecordState = .idle
    private(set) var recordElapsed: TimeInterval = 0
    private(set) var recordLevel: Float = 0

    private(set) var playingID: UUID?
    private(set) var isPlaying = false
    private(set) var playTime: TimeInterval = 0
    private(set) var playDuration: TimeInterval = 0
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    /// Called with each playback position update (about 20 times a second).
    @ObservationIgnored var onPlaybackTime: ((TimeInterval) -> Void)?
    /// Called when recording starts, periodically while it runs, and when it
    /// finishes, with the recording as it stands (same id each time), so the
    /// notebook always knows about the audio even if the app is killed.
    @ObservationIgnored var onRecordingUpdated: ((Recording) -> Void)?
    /// Called when a recording finishes.
    @ObservationIgnored var onRecordingFinished: ((Recording) -> Void)?
    /// Called when a too-short recording is thrown away.
    @ObservationIgnored var onRecordingDiscarded: ((UUID) -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored var onPlaybackEnded: (() -> Void)?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var segments: [Recording.Segment] = []
    @ObservationIgnored private var segmentStart: (wall: Date, media: TimeInterval)?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordingAsset = ""
    @ObservationIgnored private var recordingCreated = Date()
    @ObservationIgnored private var recordingID = UUID()
    @ObservationIgnored private var lastProgressReport: TimeInterval = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let assetsFolder: URL

    init(assetsFolder: URL) {
        self.assetsFolder = assetsFolder
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                if type == .began {
                    if self.recordState == .recording { self.pauseRecording() }
                    if self.isPlaying { self.pause() }
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones unplugged: pause playback like every audio app does.
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, self?.isPlaying == true {
                    self?.pause()
                }
            }
        })
    }

    func tearDown() {
        if recordState != .idle { stopRecording() }
        stopPlayback()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        timer?.invalidate()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Recording

    var isRecordingActive: Bool { recordState != .idle }

    func startRecording() {
        guard recordState == .idle else { return }
        stopPlayback()
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.onError?("NotesCraft needs microphone access to record. You can turn it on in Settings › Privacy › Microphone.")
                }
            }
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
            // CAF stays readable even if the app is killed mid-recording.
            recordingID = UUID()
            recordingAsset = "rec-\(recordingID.uuidString).caf"
            let url = assetsFolder.appendingPathComponent(recordingAsset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 64000,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.delegate = self
            guard rec.record() else {
                onError?("Recording couldn't start. Another app may be using the microphone.")
                return
            }
            recorder = rec
            recordingURL = url
            recordingCreated = Date()
            segments = []
            segmentStart = (Date(), 0)
            recordElapsed = 0
            recordState = .recording
            UIApplication.shared.isIdleTimerDisabled = true
            lastProgressReport = 0
            startTimer()
            onRecordingUpdated?(liveRecording(mediaNow: 0))
            Haptics.success()
        } catch {
            onError?("Recording couldn't start: \(error.localizedDescription)")
        }
    }

    func pauseRecording() {
        guard recordState == .recording, let recorder else { return }
        closeSegment(mediaNow: recorder.currentTime)
        recorder.pause()
        recordState = .paused
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resumeRecording() {
        guard recordState == .paused, let recorder else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let media = recorder.currentTime
        guard recorder.record() else {
            onError?("Recording couldn't resume.")
            return
        }
        segmentStart = (Date(), media)
        recordState = .recording
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stopRecording() {
        guard recordState != .idle, let recorder else { return }
        let duration = recorder.currentTime
        if recordState == .recording { closeSegment(mediaNow: duration) }
        recorder.stop()
        self.recorder = nil
        recordState = .idle
        UIApplication.shared.isIdleTimerDisabled = false
        timer?.invalidate()
        timer = nil
        let total = max(duration, segments.map { $0.mediaStart + $0.duration }.max() ?? 0)
        guard total > 0.3 else {
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            onRecordingDiscarded?(recordingID)
            return
        }
        var recording = liveRecording(mediaNow: total)
        recording.duration = total
        onRecordingFinished?(recording)
        Haptics.success()
    }

    /// The recording as it stands, including the segment in progress.
    private func liveRecording(mediaNow: TimeInterval) -> Recording {
        var segs = segments
        if let start = segmentStart {
            segs.append(Recording.Segment(wallStart: start.wall, mediaStart: start.media, duration: max(0, mediaNow - start.media)))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let total = max(mediaNow, segs.map { $0.mediaStart + $0.duration }.max() ?? 0)
        return Recording(id: recordingID, asset: recordingAsset, title: formatter.string(from: recordingCreated),
                         createdAt: recordingCreated, duration: total, segments: segs)
    }

    private func closeSegment(mediaNow: TimeInterval) {
        guard let start = segmentStart else { return }
        segments.append(Recording.Segment(wallStart: start.wall, mediaStart: start.media, duration: max(0, mediaNow - start.media)))
        segmentStart = nil
    }

    // MARK: - Playback

    func play(_ recording: Recording, from time: TimeInterval? = nil) {
        if recordState != .idle { return }
        if playingID != recording.id || player == nil {
            stopPlayback()
            let url = assetsFolder.appendingPathComponent(recording.asset)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let p = try AVAudioPlayer(contentsOf: url)
                p.enableRate = true
                p.rate = rate
                p.delegate = self
                p.prepareToPlay()
                player = p
                playingID = recording.id
                playDuration = p.duration
            } catch {
                onError?("This recording couldn't be played. The audio file may be missing.")
                return
            }
        }
        guard let player else { return }
        if let time { player.currentTime = min(max(0, time), player.duration) }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlay(_ recording: Recording) {
        if isPlaying, playingID == recording.id { pause() } else { play(recording) }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        playTime = player.currentTime
        onPlaybackTime?(playTime)
    }

    func skip(_ delta: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + delta)
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
        playTime = 0
        playDuration = 0
        if recordState == .idle {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        if let recorder, recordState != .idle {
            if tickCount % 4 == 0 { recordElapsed = recorder.currentTime }
            if recordState == .recording, recorder.currentTime - lastProgressReport > 5 {
                lastProgressReport = recorder.currentTime
                onRecordingUpdated?(liveRecording(mediaNow: recorder.currentTime))
            }
            recorder.updateMeters()
            let db = recorder.averagePower(forChannel: 0)
            recordLevel = max(0, min(1, (db + 50) / 50))
        }
        if let player {
            let t = player.currentTime
            if abs(t - playTime) > 0.01 {
                playTime = t
                onPlaybackTime?(t)
            }
        }
    }
}

extension AudioController: AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.playTime = self.playDuration
            self.onPlaybackTime?(self.playDuration)
            self.onPlaybackEnded?()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        Task { @MainActor [weak self] in
            self?.onError?("Recording failed: \(message)")
            self?.stopRecording()
        }
    }
}

extension TimeInterval {
    /// "4:05" or "1:02:03".
    var clock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
