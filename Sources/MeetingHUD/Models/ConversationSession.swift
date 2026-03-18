import Foundation
import SwiftData

/// A continuous audio capture session — the base unit of all recorded conversations.
/// A Meeting is a special case: a ConversationSession that was elevated when a meeting app
/// was detected. Ambient conversations remain as plain ConversationSessions.
@Model
final class ConversationSession {
    var id: UUID
    var startDate: Date
    var endDate: Date?
    var title: String

    /// Source type for this session.
    /// - "ambient": background capture, no meeting app detected
    /// - "meeting": elevated, meeting app was active
    /// - "call": phone/FaceTime call (future)
    var sourceType: String

    /// AI-generated summary of the conversation.
    var summary: String

    /// Compressed transcript blob (zlib-compressed JSON of TranscriptSegment arrays).
    var compressedTranscript: Data?

    /// Optional link to a Meeting when this session was elevated.
    var meeting: Meeting?

    /// Participants detected in this session.
    @Relationship(deleteRule: .cascade)
    var participations: [MeetingParticipation]

    /// Topics discussed during this session.
    @Relationship(deleteRule: .cascade)
    var topics: [Topic]

    init(
        sourceType: String = "ambient",
        title: String = ""
    ) {
        self.id = UUID()
        self.startDate = .now
        self.endDate = nil
        self.title = title
        self.sourceType = sourceType
        self.summary = ""
        self.compressedTranscript = nil
        self.meeting = nil
        self.participations = []
        self.topics = []
    }
}
