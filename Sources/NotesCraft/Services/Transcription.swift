import AVFoundation
import CoreMedia
import Foundation
import NotesCraftCore
import Speech

/// Where a recording's transcription stands.
enum TranscriptionStatus: Equatable {
    case waiting
    case downloading(Double)
    case working(Double)
    case failed(String)
}

/// Why a recording couldn't be transcribed, in words for the user.
enum TranscriptionError: LocalizedError {
    case unsupportedLanguage(String)
    case unavailable
    case notAuthorized
    case nothingHeard
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(name): "Transcription isn't available in \(name) on this iPad."
        case .unavailable: "Speech recognition isn't available on this iPad right now."
        case .notAuthorized: "NotesCraft isn't allowed to use speech recognition. You can allow it in Settings › NotesCraft."
        case .nothingHeard: "No speech was found in this recording."
        case let .failed(message): message
        }
    }
}

/// Transcribes recordings on the iPad. Audio never leaves the device: iPadOS 26
/// uses the new on-device speech engine (its language model is downloaded from
/// Apple once), earlier versions the classic on-device recognizer.
nonisolated enum SpeechEngine {
    /// Progress: a fraction, and whether it is still downloading the language model.
    typealias ProgressHandler = @Sendable (_ fraction: Double, _ downloading: Bool) -> Void

    static func transcribe(file: URL, locale: Locale, duration: TimeInterval, progress: @escaping ProgressHandler) async throws -> Transcript {
        if #available(iOS 26, *) {
            do {
                return try await analyze(file: file, locale: locale, duration: duration, progress: progress)
            } catch let error as TranscriptionError {
                throw error
            } catch {
                // Permission may be what's missing; ask once and try again.
                if SFSpeechRecognizer.authorizationStatus() == .notDetermined, await requestAuthorization() {
                    return try await analyze(file: file, locale: locale, duration: duration, progress: progress)
                }
                throw TranscriptionError.failed(error.localizedDescription)
            }
        }
        return try await recognize(file: file, locale: locale, duration: duration, progress: progress)
    }

    /// Languages the iPad can transcribe.
    static func supportedLocales() async -> [Locale] {
        if #available(iOS 26, *) {
            let locales = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : await DictationTranscriber.supportedLocales
            return locales.sorted { name($0) < name($1) }
        }
        return SFSpeechRecognizer.supportedLocales().filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .sorted { name($0) < name($1) }
    }

    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: iPadOS 26: SpeechAnalyzer

    @available(iOS 26, *)
    private static func analyze(file: URL, locale: Locale, duration: TimeInterval, progress: @escaping ProgressHandler) async throws -> Transcript {
        let audio = try AVAudioFile(forReading: file)
        if SpeechTranscriber.isAvailable {
            guard let chosen = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw TranscriptionError.unsupportedLanguage(name(locale))
            }
            let module = SpeechTranscriber(locale: chosen, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await installModel(for: module, progress: progress)
            let collector = Task {
                var segments: [Transcript.Segment] = []
                for try await result in module.results where result.isFinal {
                    let text = String(result.text.characters)
                    segments.append(Transcript.Segment(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
                    progress(min(1, result.range.end.seconds / max(duration, 1)), false)
                }
                return segments
            }
            try await run(SpeechAnalyzer(modules: [module]), on: audio, collector: collector)
            return try await finish(collector, locale: chosen)
        }
        // iPads without the full model: the dictation model, time-indexed.
        guard let chosen = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLanguage(name(locale))
        }
        let module = DictationTranscriber(locale: chosen, preset: .timeIndexedLongDictation)
        try await installModel(for: module, progress: progress)
        let collector = Task {
            var segments: [Transcript.Segment] = []
            for try await result in module.results where result.isFinal {
                let text = String(result.text.characters)
                segments.append(Transcript.Segment(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
                progress(min(1, result.range.end.seconds / max(duration, 1)), false)
            }
            return segments
        }
        try await run(SpeechAnalyzer(modules: [module]), on: audio, collector: collector)
        return try await finish(collector, locale: chosen)
    }

    /// Downloads the language model from Apple the first time it is needed.
    @available(iOS 26, *)
    private static func installModel(for module: any SpeechModule, progress: @escaping ProgressHandler) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        progress(0, true)
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted, true)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(0, false)
    }

    @available(iOS 26, *)
    private static func run(_ analyzer: SpeechAnalyzer, on audio: AVAudioFile, collector: Task<[Transcript.Segment], any Error>) async throws {
        do {
            if let end = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func finish(_ collector: Task<[Transcript.Segment], any Error>, locale: Locale) async throws -> Transcript {
        let transcript = Transcript(segments: try await collector.value, locale: locale.identifier)
        if transcript.isEmpty { throw TranscriptionError.nothingHeard }
        return transcript
    }

    // MARK: Earlier iPadOS: SFSpeechRecognizer, on device

    private static func recognize(file: URL, locale: Locale, duration: TimeInterval, progress: @escaping ProgressHandler) async throws -> Transcript {
        guard await requestAuthorization() else { throw TranscriptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriptionError.unsupportedLanguage(name(locale)) }
        guard recognizer.isAvailable else { throw TranscriptionError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: file)
        // Never send audio to a server.
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.unsupportedLanguage(name(locale)) }
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        progress(0, false)
        let once = Once()
        let words: [(text: String, start: Double, end: Double)] = try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if once.claim() { continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription)) }
                    return
                }
                guard let result, result.isFinal else { return }
                let words = result.bestTranscription.segments.map { (text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
                if once.claim() { continuation.resume(returning: words) }
            }
        }
        let transcript = Transcript(segments: Transcript.segments(fromWords: words), locale: recognizer.locale.identifier)
        if transcript.isEmpty { throw TranscriptionError.nothingHeard }
        return transcript
    }

    /// Lets a callback resume a continuation only once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

/// A weak reference that can be handed to code running elsewhere; read it on the main actor.
nonisolated final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}
