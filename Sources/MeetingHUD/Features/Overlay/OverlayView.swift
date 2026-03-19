import SwiftData
import SwiftUI

// MARK: - Conversation Grouping (Phase 1.2)

/// A group of consecutive transcript segments separated by silence gaps.
private struct ConversationGroup: Identifiable {
    let id = UUID()
    let segments: [TranscriptSegment]
    /// Duration of silence gap before this group (0 for the first group).
    let gapBefore: TimeInterval
    /// Start time of the first segment in the group.
    var startTime: TimeInterval { segments.first?.startTime ?? 0 }
}

/// Group transcript segments by silence gaps >= threshold.
private func groupByConversation(
    _ segments: [TranscriptSegment],
    gapThreshold: TimeInterval = 120
) -> [ConversationGroup] {
    guard !segments.isEmpty else { return [] }

    var groups: [ConversationGroup] = []
    var currentSegments: [TranscriptSegment] = [segments[0]]
    var lastEnd = segments[0].endTime

    for segment in segments.dropFirst() {
        let gap = segment.startTime - lastEnd
        if gap >= gapThreshold {
            groups.append(ConversationGroup(segments: currentSegments, gapBefore: groups.isEmpty ? 0 : gap))
            currentSegments = [segment]
        } else {
            currentSegments.append(segment)
        }
        lastEnd = segment.endTime
    }

    // Final group
    let finalGap = groups.isEmpty ? 0 : (currentSegments.first!.startTime - (groups.last!.segments.last?.endTime ?? 0))
    groups.append(ConversationGroup(segments: currentSegments, gapBefore: finalGap))

    return groups
}

// MARK: - Main Overlay View

/// Main HUD overlay view with a three-column layout and bottom chat drawer.
/// Speakers | Live Transcript Feed | Recommendations
/// ─────────────────────────────────
/// Chat Drawer (collapsible)
struct OverlayView: View {
    @Bindable var appState: AppState
    @State private var chatExpanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // MARK: - Toolbar
                OverlayToolbar(appState: appState)

                Divider().opacity(0.3)

                HStack(spacing: 0) {
                    // MARK: - Column 1: Speakers / Profiles (narrow sidebar)
                    if appState.isRecording {
                        SpeakersColumn(
                            speakers: appState.speakers,
                            onRename: { old, new in appState.renameSpeaker(from: old, to: new) },
                            onRemove: { name in appState.removeSpeaker(name: name) },
                            onMerge: { source, target in appState.mergeSpeakers(source: source, into: target) }
                        )
                            .frame(width: 180)
                    } else {
                        ProfilesColumn()
                            .frame(width: 180)
                    }

                    Divider().opacity(0.3)

                    // MARK: - Column 2: Insights Dashboard (main panel)
                    InsightsColumn(
                        recommendations: appState.recommendations,
                        dynamicWidgets: appState.dynamicWidgets,
                        currentTopic: appState.currentTopicName,
                        topics: appState.currentTopics,
                        actionItems: appState.currentActionItems,
                        speakers: appState.speakers,
                        contentType: appState.detectedContentType,
                        segmentCount: appState.activeTranscriptSegments.count,
                        meetingStartDate: appState.currentMeeting?.date,
                        keyStatements: appState.currentKeyStatements,
                        segments: appState.activeTranscriptSegments,
                        onDismiss: { id in appState.dismissRecommendation(id: id) }
                    )
                    .frame(minWidth: 500)

                    Divider().opacity(0.3)

                    // MARK: - Column 3: Live Transcript (compact sidebar)
                    TranscriptColumn(
                        segments: appState.activeTranscriptSegments,
                        isModelLoading: appState.isModelLoading,
                        loadingStatus: appState.activeTranscriptionEngine.loadingStatus,
                        downloadProgress: appState.activeTranscriptionEngine.downloadProgress,
                        recordingError: appState.recordingError,
                        isRecording: appState.isRecording,
                        isListening: appState.captureState == .listening,
                        audioLevel: appState.audioCaptureManager.audioLevel,
                        onRenameSpeaker: { old, new in appState.renameSpeaker(from: old, to: new) },
                        onRetry: {
                            appState.recordingError = nil
                            Task { await appState.startRecording() }
                        }
                    )
                    .frame(width: 320)
                }

                Divider().opacity(0.3)

                // MARK: - Chat Drawer (Phase 1.3)
                ChatDrawer(
                    appState: appState,
                    isExpanded: $chatExpanded
                )
            }
            .frame(minHeight: chatExpanded ? 640 : 550)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            .overlay(alignment: .topTrailing) {
                ResizeGrip()
                    .frame(width: 20, height: 20)
                    .padding(14)
            }
            .padding(10)

            // Debug log panel
            if appState.showDebugLog && !appState.debugLog.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("Debug")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.7))
                        Spacer()
                        Button {
                            let text = appState.debugLog.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                                .foregroundStyle(.green.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Copy debug log")
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(appState.debugLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    }
                }
                .frame(maxHeight: 120)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10)
            }

            if appState.isDiarizing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing speakers...")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $appState.showSpeakerNamingSheet) {
            SpeakerNamingSheet(
                speakerLabels: appState.speakers.map(\.name),
                onComplete: { mapping in
                    appState.completeSpeakerNaming(nameMapping: mapping)
                },
                onSkip: {
                    appState.skipSpeakerNaming()
                }
            )
        }
        .sheet(isPresented: $appState.showHistorySheet) {
            MeetingHistorySheet(appState: appState)
        }
    }
}

// MARK: - Chat Drawer (Phase 1.3)

/// Collapsible chat drawer at the bottom of the overlay.
/// Shows a single-line input when collapsed, full chat history when expanded.
private struct ChatDrawer: View {
    @Bindable var appState: AppState
    @Binding var isExpanded: Bool
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                // Chat history
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(appState.chatMessages) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }

                            if appState.isGeneratingResponse {
                                StreamingResponseView(text: appState.streamingResponse)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .id("streaming")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .frame(height: 130)
                    .onChange(of: appState.chatMessages.count) { _, _ in
                        if let last = appState.chatMessages.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: appState.isGeneratingResponse) { _, generating in
                        if generating {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("streaming", anchor: .bottom)
                            }
                        }
                    }
                }

                Divider().opacity(0.3)
            }

            // Input bar — always visible
            HStack(spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse chat" : "Expand chat")

                // Voice transcription status
                if appState.voiceInputManager.isTranscribing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Transcribing...")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Ask about this meeting...", text: $inputText, axis: .vertical)
                    .font(Theme.Typography.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...2)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }
                    .onChange(of: isInputFocused) { _, focused in
                        if focused && !isExpanded {
                            isExpanded = true
                        }
                    }

                MicButton(voiceInputManager: appState.voiceInputManager) { transcribedText in
                    inputText = transcribedText
                    sendMessage()
                }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(inputText.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.blue))
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || appState.isGeneratingResponse)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        if !isExpanded { isExpanded = true }
        Task {
            await appState.sendChatMessage(text)
        }
    }
}

// MARK: - Toolbar

private struct OverlayToolbar: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // State indicator / control
            Button {
                switch appState.captureState {
                case .off:
                    appState.startListening()
                case .listening:
                    appState.stopListening()
                case .conversation, .meeting:
                    appState.stopRecording()
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(stateLabel)
                        .font(.caption.weight(.medium))
                }
            }
            .buttonStyle(.plain)

            if appState.isRecording {
                // Audio level indicator
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    AudioLevelBar(level: appState.audioCaptureManager.audioLevel)
                        .frame(width: 40, height: 8)
                }

                // Capture mode badge
                Text(appState.audioCaptureManager.captureMode.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())

                // Mute mic button
                Button {
                    appState.toggleMute()
                } label: {
                    Image(systemName: appState.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(appState.isMicMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)

                // Clear button
                Button {
                    appState.clearLiveData()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // Hide overlay button
                Button {
                    appState.overlayPanel?.orderOut(nil)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Metrics
            HStack(spacing: 6) {
                if !appState.activeTranscriptSegments.isEmpty {
                    Text("\(appState.activeTranscriptSegments.count) segs")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(appState.metricsTracker.memoryString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if appState.metricsTracker.claudeCallCount > 0 {
                    Text("\(appState.metricsTracker.claudeCallCount) API · ~\(appState.metricsTracker.claudeTokensEstimate / 1000)K tok")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // Language badge (clickable: cycles auto → en → es)
            Button {
                appState.cycleLanguage()
            } label: {
                Text(appState.activeTranscriptionEngine.language?.uppercased() ?? "AUTO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Click to cycle: auto → EN → ES")

            // LLM status badge — shows when MLX is selected but not loaded
            if appState.selectedAnalysisProvider == .localMLX && !appState.isMLXReady {
                let manager = MLXModelManager.shared
                let statusText = manager.loadingStatusText
                let loadProgress: Double? = {
                    if case .loading(let p) = manager.loadState { return p }
                    return nil
                }()
                let hasError: String? = {
                    if case .error(let msg) = manager.loadState { return msg }
                    return nil
                }()

                Button {
                    if hasError != nil {
                        // Reset error and retry
                        manager.loadState = .unloaded
                    }
                    appState.autoLoadMLXIfNeeded()
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 3) {
                            if appState.isMLXLoading {
                                ProgressView().controlSize(.mini).scaleEffect(0.7)
                            } else if hasError != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                            } else {
                                Image(systemName: "cpu.fill")
                                    .font(.system(size: 8))
                            }

                            if let error = hasError {
                                Text("Failed — Tap to retry")
                                    .font(.system(size: 9))
                                    .help(error)
                            } else if !statusText.isEmpty {
                                Text(statusText)
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                            } else if manager.selectedModel == nil {
                                Text("No model selected")
                                    .font(.system(size: 9))
                            } else {
                                Text("Load Model")
                                    .font(.system(size: 9))
                            }
                        }

                        // Download progress bar
                        if let progress = loadProgress, progress > 0 && progress < 1.0 {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                                .tint(.orange)
                        }
                    }
                    .foregroundStyle(hasError != nil ? .red : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((hasError != nil ? Color.red : Color.orange).opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(hasError ?? "Tap to load the local MLX model")
            }

            // History button
            Button {
                appState.showHistorySheet = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Previous meetings")

            // Debug toggle
            Button {
                appState.showDebugLog.toggle()
            } label: {
                Image(systemName: "ladybug")
                    .font(.caption2)
                    .foregroundStyle(appState.showDebugLog ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle debug log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var stateColor: Color {
        switch appState.captureState {
        case .off: return .secondary
        case .listening: return .yellow
        case .conversation: return .green
        case .meeting: return .red
        }
    }

    private var stateLabel: String {
        switch appState.captureState {
        case .off: return "Paused"
        case .listening: return "Listening"
        case .conversation: return "Active"
        case .meeting: return "Meeting"
        }
    }
}

private struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(.secondary.opacity(0.2))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: max(1, geo.size.width * CGFloat(min(level * 5, 1.0))))
                }
        }
    }

    private var barColor: Color {
        if level > 0.15 { return .red }
        if level > 0.05 { return .green }
        return .secondary
    }
}

// MARK: - Speakers Column

private struct SpeakersColumn: View {
    let speakers: [SpeakerInfo]
    var onRename: ((String, String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onMerge: ((String, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Speakers", systemImage: "person.2.fill")
                .font(Theme.Typography.columnHeader)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            if speakers.isEmpty {
                ContentUnavailableView {
                    Label("No speakers yet", systemImage: "mic.slash")
                        .font(.caption)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(speakers) { speaker in
                            SpeakerRow(
                                speaker: speaker,
                                otherSpeakers: speakers.filter { $0.id != speaker.id },
                                onRename: onRename,
                                onRemove: onRemove,
                                onMerge: onMerge
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

private struct SpeakerRow: View {
    let speaker: SpeakerInfo
    var otherSpeakers: [SpeakerInfo] = []
    var onRename: ((String, String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onMerge: ((String, String) -> Void)?
    @Query(sort: \Interlocutor.lastSeen, order: .reverse) private var interlocutors: [Interlocutor]
    @State private var isEditing = false
    @State private var editName = ""
    @FocusState private var isFieldFocused: Bool

    /// Known names filtered by what the user is typing.
    private var suggestions: [String] {
        let known = interlocutors.map(\.name)
        if editName.isEmpty { return known }
        return known.filter { $0.localizedCaseInsensitiveContains(editName) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(speaker.color)
                .frame(width: 8, height: 8)
                .overlay {
                    if speaker.isSpeaking {
                        Circle()
                            .stroke(speaker.color, lineWidth: 2)
                            .scaleEffect(1.8)
                            .opacity(0.5)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name or pick below", text: $editName, onCommit: {
                            commitRename()
                        })
                        .focused($isFieldFocused)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.speakerName)
                        .frame(maxWidth: 160)
                        .onAppear { isFieldFocused = true }
                        .onChange(of: isFieldFocused) { _, focused in
                            if !focused && isEditing {
                                // Re-assert focus if lost due to view re-render
                                DispatchQueue.main.async { isFieldFocused = true }
                            }
                        }

                        // Suggestions from saved profiles
                        if !suggestions.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(suggestions, id: \.self) { name in
                                        Button {
                                            editName = name
                                            commitRename()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "person.circle")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.secondary)
                                                Text(name)
                                                    .font(.system(size: 11))
                                                    .lineLimit(1)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 2)
                                            .padding(.horizontal, 4)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 80)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                } else {
                    Text(speaker.name)
                        .font(Theme.Typography.speakerName)
                        .lineLimit(1)
                        .onTapGesture {
                            editName = ""
                            isEditing = true
                        }
                        .help("Click to rename")
                }

                Text(formatTalkTime(speaker.talkTime))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            Button("Rename") {
                editName = ""
                isEditing = true
            }
            if !otherSpeakers.isEmpty {
                Menu("Merge into...") {
                    ForEach(otherSpeakers) { other in
                        Button {
                            onMerge?(speaker.name, other.name)
                        } label: {
                            Label(other.name, systemImage: "arrow.triangle.merge")
                        }
                    }
                }
            }
            Divider()
            Button("Remove Speaker", role: .destructive) {
                onRemove?(speaker.name)
            }
        }
    }

    private func commitRename() {
        if !editName.isEmpty {
            onRename?(speaker.name, editName)
        }
        isEditing = false
    }

    private func formatTalkTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes)m \(seconds)s"
    }
}

// MARK: - Profiles Column (when not recording)

private struct ProfilesColumn: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Interlocutor.lastSeen, order: .reverse) private var interlocutors: [Interlocutor]
    @State private var selectedProfile: Interlocutor?
    @State private var profileToDelete: Interlocutor?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Profiles", systemImage: "person.crop.circle")
                    .font(Theme.Typography.columnHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(interlocutors.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)

            if interlocutors.isEmpty {
                ContentUnavailableView {
                    Label("No profiles yet", systemImage: "person.slash")
                        .font(.caption)
                } description: {
                    Text("Record a session and name speakers to build profiles")
                        .font(.caption2)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(interlocutors) { person in
                            ProfileRow(
                                person: person,
                                isSelected: selectedProfile?.id == person.id,
                                onTap: {
                                    selectedProfile = selectedProfile?.id == person.id ? nil : person
                                },
                                onDelete: {
                                    profileToDelete = person
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .alert("Delete Speaker?", isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    if selectedProfile?.id == profile.id { selectedProfile = nil }
                    modelContext.delete(profile)
                    try? modelContext.save()
                    profileToDelete = nil
                }
            }
        } message: {
            if let profile = profileToDelete {
                Text("Delete \(profile.name) and their voice profile?")
            }
        }
    }
}

private struct ProfileRow: View {
    let person: Interlocutor
    let isSelected: Bool
    var onTap: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.Colors.speakerColor(for: person.name))
                    .frame(width: 8, height: 8)

                Text(person.name)
                    .font(Theme.Typography.speakerName)
                    .lineLimit(1)

                Spacer()

                if !person.voiceEmbeddings.isEmpty {
                    Image(systemName: "waveform")
                        .font(.system(size: 8))
                        .foregroundStyle(.green.opacity(0.6))
                        .help("Voice profile saved")
                }
            }

            if isSelected {
                // Expanded detail
                VStack(alignment: .leading, spacing: 3) {
                    if !person.role.isEmpty {
                        DetailLabel(icon: "briefcase", text: person.role)
                    }
                    if !person.company.isEmpty {
                        DetailLabel(icon: "building.2", text: person.company)
                    }

                    let meetingCount = person.participations.count
                    DetailLabel(icon: "calendar", text: "\(meetingCount) meeting\(meetingCount == 1 ? "" : "s")")

                    DetailLabel(icon: "clock", text: "Last: \(formatDate(person.lastSeen))")

                    if !person.voiceEmbeddings.isEmpty {
                        DetailLabel(icon: "waveform", text: "\(person.voiceEmbeddings.count) voice sample\(person.voiceEmbeddings.count == 1 ? "" : "s")")
                    }

                    if !person.notes.isEmpty {
                        Text(person.notes)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }

                    // Stats from participations
                    if let avgSentiment = averageSentiment {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Theme.Colors.sentimentColor(avgSentiment))
                                .frame(width: 5, height: 5)
                            Text("Avg sentiment: \(String(format: "%.1f", avgSentiment))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let avgTalkPercent = averageTalkPercent {
                        DetailLabel(icon: "mic", text: "Avg talk: \(Int(avgTalkPercent))%")
                    }

                    Button {
                        onDelete?()
                    } label: {
                        Label("Delete Profile", systemImage: "trash")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.leading, 14)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private var averageSentiment: Double? {
        let values = person.participations.map(\.avgSentiment).filter { $0 != 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var averageTalkPercent: Double? {
        let values = person.participations.map(\.talkPercent).filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

private struct DetailLabel: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Transcript Column (with silence gaps & copy)

private struct TranscriptColumn: View {
    let segments: [TranscriptSegment]
    var isModelLoading: Bool = false
    var loadingStatus: String = ""
    var downloadProgress: Double = 0
    var recordingError: String? = nil
    var isRecording: Bool = false
    var isListening: Bool = false
    var audioLevel: Float = 0
    var onRenameSpeaker: ((String, String) -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live Feed", systemImage: "text.word.spacing")
                    .font(Theme.Typography.columnHeader)
                    .foregroundStyle(.secondary)

                Spacer()

                // Copy All button (Phase 1.1)
                if !segments.isEmpty {
                    Button {
                        copyAllTranscript()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy all transcript")
                }
            }
            .padding(.bottom, 4)

            if let error = recordingError {
                VStack(spacing: 12) {
                    Label("Error", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.blue)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isModelLoading {
                VStack(spacing: 14) {
                    // Download progress bar if downloading, spinner otherwise
                    if downloadProgress > 0 && downloadProgress < 1.0 {
                        VStack(spacing: 6) {
                            ProgressView(value: downloadProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 160)
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                            .scaleEffect(0.8)
                    }

                    VStack(spacing: 4) {
                        Text(loadingStatus.isEmpty ? "Loading Whisper model…" : loadingStatus)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)

                        if loadingStatus.contains("Downloading") {
                            Text("First run only · ~75MB")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                VStack(spacing: 8) {
                    if isRecording {
                        if audioLevel > 0.001 {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Transcribing audio…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("First results appear after ~8s")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        } else {
                            Image(systemName: "waveform")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("Listening… no audio detected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if isListening {
                        Image(systemName: "ear")
                            .font(.title2)
                            .foregroundStyle(.yellow.opacity(0.6))
                        Text("Listening for speech…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Transcript appears when audio is detected")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "pause.circle")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("Paused")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Phase 1.2: Group by silence gaps
                let groups = groupByConversation(segments)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(groups) { group in
                                // Gap divider between conversation groups
                                if group.gapBefore >= 120 {
                                    GapDivider(gap: group.gapBefore, timestamp: group.startTime)
                                }

                                // Group header with copy button
                                if groups.count > 1 {
                                    HStack {
                                        Spacer()
                                        Button {
                                            copyGroupTranscript(group.segments)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Copy this conversation")
                                    }
                                }

                                ForEach(group.segments) { segment in
                                    TranscriptRow(segment: segment, onRenameSpeaker: onRenameSpeaker)
                                        .id(segment.id)
                                        .contextMenu {
                                            Button("Copy") {
                                                copySegment(segment)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .onChange(of: segments.count) { _, _ in
                        if let last = segments.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Copy Functions (Phase 1.1)

    private func copyAllTranscript() {
        let text = formatSegments(segments)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyGroupTranscript(_ groupSegments: [TranscriptSegment]) {
        let text = formatSegments(groupSegments)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySegment(_ segment: TranscriptSegment) {
        let text = formatSegments([segment])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formatSegments(_ segs: [TranscriptSegment]) -> String {
        segs.map { seg in
            let minutes = Int(seg.startTime) / 60
            let seconds = Int(seg.startTime) % 60
            return "[\(seg.speakerLabel)] (\(minutes):\(String(format: "%02d", seconds))): \(seg.text)"
        }.joined(separator: "\n")
    }
}

/// Visual divider showing a silence gap between conversation groups.
private struct GapDivider: View {
    let gap: TimeInterval
    let timestamp: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.tertiary)
                .frame(height: 0.5)
            Text("— \(formatGap(gap)) gap —")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(.tertiary)
                .frame(height: 0.5)
        }
        .padding(.vertical, 6)
    }

    private func formatGap(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        if minutes > 0 {
            return "\(minutes) min \(seconds)s"
        }
        return "\(seconds)s"
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    var onRenameSpeaker: ((String, String) -> Void)?
    @State private var isEditing = false
    @State private var editName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Sentiment indicator dot
            Circle()
                .fill(sentimentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            if isEditing {
                TextField("Name", text: $editName, onCommit: {
                    if !editName.isEmpty {
                        onRenameSpeaker?(segment.speakerLabel, editName)
                    }
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(Theme.Typography.speakerLabel)
                .foregroundStyle(Theme.Colors.speakerColor(for: segment.speakerLabel))
                .frame(width: 70)
            } else {
                Text(segment.speakerLabel)
                    .font(Theme.Typography.speakerLabel)
                    .foregroundStyle(Theme.Colors.speakerColor(for: segment.speakerLabel))
                    .frame(width: 70, alignment: .trailing)
                    .onTapGesture {
                        editName = segment.speakerLabel
                        isEditing = true
                    }
                    .help("Click to rename")
            }

            Text(segment.text)
                .font(Theme.Typography.transcript)
                .textSelection(.enabled)
        }
    }

    private var sentimentColor: Color {
        guard let sentiment = segment.sentiment else {
            return .clear
        }
        return Theme.Colors.sentimentColor(sentiment)
    }
}

// MARK: - Insights Column (rich dashboard)

private struct InsightsColumn: View {
    let recommendations: [Recommendation]
    var dynamicWidgets: [DynamicWidget] = []
    var currentTopic: String?
    var topics: [TopicInfo]
    var actionItems: [SignalDetector.DetectedAction]
    var speakers: [SpeakerInfo]
    var contentType: ContentTypeClassifier.ContentType = .unknown
    var segmentCount: Int = 0
    var meetingStartDate: Date?
    var keyStatements: [SignalDetector.DetectedStatement] = []
    var segments: [TranscriptSegment] = []
    var onDismiss: ((UUID) -> Void)?

    private var totalTalkTime: TimeInterval {
        speakers.reduce(0) { $0 + $1.talkTime }
    }

    private var totalWordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    private var totalQuestions: Int {
        segments.filter { $0.text.contains("?") }.count
    }

    /// Words per minute per speaker
    private var speakerPace: [(name: String, wpm: Double, color: Color)] {
        var words: [String: Int] = [:]
        var time: [String: TimeInterval] = [:]
        for seg in segments {
            words[seg.speakerLabel, default: 0] += seg.text.split(separator: " ").count
            time[seg.speakerLabel, default: 0] += seg.endTime - seg.startTime
        }
        return speakers.compactMap { speaker in
            let w = words[speaker.name] ?? 0
            let t = time[speaker.name] ?? 0
            guard t > 5 else { return nil }
            return (speaker.name, Double(w) / (t / 60), speaker.color)
        }
    }

    /// Rolling sentiment data points (averaged per 5-segment window).
    private var sentimentDataPoints: [Double] {
        let scored = segments.compactMap(\.sentiment)
        guard scored.count >= 3 else { return [] }
        let windowSize = max(3, scored.count / 10)
        return stride(from: 0, to: scored.count, by: windowSize).map { start in
            let end = min(start + windowSize, scored.count)
            let window = scored[start..<end]
            return window.reduce(0.0, +) / Double(window.count)
        }
    }

    /// Meeting health score based on participation balance, topic coverage, and decisions.
    private var meetingHealth: (score: Int, color: Color, factors: [String]) {
        var score = 50 // base
        var factors: [String] = []

        // Participation balance (0-25 points): how evenly distributed talk time is
        if speakers.count > 1 && totalTalkTime > 0 {
            let percents = speakers.map { $0.talkTime / totalTalkTime }
            let ideal = 1.0 / Double(speakers.count)
            let deviation = percents.map { abs($0 - ideal) }.reduce(0, +) / Double(speakers.count)
            let balanceScore = Int(max(0, 25 - deviation * 100))
            score += balanceScore
            if balanceScore < 10 {
                let dominant = speakers.max(by: { $0.talkTime < $1.talkTime })?.name ?? ""
                factors.append("\(dominant) dominates (\(Int((speakers.max(by: { $0.talkTime < $1.talkTime })?.talkTime ?? 0) / totalTalkTime * 100))%)")
            } else {
                factors.append("Balanced participation")
            }
        }

        // Topic coverage (0-15 points)
        let topicScore = min(15, topics.count * 5)
        score += topicScore
        if topics.isEmpty {
            factors.append("No topics detected yet")
        } else {
            factors.append("\(topics.count) topic\(topics.count == 1 ? "" : "s") covered")
        }

        // Action items (0-10 points) — having some is positive
        if !actionItems.isEmpty {
            score += min(10, actionItems.count * 3)
            factors.append("\(actionItems.count) action item\(actionItems.count == 1 ? "" : "s")")
        }

        let clamped = min(100, max(0, score))
        let color: Color = clamped >= 70 ? .green : clamped >= 40 ? .yellow : .red
        return (clamped, color, factors)
    }

    private func categoryColor(_ category: String) -> Color {
        switch category.lowercased() {
        case "decision": return .green
        case "commitment": return .blue
        case "risk": return .red
        case "concern": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Insights", systemImage: "lightbulb.fill")
                    .font(Theme.Typography.columnHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                if contentType != .unknown {
                    HStack(spacing: 3) {
                        Image(systemName: contentType.icon)
                            .font(.system(size: 8))
                        Text(contentType.rawValue)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.purple.opacity(0.12), in: Capsule())
                }
                if let start = meetingStartDate {
                    Text(start, style: .timer)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Current topic banner
                    if let topic = currentTopic {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.purple)
                            Text(topic)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.purple)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Quick stats bar
                    if segmentCount > 0 {
                        HStack(spacing: 0) {
                            QuickStat(icon: "text.word.spacing", value: "\(totalWordCount)", label: "words")
                            Spacer()
                            QuickStat(icon: "bubble.left.and.bubble.right", value: "\(segmentCount)", label: "segments")
                            Spacer()
                            QuickStat(icon: "questionmark.circle", value: "\(totalQuestions)", label: "questions")
                            Spacer()
                            QuickStat(icon: "person.2", value: "\(speakers.count)", label: "speakers")
                            if totalTalkTime > 60 {
                                Spacer()
                                QuickStat(icon: "speedometer", value: "\(Int(Double(totalWordCount) / (totalTalkTime / 60)))", label: "wpm")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Speaker timeline (swimlane)
                    if speakers.count >= 1 && segments.count >= 3 {
                        SectionCard(icon: "timeline.selection", color: .cyan) {
                            SpeakerTimeline(segments: segments, speakers: speakers)
                                .frame(height: CGFloat(max(2, min(speakers.count, 5))) * 14 + 16)
                        }
                    }

                    // Dashboard grid — 2 columns for compact widgets
                    let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                    LazyVGrid(columns: columns, spacing: 8) {
                        // Speaker distribution
                        if speakers.count > 1 && totalTalkTime > 0 {
                            SectionCard(icon: "person.2", color: .blue) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(speakers.prefix(4)) { speaker in
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(speaker.color)
                                            .frame(width: 6, height: 6)
                                        Text(speaker.name)
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                            .frame(maxWidth: 80, alignment: .leading)

                                        GeometryReader { geo in
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(speaker.color.opacity(0.3))
                                                .overlay(alignment: .leading) {
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .fill(speaker.color)
                                                        .frame(width: geo.size.width * CGFloat(speaker.talkTime / totalTalkTime))
                                                }
                                        }
                                        .frame(height: 6)

                                        Text("\(Int((speaker.talkTime / totalTalkTime) * 100))%")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }

                    // Topics timeline
                    if !topics.isEmpty {
                        SectionCard(icon: "list.bullet", color: .teal) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(topics.suffix(5).enumerated()), id: \.offset) { _, topic in
                                    TopicRow(topic: topic, isCurrent: topic.name == currentTopic)
                                }
                            }
                        }
                    }

                    // Action items
                    if !actionItems.isEmpty {
                        SectionCard(icon: "checkmark.circle", color: .orange) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(actionItems.suffix(4).enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .top, spacing: 4) {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.orange)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.description)
                                                .font(.system(size: 10))
                                                .lineLimit(2)
                                            if !item.ownerLabel.isEmpty {
                                                Text(item.ownerLabel)
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Key quotes
                    if !keyStatements.isEmpty {
                        SectionCard(icon: "quote.opening", color: .indigo) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(keyStatements.suffix(3).enumerated()), id: \.offset) { _, stmt in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\"\(stmt.statement)\"")
                                            .font(.system(size: 10))
                                            .italic()
                                            .lineLimit(2)
                                        HStack(spacing: 4) {
                                            Text("— \(stmt.speakerLabel)")
                                                .font(.system(size: 9, weight: .medium))
                                            Text(stmt.category)
                                                .font(.system(size: 8))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(categoryColor(stmt.category).opacity(0.15), in: Capsule())
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    // Sentiment trend
                    if sentimentDataPoints.count >= 3 {
                        SectionCard(icon: "chart.xyaxis.line", color: .green) {
                            VStack(alignment: .leading, spacing: 4) {
                                SentimentSparkline(dataPoints: sentimentDataPoints)
                                    .frame(height: 30)
                                HStack {
                                    Text("Negative")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.red.opacity(0.6))
                                    Spacer()
                                    let avg = sentimentDataPoints.reduce(0.0, +) / Double(sentimentDataPoints.count)
                                    Text("avg: \(avg > 0 ? "+" : "")\(String(format: "%.1f", avg))")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Positive")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.green.opacity(0.6))
                                }
                            }
                        }
                    }

                    // Speaking pace (words per minute)
                    if !speakerPace.isEmpty {
                        SectionCard(icon: "speedometer", color: .mint) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(speakerPace, id: \.name) { item in
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(item.color)
                                            .frame(width: 6, height: 6)
                                        Text(item.name)
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                            .frame(maxWidth: 80, alignment: .leading)
                                        Spacer()
                                        Text("\(Int(item.wpm)) wpm")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(item.wpm > 180 ? .orange : item.wpm < 100 ? .blue : .green)
                                    }
                                }
                            }
                        }
                    }

                    // Meeting health score
                    if speakers.count > 1 && totalTalkTime > 30 {
                        SectionCard(icon: "heart.text.square", color: .pink) {
                            let health = meetingHealth
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Meeting Health")
                                        .font(.system(size: 10, weight: .medium))
                                    Spacer()
                                    Text("\(health.score)%")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(health.color)
                                }
                                HealthBar(value: Double(health.score) / 100.0, color: health.color)
                                    .frame(height: 4)
                                ForEach(health.factors, id: \.self) { factor in
                                    Text(factor)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    } // end LazyVGrid

                    // JARVIS dynamic widgets (full-width, below the grid)
                    if !dynamicWidgets.isEmpty {
                        ForEach(dynamicWidgets) { widget in
                            DynamicWidgetView(widget: widget)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    // LLM insights — fallback for MLX / non-JARVIS mode
                    if !recommendations.isEmpty {
                        ForEach(recommendations) { rec in
                            RecommendationCard(recommendation: rec, onDismiss: {
                                onDismiss?(rec.id)
                            })
                        }
                    }

                    // Empty state
                    if recommendations.isEmpty && dynamicWidgets.isEmpty && topics.isEmpty && actionItems.isEmpty && currentTopic == nil {
                        ContentUnavailableView {
                            Label("Insights will appear here", systemImage: "sparkles")
                                .font(.caption)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(12)
    }
}

/// A topic row that expands inline to show its summary on tap.
/// Mini sparkline chart for sentiment trend.
private struct SentimentSparkline: View {
    let dataPoints: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2

            // Zero line
            Path { path in
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: w, y: midY))
            }
            .stroke(.secondary.opacity(0.2), lineWidth: 0.5)

            // Sentiment line
            Path { path in
                guard dataPoints.count >= 2 else { return }
                let step = w / CGFloat(dataPoints.count - 1)
                for (i, val) in dataPoints.enumerated() {
                    let x = CGFloat(i) * step
                    let y = midY - CGFloat(val) * midY // -1→bottom, +1→top
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(
                LinearGradient(
                    colors: [.red.opacity(0.7), .yellow, .green.opacity(0.7)],
                    startPoint: .bottom, endPoint: .top
                ),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// Simple horizontal bar for meeting health.
private struct HealthBar: View {
    let value: Double // 0.0–1.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.2))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                }
        }
    }
}

/// Quick stat pill for the stats bar.
private struct QuickStat: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Swimlane timeline showing when each speaker talked.
private struct SpeakerTimeline: View {
    let segments: [TranscriptSegment]
    let speakers: [SpeakerInfo]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            guard let first = segments.first, let last = segments.last else {
                return AnyView(EmptyView())
            }
            let totalDuration = max(1, last.endTime - first.startTime)
            let baseTime = first.startTime
            let speakerNames = speakers.prefix(5).map(\.name)
            let rowHeight: CGFloat = 14

            return AnyView(
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(speakerNames.enumerated()), id: \.offset) { idx, name in
                        let speakerColor = speakers.first(where: { $0.name == name })?.color ?? .gray
                        HStack(spacing: 4) {
                            Text(name)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: 55, alignment: .trailing)
                                .lineLimit(1)

                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(.white.opacity(0.03))
                                    .frame(height: rowHeight - 4)

                                ForEach(segments.filter({ $0.speakerLabel == name }), id: \.id) { seg in
                                    let xStart = CGFloat((seg.startTime - baseTime) / totalDuration) * (w - 63)
                                    let segWidth = max(2, CGFloat((seg.endTime - seg.startTime) / totalDuration) * (w - 63))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(speakerColor.opacity(0.7))
                                        .frame(width: segWidth, height: rowHeight - 4)
                                        .offset(x: xStart)
                                }
                            }
                        }
                        .frame(height: rowHeight)
                    }

                    // Time axis
                    HStack {
                        Text("0:00")
                        Spacer()
                        let mins = Int(totalDuration / 60)
                        if mins > 0 {
                            Text("\(mins)m")
                        } else {
                            Text("\(Int(totalDuration))s")
                        }
                    }
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 59)
                }
            )
        }
    }
}

private struct TopicRow: View {
    let topic: TopicInfo
    let isCurrent: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isCurrent ? .teal : .secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
                Text(topic.name)
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                if !topic.summary.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !topic.summary.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                Text(topic.summary)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, 9)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Compact section card for the insights column.
private struct SectionCard<Content: View>: View {
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
        )
    }
}

private struct RecommendationCard: View {
    let recommendation: Recommendation
    var onDismiss: (() -> Void)?
    @State private var opacity: Double = 1.0
    @State private var isExpanded = false

    /// Seconds before auto-dismiss.
    private let autoDismissDelay: TimeInterval = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(recommendation.category == .nextTopic ? "Next Topic" : recommendation.category.rawValue.capitalized)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text(recommendation.text)
                .font(Theme.Typography.body)
                .lineLimit(isExpanded ? nil : 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .opacity(opacity)
        .task {
            // Fade out and auto-dismiss after delay
            try? await Task.sleep(for: .seconds(autoDismissDelay - 2))
            withAnimation(.easeOut(duration: 2)) { opacity = 0.3 }
            try? await Task.sleep(for: .seconds(2))
            onDismiss?()
        }
    }

    private var iconName: String {
        switch recommendation.category {
        case .suggestion: "lightbulb"
        case .warning: "exclamationmark.triangle"
        case .insight: "sparkles"
        case .observation: "eye"
        case .risk: "exclamationmark.shield"
        case .summary: "doc.text"
        case .nextTopic: "arrow.right.circle"
        }
    }

    private var iconColor: Color {
        switch recommendation.category {
        case .suggestion: .yellow
        case .warning: .orange
        case .insight: .purple
        case .observation: .blue
        case .risk: .red
        case .summary: .teal
        case .nextTopic: .green
        }
    }
}

// MARK: - Mic Button (Push-to-Talk)

private struct MicButton: View {
    @Bindable var voiceInputManager: VoiceInputManager
    let onTranscribed: (String) -> Void

    var body: some View {
        Button {
            if voiceInputManager.isRecording {
                Task { await stopAndSend() }
            } else {
                voiceInputManager.startRecording()
            }
        } label: {
            ZStack {
                if voiceInputManager.isRecording {
                    Circle()
                        .fill(.red.opacity(0.2))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle()
                                .stroke(.red.opacity(0.4), lineWidth: 1.5)
                                .scaleEffect(1 + CGFloat(voiceInputManager.audioLevel) * 3)
                                .opacity(Double(1 - voiceInputManager.audioLevel * 2))
                                .animation(.easeOut(duration: 0.1), value: voiceInputManager.audioLevel)
                        }
                }

                Image(systemName: voiceInputManager.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 12))
                    .foregroundStyle(voiceInputManager.isRecording ? .red : .secondary)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(voiceInputManager.isTranscribing)
        .help(voiceInputManager.isRecording ? "Tap to stop" : "Tap to speak")
    }

    private func stopAndSend() async {
        guard let text = await voiceInputManager.stopAndTranscribe() else { return }
        onTranscribed(text)
    }
}

// MARK: - Chat Bubble

/// Animated streaming response indicator shown while the LLM is generating.
private struct StreamingResponseView: View {
    let text: String
    @State private var dotCount = 1
    @State private var dotTimer: Timer?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Animated dot indicator
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.blue.opacity(i < dotCount ? 0.8 : 0.2))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.top, 4)

            if text.isEmpty {
                Text("Thinking…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 30)
        }
        .onAppear {
            dotTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                dotCount = (dotCount % 3) + 1
            }
        }
        .onDisappear {
            dotTimer?.invalidate()
            dotTimer = nil
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 30) }

            Text(message.content)
                .font(Theme.Typography.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(.blue.opacity(0.2))
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .textSelection(.enabled)

            if message.role == .assistant { Spacer(minLength: 30) }
        }
    }
}

// MARK: - Resize Grip

/// Resize grip using a native NSView to bypass isMovableByWindowBackground.
private struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeGripNSView {
        let grip = ResizeGripNSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        grip.wantsLayer = true
        return grip
    }

    func updateNSView(_ nsView: ResizeGripNSView, context: Context) {}
}
