import Foundation

/// Snapshot of all analytics computed during a meeting, for persistence.
struct AnalyticsSnapshot: Sendable {
    let perSpeaker: [String: SpeakerAnalytics]
    let topics: [TopicSnapshot]
    let actionItems: [ActionSnapshot]
    let meetingSummary: String

    struct TopicSnapshot: Sendable {
        let name: String
        let startTime: TimeInterval
        let endTime: TimeInterval?
        let summary: String
    }

    struct ActionSnapshot: Sendable {
        let description: String
        let ownerLabel: String?
        let extractedFrom: String
    }
}

/// Per-speaker analytics aggregated across an entire meeting.
struct SpeakerAnalytics: Sendable {
    let avgSentiment: Double
    let vocabularyComplexity: Double
    let questionRatio: Double
    let topicsRaised: [String]
    let keyStatements: [String]
}

/// Central orchestrator for all live meeting analysis.
/// Runs sentiment, topic extraction, signal detection, and communication metrics
/// on a periodic timer, feeding results to AppState via callbacks.
@Observable @MainActor
final class MeetingEngine {

    // MARK: - Live State

    /// Total number of ingested segments (used for watermark comparisons).
    private(set) var segmentCount = 0
    private(set) var topics: [TopicInfo] = []
    private(set) var detectedActions: [SignalDetector.DetectedAction] = []
    private(set) var speakerMetrics: [String: CommunicationMetrics.Stats] = [:]

    /// Current topic name for display in the HUD.
    var currentTopicName: String? {
        topics.last?.name
    }

    // MARK: - Callbacks

    /// Called when recommendations should be added to AppState.
    var onRecommendation: (@MainActor (Recommendation) -> Void)?

    /// Called when segment sentiments are updated.
    var onSentimentsUpdated: (@MainActor ([UUID: Double]) -> Void)?

    /// Called when a new topic is detected (for recommendation agent).
    var onTopicDetected: (@MainActor (String) -> Void)?

    /// Called at the end of each analysis pass (for periodic recommendation agent triggers).
    var onAnalysisPassComplete: (@MainActor () -> Void)?

    /// Debug log callback (wired to AppState.addDebug).
    var onDebugLog: ((String) -> Void)?

    // MARK: - Private State

    var llmProvider: any LLMProvider
    private let analysisQueue: AnalysisQueue
    private let sentimentAnalyzer = SentimentAnalyzer()
    private let topicExtractor = TopicExtractor()
    private let signalDetector = SignalDetector()
    private let communicationMetrics = CommunicationMetrics()

    /// Content type classifier — detects meeting type, news, podcast, etc.
    let contentTypeClassifier: ContentTypeClassifier

    /// Watermarks tracking the last-analyzed segment index for each pipeline.
    private var sentimentWatermark = 0
    private var topicWatermark = 0
    private var signalWatermark = 0

    /// Per-speaker sentiment accumulation for averaging.
    private var sentimentAccumulator: [String: (total: Double, count: Int)] = [:]

    /// Per-speaker key statements collected from signal detection.
    private var speakerKeyStatements: [String: [String]] = [:]

    /// Per-speaker topics raised.
    private var speakerTopics: [String: Set<String>] = [:]

    /// Per-speaker cumulative talk time (incremental, avoids re-scanning all segments).
    private var speakerTalkTime: [String: TimeInterval] = [:]
    private var totalTalkTime: TimeInterval = 0

    /// Last segment end time per speaker (for silence detection).
    private var speakerLastActive: [String: TimeInterval] = [:]

    /// Timer for periodic analysis.
    private var analysisTimer: Task<Void, Never>?

    /// Cooldown tracking for recommendations by trigger type.
    private var lastRecommendationTime: [String: Date] = [:]
    private let recommendationCooldown: TimeInterval = 25

    /// Reference to AppState's segments for LLM analysis passes (avoids duplication).
    /// Set by AppState after creation.
    var segmentsProvider: (@MainActor () -> [TranscriptSegment])?

    /// Optional meeting agenda pasted by the user. Included in analysis prompts for context.
    var meetingAgenda: String?

    // MARK: - Lifecycle

    init(llmProvider: any LLMProvider, analysisQueue: AnalysisQueue) {
        self.llmProvider = llmProvider
        self.analysisQueue = analysisQueue
        self.contentTypeClassifier = ContentTypeClassifier(llmProvider: llmProvider, analysisQueue: analysisQueue)
    }

    /// Callback for speaker dominance shifts (for recommendation agent).
    var onSpeakerDominanceShift: (@MainActor (String, Double) -> Void)?

    /// Track previous dominant speaker for shift detection.
    private var lastDominantSpeaker: String?

    /// Ingest a new transcript segment. Runs O(1) metric updates.
    func ingest(_ segment: TranscriptSegment) {
        segmentCount += 1

        // Incremental communication metrics — O(words in segment)
        communicationMetrics.ingest(segment)
        speakerMetrics = communicationMetrics.currentStats()

        // Incremental talk time tracking — O(1)
        let duration = segment.duration
        speakerTalkTime[segment.speakerLabel, default: 0] += duration
        totalTalkTime += duration
        speakerLastActive[segment.speakerLabel] = segment.endTime

        generateTalkTimeRecommendations(latestEndTime: segment.endTime)
        detectDominanceShift()
    }

    /// Detect when the dominant speaker changes.
    private func detectDominanceShift() {
        guard totalTalkTime > 60 else { return } // Need at least 1 min of data
        let ct = contentTypeClassifier.detectedType
        let isBroadcast: Bool = switch ct {
        case .news, .stream, .lecture, .presentation, .podcast: true
        default: false
        }
        guard !isBroadcast else { return }
        let dominant = speakerTalkTime.max(by: { $0.value < $1.value })
        guard let dominant, dominant.value / totalTalkTime > 0.4 else { return }

        if dominant.key != lastDominantSpeaker {
            let percent = (dominant.value / totalTalkTime) * 100
            if lastDominantSpeaker != nil {
                onSpeakerDominanceShift?(dominant.key, percent)
            }
            lastDominantSpeaker = dominant.key
        }
    }

    /// Start periodic analysis passes.
    func start() {
        analysisTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.Timing.recommendationTriggerInterval))
                guard !Task.isCancelled else { break }
                await self?.runAnalysisPass()
            }
        }
    }

    /// Stop analysis and return a snapshot for persistence.
    func stop() async -> AnalyticsSnapshot {
        analysisTimer?.cancel()
        analysisTimer = nil
        contentTypeClassifier.reset()

        // Build per-speaker analytics
        var perSpeaker: [String: SpeakerAnalytics] = [:]
        let allSpeakers = Set(speakerTalkTime.keys)

        for speaker in allSpeakers {
            let sentimentData = sentimentAccumulator[speaker]
            let avgSentiment = sentimentData.map { $0.count > 0 ? $0.total / Double($0.count) : 0.0 } ?? 0.0
            let metrics = speakerMetrics[speaker]
            let topicsRaised = Array(speakerTopics[speaker] ?? [])
            let keyStatements = speakerKeyStatements[speaker] ?? []

            perSpeaker[speaker] = SpeakerAnalytics(
                avgSentiment: avgSentiment,
                vocabularyComplexity: metrics?.vocabularyComplexity ?? 0,
                questionRatio: metrics?.questionRatio ?? 0,
                topicsRaised: topicsRaised,
                keyStatements: keyStatements
            )
        }

        let topicSnapshots = topics.map { topic in
            AnalyticsSnapshot.TopicSnapshot(
                name: topic.name,
                startTime: topic.startTime,
                endTime: topic.endTime,
                summary: topic.summary
            )
        }

        let actionSnapshots = detectedActions.map { action in
            AnalyticsSnapshot.ActionSnapshot(
                description: action.description,
                ownerLabel: action.ownerLabel.isEmpty ? nil : action.ownerLabel,
                extractedFrom: action.extractedFrom
            )
        }

        // Generate meeting summary via LLM if available
        var summaryText = ""
        let llmAvailable = await llmProvider.isAvailable
        if llmAvailable, let segments = segmentsProvider?(), !segments.isEmpty {
            let topicNames = topics.map(\.name)
            let actionDescriptions = detectedActions.map { action in
                let owner = action.ownerLabel.isEmpty ? "" : " [\(action.ownerLabel)]"
                return "\(action.description)\(owner)"
            }
            var userContent = PromptTemplates.meetingSummaryPrompt(
                segments: segments,
                topics: topicNames,
                actionItems: actionDescriptions
            )
            if let agenda = meetingAgenda, !agenda.isEmpty {
                userContent = "Meeting agenda:\n\(agenda)\n\n\(userContent)"
            }
            let messages = [
                ChatMessage(role: .system, content: PromptTemplates.meetingSummary),
                ChatMessage(role: .user, content: userContent)
            ]
            do {
                summaryText = try await llmProvider.collectResponse(messages: messages)
            } catch {
                print("[MeetingEngine] Summary generation failed: \(error)")
            }
        }

        return AnalyticsSnapshot(
            perSpeaker: perSpeaker,
            topics: topicSnapshots,
            actionItems: actionSnapshots,
            meetingSummary: summaryText
        )
    }

    // MARK: - Analysis Pass

    private func log(_ msg: String) {
        print("[MeetingEngine] \(msg)")
        onDebugLog?(msg)
    }

    private func runAnalysisPass() async {
        let isAvailable = await llmProvider.isAvailable
        guard isAvailable else {
            log("Analysis skipped — LLM not available (\(llmProvider.displayName))")
            return
        }
        guard let segments = segmentsProvider?(), !segments.isEmpty else { return }
        log("Analysis pass: \(segments.count) segs, provider=\(llmProvider.displayName)")

        // Sentiment analysis on new segments
        if sentimentWatermark < segments.count {
            let newSegments = Array(segments[sentimentWatermark...])
            let watermarkCapture = sentimentWatermark
            sentimentWatermark = segments.count

            // Pre-build ID→speaker map so applySentimentScores avoids O(n) lookups
            let speakerByID = Dictionary(
                uniqueKeysWithValues: newSegments.map { ($0.id, $0.speakerLabel) }
            )

            await analysisQueue.enqueue { [weak self, newSegments, speakerByID] in
                guard let self else { return }
                do {
                    let scores = try await self.sentimentAnalyzer.analyze(
                        segments: newSegments,
                        using: self.llmProvider
                    )
                    await MainActor.run {
                        self.applySentimentScores(scores, speakerByID: speakerByID)
                    }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run {
                        self.log("Sentiment failed: \(msg)")
                        self.sentimentWatermark = watermarkCapture
                    }
                }
            }
        }

        // Topic extraction on recent window
        if topicWatermark < segments.count {
            let windowStart = max(0, segments.count - 40)
            let window = Array(segments[windowStart...])
            let existingNames = topics.map(\.name)
            let topicWatermarkCapture = topicWatermark
            topicWatermark = segments.count

            let agenda = meetingAgenda
            await analysisQueue.enqueue { [weak self, window, existingNames, agenda, topicWatermarkCapture] in
                guard let self else { return }
                do {
                    let newTopics = try await self.topicExtractor.extract(
                        segments: window,
                        existingTopics: existingNames,
                        agenda: agenda,
                        using: self.llmProvider
                    )
                    await MainActor.run {
                        self.applyNewTopics(newTopics)
                    }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run {
                        self.log("Topic extraction failed: \(msg)")
                        self.topicWatermark = topicWatermarkCapture
                    }
                }
            }
        }

        // Signal detection on recent window
        if signalWatermark < segments.count {
            let windowStart = max(0, segments.count - 40)
            let window = Array(segments[windowStart...])
            let signalWatermarkCapture = signalWatermark
            signalWatermark = segments.count

            await analysisQueue.enqueue { [weak self, window, signalWatermarkCapture] in
                guard let self else { return }
                do {
                    let result = try await self.signalDetector.detect(
                        segments: window,
                        using: self.llmProvider
                    )
                    await MainActor.run {
                        self.applySignals(result)
                    }
                } catch {
                    let msg = error.localizedDescription
                    await MainActor.run {
                        self.log("Signal detection failed: \(msg)")
                        self.signalWatermark = signalWatermarkCapture
                    }
                }
            }
        }

        // Content type classification (runs early, then re-evaluates periodically)
        let speakerList = speakerTalkTime.map { SpeakerInfo(id: UUID(), name: $0.key, talkTime: $0.value) }
        contentTypeClassifier.classifyIfNeeded(segments: segments, speakers: speakerList)

        onAnalysisPassComplete?()
    }

    // MARK: - Apply Results

    private func applySentimentScores(_ scores: [UUID: Double], speakerByID: [UUID: String]) {
        for (id, score) in scores {
            guard let speaker = speakerByID[id] else { continue }
            var acc = sentimentAccumulator[speaker] ?? (total: 0, count: 0)
            acc.total += score
            acc.count += 1
            sentimentAccumulator[speaker] = acc

            if score < -0.3 {
                emitRecommendation(
                    trigger: "sentiment_\(speaker)",
                    text: "\(speaker)'s tone shifted negative",
                    category: .warning
                )
            }
        }

        onSentimentsUpdated?(scores)
    }

    private func applyNewTopics(_ newTopics: [TopicExtractor.ExtractedTopic]) {
        for extracted in newTopics {
            // Close previous topic
            if var last = topics.last, last.endTime == nil {
                last.endTime = extracted.startTime
                topics[topics.count - 1] = last
            }

            let topic = TopicInfo(
                name: extracted.name,
                startTime: extracted.startTime,
                summary: extracted.summary
            )
            topics.append(topic)

            emitRecommendation(
                trigger: "topic_\(extracted.name)",
                text: "Topic: \(extracted.name)",
                category: .insight
            )

            onTopicDetected?(extracted.name)
        }
    }

    private func applySignals(_ result: SignalDetector.SignalResult) {
        for action in result.actionItems {
            // Deduplicate by description
            guard !detectedActions.contains(where: {
                $0.description.lowercased() == action.description.lowercased()
            }) else { continue }

            detectedActions.append(action)

            let ownerText = action.ownerLabel.isEmpty ? "" : " (\(action.ownerLabel))"
            emitRecommendation(
                trigger: "action_\(action.description.prefix(30))",
                text: "Action: \(action.description)\(ownerText)",
                category: .insight
            )
        }

        for stmt in result.keyStatements {
            let speaker = stmt.speakerLabel
            if !speaker.isEmpty {
                speakerKeyStatements[speaker, default: []].append(stmt.statement)
            }
        }
    }

    // MARK: - Recommendation Generation

    private func generateTalkTimeRecommendations(latestEndTime: TimeInterval) {
        guard segmentCount > 10, totalTalkTime > 0 else { return }
        // Don't fire dominance alerts when there's only 1 speaker — it's always 100%
        guard speakerTalkTime.count > 1 else { return }

        // Skip speaker-balance alerts for broadcast/one-to-many content where dominance is expected
        let ct = contentTypeClassifier.detectedType
        let isBroadcast: Bool = switch ct {
        case .news, .stream, .lecture, .presentation, .podcast: true
        default: false
        }
        guard !isBroadcast else { return }

        for (speaker, time) in speakerTalkTime {
            let percent = (time / totalTalkTime) * 100
            if percent > 60 {
                emitRecommendation(
                    trigger: "talktime_\(speaker)",
                    text: "\(speaker) has spoken \(Int(percent))% of the time",
                    category: .suggestion
                )
            }
        }

        // Check for silent speakers (> 3 min since last segment)
        for (speaker, lastActive) in speakerLastActive {
            let silenceTime = latestEndTime - lastActive
            if silenceTime > 180 {
                let minutes = Int(silenceTime / 60)
                emitRecommendation(
                    trigger: "silence_\(speaker)",
                    text: "\(speaker) hasn't spoken in \(minutes) minutes",
                    category: .suggestion
                )
            }
        }
    }

    private func emitRecommendation(trigger: String, text: String, category: Recommendation.Category) {
        let now = Date.now
        if let lastTime = lastRecommendationTime[trigger],
           now.timeIntervalSince(lastTime) < recommendationCooldown {
            return
        }
        lastRecommendationTime[trigger] = now
        onRecommendation?(Recommendation(text: text, category: category))
    }
}

// MARK: - Supporting Types

/// In-memory topic representation during a live meeting.
struct TopicInfo: Sendable {
    let name: String
    let startTime: TimeInterval
    var endTime: TimeInterval?
    let summary: String
}
