import Foundation
import SpeakerKit

/// Post-meeting speaker diarization using SpeakerKit.
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
    }

    /// Run SpeakerKit diarization on the full meeting audio, then align results
    /// to the existing transcript segments.
    func diarize(
        audio: [Float],
        segments: [TranscriptSegment]
    ) async throws -> DiarizationOutput {
        let config = PyannoteConfig()
        let speakerKit = try await SpeakerKit(config)

        let result = try await speakerKit.diarize(audioArray: audio)

        // Build label mapping: numeric speaker ID → "Speaker A/B/C..."
        var speakerIDToLabel: [Int: String] = [:]
        var nextIndex = 0
        for diarSegment in result.segments {
            if case .speakerId(let id) = diarSegment.speaker {
                if speakerIDToLabel[id] == nil {
                    speakerIDToLabel[id] = Constants.speakerLabel(index: nextIndex)
                    nextIndex += 1
                }
            }
        }

        let orderedLabels = speakerIDToLabel
            .sorted { $0.key < $1.key }
            .map(\.value)

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
                    if case .speakerId(let id) = diarSegment.speaker {
                        bestLabel = speakerIDToLabel[id]
                    }
                }
            }

            if let label = bestLabel {
                updatedSegments[i].speakerLabel = label
            }
        }

        return DiarizationOutput(
            segments: updatedSegments,
            speakerCount: speakerIDToLabel.count,
            speakerLabels: orderedLabels
        )
    }
}
