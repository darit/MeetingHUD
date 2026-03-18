import SwiftUI

/// Settings window with tabs for General, Models, and About.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            TranscriptionSettingsTab()
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }

            ModelSettingsTab()
                .tabItem {
                    Label("LLM", systemImage: "cpu")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - General Settings

private struct GeneralSettingsTab: View {
    @AppStorage("userName") private var userName = "Danny"
    @AppStorage("autoDetectMeetings") private var autoDetect = true
    @AppStorage("showOverlayOnStart") private var showOverlayOnStart = true
    @AppStorage("maxRecommendations") private var maxRecommendations = 10

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Your name", text: $userName)
                Text("Used as default speaker label when recording from microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meeting Detection") {
                Toggle("Auto-detect meetings", isOn: $autoDetect)
                Toggle("Show overlay when meeting starts", isOn: $showOverlayOnStart)
            }

            Section("Display") {
                Stepper("Max recommendations: \(maxRecommendations)", value: $maxRecommendations, in: 3...20)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Transcription Settings

/// Available Whisper models with metadata for the picker.
private struct WhisperModelOption: Identifiable {
    let id: String          // model name passed to WhisperKit
    let label: String       // display name
    let languages: String   // supported languages
    let size: String        // approximate download size
    let speed: String       // relative speed
    let note: String?       // optional note

    static let all: [WhisperModelOption] = [
        // English-only (faster, smaller)
        WhisperModelOption(id: "tiny.en",  label: "Tiny",  languages: "English only",  size: "~40 MB",  speed: "Fastest", note: "Lower accuracy"),
        WhisperModelOption(id: "base.en",  label: "Base",  languages: "English only",  size: "~75 MB",  speed: "Fast",    note: nil),
        WhisperModelOption(id: "small.en", label: "Small", languages: "English only",  size: "~250 MB", speed: "Medium",  note: "High accuracy"),

        // Multilingual (supports Spanish, English, and 90+ languages)
        WhisperModelOption(id: "tiny",     label: "Tiny",  languages: "Multilingual",  size: "~40 MB",  speed: "Fastest", note: "Lower accuracy"),
        WhisperModelOption(id: "base",     label: "Base",  languages: "Multilingual",  size: "~75 MB",  speed: "Fast",    note: "Recommended for Spanish + English"),
        WhisperModelOption(id: "small",    label: "Small", languages: "Multilingual",  size: "~250 MB", speed: "Medium",  note: "Best accuracy for multilingual"),
        WhisperModelOption(id: "large-v3", label: "Large", languages: "Multilingual",  size: "~1.5 GB", speed: "Slow",    note: "Best overall accuracy, needs 16 GB+ RAM"),
    ]
}

private struct TranscriptionSettingsTab: View {
    @AppStorage("transcriptionModel") private var transcriptionModel = "base"
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"

    private static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("es", "Spanish"),
        ("en", "English"),
        ("pt", "Portuguese"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
    ]

    var body: some View {
        Form {
            Section("Language") {
                Picker("Transcription language", selection: $transcriptionLanguage) {
                    ForEach(Self.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)

                Text("Set to your spoken language for best accuracy. Auto-detect is unreliable on short audio chunks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Whisper Model") {
                List(WhisperModelOption.all) { model in
                    HStack(spacing: 12) {
                        // Selection indicator
                        Image(systemName: transcriptionModel == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(transcriptionModel == model.id ? AnyShapeStyle(.blue) : AnyShapeStyle(.tertiary))
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.label)
                                    .font(.body.weight(.medium))

                                Text(model.languages)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(model.languages == "Multilingual" ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.12))
                                    .foregroundStyle(model.languages == "Multilingual" ? .blue : .secondary)
                                    .clipShape(Capsule())
                            }

                            HStack(spacing: 8) {
                                Text(model.size)
                                Text("·")
                                Text(model.speed)
                                if let note = model.note {
                                    Text("·")
                                    Text(note)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        transcriptionModel = model.id
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Section {
                Text("Multilingual models support Spanish, English, and 90+ languages with automatic language detection. English-only models are faster but cannot transcribe other languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - LLM Model Settings

private struct ModelSettingsTab: View {
    @State private var modelManager = MLXModelManager.shared

    private var ramGB: Double {
        Double(modelManager.systemRAM) / 1_073_741_824
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LLM Model")
                    .font(.headline)
                Spacer()
                Text("System RAM: \(String(format: "%.0f", ramGB)) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Used for sentiment analysis, topic extraction, summaries, and recommendations. Runs on GPU (separate from Whisper on Neural Engine).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if modelManager.availableModels.isEmpty {
                ContentUnavailableView(
                    "No Models Found",
                    systemImage: "cpu.fill",
                    description: Text("Download a model to enable AI features.\nModels are stored in the Hugging Face cache.")
                )
            } else {
                List(modelManager.availableModels, id: \.id) { model in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.body.weight(.medium))

                            HStack(spacing: 8) {
                                Label(model.parameterCount, systemImage: "cpu")
                                Label(model.quantization, systemImage: "memorychip")
                                Label(formatBytes(model.sizeOnDisk), systemImage: "internaldrive")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            HStack(spacing: 6) {
                                if model.minimumRAM > modelManager.systemRAM {
                                    Text("Needs \(formatBytes(model.minimumRAM)) RAM")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }

                                switch model.source {
                                case .recommended:
                                    Text("Recommended")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                case .huggingFace:
                                    Text("HuggingFace Cache")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                case .lmStudio:
                                    Text("LM Studio")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                case .local:
                                    Text("Local")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()

                        if modelManager.selectedModel?.id == model.id {
                            switch modelManager.loadState {
                            case .loaded:
                                Label("Active", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            case .loading(let progress):
                                ProgressView(value: progress)
                                    .frame(width: 60)
                            case .error(let msg):
                                VStack(spacing: 2) {
                                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                }
                            case .unloaded:
                                Button("Load") {
                                    Task { try? await modelManager.loadModel(model) }
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Button("Select") {
                                Task { try? await modelManager.loadModel(model) }
                            }
                            .controlSize(.small)
                            .disabled(model.minimumRAM > modelManager.systemRAM)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            if modelManager.loadState == .loaded {
                HStack {
                    Spacer()
                    Button("Unload Model") {
                        modelManager.unloadModel()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding()
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Double(bytes) / 1_048_576
            return String(format: "%.0f MB", mb)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("MeetingHUD")
                .font(.title2.bold())

            Text("Real-time meeting intelligence for macOS")
                .foregroundStyle(.secondary)

            Text("All processing runs locally on your Mac.\nNo data leaves your device.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
