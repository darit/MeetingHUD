import KeyboardShortcuts
import SwiftUI
import SwiftData

// MARK: - Global Hotkeys

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay", default: .init(.h, modifiers: [.control, .option]))
    static let toggleMute = Self("toggleMute", default: .init(.m, modifiers: [.control, .option]))
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.control, .option]))
}

/// Main entry point for MeetingHUD.
/// Provides a menu bar presence and a floating overlay window.
@main
struct MeetingHUDApp: App {
    @State private var appState = AppState()
    @State private var didSetup = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Interlocutor.self,
            Meeting.self,
            MeetingParticipation.self,
            Topic.self,
            ActionItem.self,
            ConversationSession.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        // Install crash handler — writes debug log + stack trace to ~/Library/Logs/MeetingHUD/
        CrashReporter.install()
    }

    var body: some Scene {
        MenuBarExtra("MeetingHUD", systemImage: menuBarIcon) {
            MenuBarView(
                appState: appState,
                sharedModelContainer: sharedModelContainer,
                didSetup: $didSetup
            )
        }

        Settings {
            SettingsView()
        }
    }

    private var menuBarIcon: String {
        switch appState.captureState {
        case .off: return "waveform.badge.mic"
        case .listening: return "ear"
        case .conversation: return "waveform"
        case .meeting: return "waveform.circle.fill"
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @Bindable var appState: AppState
    let sharedModelContainer: ModelContainer
    @Binding var didSetup: Bool

    private var llmStatusLabel: String {
        switch appState.selectedAnalysisProvider {
        case .localMLX:
            if let model = MLXModelManager.shared.selectedModel {
                return model.name
            }
            return "Local (MLX)"
        case .claudeHaiku: return "Claude Haiku"
        case .claudeSonnet: return "Claude Sonnet"
        }
    }

    var body: some View {
        Group {
            Button(appState.overlayPanel?.isVisible == true ? "Hide Overlay" : "Show Overlay") {
                toggleOverlay()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Text(appState.autoDetectStatus)
                .font(.caption)

            if let meeting = appState.detectedMeeting {
                Text(meeting.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            switch appState.captureState {
            case .off:
                Button("Start Recording") {
                    appState.startRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Start Listening (Always-On)") {
                    appState.startListening()
                }

            case .listening:
                Text("Listening for speech...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Stop Listening") {
                    appState.stopListening()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            case .conversation:
                Text("Conversation active")
                    .font(.caption2)
                    .foregroundStyle(.green)

                Button("Stop Recording") {
                    appState.stopRecording()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Clear Transcript") {
                    appState.clearLiveData()
                }

            case .meeting:
                Text("In meeting")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                Button("Stop Recording") {
                    appState.stopRecording()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Clear Transcript") {
                    appState.clearLiveData()
                }
            }

            Button(appState.isMicMuted ? "Unmute Mic" : "Mute Mic") {
                appState.toggleMute()
            }

            Toggle("Auto-Detect Meetings", isOn: $appState.autoDetectEnabled)

            Divider()

            Button("Paste Meeting Agenda") {
                if let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty {
                    appState.meetingAgenda = clipboard
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            if !appState.meetingAgenda.isEmpty {
                Text("Agenda: \(appState.meetingAgenda.prefix(60))...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("Clear Agenda") {
                    appState.meetingAgenda = ""
                }
            }

            Divider()

            Menu("LLM: \(llmStatusLabel)") {
                ForEach(AppState.AnalysisProvider.allCases, id: \.self) { provider in
                    Button {
                        appState.switchAnalysisProvider(to: provider)
                    } label: {
                        HStack {
                            Text(provider.rawValue)
                            if provider == appState.selectedAnalysisProvider {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if appState.selectedAnalysisProvider == .localMLX {
                    Divider()
                    let models = MLXModelManager.shared.availableModels
                    if models.isEmpty {
                        Text("No models found").font(.caption2)
                    } else {
                        ForEach(models) { model in
                            Button {
                                Task {
                                    try? await MLXModelManager.shared.loadModel(model)
                                }
                            } label: {
                                HStack {
                                    Text("\(model.name) (\(MLXModelManager.formatBytes(model.sizeOnDisk)))")
                                    if model == MLXModelManager.shared.selectedModel {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Menu("ASR: \(appState.selectedTranscriptionBackend.rawValue)") {
                ForEach(AppState.TranscriptionBackend.allCases, id: \.self) { backend in
                    Button {
                        appState.switchTranscriptionBackend(to: backend)
                    } label: {
                        HStack {
                            Text(backend.rawValue)
                            if backend == appState.selectedTranscriptionBackend {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if appState.selectedTranscriptionBackend == .whisperKit {
                    Divider()
                    ForEach(["base", "small", "large-v3-turbo"], id: \.self) { model in
                        Button {
                            appState.switchWhisperModel(to: model)
                        } label: {
                            HStack {
                                Text(model)
                                if model == appState.transcriptionEngine.modelName {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Toggle("Debug Log", isOn: $appState.showDebugLog)

            if !appState.activeTranscriptSegments.isEmpty {
                Divider()

                Button("Export Meeting...") {
                    exportMeeting()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Copy Transcript") {
                    let markdown = MeetingExporter.exportMarkdown(
                        title: appState.currentMeeting?.title ?? "Meeting",
                        date: appState.currentMeeting?.date ?? .now,
                        segments: appState.activeTranscriptSegments,
                        speakers: appState.speakers,
                        topics: appState.currentTopics,
                        actionItems: appState.currentActionItems,
                        summary: nil
                    )
                    MeetingExporter.copyToClipboard(markdown)
                }
            }

            Divider()

            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit MeetingHUD") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            setupOnce()
        }
    }

    private func setupOnce() {
        guard !didSetup else { return }
        didSetup = true
        appState.configure(modelContainer: sharedModelContainer)
        appState.setup()
        showOverlay()

        // Global hotkeys — work even when app is in background / behind notch
        KeyboardShortcuts.onKeyUp(for: .toggleOverlay) { [self] in
            toggleOverlay()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleMute) { [self] in
            appState.toggleMute()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [self] in
            if appState.isRecording {
                appState.stopRecording()
            } else {
                appState.startRecording()
            }
        }
    }

    private func toggleOverlay() {
        if let panel = appState.overlayPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            showOverlay()
        }
    }

    private func showOverlay() {
        if let panel = appState.overlayPanel {
            panel.orderFrontRegardless()
        } else {
            let panel = OverlayPanel.create()
            let hostingView = NSHostingView(
                rootView: OverlayView(appState: appState)
                    .modelContainer(sharedModelContainer)
            )
            panel.contentView = hostingView
            panel.orderFrontRegardless()
            appState.overlayPanel = panel
        }
    }

    private func exportMeeting() {
        let title = appState.currentMeeting?.title ?? "Meeting"
        let markdown = MeetingExporter.exportMarkdown(
            title: title,
            date: appState.currentMeeting?.date ?? .now,
            segments: appState.activeTranscriptSegments,
            speakers: appState.speakers,
            topics: appState.currentTopics,
            actionItems: appState.currentActionItems,
            summary: nil
        )
        let safeName = title.replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
        Task {
            await MeetingExporter.saveToFile(markdown: markdown, suggestedName: safeName)
        }
    }
}
