import Foundation
import SpeechVAD

/// Post-meeting speaker diarization using PyannoteDiarizationPipeline.
/// Aligns diarization results to existing TranscriptSegments by temporal overlap.
final class SpeakerDiarizer: Sendable {

    /// Result of diarization aligned to transcript segments.
    struct DiarizationOutput: Sendable {
        /// Transcript segments with updated speaker labels.
        let segments: [TranscriptSegment]
        /// Number of distinct speakers detected.
        let speakerCount: Int
        /// Ordered speaker labels (e.g. ["Speaker A", "Speaker B"]).
        let speakerLabels: [String]
        /// 256-dim speaker embedding centroids per speaker label.
        let speakerEmbeddings: [String: [Float]]
    }

    /// Run diarization on the full meeting audio, then align results
    /// to the existing transcript segments.
    func diarize(
        audio: [Float],
        segments: [TranscriptSegment],
        analysisQueue: AnalysisQueue? = nil
    ) async throws -> DiarizationOutput {
        let pipeline = try await PyannoteDiarizationPipeline.fromPretrained(
            embeddingEngine: .coreml
        )

        let config = DiarizationConfig(
            onset: 0.4,
            offset: 0.25,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.15,
            clusteringThreshold: 0.75
        )

        // Run through shared GPU queue to avoid Metal contention with LLM
        let result: DiarizationResult
        if let queue = analysisQueue {
            result = await withCheckedContinuation { continuation in
                Task {
                    await queue.enqueue {
                        let r = pipeline.diarize(audio: audio, sampleRate: 16000, config: config)
                        continuation.resume(returning: r)
                    }
                }
            }
        } else {
            result = pipeline.diarize(audio: audio, sampleRate: 16000, config: config)
        }

        // Build label mapping: numeric speaker ID → "Speaker A/B/C..."
        var speakerIDToLabel: [Int: String] = [:]
        var nextIndex = 0
        for diarSegment in result.segments {
            if speakerIDToLabel[diarSegment.speakerId] == nil {
                speakerIDToLabel[diarSegment.speakerId] = Constants.speakerLabel(index: nextIndex)
                nextIndex += 1
            }
        }

        let orderedLabels = speakerIDToLabel
            .sorted { $0.key < $1.key }
            .map(\.value)

        // Map speaker embeddings to labels
        var labeledEmbeddings: [String: [Float]] = [:]
        for (id, label) in speakerIDToLabel {
            if id < result.speakerEmbeddings.count {
                labeledEmbeddings[label] = result.speakerEmbeddings[id]
            }
        }

        // Align diarization segments to transcript segments by maximum overlap
        var updatedSegments = segments
        for i in updatedSegments.indices {
            let tStart = Float(updatedSegments[i].startTime)
            let tEnd = Float(updatedSegments[i].endTime)

            var bestOverlap: Float = 0
            var bestLabel: String?

            for diarSegment in result.segments {
                let overlapStart = max(tStart, diarSegment.startTime)
                let overlapEnd = min(tEnd, diarSegment.endTime)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestLabel = speakerIDToLabel[diarSegment.speakerId]
                }
            }

            if let label = bestLabel {
                updatedSegments[i].speakerLabel = label
            }
        }

        return DiarizationOutput(
            segments: updatedSegments,
            speakerCount: speakerIDToLabel.count,
            speakerLabels: orderedLabels,
            speakerEmbeddings: labeledEmbeddings
        )
    }
}
