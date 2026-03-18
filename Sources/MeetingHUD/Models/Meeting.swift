import Foundation
import SwiftData

/// A single meeting session, from start to finish.
/// Stores compressed transcript, summary, and relationships to participants and extracted data.
@Model
final class Meeting {
    var id: UUID
    var date: Date
    var title: String
    var sourceApp: String
    var duration: TimeInterval

    /// AI-generated summary of the meeting.
    var summary: String

    /// Compressed transcript blob (zlib-compressed JSON of TranscriptSegment arrays).
    /// Keeps storage manageable for long meetings.
    var compressedTranscript: Data?

    /// Participants and their per-meeting stats.
    @Relationship(deleteRule: .cascade)
    var participations: [MeetingParticipation]

    /// Topics discussed during this meeting.
    @Relationship(deleteRule: .cascade)
    var topics: [Topic]

    /// Action items extracted from this meeting.
    @Relationship(deleteRule: .cascade)
    var actionItems: [ActionItem]

    init(
        title: String,
        sourceApp: String = "Unknown",
        date: Date = .now
    ) {
        self.id = UUID()
        self.date = date
        self.title = title
        self.sourceApp = sourceApp
        self.duration = 0
        self.summary = ""
        self.compressedTranscript = nil
        self.participations = []
        self.topics = []
        self.actionItems = []
    }
}
