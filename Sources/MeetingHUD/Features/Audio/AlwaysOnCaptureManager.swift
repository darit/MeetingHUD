import Foundation

/// Manages always-on audio capture with voice activity detection (VAD).
///
/// State machine:
/// ```
/// .idle (no speech, only energy-based VAD runs on CPU)
///   → RMS > threshold for 500ms →
/// .conversation (speech detected, WhisperKit transcribing)
///   → silence > 2 min →
/// .idle (save ConversationSession, stop transcription)
/// ```
///
/// Two-tier VAD:
/// 1. Fast energy check (CPU): RMS metering already exists in AudioCaptureManager.
///    Only proceeds to step 2 if energy exceeds threshold.
/// 2. WhisperKit confirmation (ANE): If energy is present, WhisperKit processes the buffer.
///    If it produces non-empty text, speech is confirmed.
@Observable @MainActor
final class AlwaysOnCaptureManager {

    // MARK: - Configuration

    /// RMS threshold to trigger speech detection (energy-based VAD tier 1).
    /// Low threshold works for both mic and system audio capture.
    var rmsThreshold: Float = 0.003

    /// Duration of sustained RMS above threshold before confirming speech onset (seconds).
    var onsetDuration: TimeInterval = 0.5

    /// Duration of silence before ending a conversation (seconds).
    /// 5 minutes — meetings have natural pauses; don't fragment sessions aggressively.
    var silenceTimeout: TimeInterval = 300

    // MARK: - State

    enum VADState: Equatable {
        /// No speech detected, only energy-based VAD running.
        case idle
        /// RMS exceeded threshold, waiting for onset confirmation.
        case detecting(since: Date)
        /// Speech confirmed, actively transcribing.
        case conversation(since: Date)
    }

    private(set) var state: VADState = .idle

    /// Timestamp of last detected speech activity (RMS above threshold).
    private var lastSpeechTime: Date?

    /// Timer for monitoring silence in conversation state.
    private var silenceMonitorTask: Task<Void, Never>?

    // MARK: - Callbacks

    /// Called when VAD transitions from idle to conversation.
    var onConversationStarted: (() -> Void)?

    /// Called when VAD transitions from conversation back to idle.
    var onConversationEnded: (() -> Void)?

    // MARK: - Energy Monitoring

    /// Process an audio level sample from AudioCaptureManager.
    /// Called frequently (tied to audio callback rate).
    func processAudioLevel(_ rmsLevel: Float) {
        let now = Date.now
        let isSpeech = rmsLevel > rmsThreshold

        switch state {
        case .idle:
            if isSpeech {
                state = .detecting(since: now)
            }

        case .detecting(let since):
            if isSpeech {
                // Check if we've sustained speech long enough
                if now.timeIntervalSince(since) >= onsetDuration {
                    state = .conversation(since: since)
                    lastSpeechTime = now
                    startSilenceMonitor()
                    onConversationStarted?()
                }
            } else {
                // Speech stopped before onset threshold
                state = .idle
            }

        case .conversation:
            if isSpeech {
                lastSpeechTime = now
            }
            // Silence detection handled by silenceMonitorTask
        }
    }

    /// Force transition to idle (e.g., user turned off always-on mode).
    func forceIdle() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        state = .idle
        lastSpeechTime = nil
    }

    // MARK: - Private

    private func startSilenceMonitor() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, case .conversation = self.state else { break }

                if let lastSpeech = self.lastSpeechTime,
                   Date.now.timeIntervalSince(lastSpeech) >= self.silenceTimeout {
                    self.state = .idle
                    self.lastSpeechTime = nil
                    self.onConversationEnded?()
                    break
                }
            }
        }
    }
}
