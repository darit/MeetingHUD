import Foundation

/// A single segment of transcribed speech. Lives in memory during a meeting
/// and is compressed into Meeting.compressedTranscript when the meeting ends.
///
/// Not a SwiftData model -- these are transient, high-frequency objects.
struct TranscriptSegment: Identifiable, Codable, Sendable {
    let id: UUID
    var text: String
    var speakerLabel: String
    var speakerID: UUID?
    var startTime: TimeInterval
    var endTime: TimeInterval

    /// Sentiment score from NLP analysis (-1.0 = negative, 1.0 = positive).
    /// Nil if not yet analyzed.
    var sentiment: Double?

    init(
        text: String,
        speakerLabel: String,
        speakerID: UUID? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        sentiment: Double? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.speakerLabel = speakerLabel
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.sentiment = sentiment
    }

    /// Duration of this segment in seconds.
    var duration: TimeInterval {
        endTime - startTime
    }
}
