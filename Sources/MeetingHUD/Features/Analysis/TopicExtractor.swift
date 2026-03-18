import Foundation

/// Rolling-window topic detection via LLM.
struct TopicExtractor: Sendable {

    struct ExtractedTopic: Sendable {
        let name: String
        let summary: String
        let startTime: TimeInterval
    }

    /// Extract new topics from a window of segments.
    /// Passes existing topic names so the LLM only reports new ones.
    func extract(
        segments: [TranscriptSegment],
        existingTopics: [String],
        agenda: String? = nil,
        using provider: any LLMProvider
    ) async throws -> [ExtractedTopic] {
        guard !segments.isEmpty else { return [] }

        // Cap at ~40 segments to stay within token budget
        let window = segments.suffix(40)

        let existingList = existingTopics.isEmpty
            ? "None yet."
            : existingTopics.joined(separator: ", ")

        var parts: [String] = []
        if let agenda, !agenda.isEmpty {
            parts.append("Meeting agenda:\n\(agenda)")
        }
        parts.append("Already identified topics: \(existingList)")
        parts.append("Transcript:\n\(PromptTemplates.topicPrompt(segments: Array(window)))")

        let userContent = parts.joined(separator: "\n\n")

        let messages = [
            ChatMessage(role: .system, content: PromptTemplates.topicExtraction),
            ChatMessage(role: .user, content: userContent)
        ]

        let fullResponse = try await provider.collectResponse(messages: messages)
        let parsed = try LLMJSONParser.extract([TopicEntry].self, from: fullResponse)

        return parsed.map { entry in
            ExtractedTopic(
                name: entry.topic,
                summary: entry.summary,
                startTime: window.first?.startTime ?? 0
            )
        }
    }
}

private struct TopicEntry: Decodable {
    let topic: String
    let summary: String
}
