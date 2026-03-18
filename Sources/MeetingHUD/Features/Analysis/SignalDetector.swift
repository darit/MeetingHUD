import Foundation

/// Detects action items and key statements from transcript segments via LLM.
struct SignalDetector: Sendable {

    struct SignalResult: Sendable {
        let actionItems: [DetectedAction]
        let keyStatements: [DetectedStatement]
    }

    struct DetectedAction: Sendable {
        let description: String
        let ownerLabel: String
        let extractedFrom: String
    }

    struct DetectedStatement: Sendable {
        let speakerLabel: String
        let statement: String
        /// One of: decision, commitment, risk, concern
        let category: String
    }

    /// Detect signals from a window of transcript segments.
    func detect(
        segments: [TranscriptSegment],
        using provider: any LLMProvider
    ) async throws -> SignalResult {
        guard !segments.isEmpty else {
            return SignalResult(actionItems: [], keyStatements: [])
        }

        let window = segments.suffix(40)

        let messages = [
            ChatMessage(role: .system, content: PromptTemplates.signalDetection),
            ChatMessage(role: .user, content: PromptTemplates.signalDetectionPrompt(segments: Array(window)))
        ]

        let fullResponse = try await provider.collectResponse(messages: messages)
        let parsed = try LLMJSONParser.extract(SignalJSON.self, from: fullResponse)

        return SignalResult(
            actionItems: parsed.actionItems.map { item in
                DetectedAction(
                    description: item.description,
                    ownerLabel: item.owner ?? "",
                    extractedFrom: item.quote ?? ""
                )
            },
            keyStatements: parsed.keyStatements.map { stmt in
                DetectedStatement(
                    speakerLabel: stmt.speaker ?? "",
                    statement: stmt.statement,
                    category: stmt.category ?? "insight"
                )
            }
        )
    }
}

// MARK: - JSON Models

private struct SignalJSON: Decodable {
    let actionItems: [ActionJSON]
    let keyStatements: [StatementJSON]

    enum CodingKeys: String, CodingKey {
        case actionItems = "action_items"
        case keyStatements = "key_statements"
    }
}

private struct ActionJSON: Decodable {
    let description: String
    let owner: String?
    let quote: String?
}

private struct StatementJSON: Decodable {
    let speaker: String?
    let statement: String
    let category: String?
}
