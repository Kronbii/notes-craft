#if NOTESCRAFT_DEV
// Development builds only (see Package.swift).
import AVFoundation
import Foundation
import NotesCraftCore
import os

/// On-device test of transcription (scenario `transcribe`): the iPad speaks a
/// sentence into an audio file, transcribes it, and the transcript is checked in
/// the engine, in Find, in the panel and in playback. Logs "NCTRANSCRIBE ...".
enum TranscriptionTest {
    static let logger = Logger(subsystem: "com.kronbii.NotesCraft", category: "transcribe")
    private static var passed = 0
    private static var failed = 0

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        let d = detail()
        logger.error("NCTRANSCRIBE \(ok ? "PASS" : "FAIL", privacy: .public) \(name, privacy: .public) \(d, privacy: .public)")
    }

    static let sentence = "Entropy never decreases in an isolated system. The professor said the exam is on Thursday morning."

    static func run() async {
        passed = 0
        failed = 0
        let library = LibraryStore.shared
        let title = Tour.tourPrefix + "Transcription"
        library.deletePermanently(library.index.notebooks.filter { $0.title == title }.map(\.id))
        do {
            // 1. The engine on its own.
            let speech = FileManager.default.temporaryDirectory.appendingPathComponent("nc-speech-\(UUID().uuidString).caf")
            let duration = try await synthesize(sentence, to: speech)
            check(duration > 2, "synthesized", String(format: "%.1fs", duration))
            let started = Date()
            let transcript = try await SpeechEngine.transcribe(file: speech, locale: Locale(identifier: "en_US"), duration: duration) { _, _ in }
            let text = transcript.text.lowercased()
            let heard = ["entropy", "isolated", "system", "professor", "exam", "thursday"].filter { text.contains($0) }
            check(heard.count >= 4, "engine.words", "\"\(transcript.text)\" in \(Int(Date().timeIntervalSince(started)))s")
            check(transcript.segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.start <= duration + 1 }, "engine.times",
                  transcript.segments.map { String(format: "%.1f-%.1f", $0.start, $0.end) }.joined(separator: " "))

            // 2. In a notebook: transcribed from the recording, shown, found and played.
            let meta = try library.createNotebook(title: title, paper: PaperStyle(kind: .collegeRuled), cover: .design(color: .ocean, pattern: .plain), folder: nil)
            guard let editor = await Tour.open("Transcription") else {
                check(false, "open")
                return
            }
            let asset = "rec-\(UUID().uuidString).caf"
            try FileManager.default.copyItem(at: speech, to: editor.document.assets.url(for: asset))
            let recording = Recording(asset: asset, title: "Lecture 1", createdAt: Date().addingTimeInterval(-60), duration: duration,
                                      segments: [.init(wallStart: Date().addingTimeInterval(-60), mediaStart: 0, duration: duration)])
            editor.document.content.recordings.append(recording)
            editor.document.markContentChanged()
            editor.selectedRecordingID = recording.id
            editor.showAudioBar = true
            editor.showTranscript = true
            editor.transcribe(recording.id)
            check(editor.transcriptionStatus[recording.id] != nil, "queued")
            await Automation.wait(0.6)
            await Automation.shot("transcript-working")
            for _ in 0 ..< 240 where editor.transcriptionStatus[recording.id] != nil {
                await Automation.wait(0.25)
            }
            let stored = editor.document.content.recordings.first { $0.id == recording.id }?.transcript
            check(stored != nil, "stored", editor.transcriptionStatus[recording.id].map { "\($0)" } ?? "")
            await Automation.wait(0.8)
            await Automation.shot("transcript-panel")

            // Tap a line: playback jumps there.
            if let line = stored?.segments.last {
                editor.playRecording(recording.id, at: line.start)
                await Automation.wait(0.7)
                check(editor.audio.playingID == recording.id && abs(editor.audio.playTime - line.start) < 1.5, "tapLinePlays",
                      String(format: "%.1f vs %.1f", editor.audio.playTime, line.start))
                await Automation.shot("transcript-playing")
                editor.audio.pause()
            }

            // Find lists it under Recordings, and choosing it plays from there.
            editor.showFind = true
            editor.findQuery = "thursday"
            editor.runFind()
            for _ in 0 ..< 20 where editor.isSearching { await Automation.wait(0.2) }
            await Automation.wait(0.4)
            let hit = editor.findResults.first { $0.source == .transcript }
            check(hit != nil, "findListsTranscript", "\(editor.findResults.count) results")
            await Automation.shot("find-transcript")
            if let hit {
                editor.showFindResult(hit)
                await Automation.wait(0.6)
                check(editor.audio.playingID == recording.id, "findResultPlays")
                editor.audio.pause()
            }
            editor.clearFind()
            editor.showFind = false

            // Saved with the notebook, and searchable from the library.
            editor.saveNow()
            await DiskWriter.shared.flush()
            let reopened = try await NotebookDocument.open(id: meta.id)
            check(reopened.content.recordings.first?.transcript?.text == stored?.text, "savedWithNotebook")
            let hits = library.search.search("thursday", in: [meta])
            check(hits.contains { $0.source == .transcript }, "librarySearch", "\(hits.map(\.source.rawValue))")
            editor.closeAudioBar()
            editor.showTranscript = false
            await Tour.closeEditorIfOpen()
            library.deletePermanently([meta.id])
        } catch {
            check(false, "run", error.localizedDescription)
        }
        logger.error("NCTRANSCRIBE INFO done passed=\(passed, privacy: .public) failed=\(failed, privacy: .public)")
    }

    /// Speaks `text` into an audio file with the system voice; returns its length.
    static func synthesize(_ text: String, to url: URL) async throws -> TimeInterval {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let sink = AudioSink(url: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sink.continuation = continuation
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    sink.finish(nil)
                } else {
                    sink.append(pcm)
                }
            }
            // Never wait forever if the last (empty) buffer doesn't come.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { sink.finish(nil) }
        }
        withExtendedLifetime(synthesizer) {}
        return sink.duration
    }

    nonisolated private final class AudioSink: @unchecked Sendable {
        let url: URL
        private let lock = NSLock()
        private var file: AVAudioFile?
        private var frames: AVAudioFramePosition = 0
        private var sampleRate: Double = 1
        private var done = false
        var continuation: CheckedContinuation<Void, any Error>?

        init(url: URL) { self.url = url }

        var duration: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Double(frames) / sampleRate
        }

        func append(_ pcm: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    sampleRate = pcm.format.sampleRate
                }
                try file?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            } catch {
                done = true
                file = nil
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }

        func finish(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            file = nil // closes the file
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
            continuation = nil
        }
    }
}
#endif
