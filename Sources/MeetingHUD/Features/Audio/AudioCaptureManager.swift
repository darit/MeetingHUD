import AudioToolbox
import AVFoundation
import CoreAudio
import ScreenCaptureKit

/// Errors that can occur during audio capture setup.
enum AudioCaptureError: Error, LocalizedError {
    case tapCreationFailed(OSStatus)
    case tapDeviceUIDNotFound
    case aggregateDeviceCreationFailed(OSStatus)
    case engineStartFailed(Error)
    case noProcesses
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            "Failed to create process tap (OSStatus: \(status))"
        case .tapDeviceUIDNotFound:
            "Could not retrieve tap device UID"
        case .aggregateDeviceCreationFailed(let status):
            "Failed to create aggregate device (OSStatus: \(status))"
        case .engineStartFailed(let error):
            "Audio engine failed to start: \(error.localizedDescription)"
        case .noProcesses:
            "No process IDs provided for capture"
        case .microphonePermissionDenied:
            "Microphone permission denied. Grant access in System Settings → Privacy → Microphone."
        }
    }
}

/// Captures audio for meeting transcription.
///
/// Supports two modes:
/// - **Process tap** (macOS 14.4+): Non-destructive tap of specific process audio via
///   CATapDescription / AudioHardwareCreateProcessTap. Requires `com.apple.security.audio.capture`
///   entitlement and Screen & System Audio Recording TCC permission.
/// - **Microphone** (fallback): Captures from the default audio input device. Works with any app.
///   Picks up meeting audio from speakers + your voice. Requires microphone permission.
///
/// Yields raw Float32 samples (16kHz mono) via an `AsyncStream` for downstream processing.
@Observable
final class AudioCaptureManager: @unchecked Sendable {
    // MARK: - State

    var isCapturing = false
    var capturedProcesses: [pid_t] = []
    var audioLevel: Float = 0.0
    var micLevel: Float = 0.0
    var captureMode: CaptureMode = .microphone
    /// When true, mic audio is not mixed into the stream (system audio continues).
    var isMicMuted = false
    /// Whether mic is active alongside system audio.
    var hasMicCapture = false

    enum CaptureMode: String {
        case processTap = "System Audio (Process Tap)"
        case screenCapture = "System Audio (ScreenCaptureKit)"
        case microphone = "Microphone"
        case systemPlusMic = "System + Mic"
    }

    // MARK: - Audio Format

    /// Standard format for processing: 16kHz mono Float32 (WhisperKit expects 16kHz).
    private let processingFormat = Constants.Audio.processingFormat

    // MARK: - Stream

    /// Continuation backing the public audio stream.
    private var streamContinuation: AsyncStream<[Float]>.Continuation?

    /// Async stream of Float32 sample arrays for downstream consumers.
    /// Access this ONCE before calling `startCapture` — it sets up the internal continuation.
    var audioStream: AsyncStream<[Float]> {
        AsyncStream { continuation in
            self.streamContinuation = continuation
        }
    }

    // MARK: - Audio Level

    /// Atomic storage for audio level updated from the audio render thread.
    private let _audioLevelStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    // MARK: - Core Audio Tap References

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var audioEngine: AVAudioEngine?
    private var micEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var scStreamDelegate: SCStreamAudioHandler?
    private var scErrorDelegate: SCStreamErrorDelegate?
    private let _micLevelStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    // MARK: - Capture Control

    /// Begin capturing audio. Tries process tap first, falls back to microphone input.
    ///
    /// Access `audioStream` before calling this method to set up the buffer continuation.
    func startCapture(pids: [pid_t] = [], useGlobalTap: Bool = false) async throws {
        guard !isCapturing else { return }

        // Try process tap first (best quality — captures system audio directly)
        if tryStartProcessTap(pids: pids, useGlobalTap: useGlobalTap) {
            captureMode = .processTap
            capturedProcesses = pids
            isCapturing = true
            startLevelMetering()
            startMicAlongside()
            print("[AudioCapture] Started via process tap")
            return
        }

        // Try ScreenCaptureKit (captures all system audio, needs Screen Recording permission)
        if await tryStartScreenCapture() {
            captureMode = .screenCapture
            capturedProcesses = []
            isCapturing = true
            startLevelMetering()
            startMicAlongside()
            print("[AudioCapture] Started via ScreenCaptureKit")
            return
        }

        // Fall back to microphone input
        print("[AudioCapture] System audio unavailable, falling back to microphone input")
        try startMicrophoneCapture()
        captureMode = .microphone
        capturedProcesses = []
        isCapturing = true
        startLevelMetering()
        print("[AudioCapture] Started via microphone input")
    }

    /// Stop capturing and release all resources.
    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false

        levelTimer?.cancel()
        levelTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        micEngine?.stop()
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine = nil
        hasMicCapture = false

        // Stop ScreenCaptureKit stream
        if let stream = scStream {
            Task { try? await stream.stopCapture() }
            scStream = nil
            scStreamDelegate = nil
        }

        destroyCoreAudioResources()

        streamContinuation?.finish()
        streamContinuation = nil
        capturedProcesses = []
        audioLevel = 0.0
        micLevel = 0.0
        _audioLevelStorage.pointee = 0
        _micLevelStorage.pointee = 0
    }

    // MARK: - Process Tap (System Audio)

    /// Attempt to start a Core Audio process tap. Returns true on success.
    private func tryStartProcessTap(pids: [pid_t], useGlobalTap: Bool) -> Bool {
        let tapDescription: CATapDescription
        if useGlobalTap || pids.isEmpty {
            let selfPID = AudioObjectID(ProcessInfo.processInfo.processIdentifier)
            tapDescription = CATapDescription(
                stereoGlobalTapButExcludeProcesses: [selfPID]
            )
        } else {
            tapDescription = CATapDescription(
                stereoMixdownOfProcesses: pids.map { AudioObjectID($0) }
            )
        }
        tapDescription.name = "MeetingHUD Audio Tap"
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else {
            print("[AudioCapture] Process tap creation failed (OSStatus: \(tapStatus))")
            return false
        }
        self.tapObjectID = tapID

        guard let tapDeviceUID = getTapDeviceUID(tapID: tapID, tapDescription: tapDescription) else {
            AudioHardwareDestroyProcessTap(tapID)
            print("[AudioCapture] Could not get tap device UID")
            return false
        }

        let aggregateUID = "com.meetinghud.aggregate.\(UUID().uuidString)"
        let aggregateDescription: NSDictionary = [
            kAudioAggregateDeviceNameKey: "MeetingHUD",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: tapDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDeviceUID]
            ],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]

        var aggDeviceID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggDeviceID
        )
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            print("[AudioCapture] Aggregate device creation failed (OSStatus: \(aggStatus))")
            return false
        }
        self.aggregateDeviceID = aggDeviceID

        let engine = AVAudioEngine()
        var deviceID = aggDeviceID
        AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        installTap(on: engine)

        do {
            try engine.start()
        } catch {
            destroyCoreAudioResources()
            print("[AudioCapture] Engine start failed for process tap: \(error)")
            return false
        }

        self.audioEngine = engine
        return true
    }

    // MARK: - ScreenCaptureKit (System Audio)

    /// Attempt to capture all system audio via ScreenCaptureKit.
    /// Requires Screen Recording permission (granted via System Settings).
    private func tryStartScreenCapture() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                print("[AudioCapture] No display found for ScreenCaptureKit")
                return false
            }

            // Capture audio only (no video) from all apps except ourselves
            let selfBundleID = Bundle.main.bundleIdentifier ?? ""
            let excludedApps = content.applications.filter { $0.bundleIdentifier == selfBundleID }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 16000
            config.channelCount = 1
            // Minimize video overhead — we only want audio
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps

            let handler = SCStreamAudioHandler(
                continuation: self.streamContinuation,
                levelPtr: self._audioLevelStorage
            )
            self.scStreamDelegate = handler

            let errorDelegate = SCStreamErrorDelegate { [weak self] error in
                print("[AudioCapture] SCStream error: \(error)")
                // Try to restart capture
                Task { @MainActor [weak self] in
                    guard let self, self.isCapturing else { return }
                    print("[AudioCapture] Attempting SCStream restart...")
                    if let stream = self.scStream {
                        try? await stream.stopCapture()
                    }
                    self.scStream = nil
                    // Retry after brief delay
                    try? await Task.sleep(for: .seconds(1))
                    if self.isCapturing {
                        let restarted = await self.tryStartScreenCapture()
                        print("[AudioCapture] SCStream restart: \(restarted ? "success" : "failed")")
                    }
                }
            }
            self.scErrorDelegate = errorDelegate

            let stream = SCStream(filter: filter, configuration: config, delegate: errorDelegate)
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
            self.scStream = stream
            return true
        } catch {
            print("[AudioCapture] ScreenCaptureKit failed: \(error)")
            return false
        }
    }

    // MARK: - Microphone Capture (Fallback)

    /// Start capturing from the default audio input device (microphone).
    private func startMicrophoneCapture() throws {
        // Check microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Request permission synchronously isn't ideal but we need it now
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else { throw AudioCaptureError.microphonePermissionDenied }
        default:
            throw AudioCaptureError.microphonePermissionDenied
        }

        let engine = AVAudioEngine()
        // AVAudioEngine uses the default input device — resample from hardware rate to 16kHz
        installTap(on: engine, resample: true)

        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineStartFailed(error)
        }

        self.audioEngine = engine
    }

    // MARK: - Mic Alongside System Audio

    /// Start mic capture alongside system audio. Mic samples are mixed into the same
    /// stream but can be muted independently via `isMicMuted`.
    private func startMicAlongside() {
        // Check mic permission
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("[AudioCapture] Mic permission not granted, skipping mic capture")
            return
        }

        let engine = AVAudioEngine()

        // Enable Apple's built-in voice processing on the mic input.
        // This activates Acoustic Echo Cancellation (AEC) + noise suppression +
        // automatic gain control — strips speaker output from the mic signal so
        // we don't double-capture system audio.
        // Note: Voice processing (AEC) is NOT enabled because it causes macOS to
        // "duck" (lower volume of) all other system audio — Chrome, YouTube, etc.
        // get quieter. The mic mute button handles echo control instead.

        let continuation = self.streamContinuation
        let levelPtr = self._micLevelStorage
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: processingFormat)

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self, !self.isMicMuted else { return }

            guard let converter else {
                guard let channelData = buffer.floatChannelData else { return }
                let frameCount = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
                continuation?.yield(samples)
                return
            }

            let ratio = 16000.0 / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil,
                  let channelData = outputBuffer.floatChannelData else { return }
            let frameCount = Int(outputBuffer.frameLength)
            guard frameCount > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

            var sumOfSquares: Float = 0
            for sample in samples { sumOfSquares += sample * sample }
            levelPtr.pointee = sqrtf(sumOfSquares / Float(frameCount))

            continuation?.yield(samples)
        }

        do {
            try engine.start()
            self.micEngine = engine
            self.hasMicCapture = true
            let modeLabel = captureMode == .processTap ? "Process Tap" : "ScreenCaptureKit"
            captureMode = .systemPlusMic
            print("[AudioCapture] Mic capture started alongside \(modeLabel)")
        } catch {
            print("[AudioCapture] Mic alongside failed: \(error), continuing with system audio only")
        }
    }

    // MARK: - Shared

    /// Install a tap on the engine's input node to capture audio samples.
    /// For process taps, requests 16kHz mono directly.
    /// For microphone, accepts hardware format and resamples to 16kHz mono.
    private func installTap(on engine: AVAudioEngine, resample: Bool = false) {
        let continuation = self.streamContinuation
        let levelPtr = self._audioLevelStorage

        if resample {
            // Mic: accept hardware format, then convert to 16kHz mono
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            let converter = AVAudioConverter(from: inputFormat, to: processingFormat)
            print("[AudioCapture] Mic format: \(inputFormat), resampling to \(processingFormat)")

            engine.inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: inputFormat
            ) { buffer, _ in
                guard let converter else {
                    // No conversion possible — pass raw samples from channel 0
                    guard let channelData = buffer.floatChannelData else { return }
                    let frameCount = Int(buffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
                    continuation?.yield(samples)
                    return
                }

                // Calculate output frame count based on sample rate ratio
                let ratio = 16000.0 / inputFormat.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat,
                    frameCapacity: outputFrameCount
                ) else { return }

                var error: NSError?
                var consumed = false
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                guard error == nil,
                      let channelData = outputBuffer.floatChannelData else { return }
                let frameCount = Int(outputBuffer.frameLength)
                guard frameCount > 0 else { return }
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

                // RMS metering
                var sumOfSquares: Float = 0
                for sample in samples { sumOfSquares += sample * sample }
                levelPtr.pointee = sqrtf(sumOfSquares / Float(frameCount))

                continuation?.yield(samples)
            }
        } else {
            // Process tap: can request 16kHz mono directly
            engine.inputNode.installTap(
                onBus: 0,
                bufferSize: UInt32(Constants.Audio.bufferSize),
                format: processingFormat
            ) { buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameCount = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

                var sumOfSquares: Float = 0
                for sample in samples { sumOfSquares += sample * sample }
                levelPtr.pointee = sqrtf(sumOfSquares / Float(max(frameCount, 1)))

                continuation?.yield(samples)
            }
        }
    }

    private var levelTimer: Task<Void, Never>?

    private func startLevelMetering() {
        nonisolated(unsafe) let levelPtr = _audioLevelStorage
        nonisolated(unsafe) let micLevelPtr = _micLevelStorage
        levelTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                self?.audioLevel = levelPtr.pointee
                self?.micLevel = micLevelPtr.pointee
            }
        }
    }

    // MARK: - Private

    /// Clean up Core Audio tap and aggregate device.
    private func destroyCoreAudioResources() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
    }

    /// Get the device UID associated with a process tap.
    private func getTapDeviceUID(tapID: AudioObjectID, tapDescription: CATapDescription) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(tapID, &address, 0, nil, &size)
        if sizeStatus == noErr && size > 0 {
            let buffer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
            defer { buffer.deallocate() }
            buffer.initialize(to: nil)

            var propSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &propSize, buffer)
            if status == noErr, let cfString = buffer.pointee?.takeRetainedValue() {
                return cfString as String
            }
        }

        return tapDescription.uuid.uuidString
    }
}

// MARK: - ScreenCaptureKit Audio Handler

/// Receives audio samples from SCStream and forwards them to the async stream.
final class SCStreamAudioHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuation: AsyncStream<[Float]>.Continuation?
    private let levelPtr: UnsafeMutablePointer<Float>

    init(continuation: AsyncStream<[Float]>.Continuation?, levelPtr: UnsafeMutablePointer<Float>) {
        self.continuation = continuation
        self.levelPtr = levelPtr
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // Extract Float32 samples from CMSampleBuffer
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == noErr, let ptr = dataPointer else { return }

        // SCStream configured for 16kHz mono Float32
        let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
        let frameCount = length / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(start: floatPtr, count: frameCount))

        // RMS metering
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        levelPtr.pointee = sqrtf(sumOfSquares / Float(max(frameCount, 1)))

        continuation?.yield(samples)
    }
}

/// Detects SCStream errors and triggers reconnection.
final class SCStreamErrorDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}
