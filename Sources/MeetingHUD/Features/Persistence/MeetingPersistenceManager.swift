import Foundation
import SwiftData

/// Per-speaker stats computed from transcript segments after a meeting ends.
struct SpeakerStats: Sendable {
    let talkTime: TimeInterval
    let interventionCount: Int
}

/// Handles persisting meetings, interlocutors, and participation records to SwiftData.
@MainActor
final class MeetingPersistenceManager {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    /// Save a completed meeting with transcript, speaker stats, analytics, interlocutor links,
    /// and optionally store voice embeddings for speaker profiles.
    func saveMeeting(
        _ meeting: Meeting,
        segments: [TranscriptSegment],
        speakerStats: [String: SpeakerStats],
        speakerToInterlocutor: [String: String],
        analytics: AnalyticsSnapshot? = nil,
        voiceEmbeddings: [String: [Float]]? = nil
    ) throws {
        // Compress transcript
        meeting.compressedTranscript = try compressTranscript(segments)
        meeting.duration = segments.last?.endTime ?? 0

        // Set meeting summary from analytics
        if let summary = analytics?.meetingSummary, !summary.isEmpty {
            meeting.summary = summary
        }

        modelContext.insert(meeting)

        // Total talk time for percentage calculation
        let totalTalkTime = speakerStats.values.reduce(0) { $0 + $1.talkTime }

        // Build a lookup for interlocutors by speaker label (for action item ownership)
        var interlocutorsByLabel: [String: Interlocutor] = [:]

        for (speakerLabel, stats) in speakerStats {
            let interlocutor: Interlocutor?
            if let name = speakerToInterlocutor[speakerLabel], !name.isEmpty {
                let found = try findOrCreateInterlocutor(name: name)
                interlocutor = found
                interlocutorsByLabel[speakerLabel] = found

                // Store voice embedding if available (Phase 2.2)
                if let embedding = voiceEmbeddings?[speakerLabel] {
                    let data = SpeakerIdentifier.serializeEmbedding(embedding)
                    // Keep at most 5 embeddings per interlocutor (most recent)
                    if found.voiceEmbeddings.count >= 5 {
                        found.voiceEmbeddings.removeFirst()
                    }
                    found.voiceEmbeddings.append(data)
                }
            } else {
                interlocutor = nil
            }

            let participation = MeetingParticipation(
                interlocutor: interlocutor,
                meeting: meeting
            )
            participation.talkTime = stats.talkTime
            participation.talkPercent = totalTalkTime > 0
                ? (stats.talkTime / totalTalkTime) * 100
                : 0
            participation.interventionCount = stats.interventionCount

            // Populate NLP fields from analytics
            if let speakerAnalytics = analytics?.perSpeaker[speakerLabel] {
                participation.avgSentiment = speakerAnalytics.avgSentiment
                participation.vocabularyComplexity = speakerAnalytics.vocabularyComplexity
                participation.questionRatio = speakerAnalytics.questionRatio
                participation.topicsRaised = speakerAnalytics.topicsRaised
                participation.keyStatements = speakerAnalytics.keyStatements
            }

            modelContext.insert(participation)
        }

        // Persist topics
        if let topicSnapshots = analytics?.topics {
            for snapshot in topicSnapshots {
                let topic = Topic(
                    name: snapshot.name,
                    startTime: snapshot.startTime,
                    endTime: snapshot.endTime,
                    summary: snapshot.summary,
                    meeting: meeting
                )
                modelContext.insert(topic)
            }
        }

        // Persist action items
        if let actionSnapshots = analytics?.actionItems {
            for snapshot in actionSnapshots {
                let owner = snapshot.ownerLabel.flatMap { interlocutorsByLabel[$0] }
                let actionItem = ActionItem(
                    desc: snapshot.description,
                    extractedFrom: snapshot.extractedFrom,
                    owner: owner,
                    meeting: meeting
                )
                modelContext.insert(actionItem)
            }
        }

        try modelContext.save()
    }

    /// Find an existing interlocutor by name, or create a new one.
    func findOrCreateInterlocutor(name: String) throws -> Interlocutor {
        let predicate = #Predicate<Interlocutor> { $0.name == name }
        var descriptor = FetchDescriptor<Interlocutor>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.lastSeen = .now
            return existing
        }

        let new = Interlocutor(name: name)
        modelContext.insert(new)
        return new
    }

    /// JSON-encode transcript segments and compress with zlib.
    private func compressTranscript(_ segments: [TranscriptSegment]) throws -> Data {
        let jsonData = try JSONEncoder().encode(segments)
        let nsData = jsonData as NSData
        return try nsData.compressed(using: .zlib) as Data
    }
}
