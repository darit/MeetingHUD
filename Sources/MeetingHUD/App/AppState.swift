import Foundation
import SwiftData
import SwiftUI

/// Central observable state for the entire app.
/// Coordinates audio capture, transcription, and meeting lifecycle.
@Observable @MainActor
final class AppState {
    // MARK: - Capture State (Phase 3)

    /// The app's capture state machine.
    /// - `.off`: user paused everything
    /// - `.listening`: always-on, no speech detected
    /// - `.conversation`: speech detected, basic transcription only
    /// - `.meeting`: elevated, full analysis pipeline
    enum CaptureState: Equatable {
        case off
        case listening
        case conversation
        case meeting
    }

    var captureState: CaptureState = .off

    /// Convenience — true when actively transcribing (conversation or meeting).
    var isRecording: Bool { captureState == .conversation || captureState == .meeting }

    var currentMeeting: Meeting?

    /// Current conversation session (ambient or meeting).
    var currentSession: ConversationSession?

    /// The overlay panel reference (managed here to avoid @State/@Binding issues with NSPanel).
    var overlayPanel: OverlayPanel?

    /// User-visible error message when recording fails to start or stops unexpectedly.
    var recordingError: String?

    /// Debug log messages (shown in overlay when enabled).
    var debugLog: [String] = []
    var showDebugLog = false
    var showHistorySheet = false

    /// When true, audio processing is paused (not fed to transcription/diarization).
    var isMicMuted = false

    // MARK: - Model Loading

    var isModelLoading = false

    /// Whether the MLX local model is currently loaded and ready.
    var isMLXReady: Bool { MLXModelManager.shared.loadState == .loaded }

    /// Whether the MLX local model is currently loading.
    var isMLXLoading: Bool {
        if case .loading = MLXModelManager.shared.loadState { return true }
        return false
    }

    /// Auto-load the last-used MLX model if one is selected but not loaded.
    func autoLoadMLXIfNeeded() {
        guard selectedAnalysisProvider == .localMLX else { return }
        guard MLXModelManager.shared.loadState == .unloaded else { return }
        guard let model = MLXModelManager.shared.selectedModel else { return }
        isModelLoading = true
        Task {
            do {
                try await MLXModelManager.shared.loadModel(model)
            } catch {
                addDebug("[MLX] Auto-load failed: \(error.localizedDescription)")
            }
            isModelLoading = false
        }
    }

    // MARK: - Live Data

    /// Transcript segments for the active meeting (in-memory, not persisted until meeting ends).
    var activeTranscriptSegments: [TranscriptSegment] = []

    /// Currently identified speakers and their running stats.
    var speakers: [SpeakerInfo] = []

    /// AI-generated recommendations surfaced during the meeting.
    var recommendations: [Recommendation] = []

    // MARK: - Post-Meeting Processing

    var isDiarizing = false
    var showSpeakerNamingSheet = false

    /// Pending state held between diarization completing and speaker naming.
    private var pendingDiarizationOutput: SpeakerDiarizer.DiarizationOutput?
    private var pendingMeeting: Meeting?
    private var pendingSegments: [TranscriptSegment] = []
    /// Voice embeddings extracted per speaker label during diarization (for persistence).
    private var pendingVoiceEmbeddings: [String: [Float]] = [:]

    // MARK: - Speaker Renames

    /// Maps ANY raw label → user-chosen display name.
    /// When a user renames a speaker, ALL raw labels that currently resolve to the old
    /// display name get remapped to the new display name.
    /// The diarization callback adds new raw labels when it discovers them.
    private var speakerRenames: [String: String] = [:]

    /// Resolve a raw label to its display name via the rename map.
    private func displayName(for rawLabel: String) -> String {
        speakerRenames[rawLabel] ?? rawLabel
    }

    /// Find all raw labels that currently resolve to a given display name.
    private func rawLabels(for displayName: String) -> Set<String> {
        var labels = Set<String>()
        for (raw, display) in speakerRenames {
            if display == displayName { labels.insert(raw) }
        }
        // The displayName itself might also appear as a raw label in segments
        labels.insert(displayName)
        return labels
    }

    // MARK: - Auto-Detection

    var autoDetectEnabled = true
    var detectedMeeting: DetectedMeeting?
    var autoDetectStatus: String = "Monitoring..."

    // MARK: - Meeting Agenda

    /// Optional meeting agenda pasted by the user. Fed to LLM for context-aware analysis.
    var meetingAgenda: String = ""

    // MARK: - Chat

    /// Chat conversation messages (user + assistant, excludes system).
    var chatMessages: [ChatMessage] = []

    /// Whether the LLM is currently generating a chat response.
    var isGeneratingResponse = false

    /// Partial response being streamed from the LLM.
    var streamingResponse = ""

    /// Active chat generation task (for cancellation).
    private var chatTask: Task<Void, Never>?

    // MARK: - LLM Provider Selection

    /// Available provider choices for analysis.
    enum AnalysisProvider: String, CaseIterable {
        case localMLX = "Local (MLX)"
        case claudeHaiku = "Claude Haiku"
        case claudeSonnet = "Claude Sonnet"
    }

    /// The active provider for meeting analysis (sentiment, topics, signals, recommendations).
    var selectedAnalysisProvider: AnalysisProvider = .localMLX

    /// The active LLM provider instance used by analysis pipelines.
    var analysisLLMProvider: any LLMProvider { activeProvider ?? mlxProvider }

    /// Claude CLI provider (lazy, created on first use).
    private var claudeHaikuProvider: ClaudeCLIProvider?
    private var claudeSonnetProvider: ClaudeCLIProvider?
    private var activeProvider: (any LLMProvider)?

    /// Switch the analysis provider. Takes effect on next analysis pass.
    func switchAnalysisProvider(to choice: AnalysisProvider) {
        selectedAnalysisProvider = choice
        switch choice {
        case .localMLX:
            activeProvider = nil // falls back to mlxProvider
        case .claudeHaiku:
            if claudeHaikuProvider == nil {
                claudeHaikuProvider = ClaudeCLIProvider(model: .haiku)
            }
            activeProvider = claudeHaikuProvider
            // Unload MLX model to free GPU memory
            MLXModelManager.shared.unloadModel()
        case .claudeSonnet:
            if claudeSonnetProvider == nil {
                claudeSonnetProvider = ClaudeCLIProvider(model: .sonnet)
            }
            activeProvider = claudeSonnetProvider
            MLXModelManager.shared.unloadModel()
        }
        UserDefaults.standard.set(choice.rawValue, forKey: "analysisProvider")
        addDebug("Switched analysis provider to \(choice.rawValue)")
    }

    /// Switch the Whisper transcription model. Takes effect on next recording session.
    func switchWhisperModel(to model: String) {
        guard !isRecording else {
            addDebug("Cannot switch Whisper model while recording")
            return
        }
        selectedTranscriptionBackend = .whisperKit
        transcriptionEngine.modelName = model
        transcriptionEngine.isModelLoaded = false
        UserDefaults.standard.set(model, forKey: "whisperModel")
        UserDefaults.standard.set(TranscriptionBackend.whisperKit.rawValue, forKey: "transcriptionBackend")
        addDebug("Whisper model set to \(model) — will load on next recording")
    }

    // MARK: - Analytics

    /// Current topic name detected by the analytics engine.
    var currentTopicName: String?

    /// Detected content type (meeting, standup, news, podcast, etc.).
    var detectedContentType: ContentTypeClassifier.ContentType {
        meetingEngine?.contentTypeClassifier.detectedType ?? .unknown
    }

    /// Confidence of the content type classification.
    var contentTypeConfidence: Double {
        meetingEngine?.contentTypeClassifier.confidence ?? 0
    }

    /// Read-only access to current topics (from MeetingEngine).
    var currentTopics: [TopicInfo] { meetingEngine?.topics ?? [] }

    /// Read-only access to current action items (from MeetingEngine).
    var currentActionItems: [SignalDetector.DetectedAction] { meetingEngine?.detectedActions ?? [] }

    /// Live meeting analytics engine (active during recording).
    private var meetingEngine: MeetingEngine?

    /// Analytics collected at meeting end, passed to persistence.
    private var pendingAnalytics: AnalyticsSnapshot?

    // MARK: - Transcription Backend

    enum TranscriptionBackend: String, CaseIterable {
        case parakeet = "Parakeet TDT"
        case whisperKit = "WhisperKit"
    }

    var selectedTranscriptionBackend: TranscriptionBackend = .parakeet

    /// The active transcription engine based on selected backend.
    var activeTranscriptionEngine: any TranscriptionProvider {
        switch selectedTranscriptionBackend {
        case .parakeet: return parakeetEngine
        case .whisperKit: return transcriptionEngine
        }
    }

    func switchTranscriptionBackend(to backend: TranscriptionBackend) {
        guard !isRecording else {
            addDebug("Cannot switch ASR backend while recording")
            return
        }
        selectedTranscriptionBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: "transcriptionBackend")
        addDebug("ASR backend set to \(backend.rawValue)")
    }

    // MARK: - Subsystems

    let audioCaptureManager = AudioCaptureManager()
    let transcriptionEngine = TranscriptionEngine()
    let parakeetEngine = ParakeetTranscriptionEngine()
    private let meetingAppDetector = MeetingAppDetector()
    private let meetingAutoDetector = MeetingAutoDetector()
    private let speakerDiarizer = SpeakerDiarizer()
    private let liveSpeakerDiarizer = LiveSpeakerDiarizer()
    let speakerIdentifier = SpeakerIdentifier()
    let realTimeSpeakerDetector = RealTimeSpeakerDetector()
    let alwaysOnCapture = AlwaysOnCaptureManager()
    let mlxProvider = MLXProvider()
    private let sharedAnalysisQueue = AnalysisQueue()
    private(set) var voiceInputManager: VoiceInputManager!
    private(set) var memoryManager: MemoryManager!
    private(set) var recommendationAgent: RecommendationAgent!
    private var persistenceManager: MeetingPersistenceManager?
    private var modelContainer: ModelContainer?

    init() {
        // Restore saved backend
        if let saved = UserDefaults.standard.string(forKey: "transcriptionBackend"),
           let backend = TranscriptionBackend(rawValue: saved) {
            selectedTranscriptionBackend = backend
        }
        voiceInputManager = VoiceInputManager(transcriptionProvider: activeTranscriptionEngine)
        memoryManager = MemoryManager(llmProvider: mlxProvider, analysisQueue: sharedAnalysisQueue)
        recommendationAgent = RecommendationAgent(
            llmProvider: mlxProvider,
            memoryManager: memoryManager,
            analysisQueue: sharedAnalysisQueue
        )
    }

    // MARK: - Tasks

    private var transcriptionTask: Task<Void, Never>?
    private var segmentConsumerTask: Task<Void, Never>?

    // MARK: - Configuration

    /// Must be called before `setup()` to enable persistence and model discovery.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        persistenceManager = MeetingPersistenceManager(modelContainer: modelContainer)
        MLXModelManager.shared.initialScan()
        // Load known speaker profiles for voice identification
        speakerIdentifier.loadKnownProfiles(from: modelContainer)
    }

    // MARK: - Initialization

    func setup() {
        // Sync settings from UserDefaults (written by SettingsView @AppStorage)
        autoDetectEnabled = UserDefaults.standard.object(forKey: "autoDetectMeetings") as? Bool ?? true
        transcriptionEngine.modelName = UserDefaults.standard.string(forKey: "whisperModel")
            ?? UserDefaults.standard.string(forKey: "transcriptionModel")
            ?? "large-v3-turbo"
        let langSetting = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        let langValue = langSetting == "auto" ? nil : langSetting
        transcriptionEngine.language = langValue
        parakeetEngine.language = langValue

        // Restore saved analysis provider choice
        if let savedProvider = UserDefaults.standard.string(forKey: "analysisProvider"),
           let choice = AnalysisProvider(rawValue: savedProvider) {
            switchAnalysisProvider(to: choice)
        }

        // Auto-load LLM: try previously selected model, or download best for this machine
        autoLoadLLMModel()

        guard autoDetectEnabled else { return }

        meetingAutoDetector.onMeetingStarted = { [weak self] meeting in
            guard let self else { return }
            self.detectedMeeting = meeting
            self.autoDetectStatus = "Detected: \(meeting.appName)"
            // If already in conversation, elevate to meeting; otherwise start fresh
            if self.captureState == .conversation {
                self.elevateTo(meeting: meeting)
            } else {
                self.startRecording(from: meeting)
            }
        }

        meetingAutoDetector.onMeetingEnded = { [weak self] in
            guard let self else { return }
            self.detectedMeeting = nil
            self.autoDetectStatus = "Monitoring..."
            // De-elevate to conversation if in meeting, otherwise stop
            if self.captureState == .meeting {
                self.deElevateMeeting()
            } else {
                self.stopRecording()
            }
        }

        meetingAutoDetector.startMonitoring()
    }

    // MARK: - Recording Control

    func startRecording(from detectedMeeting: DetectedMeeting? = nil) {
        guard captureState == .off || captureState == .listening else { return }
        captureState = detectedMeeting != nil ? .meeting : .conversation
        recordingError = nil

        // Clear previous meeting data
        activeTranscriptSegments = []
        speakers = []
        recommendations = []
        speakerRenames = [:]
        clearChat()
        memoryManager.reset()
        speakerIdentifier.reset()
        // Reload known profiles for auto-identification
        if let mc = modelContainer {
            speakerIdentifier.loadKnownProfiles(from: mc)
        }

        // Load speaker embedding models (for voice profile extraction when naming)
        Task {
            do {
                await realTimeSpeakerDetector.reset()
                await realTimeSpeakerDetector.configure(
                    onDebugLog: { [weak self] msg in
                        self?.addDebug(msg)
                    }
                )
                try await realTimeSpeakerDetector.loadModels()
            } catch {
                addDebug("Speaker detection load failed: \(error.localizedDescription)")
            }
        }

        let title: String
        let sourceApp: String

        if let detected = detectedMeeting {
            title = detected.title
            sourceApp = detected.appName
        } else {
            let meetingApps = meetingAppDetector.detectRunningMeetingApps()
            title = "Meeting — \(formattedNow())"
            sourceApp = meetingApps.first?.name ?? "Unknown"
        }

        let meeting = Meeting(title: title, sourceApp: sourceApp)
        currentMeeting = meeting

        // Create and start the analytics engine (uses selected analysis provider)
        let provider = analysisLLMProvider
        let engine = MeetingEngine(llmProvider: provider, analysisQueue: sharedAnalysisQueue)
        engine.segmentsProvider = { [weak self] in
            self?.activeTranscriptSegments ?? []
        }
        engine.onRecommendation = { [weak self] rec in
            guard let self else { return }
            self.appendRecommendation(rec)
            self.currentTopicName = self.meetingEngine?.currentTopicName
        }
        engine.onSentimentsUpdated = { [weak self] scores in
            guard let self else { return }
            for (id, score) in scores {
                if let index = self.activeTranscriptSegments.firstIndex(where: { $0.id == id }) {
                    self.activeTranscriptSegments[index].sentiment = score
                }
            }
        }
        meetingEngine = engine
        if !meetingAgenda.isEmpty {
            engine.meetingAgenda = meetingAgenda
        }
        engine.start()
        memoryManager.start()

        // Wire LLM recommendation agent
        recommendationAgent.onRecommendations = { [weak self] recs in
            guard let self else { return }
            for rec in recs {
                self.appendRecommendation(rec)
            }
        }
        engine.onTopicDetected = { [weak self] topicName in
            guard let self else { return }
            self.recommendationAgent.onTopicShift(
                newTopic: topicName,
                allSegments: self.activeTranscriptSegments,
                speakers: self.speakers,
                topics: self.meetingEngine?.topics ?? [],
                actionItems: self.meetingEngine?.detectedActions ?? [],
                agenda: self.meetingAgenda.isEmpty ? nil : self.meetingAgenda,
                contentType: self.meetingEngine?.contentTypeClassifier.detectedType
            )
        }
        engine.onAnalysisPassComplete = { [weak self] in
            guard let self else { return }
            self.recommendationAgent.onPeriodicCheck(
                allSegments: self.activeTranscriptSegments,
                speakers: self.speakers,
                topics: self.meetingEngine?.topics ?? [],
                actionItems: self.meetingEngine?.detectedActions ?? [],
                agenda: self.meetingAgenda.isEmpty ? nil : self.meetingAgenda,
                currentTopic: self.currentTopicName,
                contentType: self.meetingEngine?.contentTypeClassifier.detectedType
            )
        }
        engine.onSpeakerDominanceShift = { [weak self] speaker, percent in
            guard let self else { return }
            self.recommendationAgent.onSpeakerDominanceShift(
                speaker: speaker,
                percent: percent,
                allSegments: self.activeTranscriptSegments,
                speakers: self.speakers,
                topics: self.meetingEngine?.topics ?? [],
                actionItems: self.meetingEngine?.detectedActions ?? [],
                agenda: self.meetingAgenda.isEmpty ? nil : self.meetingAgenda,
                contentType: self.meetingEngine?.contentTypeClassifier.detectedType
            )
        }

        // Batch speaker diarization via SpeakerKit (Full pass only, every 20s).
        // WeSpeaker per-segment embeddings don't work well for system audio
        // (same channel makes all voices look similar). SpeakerKit uses spectral
        // change detection which works better.
        Task {
            await liveSpeakerDiarizer.configure(
                audioProvider: { [weak self] in
                    self?.activeTranscriptionEngine.accumulatedAudio ?? []
                },
                segmentsProvider: { [weak self] in
                    self?.activeTranscriptSegments ?? []
                },
                onDiarizationComplete: { [weak self] updatedSegments in
                    guard let self else { return }

                    // Apply rename map to diarized segments
                    var segments = updatedSegments
                    for i in segments.indices {
                        segments[i].speakerLabel = self.displayName(for: segments[i].speakerLabel)
                    }

                    // Merge: the diarizer worked on a snapshot taken at start of its run.
                    // New segments may have arrived since then — append any that aren't
                    // in the diarized set so we never lose data.
                    let diarizedIDs = Set(segments.map(\.id))
                    let newSegments = self.activeTranscriptSegments.filter { !diarizedIDs.contains($0.id) }
                    segments.append(contentsOf: newSegments)

                    self.activeTranscriptSegments = segments
                    self.rebuildSpeakers(from: segments)

                    // Set defaultSpeakerName to the speaker with the most segments
                    // (not just the last one — avoids short interjections stealing the label)
                    var labelCounts: [String: Int] = [:]
                    for seg in updatedSegments.suffix(10) {
                        labelCounts[seg.speakerLabel, default: 0] += 1
                    }
                    if let dominant = labelCounts.max(by: { $0.value < $1.value }) {
                        self.activeTranscriptionEngine.defaultSpeakerName = dominant.key
                    }
                },
                onDebugLog: { [weak self] msg in
                    self?.addDebug(msg)
                }
            )
            await liveSpeakerDiarizer.start()
        }

        Task {
            await runTranscriptionPipeline()
        }
    }

    /// Cycle transcription language: auto → en → es → auto.
    /// Takes effect on the next transcription chunk (no restart needed).
    func cycleLanguage() {
        let current = activeTranscriptionEngine.language
        let next: String?
        switch current {
        case nil:    next = "en"    // auto → English
        case "en":   next = "es"    // English → Spanish
        case "es":   next = nil     // Spanish → auto
        default:     next = nil     // anything else → auto
        }
        activeTranscriptionEngine.language = next
        UserDefaults.standard.set(next ?? "auto", forKey: "transcriptionLanguage")
    }

    /// Clear transcript, speakers, and recommendations without stopping recording.
    func clearLiveData() {
        activeTranscriptSegments = []
        speakers = []
        recommendations = []
        recordingError = nil
    }

    /// Toggle mic mute — when muted, mic audio is silenced but system audio continues.
    func toggleMute() {
        isMicMuted.toggle()
        audioCaptureManager.isMicMuted = isMicMuted
        addDebug(isMicMuted ? "Mic muted" : "Mic unmuted")
    }

    /// Rename a speaker. Works from either the Speakers column or the Live Feed.
    ///
    /// Also extracts and saves a voice embedding for the speaker so they can be
    /// recognized in future recordings.
    func renameSpeaker(from oldName: String, to newName: String) {
        guard !newName.isEmpty, oldName != newName else { return }

        // 1. All raw labels that currently show as oldName → now show as newName
        let labels = rawLabels(for: oldName)
        for label in labels {
            speakerRenames[label] = newName
        }

        // 2. Update every segment that displays oldName
        for i in activeTranscriptSegments.indices {
            if activeTranscriptSegments[i].speakerLabel == oldName {
                activeTranscriptSegments[i].speakerLabel = newName
            }
        }

        // 3. Merge speaker entries
        rebuildSpeakers(from: activeTranscriptSegments)

        // 4. Save voice embedding (trains the profile for better future matching)
        Task {
            await saveVoiceProfile(speakerLabel: oldName, displayName: newName)
        }
    }

    /// Remove a speaker from the speakers list and re-label their segments as the next speaker.
    func removeSpeaker(name: String) {
        speakers.removeAll { $0.name == name }
    }

    /// After diarization, try to match each unnamed speaker against saved voice profiles.
    /// If a match is found, auto-rename the speaker to the known name.
    private func autoIdentifySpeakers(diarizedSegments: [TranscriptSegment]) async {
        guard let mc = modelContainer else { return }

        let audio = activeTranscriptionEngine.accumulatedAudio
        guard !audio.isEmpty else { return }

        // Load known profiles
        let profiles = speakerIdentifier.loadKnownProfilesForDetector(from: mc)
        guard !profiles.isEmpty else { return }

        // Find unique raw speaker labels that don't already have a user rename
        let rawLabels = Set(diarizedSegments.map(\.speakerLabel))
        let unmappedLabels = rawLabels.filter { speakerRenames[$0] == nil }
        guard !unmappedLabels.isEmpty else { return }

        for rawLabel in unmappedLabels {
            // Only auto-ID speakers with enough evidence (3+ segments)
            let segCount = diarizedSegments.filter({ $0.speakerLabel == rawLabel }).count
            guard segCount >= 3 else { continue }

            // Find the longest segment for this speaker
            guard let bestSegment = diarizedSegments
                .filter({ $0.speakerLabel == rawLabel })
                .max(by: { $0.duration < $1.duration })
            else { continue }

            // Extract audio slice
            let startSample = max(0, Int(bestSegment.startTime * 16000))
            let endSample = min(audio.count, Int(bestSegment.endTime * 16000))
            let maxSamples = 5 * 16000
            let sliceEnd = min(endSample, startSample + maxSamples)
            guard sliceEnd - startSample >= 16000 else { continue }

            let audioSlice = Array(audio[startSample..<sliceEnd])
            guard let embedding = await realTimeSpeakerDetector.extractEmbedding(from: audioSlice) else { continue }

            // Use the detector's channel-compensated matching
            let label = await realTimeSpeakerDetector.identifySpeaker(embedding: embedding)

            // If the detector matched a known profile name, auto-rename
            let isKnownName = profiles.contains { $0.name == label }
            let alreadyUsed = speakerRenames.values.contains(label)

            if isKnownName && !alreadyUsed && label != rawLabel {
                speakerRenames[rawLabel] = label
                addDebug("Auto-identified \(rawLabel) → \(label)")
            }
        }
    }

    /// Cosine similarity between two Float arrays.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    /// Extract a voice embedding for a speaker and persist it to their Interlocutor profile.
    private func saveVoiceProfile(speakerLabel: String, displayName: String) async {
        let audio = activeTranscriptionEngine.accumulatedAudio
        guard !audio.isEmpty else { return }

        // Find the longest segment for this speaker (use all aliases)
        let labels = rawLabels(for: displayName).union([speakerLabel])
        let matchingSegments = activeTranscriptSegments.filter {
            labels.contains($0.speakerLabel) || $0.speakerLabel == displayName
        }

        guard let bestSegment = matchingSegments.max(by: { $0.duration < $1.duration }) else { return }

        let startSample = max(0, Int(bestSegment.startTime * 16000))
        let endSample = min(audio.count, Int(bestSegment.endTime * 16000))
        let maxSamples = 5 * 16000
        let sliceEnd = min(endSample, startSample + maxSamples)
        guard sliceEnd - startSample >= 16000 else { return }

        let audioSlice = Array(audio[startSample..<sliceEnd])
        guard let embedding = await realTimeSpeakerDetector.extractEmbedding(from: audioSlice) else { return }

        // Save to SwiftData
        do {
            let interlocutor = try persistenceManager?.findOrCreateInterlocutor(name: displayName)
            if let interlocutor {
                let data = SpeakerIdentifier.serializeEmbedding(embedding)
                if interlocutor.voiceEmbeddings.count >= 5 {
                    interlocutor.voiceEmbeddings.removeFirst()
                }
                interlocutor.voiceEmbeddings.append(data)
                addDebug("Saved voice profile for \(displayName) (\(embedding.count)-dim)")
            }
        } catch {
            addDebug("Failed to save voice profile: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard captureState == .conversation || captureState == .meeting else { return }
        captureState = .off

        // Stop pipeline
        if let whisper = activeTranscriptionEngine as? TranscriptionEngine {
            whisper.stopTranscribing()
        } else if let parakeet = activeTranscriptionEngine as? ParakeetTranscriptionEngine {
            parakeet.stopTranscribing()
        }
        audioCaptureManager.stopCapture()

        transcriptionTask?.cancel()
        transcriptionTask = nil
        segmentConsumerTask?.cancel()
        segmentConsumerTask = nil
        chatTask?.cancel()
        memoryManager.stop()
        recommendationAgent.stop()
        Task { await liveSpeakerDiarizer.stop() }

        // Mark all speakers as not speaking
        for i in speakers.indices {
            speakers[i].isSpeaking = false
        }

        // Stop analytics engine and capture snapshot
        currentTopicName = nil
        Task {
            if let engine = meetingEngine {
                pendingAnalytics = await engine.stop()
            }
            meetingEngine = nil
            await runPostMeetingProcessing()
        }
    }

    // MARK: - Meeting Elevation (Phase 3.4)

    /// Elevate from .conversation to .meeting when a meeting app is detected.
    func elevateTo(meeting detectedMeeting: DetectedMeeting) {
        guard captureState == .conversation else { return }
        captureState = .meeting

        let title = detectedMeeting.title
        let sourceApp = detectedMeeting.appName

        let meeting = Meeting(title: title, sourceApp: sourceApp)
        currentMeeting = meeting

        // Link session to meeting
        if let session = currentSession {
            session.sourceType = "meeting"
            session.meeting = meeting
        }

        // Start the full analysis pipeline
        let engine = MeetingEngine(llmProvider: mlxProvider, analysisQueue: sharedAnalysisQueue)
        engine.segmentsProvider = { [weak self] in
            self?.activeTranscriptSegments ?? []
        }
        engine.onRecommendation = { [weak self] rec in
            guard let self else { return }
            self.appendRecommendation(rec)
            self.currentTopicName = self.meetingEngine?.currentTopicName
        }
        engine.onSentimentsUpdated = { [weak self] scores in
            guard let self else { return }
            for (id, score) in scores {
                if let index = self.activeTranscriptSegments.firstIndex(where: { $0.id == id }) {
                    self.activeTranscriptSegments[index].sentiment = score
                }
            }
        }
        meetingEngine = engine
        if !meetingAgenda.isEmpty {
            engine.meetingAgenda = meetingAgenda
        }
        engine.start()
        memoryManager.start()

        // Wire recommendation agent
        recommendationAgent.onRecommendations = { [weak self] recs in
            guard let self else { return }
            for rec in recs { self.appendRecommendation(rec) }
        }
        engine.onTopicDetected = { [weak self] topicName in
            guard let self else { return }
            self.recommendationAgent.onTopicShift(
                newTopic: topicName,
                allSegments: self.activeTranscriptSegments,
                speakers: self.speakers,
                topics: self.meetingEngine?.topics ?? [],
                actionItems: self.meetingEngine?.detectedActions ?? [],
                agenda: self.meetingAgenda.isEmpty ? nil : self.meetingAgenda,
                contentType: self.meetingEngine?.contentTypeClassifier.detectedType
            )
        }
        engine.onAnalysisPassComplete = { [weak self] in
            guard let self else { return }
            self.recommendationAgent.onPeriodicCheck(
                allSegments: self.activeTranscriptSegments,
                speakers: self.speakers,
                topics: self.meetingEngine?.topics ?? [],
                actionItems: self.meetingEngine?.detectedActions ?? [],
                agenda: self.meetingAgenda.isEmpty ? nil : self.meetingAgenda,
                currentTopic: self.currentTopicName,
                contentType: self.meetingEngine?.contentTypeClassifier.detectedType
            )
        }
        engine.onSpeakerDominanceShift = { [weak self] speaker, percent in
            guard let self else { return }
            self.recommendationAgent.onSpeakerDominanceShift(
                speaker: speaker, percent: percent,
                allSegments: self.activeTranscriptSegments,
                speakers: self.speakers,
                topics: self.meetingEngine?.topics ?? [],
                actionItems: self.meetingEngine?.detectedActions ?? [],
                agenda: self.meetingAgenda.isEmpty ? nil : self.meetingAgenda,
                contentType: self.meetingEngine?.contentTypeClassifier.detectedType
            )
        }

        // Backfill: ingest existing segments into the engine
        for segment in activeTranscriptSegments {
            engine.ingest(segment)
        }

        addDebug("Elevated to meeting: \(title)")
    }

    /// De-elevate from .meeting back to .conversation or .off.
    func deElevateMeeting() {
        guard captureState == .meeting else { return }

        // Stop meeting-specific pipelines
        memoryManager.stop()
        recommendationAgent.stop()
        currentTopicName = nil

        Task {
            if let engine = meetingEngine {
                pendingAnalytics = await engine.stop()
            }
            meetingEngine = nil
            await runPostMeetingProcessing()
        }

        captureState = .conversation
        addDebug("De-elevated from meeting to conversation")
    }

    // MARK: - Always-On Listening (Phase 3.2)

    /// Enter always-on listening mode.
    func startListening() {
        guard captureState == .off else { return }
        captureState = .listening

        alwaysOnCapture.onConversationStarted = { [weak self] in
            guard let self, self.captureState == .listening else { return }
            self.startRecording()
        }

        alwaysOnCapture.onConversationEnded = { [weak self] in
            guard let self, self.captureState == .conversation else { return }
            self.stopRecording()
            self.startListening()
        }

        addDebug("Entered always-on listening mode")
    }

    /// Stop always-on listening.
    func stopListening() {
        alwaysOnCapture.forceIdle()
        if captureState == .listening {
            captureState = .off
        }
    }

    // MARK: - Post-Meeting Processing

    private func runPostMeetingProcessing() async {
        guard let meeting = currentMeeting else { return }

        let audio = activeTranscriptionEngine.accumulatedAudio
        let segments = activeTranscriptSegments

        guard !segments.isEmpty else { return }

        // Try SpeakerKit diarization for final refinement
        var finalSegments = segments
        if !audio.isEmpty {
            isDiarizing = true
            do {
                let output = try await speakerDiarizer.diarize(audio: audio, segments: segments)
                // Apply rename map to diarized segments
                var diarSegments = output.segments
                for i in diarSegments.indices {
                    diarSegments[i].speakerLabel = displayName(for: diarSegments[i].speakerLabel)
                }
                activeTranscriptSegments = diarSegments
                rebuildSpeakers(from: diarSegments)
                finalSegments = diarSegments

                pendingDiarizationOutput = output
            } catch {
                print("[AppState] Post-meeting diarization failed: \(error)")
                pendingDiarizationOutput = nil
            }
            isDiarizing = false
        }

        pendingMeeting = meeting
        pendingSegments = finalSegments

        // Extract voice embeddings for persistence
        let speakerLabels = Array(Set(finalSegments.map(\.speakerLabel)))
        await extractVoiceEmbeddings(audio: audio, segments: finalSegments, speakerLabels: speakerLabels)

        // Check if all speakers already have real names (not "Speaker A/B/C" patterns)
        let allNamed = speakerLabels.allSatisfy { label in
            !label.hasPrefix("Speaker ") // Raw diar labels start with "Speaker "
        }

        if allNamed {
            // All speakers were already named during the session — save directly
            let mapping = Dictionary(uniqueKeysWithValues: speakerLabels.map { ($0, $0) })
            savePendingMeeting(speakerToInterlocutor: mapping)
            addDebug("All speakers named — saved without naming sheet")
        } else {
            // Some speakers unnamed — show naming sheet with known names pre-filled
            showSpeakerNamingSheet = true
        }

        activeTranscriptionEngine.clearAccumulatedAudio()
    }

    /// Extract a representative voice embedding per speaker from accumulated audio.
    /// Finds the longest segment for each speaker and extracts a WeSpeaker embedding.
    private func extractVoiceEmbeddings(
        audio: [Float],
        segments: [TranscriptSegment],
        speakerLabels: [String]
    ) async {
        var embeddings: [String: [Float]] = [:]

        for label in speakerLabels {
            // Find the longest segment for this speaker (best audio quality)
            guard let bestSegment = segments
                .filter({ $0.speakerLabel == label })
                .max(by: { $0.duration < $1.duration })
            else { continue }

            // Extract audio slice (at least 2s, up to 5s)
            let startSample = max(0, Int(bestSegment.startTime * 16000))
            let endSample = min(audio.count, Int(bestSegment.endTime * 16000))
            let maxSamples = 5 * 16000 // 5 seconds max
            let sliceEnd = min(endSample, startSample + maxSamples)

            guard sliceEnd - startSample >= 16000 else { continue } // need at least 1s

            let audioSlice = Array(audio[startSample..<sliceEnd])
            if let embedding = await realTimeSpeakerDetector.extractEmbedding(from: audioSlice) {
                embeddings[label] = embedding
                addDebug("Voice embedding extracted for \(label) (\(audioSlice.count / 16000)s)")
            }
        }

        pendingVoiceEmbeddings = embeddings
    }

    /// Rebuild the speakers array from updated transcript segments.
    private func rebuildSpeakers(from segments: [TranscriptSegment]) {
        var speakerMap: [String: SpeakerInfo] = [:]
        for segment in segments {
            if var info = speakerMap[segment.speakerLabel] {
                info.talkTime += segment.duration
                speakerMap[segment.speakerLabel] = info
            } else {
                let color = Theme.Colors.speakerPalette[
                    speakerMap.count % Theme.Colors.speakerPalette.count
                ]
                speakerMap[segment.speakerLabel] = SpeakerInfo(
                    id: segment.speakerID ?? UUID(),
                    name: segment.speakerLabel,
                    talkTime: segment.duration,
                    color: color
                )
            }
        }
        speakers = speakerMap.values.sorted { $0.talkTime > $1.talkTime }
    }

    /// Called when user enters names in the speaker naming sheet.
    func completeSpeakerNaming(nameMapping: [String: String]) {
        savePendingMeeting(speakerToInterlocutor: nameMapping)
    }

    /// Called when user skips naming speakers.
    func skipSpeakerNaming() {
        savePendingMeeting(speakerToInterlocutor: [:])
    }

    private func savePendingMeeting(speakerToInterlocutor: [String: String]) {
        guard let meeting = pendingMeeting else {
            clearPendingState()
            return
        }

        let stats = buildSpeakerStats(from: pendingSegments)
        let analytics = pendingAnalytics
        let embeddings = pendingVoiceEmbeddings

        Task {
            do {
                try persistenceManager?.saveMeeting(
                    meeting,
                    segments: pendingSegments,
                    speakerStats: stats,
                    speakerToInterlocutor: speakerToInterlocutor,
                    analytics: analytics,
                    voiceEmbeddings: embeddings
                )
            } catch {
                print("[AppState] Failed to save meeting: \(error)")
            }
        }

        clearPendingState()
    }

    private func buildSpeakerStats(from segments: [TranscriptSegment]) -> [String: SpeakerStats] {
        var stats: [String: (talkTime: TimeInterval, interventions: Int)] = [:]
        var lastSpeaker: String?

        for segment in segments {
            let label = segment.speakerLabel
            var entry = stats[label] ?? (talkTime: 0, interventions: 0)
            entry.talkTime += segment.duration
            if label != lastSpeaker {
                entry.interventions += 1
            }
            stats[label] = entry
            lastSpeaker = label
        }

        return stats.mapValues { SpeakerStats(talkTime: $0.talkTime, interventionCount: $0.interventions) }
    }

    private func clearPendingState() {
        showSpeakerNamingSheet = false
        pendingDiarizationOutput = nil
        pendingMeeting = nil
        pendingSegments = []
        pendingAnalytics = nil
        pendingVoiceEmbeddings = [:]
    }

    // MARK: - Chat

    /// Send a user question about the current meeting and stream the LLM response.
    func sendChatMessage(_ text: String) async {
        // Cancel any in-flight generation before starting a new one
        chatTask?.cancel()

        let userMessage = ChatMessage(role: .user, content: text)
        chatMessages.append(userMessage)

        // Use the active analysis provider (Claude or local MLX)
        let chatProvider = analysisLLMProvider
        guard await chatProvider.isAvailable else {
            chatMessages.append(ChatMessage(
                role: .assistant,
                content: "No LLM available. Load a local model or switch to Claude in the menu bar."
            ))
            return
        }

        isGeneratingResponse = true
        streamingResponse = ""

        // Build meeting context using three-tier memory
        let context = memoryManager.buildContext(
            allSegments: activeTranscriptSegments,
            speakers: speakers,
            topics: meetingEngine?.topics ?? [],
            actionItems: meetingEngine?.detectedActions ?? [],
            agenda: meetingAgenda.isEmpty ? nil : meetingAgenda,
            currentTopic: currentTopicName
        )

        // Build messages: system + context + conversation history (last 6 turns)
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: PromptTemplates.meetingQA),
            ChatMessage(role: .user, content: PromptTemplates.meetingQAContext(context)),
            ChatMessage(role: .assistant, content: "I have the meeting context. How can I help?"),
        ]

        // Append recent conversation history (skip system messages)
        let recentTurns = chatMessages.suffix(6)
        messages.append(contentsOf: recentTurns)

        chatTask = Task {
            defer {
                isGeneratingResponse = false
                streamingResponse = ""
            }

            do {
                let stream = try await chatProvider.stream(messages: messages)
                var fullResponse = ""
                var lastUIUpdate = ContinuousClock.now

                for await chunk in stream {
                    guard !Task.isCancelled else { break }
                    fullResponse += chunk
                    // Throttle UI updates to ~12/sec to avoid per-token view thrashing
                    let now = ContinuousClock.now
                    if now - lastUIUpdate > .milliseconds(80) {
                        streamingResponse = fullResponse
                        lastUIUpdate = now
                    }
                }
                streamingResponse = fullResponse // final flush

                if !Task.isCancelled {
                    chatMessages.append(ChatMessage(role: .assistant, content: fullResponse))
                }
            } catch {
                chatMessages.append(ChatMessage(
                    role: .assistant,
                    content: "Error: \(error.localizedDescription)"
                ))
            }
        }
    }

    /// Append a recommendation, deduplicating, auto-dismissing stale ones (>60s), capping at 5.
    private func appendRecommendation(_ rec: Recommendation) {
        // Prune stale recommendations older than 60s
        let cutoff = Date.now.addingTimeInterval(-60)
        recommendations.removeAll { $0.timestamp < cutoff }

        // Don't add if identical text already visible
        guard !recommendations.contains(where: { $0.text == rec.text }) else { return }

        recommendations.append(rec)

        // Keep at most 5 visible — remove oldest if over
        while recommendations.count > 5 {
            recommendations.removeFirst()
        }
    }

    /// Dismiss a recommendation by ID.
    func dismissRecommendation(id: UUID) {
        recommendations.removeAll { $0.id == id }
    }

    /// Clear chat history.
    func clearChat() {
        chatTask?.cancel()
        chatMessages = []
        isGeneratingResponse = false
        streamingResponse = ""
    }

    // MARK: - Private

    // MARK: - LLM Auto-Load

    /// Auto-load the best available LLM model on startup.
    /// Deferred and wrapped in error handling to avoid crashing on Metal/MLX issues.
    private func autoLoadLLMModel() {
        // If Claude CLI is available, prefer that — no Metal dependency
        Task {
            let claudeCheck = ClaudeCLIProvider(model: .haiku)
            if await claudeCheck.isAvailable {
                if selectedAnalysisProvider == .localMLX {
                    // Default to Claude Haiku if available and no explicit choice was made
                    let savedProvider = UserDefaults.standard.string(forKey: "analysisProvider")
                    if savedProvider == nil {
                        switchAnalysisProvider(to: .claudeHaiku)
                        addDebug("Claude CLI available — defaulting to Haiku for analysis")
                    }
                }
            }
        }

        // Try loading local MLX model in background (may fail if Metal not available)
        Task {
            let manager = MLXModelManager.shared

            // Wait for model scan to complete
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(500))
                if !manager.availableModels.isEmpty { break }
            }

            addDebug("LLM scan found \(manager.availableModels.count) models")

            // Try previously selected model first
            if let selected = manager.selectedModel, manager.isDownloaded(selected) {
                addDebug("Auto-loading LLM: \(selected.name)")
                do {
                    try await manager.loadModel(selected)
                    addDebug("LLM loaded: \(selected.name)")
                } catch {
                    addDebug("LLM load failed (Metal?): \(error.localizedDescription)")
                }
                return
            }

            // Find the best (largest) downloaded model that fits in RAM
            let downloaded = manager.availableModels
                .filter { manager.isDownloaded($0) && manager.canFitInRAM($0) }
                .sorted { $0.sizeOnDisk < $1.sizeOnDisk }
            if let best = downloaded.last {
                addDebug("Auto-loading LLM: \(best.name) (\(MLXModelManager.formatBytes(best.sizeOnDisk)))")
                do {
                    try await manager.loadModel(best)
                    addDebug("LLM loaded: \(best.name)")
                } catch {
                    addDebug("LLM load failed (Metal?): \(error.localizedDescription)")
                }
                return
            }

            addDebug("No downloaded LLM found that fits in RAM")
        }
    }

    private func addDebug(_ msg: String) {
        debugLog.append(msg)
        if debugLog.count > 50 { debugLog.removeFirst() }
    }

    private func runTranscriptionPipeline() async {
        recordingError = nil

        let engine = activeTranscriptionEngine
        let backendName = selectedTranscriptionBackend.rawValue

        // Load ASR model if needed (may download on first run)
        if !engine.isModelLoaded {
            isModelLoading = true
            addDebug("Loading \(backendName) model...")
            do {
                try await engine.loadModel()
                addDebug("\(backendName) model loaded")
            } catch {
                print("[AppState] Model loading failed: \(error)")
                isModelLoading = false
                recordingError = "Failed to load transcription model: \(error.localizedDescription)"
                captureState = .off
                return
            }
            isModelLoading = false
        }

        addDebug("Language: \(engine.language ?? "auto-detect")")

        // Set up streams BEFORE starting capture to avoid losing early buffers
        let audioStream = audioCaptureManager.audioStream

        // Get the segment stream from the active engine
        let segmentStream: AsyncStream<TranscriptSegment>
        if let whisper = engine as? TranscriptionEngine {
            segmentStream = whisper.transcriptStream
        } else if let parakeet = engine as? ParakeetTranscriptionEngine {
            segmentStream = parakeet.transcriptStream
        } else {
            recordingError = "Unknown transcription backend"
            captureState = .off
            return
        }

        // Start audio capture — tries process tap → ScreenCaptureKit → microphone
        do {
            try await audioCaptureManager.startCapture()
            addDebug("Audio capture: \(audioCaptureManager.captureMode.rawValue)")
        } catch {
            print("[AppState] Audio capture failed: \(error)")
            recordingError = "Audio capture failed: \(error.localizedDescription)"
            captureState = .off
            return
        }

        // Set default speaker name based on capture mode
        let userName = UserDefaults.standard.string(forKey: "userName") ?? "Danny"
        if audioCaptureManager.captureMode == .microphone {
            engine.defaultSpeakerName = userName
            addDebug("Mic mode: default speaker = \(userName)")
        } else {
            engine.defaultSpeakerName = "Speaker 1"
        }

        // Launch transcription in background (consumes audio, produces transcript segments)
        if let whisper = engine as? TranscriptionEngine {
            transcriptionTask = Task.detached {
                await whisper.startTranscribing(from: audioStream)
            }
        } else if let parakeet = engine as? ParakeetTranscriptionEngine {
            transcriptionTask = Task.detached {
                await parakeet.startTranscribing(from: audioStream)
            }
        }

        // Consume transcript segments. Use the diarizer's labels as the source of truth.
        // Between diarizer runs, segments get defaultSpeakerName (last diarized speaker).
        for await segment in segmentStream {
            guard isRecording else { break }
            var seg = segment
            seg.speakerLabel = displayName(for: seg.speakerLabel)
            activeTranscriptSegments.append(seg)
            updateSpeaker(for: seg)
            meetingEngine?.ingest(seg)
            memoryManager.ingest(allSegments: activeTranscriptSegments)
        }
    }

    /// Update speaker tracking based on a new transcript segment.
    private func updateSpeaker(for segment: TranscriptSegment) {
        // Mark all speakers as not currently speaking
        for i in speakers.indices {
            speakers[i].isSpeaking = false
        }

        if let index = speakers.firstIndex(where: { $0.name == segment.speakerLabel }) {
            // Update existing speaker
            speakers[index].talkTime += segment.duration
            speakers[index].isSpeaking = true
        } else {
            // Add new speaker
            let color = Theme.Colors.speakerPalette[
                speakers.count % Theme.Colors.speakerPalette.count
            ]
            speakers.append(SpeakerInfo(
                id: segment.speakerID ?? UUID(),
                name: segment.speakerLabel,
                talkTime: segment.duration,
                isSpeaking: true,
                color: color
            ))
        }
    }

    private func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: .now)
    }
}

// MARK: - Supporting Types

/// Lightweight speaker info displayed in the overlay.
struct SpeakerInfo: Identifiable {
    let id: UUID
    var name: String
    var talkTime: TimeInterval = 0
    var isSpeaking: Bool = false
    var color: Color = .blue
}

/// An AI recommendation surfaced during a meeting.
struct Recommendation: Identifiable {
    let id = UUID()
    let text: String
    let category: Category
    let timestamp: Date = .now

    enum Category: String {
        case suggestion
        case warning
        case insight
        case observation
        case risk
        case summary
        case nextTopic = "next_topic"
    }
}
