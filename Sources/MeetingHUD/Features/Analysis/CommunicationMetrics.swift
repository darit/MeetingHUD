import Foundation

/// Pure-Swift communication metrics computed per speaker without LLM.
/// Maintains incremental state to avoid recomputing over all segments.
final class CommunicationMetrics: @unchecked Sendable {

    struct Stats: Sendable {
        /// Type-token ratio: unique words / total words. Higher = more varied vocabulary.
        let vocabularyComplexity: Double
        /// Fraction of segments ending with "?" (0.0 - 1.0).
        let questionRatio: Double
        /// Average word length in characters.
        let avgWordLength: Double
    }

    /// Per-speaker accumulator for incremental computation.
    private var accumulators: [String: SpeakerAccumulator] = [:]

    private struct SpeakerAccumulator {
        var totalWords: Int = 0
        var uniqueWords: Set<String> = []
        var totalWordLength: Int = 0
        var segmentCount: Int = 0
        var questionCount: Int = 0

        var stats: Stats {
            Stats(
                vocabularyComplexity: totalWords > 0
                    ? Double(uniqueWords.count) / Double(totalWords) : 0,
                questionRatio: segmentCount > 0
                    ? Double(questionCount) / Double(segmentCount) : 0,
                avgWordLength: totalWords > 0
                    ? Double(totalWordLength) / Double(totalWords) : 0
            )
        }
    }

    /// Incrementally update metrics with a single new segment. O(words in segment).
    func ingest(_ segment: TranscriptSegment) {
        var acc = accumulators[segment.speakerLabel] ?? SpeakerAccumulator()

        let words = segment.text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        acc.totalWords += words.count
        for word in words {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            if !cleaned.isEmpty {
                acc.uniqueWords.insert(cleaned)
                acc.totalWordLength += cleaned.count
            }
        }

        acc.segmentCount += 1
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") {
            acc.questionCount += 1
        }

        accumulators[segment.speakerLabel] = acc
    }

    /// Return current stats for all speakers. O(number of speakers).
    func currentStats() -> [String: Stats] {
        accumulators.mapValues(\.stats)
    }
}
