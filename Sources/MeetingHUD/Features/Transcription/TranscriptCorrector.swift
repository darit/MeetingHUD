import Foundation

/// Background transcript correction pass.
/// Periodically re-transcribes recent audio with a larger context window,
/// producing more accurate results than the real-time first pass.
/// Silently updates existing segments when the correction is better.
@Observable @MainActor
final class TranscriptCorrector {

    /// How often to run correction (seconds).
    private let interval: TimeInterval = 45

    /// How far back to correct (seconds of audio).
    private let correctionWindowSeconds: TimeInterval = 90

    /// Minimum segments before first correction.
    private let minSegmentsToCorrect = 5

    /// Track which segment index we've corrected up to.
    private var correctedUpTo = 0

    private var correctionTask: Task<Void, Never>?
    private var isRunning = false

    var onDebugLog: ((String) -> Void)?

    private func log(_ msg: String) {
        print("[Corrector] \(msg)")
        onDebugLog?(msg)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        correctedUpTo = 0

        correctionTask = Task { [weak self] in
            // Wait before first correction to accumulate context
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.runCorrectionPass()
                try? await Task.sleep(for: .seconds(self?.interval ?? 45))
            }
        }
    }

    func stop() {
        isRunning = false
        correctionTask?.cancel()
        correctionTask = nil
        correctedUpTo = 0
    }

    // MARK: - Dependencies (set by AppState)

    var segmentsProvider: (() -> [TranscriptSegment])?
    var audioProvider: (() -> [Float])?
    var transcriptionEngine: ParakeetTranscriptionEngine?
    var onSegmentsCorrected: (([TranscriptSegment]) -> Void)?

    // MARK: - Correction Pass

    /// Parakeet max input is ~28s (3000 mel frames). Process in windows.
    private let maxWindowSeconds: TimeInterval = 25

    private func runCorrectionPass() async {
        guard let segmentsProvider, let audioProvider, let engine = transcriptionEngine else { return }
        let segments = segmentsProvider()
        let audio = audioProvider()

        guard segments.count >= minSegmentsToCorrect else { return }
        guard !audio.isEmpty else { return }

        // Leave the last 3 segments alone (still receiving live updates)
        let endIndex = max(correctedUpTo, segments.count - 3)
        guard endIndex > correctedUpTo else { return }

        let sampleRate = 16000
        var batchStart = correctedUpTo
        var totalCorrected = 0

        // Process in windows that stay under Parakeet's 30s limit.
        // Segments can have large time gaps between them, so we check actual audio duration.
        while batchStart < endIndex {
            var batchEnd = batchStart + 1 // At least 1 segment

            // Add segments until audio window would exceed limit
            for i in (batchStart + 1)..<endIndex {
                let candidateEnd = segments[i].endTime + 1
                let candidateStart = segments[batchStart].startTime - 1
                let audioDuration = candidateEnd - candidateStart
                if audioDuration > maxWindowSeconds {
                    break
                }
                batchEnd = i + 1
            }

            let batchSegments = Array(segments[batchStart..<batchEnd])
            guard !batchSegments.isEmpty else { break }

            // Extract audio window with 1s padding
            let windowStart = max(0, batchSegments.first!.startTime - 1)
            let windowEnd = min(Double(audio.count) / Double(sampleRate), batchSegments.last!.endTime + 1)
            let startSample = max(0, Int(windowStart * Double(sampleRate)))
            let endSample = min(audio.count, Int(windowEnd * Double(sampleRate)))
            let audioDuration = Double(endSample - startSample) / Double(sampleRate)

            // Skip if audio window exceeds limit (single long segment)
            guard audioDuration <= maxWindowSeconds + 2 else {
                log("Skipping seg \(batchStart): \(String(format: "%.0f", audioDuration))s exceeds limit")
                batchStart = batchEnd
                continue
            }

            guard endSample - startSample >= sampleRate * 2 else {
                batchStart = batchEnd
                continue
            }

            let audioWindow = Array(audio[startSample..<endSample])
            let windowDuration = Double(audioWindow.count) / Double(sampleRate)

            log("Correcting segs \(batchStart)-\(batchEnd - 1) (\(batchSegments.count) segs, \(String(format: "%.0f", windowDuration))s audio)")

            let normalized = Self.normalizeAudio(audioWindow)
            do {
                let newText = try await engine.transcribeAudio(normalized)
                let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)

                if !trimmed.isEmpty {
                    let sentences = splitIntoSentences(trimmed)
                    if !sentences.isEmpty {
                        let changed = applyCorrections(
                            sentences: sentences,
                            toSegments: batchSegments
                        )
                        totalCorrected += changed
                    }
                }
            } catch {
                log("Correction batch failed: \(error.localizedDescription)")
            }

            batchStart = batchEnd
        }

        if totalCorrected > 0 {
            log("Total corrected: \(totalCorrected) segments")
        }
        correctedUpTo = endIndex
    }

    /// Apply corrected sentences back to segments and emit via callback.
    /// Returns number of segments that changed.
    private func applyCorrections(sentences: [String], toSegments original: [TranscriptSegment]) -> Int {
        var corrected = original

        if sentences.count == corrected.count {
            for i in corrected.indices {
                corrected[i].text = sentences[i]
            }
        } else if sentences.count < corrected.count {
            let ratio = Double(sentences.count) / Double(corrected.count)
            for i in corrected.indices {
                let sentIdx = min(Int(Double(i) * ratio), sentences.count - 1)
                corrected[i].text = sentences[sentIdx]
            }
        } else {
            for i in corrected.indices {
                if i < sentences.count {
                    corrected[i].text = sentences[i]
                }
            }
            if sentences.count > corrected.count {
                let extra = sentences[corrected.count...].joined(separator: " ")
                corrected[corrected.count - 1].text += " " + extra
            }
        }

        var changedCount = 0
        for i in corrected.indices {
            if corrected[i].text != original[i].text {
                changedCount += 1
            }
        }

        if changedCount > 0 {
            onSegmentsCorrected?(corrected)
        }
        return changedCount
    }

    /// Split text into sentences using punctuation boundaries.
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if ".?!".contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 3 {
                    sentences.append(trimmed)
                    current = ""
                }
            }
        }
        let remaining = current.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            if remaining.count > 3 {
                sentences.append(remaining)
            } else if let last = sentences.last {
                sentences[sentences.count - 1] = last + " " + remaining
            }
        }

        return sentences
    }
}

// MARK: - Audio Helpers

extension TranscriptCorrector {
    /// Peak-normalize audio to target amplitude.
    static func normalizeAudio(_ samples: [Float], targetPeak: Float = 0.9) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.0001 && peak < targetPeak else { return samples }
        let gain = min(targetPeak / peak, 20.0)
        return samples.map { $0 * gain }
    }
}
