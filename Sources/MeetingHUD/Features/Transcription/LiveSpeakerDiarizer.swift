import Foundation
import SpeechVAD

/// Runs speaker diarization on accumulated audio every 2s.
/// Uses PyannoteDiarizationPipeline for spectral segmentation + clustering,
/// which detects speaker changes from audio characteristics — works well
/// even when all audio comes through the same system capture channel.
actor LiveSpeakerDiarizer {

    /// How often to run diarization (seconds).
    private let interval: TimeInterval = 2.0

    /// Minimum audio before first run (seconds).
    private let minAudioDuration: TimeInterval = 8.0

    private var pipeline: PyannoteDiarizationPipeline?
    private var sortformer: SortformerDiarizer?
    private var isRunning = false
    private var timerTask: Task<Void, Never>?
    private var runCount = 0
    private var isProcessing = false

    /// Stable labels assigned in order of first appearance.
    private var stableLabels: [String] = []

    /// Best speaker count seen so far.
    private var maxSpeakersSeen = 1
    /// Consecutive runs that found fewer speakers than max — allows regression after streak.
    private var regressionStreak = 0

    private var onDiarizationComplete: (([TranscriptSegment]) -> Void)?
    private var onDebugLog: ((String) -> Void)?
    private var audioProvider: (() -> [Float])?
    private var stereoAudioProvider: (() -> [Float])?
    private var segmentsProvider: (() -> [TranscriptSegment])?

    /// Shared GPU queue — serializes diarization with LLM inference to prevent Metal crashes.
    private var analysisQueue: AnalysisQueue?

    /// Stereo-aware diarizer (used when stereo audio is available).
    private var stereoDiarizer = StereoSpeakerDiarizer()

    func configure(
        audioProvider: @escaping () -> [Float],
        stereoAudioProvider: (() -> [Float])? = nil,
        segmentsProvider: @escaping () -> [TranscriptSegment],
        onDiarizationComplete: @escaping ([TranscriptSegment]) -> Void,
        onDebugLog: ((String) -> Void)? = nil,
        analysisQueue: AnalysisQueue? = nil
    ) {
        self.audioProvider = audioProvider
        self.stereoAudioProvider = stereoAudioProvider
        self.segmentsProvider = segmentsProvider
        self.onDiarizationComplete = onDiarizationComplete
        self.onDebugLog = onDebugLog
        self.analysisQueue = analysisQueue
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        stableLabels = []
        maxSpeakersSeen = 1
        regressionStreak = 0
        runCount = 0

        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.runDiarization()
                try? await Task.sleep(for: .seconds(self?.interval ?? 20))
            }
        }
    }

    func stop() {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        pipeline = nil
        stableLabels = []
    }

    private func log(_ msg: String) {
        print("[LiveDiarizer] \(msg)")
        onDebugLog?(msg)
    }

    private func runDiarization() async {
        guard !isProcessing else { return }
        guard let audioProvider, let segmentsProvider, let onDiarizationComplete else { return }

        let audio = audioProvider()
        let segments = segmentsProvider()
        let duration = Double(audio.count) / 16000.0

        guard !segments.isEmpty, duration >= minAudioDuration else { return }

        isProcessing = true
        defer { isProcessing = false }
        runCount += 1

        // Use Pyannote pipeline (stereo diarizer is too slow for live use)
        await runPyannoteDiarization(audio: audio, segments: segments, duration: duration)
    }

    private func runStereoDiarization(stereoAudio: [Float], monoAudio: [Float], segments: [TranscriptSegment], duration: Double) async {
        do {
            try await stereoDiarizer.loadModels()
        } catch {
            log("Stereo diarizer load failed: \(error.localizedDescription), falling back to Pyannote")
            await runPyannoteDiarization(audio: monoAudio, segments: segments, duration: duration)
            return
        }

        let startTime = Date()
        let result = await stereoDiarizer.diarize(stereoAudio: stereoAudio, sampleRate: 16000)
        let elapsed = Date().timeIntervalSince(startTime)

        guard !result.segments.isEmpty else {
            log("Run #\(runCount) stereo: no segments, falling back to Pyannote")
            await runPyannoteDiarization(audio: monoAudio, segments: segments, duration: duration)
            return
        }

        var seenIDs: [Int] = []
        for seg in result.segments {
            if !seenIDs.contains(seg.speakerId) { seenIDs.append(seg.speakerId) }
        }

        let speakerCount = seenIDs.count
        log("Run #\(runCount) stereo (\(String(format: "%.1f", elapsed))s): \(String(format: "%.0f", duration))s audio, \(speakerCount) speakers, \(result.segments.count) segs")

        applyDiarization(speakerCount: speakerCount, seenIDs: seenIDs, segments: segments) { id in
            result.segments.filter { $0.speakerId == id }
                .map { (startTime: $0.startTime, endTime: $0.endTime) }
        }
    }

    private func runPyannoteDiarization(audio: [Float], segments: [TranscriptSegment], duration: Double) async {
        do {
            // Use Sortformer (CoreML, Neural Engine, 120x real-time) instead of Pyannote
            if sortformer == nil {
                log("Loading Sortformer diarizer (CoreML)...")
                sortformer = try await SortformerDiarizer.fromPretrained()
                log("Sortformer loaded")
            }
            guard let sortformer else { return }

            let startTime = Date()
            let config = DiarizationConfig(
                onset: 0.35,
                offset: 0.25,
                minSpeechDuration: 0.3,
                minSilenceDuration: 0.15,
                clusteringThreshold: 0.4 // WeSpeaker clustering — low threshold to separate voices in compressed mono audio
            )
            sortformer.resetState()
            let result = sortformer.diarize(audio: audio, sampleRate: 16000, config: config)
            let elapsed = Date().timeIntervalSince(startTime)

            var seenIDs: [Int] = []
            for diarSeg in result.segments {
                if !seenIDs.contains(diarSeg.speakerId) { seenIDs.append(diarSeg.speakerId) }
            }

            let speakerCount = seenIDs.count
            log("Run #\(runCount) pyannote (\(String(format: "%.1f", elapsed))s): \(String(format: "%.0f", duration))s audio, \(result.numSpeakers) raw → \(speakerCount) speakers, \(result.segments.count) segs")

            applyDiarization(speakerCount: speakerCount, seenIDs: seenIDs, segments: segments) { id in
                result.segments.filter { $0.speakerId == id }
                    .map { (startTime: $0.startTime, endTime: $0.endTime) }
            }

        } catch {
            log("Diarization failed: \(error)")
        }
    }

    // MARK: - Shared Alignment

    /// Apply diarization results to transcript segments. Shared by both stereo and Pyannote paths.
    private func applyDiarization(
        speakerCount: Int,
        seenIDs: [Int],
        segments: [TranscriptSegment],
        segmentsForSpeaker: (Int) -> [(startTime: Float, endTime: Float)]
    ) {
        guard let onDiarizationComplete else { return }

        // Speaker count regression logic
        if speakerCount < maxSpeakersSeen {
            regressionStreak += 1
            if regressionStreak >= 5 {
                log("Resetting max speakers from \(maxSpeakersSeen) to \(speakerCount)")
                maxSpeakersSeen = speakerCount
                regressionStreak = 0
            } else {
                log("Skipping \(speakerCount)-speaker result (saw \(maxSpeakersSeen), streak \(regressionStreak)/5)")
                return
            }
        } else {
            regressionStreak = 0
        }
        if speakerCount > maxSpeakersSeen { maxSpeakersSeen = speakerCount }

        // Assign stable labels by matching diarization speakers to existing
        // transcript labels via temporal overlap. This prevents speaker ID flips
        // between runs (where Pyannote arbitrarily swaps speaker 0 and 1).
        while stableLabels.count < seenIDs.count {
            stableLabels.append(Constants.speakerLabel(index: stableLabels.count))
        }
        var idToLabel: [Int: String] = [:]

        if !segments.isEmpty && runCount > 1 {
            // Match diarization IDs to existing labels by overlap
            var usedLabels = Set<String>()
            for id in seenIDs {
                let diarSegs = segmentsForSpeaker(id)
                var bestLabel: String?
                var bestOverlap: Float = 0

                // Find which existing transcript label this diar speaker overlaps most with
                let existingLabels = Set(segments.map(\.speakerLabel))
                for label in existingLabels {
                    guard !usedLabels.contains(label) else { continue }
                    let labelSegs = segments.filter { $0.speakerLabel == label }
                    var totalOverlap: Float = 0
                    for dSeg in diarSegs {
                        for tSeg in labelSegs {
                            let o = max(0, min(Float(tSeg.endTime), dSeg.endTime) - max(Float(tSeg.startTime), dSeg.startTime))
                            totalOverlap += o
                        }
                    }
                    if totalOverlap > bestOverlap {
                        bestOverlap = totalOverlap
                        bestLabel = label
                    }
                }

                if let label = bestLabel, bestOverlap > 0 {
                    idToLabel[id] = label
                    usedLabels.insert(label)
                }
            }
            // Assign new labels for unmatched speakers
            for id in seenIDs where idToLabel[id] == nil {
                let nextLabel = stableLabels.first { !usedLabels.contains($0) } ?? Constants.speakerLabel(index: usedLabels.count)
                idToLabel[id] = nextLabel
                usedLabels.insert(nextLabel)
            }
        } else {
            // First run: assign in order of appearance
            for (index, id) in seenIDs.enumerated() {
                idToLabel[id] = stableLabels[index]
            }
        }

        // Log distribution
        for (id, label) in idToLabel.sorted(by: { $0.key < $1.key }) {
            let spkSegs = segmentsForSpeaker(id)
            let totalDur = spkSegs.reduce(0.0) { $0 + Double($1.endTime - $1.startTime) }
            log("  \(label): \(spkSegs.count) segs, \(String(format: "%.0f", totalDur))s total")
        }

        // Align diarization to transcript segments by temporal overlap
        var updated = segments
        var relabeled = 0

        // Build flat list of (startTime, endTime, speakerId) for overlap matching
        var allDiarSegs: [(startTime: Float, endTime: Float, label: String)] = []
        for (id, label) in idToLabel {
            for seg in segmentsForSpeaker(id) {
                allDiarSegs.append((seg.startTime, seg.endTime, label))
            }
        }

        for i in updated.indices {
            let tStart = Float(updated[i].startTime)
            let tEnd = Float(updated[i].endTime)
            var bestOverlap: Float = 0
            var bestLabel: String?
            for diar in allDiarSegs {
                let overlap = max(0, min(tEnd, diar.endTime) - max(tStart, diar.startTime))
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestLabel = diar.label
                }
            }
            if let label = bestLabel, updated[i].speakerLabel != label {
                updated[i].speakerLabel = label
                relabeled += 1
            }
        }

        log("Relabeled \(relabeled)/\(updated.count) segments")
        onDiarizationComplete(updated)
    }
}
