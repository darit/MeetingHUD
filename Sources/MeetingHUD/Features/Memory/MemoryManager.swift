import Foundation

/// Three-tier memory system for managing meeting context at different fidelity levels.
///
/// - **HOT**: Rolling window of recent verbatim transcript (~last 5 min).
/// - **WARM**: LLM-compressed summary of older transcript. Updated periodically.
/// - **COLD**: SwiftData persistent store (previous meetings). Queried on demand.
///
/// The memory manager ensures the LLM always has the most relevant context
/// without exceeding token budgets.
@Observable @MainActor
final class MemoryManager {

    // MARK: - Tier State

    /// Compressed summary of older transcript (warm tier).
    private(set) var warmSummary: String = ""

    /// Timestamp of the last compression pass.
    private(set) var lastCompressionTime: Date?

    // MARK: - Configuration

    /// Number of recent segments to keep verbatim in the hot tier.
    /// Segments older than this are compressed into the warm tier.
    private let hotWindowSegments = 60

    // MARK: - Compression Tracking

    /// Index of the oldest segment that has NOT yet been compressed.
    /// Everything before this index has been folded into warmSummary.
    private var compressionWatermark = 0

    /// Segments awaiting compression (accumulated since last pass).
    private var pendingCompression: [TranscriptSegment] = []

    // MARK: - Dependencies

    private let llmProvider: any LLMProvider
    private let analysisQueue: AnalysisQueue
    private var compressionTimer: Task<Void, Never>?

    init(llmProvider: any LLMProvider, analysisQueue: AnalysisQueue) {
        self.llmProvider = llmProvider
        self.analysisQueue = analysisQueue
    }

    // MARK: - Lifecycle

    func start() {
        compressionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.Timing.memoryCompressionInterval))
                guard !Task.isCancelled else { break }
                await self?.runCompression()
            }
        }
    }

    func stop() {
        compressionTimer?.cancel()
        compressionTimer = nil
    }

    func reset() {
        stop()
        warmSummary = ""
        compressionWatermark = 0
        pendingCompression = []
        lastCompressionTime = nil
    }

    // MARK: - Segment Ingestion

    /// Called when new segments arrive. Moves segments that fell out of the hot window
    /// into the pending compression queue.
    func ingest(allSegments: [TranscriptSegment]) {
        let coldBoundary = allSegments.count - hotWindowSegments
        if coldBoundary > compressionWatermark {
            let newColdSegments = Array(allSegments[compressionWatermark..<coldBoundary])
            pendingCompression.append(contentsOf: newColdSegments)
            compressionWatermark = coldBoundary
        }
    }

    // MARK: - Context Assembly

    /// Build a complete context string using all memory tiers.
    /// Returns a context that fits within the total token budget.
    func buildContext(
        allSegments: [TranscriptSegment],
        speakers: [SpeakerInfo],
        topics: [TopicInfo],
        actionItems: [SignalDetector.DetectedAction],
        agenda: String?,
        currentTopic: String?,
        contentType: ContentTypeClassifier.ContentType? = nil
    ) -> String {
        var parts: [String] = []

        // Content type — helps the LLM tailor its analysis
        if let contentType, contentType != .unknown {
            parts.append("Content type: \(contentType.rawValue)")
        }

        // Meeting metadata
        if let topic = currentTopic {
            parts.append("Current topic: \(topic)")
        }

        if let agenda, !agenda.isEmpty {
            parts.append("Meeting agenda:\n\(agenda)")
        }

        // Speaker summary
        if !speakers.isEmpty {
            let totalTime = speakers.reduce(0) { $0 + $1.talkTime }
            let speakerLines = speakers.map { speaker in
                let pct = totalTime > 0 ? Int((speaker.talkTime / totalTime) * 100) : 0
                return "- \(speaker.name): \(pct)% talk time"
            }
            parts.append("Speakers:\n\(speakerLines.joined(separator: "\n"))")
        }

        // Topics discussed
        if !topics.isEmpty {
            let topicLines = topics.map { "- \($0.name): \($0.summary)" }
            parts.append("Topics discussed:\n\(topicLines.joined(separator: "\n"))")
        }

        // Action items
        if !actionItems.isEmpty {
            let actionLines = actionItems.map { action in
                let owner = action.ownerLabel.isEmpty ? "" : " [\(action.ownerLabel)]"
                return "- \(action.description)\(owner)"
            }
            parts.append("Action items:\n\(actionLines.joined(separator: "\n"))")
        }

        // WARM tier: compressed summary of older transcript
        if !warmSummary.isEmpty {
            parts.append("Earlier in this meeting (summary):\n\(warmSummary)")
        }

        // HOT tier: recent verbatim transcript
        let hotSegments = recentSegments(from: allSegments)
        if !hotSegments.isEmpty {
            parts.append("Recent transcript:\n\(PromptTemplates.timestampedTranscript(segments: hotSegments))")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Private

    /// Get the most recent segments that fit in the hot tier token budget.
    private func recentSegments(from allSegments: [TranscriptSegment]) -> [TranscriptSegment] {
        // Take the last `hotWindowSegments` segments, then trim to token budget
        let recentSlice = allSegments.suffix(hotWindowSegments)
        return trimToTokenBudget(Array(recentSlice), maxTokens: Constants.TokenBudgets.hotTierMax)
    }

    /// Trim segments from the front to fit within approximate token budget.
    private func trimToTokenBudget(_ segments: [TranscriptSegment], maxTokens: Int) -> [TranscriptSegment] {
        let maxChars = maxTokens * 4
        var result: [TranscriptSegment] = []
        var charCount = 0

        for segment in segments.reversed() {
            let lineLength = segment.speakerLabel.count + segment.text.count + 20
            if charCount + lineLength > maxChars { break }
            charCount += lineLength
            result.append(segment)
        }

        result.reverse()
        return result
    }

    /// Compress pending segments into the warm tier summary via the shared analysis queue.
    private func runCompression() async {
        guard !pendingCompression.isEmpty else { return }
        let isAvailable = await llmProvider.isAvailable
        guard isAvailable else { return }

        let segmentsToCompress = pendingCompression
        pendingCompression = []

        // Build the compression prompt
        let transcript = PromptTemplates.timestampedTranscript(segments: segmentsToCompress)
        let currentWarmSummary = warmSummary
        var userContent = transcript
        if !currentWarmSummary.isEmpty {
            userContent = "Previous summary:\n\(currentWarmSummary)\n\nNew transcript to incorporate:\n\(transcript)"
        }

        let messages = [
            ChatMessage(role: .system, content: PromptTemplates.transcriptCompression),
            ChatMessage(role: .user, content: userContent),
        ]

        let llm = llmProvider
        await analysisQueue.enqueue { [weak self] in
            do {
                let compressed = try await llm.collectResponse(messages: messages)
                await MainActor.run {
                    guard let self else { return }
                    let maxWarmChars = Constants.TokenBudgets.warmTierMax * 4
                    self.warmSummary = compressed.count > maxWarmChars
                        ? String(compressed.prefix(maxWarmChars))
                        : compressed
                    self.lastCompressionTime = .now
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.pendingCompression = segmentsToCompress + self.pendingCompression
                }
                print("[MemoryManager] Compression failed: \(error)")
            }
        }
    }
}
