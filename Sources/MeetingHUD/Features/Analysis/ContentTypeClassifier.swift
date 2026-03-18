import Foundation

/// Classifies what type of audio content is being heard based on transcript patterns.
/// Runs once after enough segments are collected, then re-evaluates periodically
/// as more context becomes available.
@Observable @MainActor
final class ContentTypeClassifier {

    // MARK: - Content Types

    /// The detected type of audio content.
    enum ContentType: String, Sendable, CaseIterable {
        case meeting = "Meeting"
        case standup = "Daily Standup"
        case refinement = "Backlog Refinement"
        case retrospective = "Retrospective"
        case interview = "Interview"
        case presentation = "Presentation"
        case news = "News"
        case roundtable = "Round Table"
        case podcast = "Podcast"
        case stream = "Stream"
        case lecture = "Lecture"
        case conversation = "Conversation"
        case unknown = "Unknown"

        /// SF Symbol for display in the HUD.
        var icon: String {
            switch self {
            case .meeting: return "person.3"
            case .standup: return "figure.stand"
            case .refinement: return "checklist"
            case .retrospective: return "arrow.counterclockwise"
            case .interview: return "mic.badge.plus"
            case .presentation: return "tv"
            case .news: return "newspaper"
            case .roundtable: return "circle.grid.3x3"
            case .podcast: return "headphones"
            case .stream: return "play.tv"
            case .lecture: return "graduationcap"
            case .conversation: return "bubble.left.and.bubble.right"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    // MARK: - State

    /// The current detected content type.
    private(set) var detectedType: ContentType = .unknown

    /// Confidence level (0.0–1.0) of the classification.
    private(set) var confidence: Double = 0

    /// Whether a classification pass is in progress.
    private(set) var isClassifying = false

    /// Number of segments last used for classification.
    private var lastClassifiedSegmentCount = 0

    // MARK: - Configuration

    /// Minimum segments before first classification attempt.
    private let minSegments = 8

    /// Re-classify after this many new segments since last classification.
    private let reclassifyInterval = 30

    // MARK: - Dependencies

    private let llmProvider: any LLMProvider
    private let analysisQueue: AnalysisQueue

    init(llmProvider: any LLMProvider, analysisQueue: AnalysisQueue) {
        self.llmProvider = llmProvider
        self.analysisQueue = analysisQueue
    }

    // MARK: - Classification

    /// Check if we should classify based on segment count. Called from MeetingEngine.
    func classifyIfNeeded(segments: [TranscriptSegment], speakers: [SpeakerInfo]) {
        guard !isClassifying else { return }
        guard segments.count >= minSegments else { return }

        // First classification or enough new segments for re-evaluation
        let isFirstPass = lastClassifiedSegmentCount == 0
        let hasEnoughNew = segments.count - lastClassifiedSegmentCount >= reclassifyInterval
        guard isFirstPass || hasEnoughNew else { return }

        classify(segments: segments, speakers: speakers)
    }

    /// Run the LLM classification.
    private func classify(segments: [TranscriptSegment], speakers: [SpeakerInfo]) {
        isClassifying = true
        lastClassifiedSegmentCount = segments.count

        let speakerCount = speakers.count
        let speakerNames = speakers.map(\.name)
        let recentSegments = Array(segments.suffix(30))

        let prompt = Self.buildPrompt(
            segments: recentSegments,
            speakerCount: speakerCount,
            speakerNames: speakerNames
        )

        let messages = [
            ChatMessage(role: .system, content: Self.systemPrompt),
            ChatMessage(role: .user, content: prompt),
        ]

        let llm = llmProvider
        Task {
            defer { isClassifying = false }

            await analysisQueue.enqueue { [weak self] in
                guard !Task.isCancelled else { return }
                do {
                    let response = try await llm.collectResponse(messages: messages)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self else { return }
                        self.applyClassification(response)
                    }
                } catch {
                    print("[ContentTypeClassifier] Classification failed: \(error)")
                }
            }
        }
    }

    private func applyClassification(_ response: String) {
        if let result = try? LLMJSONParser.extract(ClassificationResult.self, from: response) {
            let matched = ContentType.allCases.first {
                $0.rawValue.lowercased() == result.type.lowercased()
            }
            if let matched {
                detectedType = matched
                confidence = max(0, min(1, result.confidence))
            }
        }
    }

    func reset() {
        detectedType = .unknown
        confidence = 0
        lastClassifiedSegmentCount = 0
        isClassifying = false
    }

    // MARK: - Prompt

    private struct ClassificationResult: Decodable {
        let type: String
        let confidence: Double
    }

    static let systemPrompt = """
        You are an audio content classifier. Given a transcript excerpt with speaker information, \
        determine what type of content is being heard.

        Possible types (use EXACTLY one of these strings):
        - "Meeting" — general work meeting, sync, 1-on-1
        - "Daily Standup" — daily standup / scrum (short, structured: yesterday/today/blockers)
        - "Backlog Refinement" — backlog grooming, story pointing, ticket review
        - "Retrospective" — sprint retro, what went well/poorly, process improvements
        - "Interview" — job interview, structured Q&A with a candidate
        - "Presentation" — one person presenting/demoing to an audience, slides
        - "News" — news broadcast, anchor reading stories, reporter segments
        - "Round Table" — panel discussion, multiple experts debating topics
        - "Podcast" — casual long-form discussion, hosts + guests, topical
        - "Stream" — live stream, gaming, commentary, chat interaction
        - "Lecture" — educational, teaching, one speaker explaining concepts
        - "Conversation" — casual chat, not structured, informal

        Signals to consider:
        - Number of speakers and how balanced the talk time is
        - Structured patterns (standup = short turns, same structure per speaker)
        - Vocabulary (technical terms, agile terms, news language, academic language)
        - Formality level
        - Whether speakers address each other or an audience
        - Turn-taking patterns (one speaker dominating = presentation/lecture/news)

        Output ONLY a JSON object:
        {"type": "...", "confidence": 0.0-1.0}

        Use the same language awareness as the transcript — the content type labels above \
        are in English but apply regardless of transcript language.
        """

    static func buildPrompt(
        segments: [TranscriptSegment],
        speakerCount: Int,
        speakerNames: [String]
    ) -> String {
        var parts: [String] = []
        parts.append("Number of speakers: \(speakerCount)")
        parts.append("Speaker labels: \(speakerNames.joined(separator: ", "))")
        parts.append("")
        parts.append("Transcript:")
        for seg in segments {
            parts.append("[\(seg.speakerLabel)]: \(seg.text)")
        }
        return parts.joined(separator: "\n")
    }
}
