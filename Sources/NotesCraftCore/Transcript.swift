import Foundation

/// What was said in a recording, as timed segments (sentences or phrases),
/// made on the iPad by the speech engine.
public struct Transcript: Codable, Hashable, Sendable {
    public struct Segment: Codable, Hashable, Sendable {
        /// Seconds into the recording's audio file.
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var segments: [Segment]
    /// Language the transcript was made in (a locale identifier such as "en_US").
    public var locale: String
    public var createdAt: Date

    public init(segments: [Segment], locale: String, createdAt: Date = Date()) {
        self.segments = Transcript.cleaned(segments)
        self.locale = locale
        self.createdAt = createdAt
    }

    /// The whole transcript as one text (for search and copying).
    public var text: String { segments.map(\.text).joined(separator: " ") }

    public var isEmpty: Bool { segments.isEmpty }

    /// The segment being heard at `time`: the last one that has started by then.
    public func segmentIndex(at time: Double) -> Int? {
        guard !segments.isEmpty, time >= segments[0].start - 0.05 else { return nil }
        var lo = 0, hi = segments.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= time + 0.05 {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// Groups timed words into readable segments: a new one after a sentence
    /// ends, after a pause, or once a segment gets long.
    public static func segments(fromWords words: [(text: String, start: Double, end: Double)],
                                pause: Double = 1.2, maxWords: Int = 40) -> [Segment] {
        var out: [Segment] = []
        var current: [String] = []
        var start = 0.0, end = 0.0
        func flush() {
            let text = current.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(Segment(start: start, end: end, text: text)) }
            current = []
        }
        for word in words {
            let w = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { continue }
            if !current.isEmpty, word.start - end > pause || current.count >= maxWords { flush() }
            if current.isEmpty { start = word.start }
            current.append(w)
            end = max(end, word.end)
            if let last = w.last, ".?!…".contains(last) { flush() }
        }
        flush()
        return out
    }

    /// Trimmed, non-empty segments in time order with sane times.
    public static func cleaned(_ segments: [Segment]) -> [Segment] {
        segments
            .map { s in
                Segment(start: max(0, s.start.isFinite ? s.start : 0),
                        end: max(s.end.isFinite ? s.end : 0, s.start.isFinite ? s.start : 0),
                        text: s.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
    }
}
