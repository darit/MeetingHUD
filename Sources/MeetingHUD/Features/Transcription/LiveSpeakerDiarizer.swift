import Foundation
import SpeakerKit

/// Runs speaker diarization on accumulated audio every 20s.
/// Uses SpeakerKit's Pyannote-based spectral segmentation + clustering,
/// which detects speaker changes from audio characteristics — works well
/// even when all audio comes through the same system capture channel.
actor LiveSpeakerDiarizer {

    /// How often to run diarization (seconds).
    private let interval: TimeInterval = 2.0

    /// Minimum audio before first run (seconds).
    private let minAudioDuration: TimeInterval = 8.0

    private var speakerKit: SpeakerKit?
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
    private var segmentsProvider: (() -> [TranscriptSegment])?

    func configure(
        audioProvider: @escaping () -> [Float],
        segmentsProvider: @escaping () -> [TranscriptSegment],
        onDiarizationComplete: @escaping ([TranscriptSegment]) -> Void,
        onDebugLog: ((String) -> Void)? = nil
    ) {
        self.audioProvider = audioProvider
        self.segmentsProvider = segmentsProvider
        self.onDiarizationComplete = onDiarizationComplete
        self.onDebugLog = onDebugLog
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
        speakerKit = nil
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

        do {
            if speakerKit == nil {
                log("Loading SpeakerKit models...")
                speakerKit = try await SpeakerKit(PyannoteConfig())
                log("SpeakerKit models loaded")
            }
            guard let speakerKit else { return }

            // Use default SpeakerKit options — custom thresholds were causing
            // under-segmentation (1 segment for 80s of audio)
            let options = PyannoteDiarizationOptions()

            let startTime = Date()
            let result = try await speakerKit.diarize(audioArray: audio, options: options)
            let elapsed = Date().timeIntervalSince(startTime)

            // Collect unique speaker IDs in order of first appearance
            var seenIDs: [Int] = []
            for diarSeg in result.segments {
                if case .speakerId(let id) = diarSeg.speaker, !seenIDs.contains(id) {
                    seenIDs.append(id)
                }
            }

            let speakerCount = seenIDs.count
            log("Run #\(runCount) (\(String(format: "%.1f", elapsed))s): \(String(format: "%.0f", duration))s audio, \(speakerCount) speakers, \(result.segments.count) diar segs")

            // Allow regression if consistently seeing fewer speakers (5+ consecutive runs)
            if speakerCount < maxSpeakersSeen {
                regressionStreak += 1
                if regressionStreak >= 5 {
                    log("Resetting max speakers from \(maxSpeakersSeen) to \(speakerCount) after \(regressionStreak) consistent runs")
                    maxSpeakersSeen = speakerCount
                    regressionStreak = 0
                } else {
                    log("Skipping \(speakerCount)-speaker result (saw \(maxSpeakersSeen), streak \(regressionStreak)/5)")
                    return
                }
            } else {
                regressionStreak = 0
            }
            if speakerCount > maxSpeakersSeen {
                maxSpeakersSeen = speakerCount
            }

            // Assign stable labels
            while stableLabels.count < seenIDs.count {
                stableLabels.append(Constants.speakerLabel(index: stableLabels.count))
            }
            var idToLabel: [Int: String] = [:]
            for (index, id) in seenIDs.enumerated() {
                idToLabel[id] = stableLabels[index]
            }

            // Log distribution
            for (id, label) in idToLabel.sorted(by: { $0.key < $1.key }) {
                let count = result.segments.filter {
                    if case .speakerId(let sid) = $0.speaker { return sid == id }
                    return false
                }.count
                log("  \(label): \(count) diar segs")
            }

            // Align diarization to transcript segments by temporal overlap
            var updated = segments
            var relabeled = 0
            for i in updated.indices {
                let tStart = Float(updated[i].startTime)
                let tEnd = Float(updated[i].endTime)

                var bestOverlap: Float = 0
                var bestLabel: String?

                for diarSeg in result.segments {
                    let oStart = max(tStart, diarSeg.startTime)
                    let oEnd = min(tEnd, diarSeg.endTime)
                    let overlap = max(0, oEnd - oStart)
                    if overlap > bestOverlap {
                        bestOverlap = overlap
                        if case .speakerId(let id) = diarSeg.speaker {
                            bestLabel = idToLabel[id]
                        }
                    }
                }

                if let label = bestLabel, updated[i].speakerLabel != label {
                    updated[i].speakerLabel = label
                    relabeled += 1
                }
            }

            log("Relabeled \(relabeled)/\(updated.count) segments")
            onDiarizationComplete(updated)

        } catch {
            log("Diarization failed: \(error)")
        }
    }
}
