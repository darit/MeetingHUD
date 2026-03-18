import Foundation

/// LLM-powered recommendation agent that generates context-aware suggestions
/// during meetings. Triggered by events (topic shifts, speaker changes, periodic timer)
/// rather than a fixed schedule.
///
/// Uses the three-tier memory system for context and generates recommendations
/// that go beyond the rule-based ones in MeetingEngine.
@Observable @MainActor
final class RecommendationAgent {

    // MARK: - State

    /// Whether the agent is currently generating a recommendation.
    private(set) var isGenerating = false

    // MARK: - Configuration

    /// Minimum seconds between LLM recommendation passes to avoid GPU contention.
    private let cooldownInterval: TimeInterval = 25

    /// Last time the agent generated recommendations.
    private var lastGenerationTime: Date?

    // MARK: - Dependencies

    private let llmProvider: any LLMProvider
    private let memoryManager: MemoryManager
    private let analysisQueue: AnalysisQueue

    /// Active generation task (for cancellation).
    private var generationTask: Task<Void, Never>?

    // MARK: - Callbacks

    var onRecommendations: (([Recommendation]) -> Void)?

    init(llmProvider: any LLMProvider, memoryManager: MemoryManager, analysisQueue: AnalysisQueue) {
        self.llmProvider = llmProvider
        self.memoryManager = memoryManager
        self.analysisQueue = analysisQueue
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
    }

    // MARK: - Event Triggers

    /// Called when a new topic is detected. Good moment for recommendations.
    func onTopicShift(
        newTopic: String,
        allSegments: [TranscriptSegment],
        speakers: [SpeakerInfo],
        topics: [TopicInfo],
        actionItems: [SignalDetector.DetectedAction],
        agenda: String?,
        contentType: ContentTypeClassifier.ContentType? = nil
    ) {
        guard shouldGenerate() else { return }
        generateRecommendations(
            trigger: "Topic shifted to: \(newTopic)",
            allSegments: allSegments,
            speakers: speakers,
            topics: topics,
            actionItems: actionItems,
            agenda: agenda,
            currentTopic: newTopic,
            contentType: contentType
        )
    }

    /// Called periodically from MeetingEngine's analysis timer.
    func onPeriodicCheck(
        allSegments: [TranscriptSegment],
        speakers: [SpeakerInfo],
        topics: [TopicInfo],
        actionItems: [SignalDetector.DetectedAction],
        agenda: String?,
        currentTopic: String?,
        contentType: ContentTypeClassifier.ContentType? = nil
    ) {
        guard shouldGenerate() else { return }
        generateRecommendations(
            trigger: "Periodic check-in",
            allSegments: allSegments,
            speakers: speakers,
            topics: topics,
            actionItems: actionItems,
            agenda: agenda,
            currentTopic: currentTopic,
            contentType: contentType
        )
    }

    /// Called when speaker dominance shifts (one speaker takes over the conversation).
    func onSpeakerDominanceShift(
        speaker: String,
        percent: Double,
        allSegments: [TranscriptSegment],
        speakers: [SpeakerInfo],
        topics: [TopicInfo],
        actionItems: [SignalDetector.DetectedAction],
        agenda: String?,
        contentType: ContentTypeClassifier.ContentType? = nil
    ) {
        guard shouldGenerate() else { return }
        generateRecommendations(
            trigger: "Speaker dominance shift: \(speaker) now at \(Int(percent))% of talk time",
            allSegments: allSegments,
            speakers: speakers,
            topics: topics,
            actionItems: actionItems,
            agenda: agenda,
            currentTopic: nil,
            contentType: contentType
        )
    }

    // MARK: - Private

    private func shouldGenerate() -> Bool {
        guard !isGenerating else { return false }
        if let lastTime = lastGenerationTime,
           Date.now.timeIntervalSince(lastTime) < cooldownInterval {
            return false
        }
        return true
    }

    private func generateRecommendations(
        trigger: String,
        allSegments: [TranscriptSegment],
        speakers: [SpeakerInfo],
        topics: [TopicInfo],
        actionItems: [SignalDetector.DetectedAction],
        agenda: String?,
        currentTopic: String?,
        contentType: ContentTypeClassifier.ContentType? = nil
    ) {
        // Don't generate insights when there's no meaningful transcript content
        guard allSegments.count >= 5 else { return }

        isGenerating = true
        lastGenerationTime = .now

        let context = memoryManager.buildContext(
            allSegments: allSegments,
            speakers: speakers,
            topics: topics,
            actionItems: actionItems,
            agenda: agenda,
            currentTopic: currentTopic,
            contentType: contentType
        )

        // Use the new proactive analysis prompt for richer categorized insights
        let messages = [
            ChatMessage(role: .system, content: PromptTemplates.proactiveAnalysis),
            ChatMessage(role: .user, content: """
                Trigger: \(trigger)

                \(context)
                """),
        ]

        let llm = llmProvider
        generationTask = Task {
            defer { isGenerating = false }

            await analysisQueue.enqueue { [weak self] in
                guard !Task.isCancelled else { return }
                do {
                    let response = try await llm.collectResponse(messages: messages)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self else { return }
                        let recommendations = self.parseRecommendations(response)
                        if !recommendations.isEmpty {
                            self.onRecommendations?(recommendations)
                        }
                    }
                } catch {
                    print("[RecommendationAgent] Generation failed: \(error)")
                }
            }
        }
    }

    // MARK: - Parsing

    /// JSON structure for categorized insight from LLM.
    private struct InsightJSON: Decodable {
        let category: String
        let text: String
    }

    /// Parse LLM response into recommendation objects.
    /// Tries JSON array first (from proactive analysis prompt), falls back to line parsing.
    private func parseRecommendations(_ response: String) -> [Recommendation] {
        // Try structured JSON parsing first
        if let insights = try? LLMJSONParser.extract([InsightJSON].self, from: response) {
            return insights.prefix(3).map { insight in
                let category = mapCategory(insight.category)
                return Recommendation(text: insight.text, category: category)
            }
        }

        // Fallback: parse as numbered/bulleted lines
        let lines = response.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line -> String in
                var s = line
                while let first = s.first, "•-*0123456789.):".contains(first) {
                    s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .filter { !$0.isEmpty && $0.count > 10 }

        return lines.prefix(3).map { text in
            let category = categorize(text)
            return Recommendation(text: text, category: category)
        }
    }

    /// Map JSON category string to enum.
    private func mapCategory(_ raw: String) -> Recommendation.Category {
        switch raw.lowercased() {
        case "observation": return .observation
        case "suggestion": return .suggestion
        case "risk": return .risk
        case "summary": return .summary
        case "warning": return .warning
        case "next_topic": return .nextTopic
        default: return .insight
        }
    }

    /// Simple categorization based on keywords (fallback).
    private func categorize(_ text: String) -> Recommendation.Category {
        let lower = text.lowercased()
        if lower.contains("warn") || lower.contains("risk") || lower.contains("concern")
            || lower.contains("careful") || lower.contains("attention") {
            return .warning
        }
        if lower.contains("consider") || lower.contains("suggest") || lower.contains("try")
            || lower.contains("could") || lower.contains("might") || lower.contains("ask") {
            return .suggestion
        }
        return .insight
    }
}
