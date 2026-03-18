import Foundation
import SwiftData

/// A person the user has met with. Persists across meetings with accumulated
/// voice embeddings for automatic speaker identification.
@Model
final class Interlocutor {
    var id: UUID
    var name: String
    var role: String
    var company: String
    var email: String
    var notes: String
    var firstSeen: Date
    var lastSeen: Date

    /// Serialized voice embedding vectors for speaker identification.
    /// Each Data blob is a serialized [Float] array.
    var voiceEmbeddings: [Data]

    /// All meetings this person has participated in.
    @Relationship(inverse: \MeetingParticipation.interlocutor)
    var participations: [MeetingParticipation]

    /// Action items assigned to this person.
    @Relationship(inverse: \ActionItem.owner)
    var actionItems: [ActionItem]

    init(
        name: String,
        role: String = "",
        company: String = "",
        email: String = "",
        notes: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.role = role
        self.company = company
        self.email = email
        self.notes = notes
        self.firstSeen = .now
        self.lastSeen = .now
        self.voiceEmbeddings = []
        self.participations = []
        self.actionItems = []
    }

    /// Add a new voice embedding for future speaker matching.
    func addVoiceEmbedding(_ embedding: [Float]) {
        let data = embedding.withUnsafeBytes { Data($0) }
        voiceEmbeddings.append(data)
    }
}
