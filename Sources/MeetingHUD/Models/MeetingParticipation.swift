import Foundation
import SwiftData

/// Junction model linking an Interlocutor to a Meeting with per-meeting analytics.
@Model
final class MeetingParticipation {
    var id: UUID

    /// The person who participated.
    var interlocutor: Interlocutor?

    /// The meeting they participated in.
    var meeting: Meeting?

    // MARK: - Speaking Analytics

    /// Total time this person spent speaking, in seconds.
    var talkTime: TimeInterval

    /// Percentage of total meeting talk time attributed to this person.
    var talkPercent: Double

    /// Number of times this person spoke (turn-taking count).
    var interventionCount: Int

    // MARK: - NLP Analytics

    /// Average sentiment score (-1.0 to 1.0).
    var avgSentiment: Double

    /// Vocabulary complexity score (type-token ratio or similar).
    var vocabularyComplexity: Double

    /// Ratio of questions to total statements.
    var questionRatio: Double

    /// Topics this person raised or contributed to.
    var topicsRaised: [String]

    /// Notable statements extracted by the LLM.
    var keyStatements: [String]

    init(interlocutor: Interlocutor? = nil, meeting: Meeting? = nil) {
        self.id = UUID()
        self.interlocutor = interlocutor
        self.meeting = meeting
        self.talkTime = 0
        self.talkPercent = 0
        self.interventionCount = 0
        self.avgSentiment = 0
        self.vocabularyComplexity = 0
        self.questionRatio = 0
        self.topicsRaised = []
        self.keyStatements = []
    }
}
