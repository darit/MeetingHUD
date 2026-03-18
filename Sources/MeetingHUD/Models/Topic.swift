import Foundation
import SwiftData

/// A topic or agenda item discussed during a meeting.
/// Extracted by the LLM from the transcript in real time.
@Model
final class Topic {
    var id: UUID
    var name: String

    /// Offset from meeting start when this topic began, in seconds.
    var startTime: TimeInterval

    /// Offset from meeting start when this topic ended. Nil if still active.
    var endTime: TimeInterval?

    /// AI-generated summary of the discussion on this topic.
    var summary: String

    /// The meeting this topic belongs to.
    var meeting: Meeting?

    init(
        name: String,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        summary: String = "",
        meeting: Meeting? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.summary = summary
        self.meeting = meeting
    }

    /// Duration of this topic in seconds. Nil if the topic is still active.
    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end - startTime
    }
}
