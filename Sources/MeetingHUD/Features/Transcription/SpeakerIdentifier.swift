import Accelerate
import Foundation
import SwiftData

/// Identifies speakers by comparing voice embeddings against known Interlocutor profiles.
///
/// When a new audio segment arrives, its embedding is compared to stored profiles.
/// If a match is found (cosine similarity above threshold), the known name is returned.
/// Otherwise, a temporary "Speaker N" label is assigned.
@Observable
final class SpeakerIdentifier {
    // MARK: - State

    /// Currently active speaker profiles for this session.
    var activeSpeakers: [SpeakerProfile] = []

    /// Known profiles loaded from SwiftData at session start.
    private var knownProfiles: [KnownProfile] = []

    /// Similarity threshold for matching a voice to a known profile.
    var matchThreshold: Float = 0.82

    // MARK: - Types

    struct SpeakerProfile: Identifiable {
        let id: UUID
        var name: String
        var embeddings: [[Float]]  // Multiple embeddings for robustness
        var interlocutorID: UUID?  // Links to persisted Interlocutor if matched
    }

    /// A known profile loaded from SwiftData for matching.
    struct KnownProfile {
        let interlocutorID: UUID
        let name: String
        let embeddings: [[Float]]
    }

    // MARK: - Profile Loading

    /// Load known profiles in the format expected by RealTimeSpeakerDetector.
    func loadKnownProfilesForDetector(from modelContainer: ModelContainer) -> [(name: String, embeddings: [[Float]])] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Interlocutor>()
        guard let interlocutors = try? context.fetch(descriptor) else { return [] }

        return interlocutors.compactMap { interlocutor in
            let embeddings = interlocutor.voiceEmbeddings.compactMap { deserializeEmbedding($0) }
            guard !embeddings.isEmpty else { return nil }
            return (name: interlocutor.name, embeddings: embeddings)
        }
    }

    /// Load all known Interlocutor profiles with voice embeddings from SwiftData.
    /// Call this at session start before any identification.
    func loadKnownProfiles(from modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Interlocutor>()
        guard let interlocutors = try? context.fetch(descriptor) else { return }

        knownProfiles = interlocutors.compactMap { interlocutor in
            let embeddings = interlocutor.voiceEmbeddings.compactMap { deserializeEmbedding($0) }
            guard !embeddings.isEmpty else { return nil }
            return KnownProfile(
                interlocutorID: interlocutor.id,
                name: interlocutor.name,
                embeddings: embeddings
            )
        }
    }

    // MARK: - Speaker Matching

    /// Match an audio segment's voice embedding to a known speaker or create a new one.
    ///
    /// - Parameter embedding: Voice embedding vector extracted from the audio segment.
    /// - Returns: The matched or newly created speaker profile.
    func identifySpeaker(embedding: [Float]) -> SpeakerProfile {
        // First, try to match against active session speakers
        var bestMatch: SpeakerProfile?
        var bestScore: Float = 0

        for speaker in activeSpeakers {
            let score = maxSimilarity(embedding: embedding, against: speaker.embeddings)
            if score > bestScore {
                bestScore = score
                bestMatch = speaker
            }
        }

        // Return match if above threshold
        if let match = bestMatch, bestScore >= matchThreshold {
            return match
        }

        // Try to match against known profiles from SwiftData
        var bestKnownScore: Float = 0
        var bestKnownProfile: KnownProfile?

        for profile in knownProfiles {
            let score = maxSimilarity(embedding: embedding, against: profile.embeddings)
            if score > bestKnownScore {
                bestKnownScore = score
                bestKnownProfile = profile
            }
        }

        if let known = bestKnownProfile, bestKnownScore >= matchThreshold {
            // Auto-identify from known profile
            let speaker = SpeakerProfile(
                id: UUID(),
                name: known.name,
                embeddings: [embedding],
                interlocutorID: known.interlocutorID
            )
            activeSpeakers.append(speaker)
            return speaker
        }

        // Create a new unknown speaker
        let newSpeaker = SpeakerProfile(
            id: UUID(),
            name: "Speaker \(activeSpeakers.count + 1)",
            embeddings: [embedding],
            interlocutorID: nil
        )
        activeSpeakers.append(newSpeaker)
        return newSpeaker
    }

    /// Match active speaker clusters against known Interlocutor profiles.
    /// Called after live diarization to auto-label recognized speakers.
    ///
    /// - Returns: Dictionary of diarization label → known name for matched speakers.
    func matchClustersAgainstKnownProfiles() -> [String: String] {
        var labelMapping: [String: String] = [:]

        for i in activeSpeakers.indices {
            guard activeSpeakers[i].interlocutorID == nil else {
                // Already matched
                labelMapping[activeSpeakers[i].name] = activeSpeakers[i].name
                continue
            }

            var bestScore: Float = 0
            var bestProfile: KnownProfile?

            for profile in knownProfiles {
                // Skip profiles already matched to another active speaker
                if activeSpeakers.contains(where: { $0.interlocutorID == profile.interlocutorID }) {
                    continue
                }

                let score = maxSimilarity(
                    embedding: activeSpeakers[i].embeddings.first ?? [],
                    against: profile.embeddings
                )
                if score > bestScore {
                    bestScore = score
                    bestProfile = profile
                }
            }

            if let profile = bestProfile, bestScore >= matchThreshold {
                let oldName = activeSpeakers[i].name
                activeSpeakers[i].name = profile.name
                activeSpeakers[i].interlocutorID = profile.interlocutorID
                labelMapping[oldName] = profile.name
            }
        }

        return labelMapping
    }

    /// Attempt to match active speakers against persisted Interlocutor profiles.
    ///
    /// - Parameter interlocutors: Known Interlocutors with stored voice embeddings.
    func matchAgainstKnownProfiles(_ interlocutors: [Interlocutor]) {
        for interlocutor in interlocutors {
            let knownEmbeddings = interlocutor.voiceEmbeddings.compactMap { data -> [Float]? in
                deserializeEmbedding(data)
            }
            guard !knownEmbeddings.isEmpty else { continue }

            for i in activeSpeakers.indices {
                guard activeSpeakers[i].interlocutorID == nil else { continue }

                let score = maxSimilarity(
                    embedding: activeSpeakers[i].embeddings.first ?? [],
                    against: knownEmbeddings
                )
                if score >= matchThreshold {
                    activeSpeakers[i].name = interlocutor.name
                    activeSpeakers[i].interlocutorID = interlocutor.id
                }
            }
        }
    }

    /// Reset all session state.
    func reset() {
        activeSpeakers.removeAll()
    }

    // MARK: - Embedding Math

    /// Cosine similarity between two vectors using Accelerate.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return dotProduct / denominator
    }

    /// Best cosine similarity of `embedding` against a set of reference embeddings.
    private func maxSimilarity(embedding: [Float], against references: [[Float]]) -> Float {
        references.map { cosineSimilarity(embedding, $0) }.max() ?? 0
    }

    /// Deserialize a Data blob into a Float array (voice embedding).
    func deserializeEmbedding(_ data: Data) -> [Float]? {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return nil }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    /// Serialize a Float array into Data for storage.
    static func serializeEmbedding(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBytes { Data($0) }
    }
}
