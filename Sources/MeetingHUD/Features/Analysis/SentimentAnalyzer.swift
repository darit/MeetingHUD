import Foundation

/// Batched LLM-based sentiment analysis for transcript segments.
struct SentimentAnalyzer: Sendable {

    /// Analyze sentiment for a batch of segments using the LLM.
    /// Returns a mapping of segment ID → sentiment score (-1.0 to 1.0).
    func analyze(
        segments: [TranscriptSegment],
        using provider: any LLMProvider
    ) async throws -> [UUID: Double] {
        guard !segments.isEmpty else { return [:] }

        // Process in batches of 5
        var result: [UUID: Double] = [:]
        let batchSize = 5

        for batchStart in stride(from: 0, to: segments.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, segments.count)
            let batch = Array(segments[batchStart..<batchEnd])

            let scores = try await analyzeBatch(batch, using: provider)
            for (key, value) in scores {
                result[key] = value
            }
        }

        return result
    }

    private func analyzeBatch(
        _ batch: [TranscriptSegment],
        using provider: any LLMProvider
    ) async throws -> [UUID: Double] {
        let messages = [
            ChatMessage(role: .system, content: PromptTemplates.batchedSentimentAnalysis),
            ChatMessage(role: .user, content: PromptTemplates.batchedSentimentPrompt(segments: batch))
        ]

        let fullResponse = try await provider.collectResponse(messages: messages)
        let parsed = try LLMJSONParser.extract([SentimentEntry].self, from: fullResponse)

        var result: [UUID: Double] = [:]
        for entry in parsed {
            let index = entry.index - 1  // 1-indexed from prompt
            if index >= 0, index < batch.count {
                result[batch[index].id] = max(-1.0, min(1.0, entry.sentiment))
            }
        }

        return result
    }
}

private struct SentimentEntry: Decodable {
    let index: Int
    let sentiment: Double
}
