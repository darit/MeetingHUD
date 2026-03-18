import SwiftUI
import SwiftData

/// A sheet showing previous meetings: list, details, insights, and LLM Q&A.
struct MeetingHistorySheet: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \Interlocutor.lastSeen, order: .reverse) private var interlocutors: [Interlocutor]
    @State private var selected: Meeting?
    @State private var meetingToDelete: Meeting?
    @State private var speakerToDelete: Interlocutor?
    @State private var showDeleteAllSpeakers = false
    @State private var showSpeakers = false

    var body: some View {
        HSplitView {
            // Left: meeting/speaker list
            VStack(spacing: 0) {
                HStack {
                    Text(showSpeakers ? "Speakers" : "Past Meetings")
                        .font(.headline)
                    Spacer()
                    Button {
                        showSpeakers.toggle()
                        if showSpeakers { selected = nil }
                    } label: {
                        Image(systemName: showSpeakers ? "calendar" : "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showSpeakers ? "Show meetings" : "Show speakers")
                    Button {
                        appState.showHistorySheet = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if showSpeakers {
                    speakerListView
                } else {
                    meetingListView
                }
            }
            .frame(minWidth: 220, maxWidth: 280)

            // Right: detail
            if showSpeakers {
                VStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("\(interlocutors.count) speaker\(interlocutors.count == 1 ? "" : "s") saved")
                        .foregroundStyle(.secondary)
                    if !interlocutors.isEmpty {
                        Text("Right-click or swipe to delete")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(interlocutors.prefix(10)) { speaker in
                                HStack(spacing: 8) {
                                    Image(systemName: speaker.voiceEmbeddings.isEmpty ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                                        .foregroundStyle(speaker.voiceEmbeddings.isEmpty ? Color.secondary : Color.green)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(speaker.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Text("\(speaker.participations.count) meetings · \(speaker.voiceEmbeddings.count) voice samples")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let meeting = selected {
                MeetingDetailView(meeting: meeting, appState: appState)
            } else {
                VStack {
                    Image(systemName: "arrow.left")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Select a meeting")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            if !showSpeakers { selected = meetings.first }
        }
        .alert("Delete Meeting?", isPresented: Binding(
            get: { meetingToDelete != nil },
            set: { if !$0 { meetingToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { meetingToDelete = nil }
            Button("Delete", role: .destructive) {
                if let meeting = meetingToDelete {
                    if selected == meeting { selected = nil }
                    modelContext.delete(meeting)
                    try? modelContext.save()
                    meetingToDelete = nil
                }
            }
        } message: {
            Text("This will permanently delete this meeting and its transcript.")
        }
        .alert("Delete Speaker?", isPresented: Binding(
            get: { speakerToDelete != nil },
            set: { if !$0 { speakerToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { speakerToDelete = nil }
            Button("Delete", role: .destructive) {
                if let speaker = speakerToDelete {
                    deleteSpeaker(speaker)
                    speakerToDelete = nil
                }
            }
        } message: {
            if let speaker = speakerToDelete {
                Text("Delete \(speaker.name) and their \(speaker.voiceEmbeddings.count) voice samples?")
            }
        }
        .alert("Delete All Speakers?", isPresented: $showDeleteAllSpeakers) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                for speaker in interlocutors {
                    modelContext.delete(speaker)
                }
                try? modelContext.save()
            }
        } message: {
            Text("This will delete all \(interlocutors.count) speakers and their voice profiles.")
        }
    }

    // MARK: - List Views

    @ViewBuilder
    private var meetingListView: some View {
        if meetings.isEmpty {
            ContentUnavailableView(
                "No meetings yet",
                systemImage: "calendar.badge.clock",
                description: Text("Meetings will appear here after you record and stop them.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List(meetings, selection: $selected) { meeting in
                HStack {
                    MeetingListRow(meeting: meeting)
                    Spacer()
                    Button {
                        archiveMeeting(meeting)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Button {
                        meetingToDelete = meeting
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundStyle(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .tag(meeting)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var speakerListView: some View {
        if interlocutors.isEmpty {
            ContentUnavailableView(
                "No speakers yet",
                systemImage: "person.2",
                description: Text("Speakers will appear after you name them in a meeting.")
            )
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                List {
                    ForEach(interlocutors) { speaker in
                        HStack {
                            SpeakerListRow(speaker: speaker, meetingCount: speaker.participations.count)
                            Spacer()
                            Button {
                                speakerToDelete = speaker
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()
                Button("Delete All Speakers", role: .destructive) {
                    showDeleteAllSpeakers = true
                }
                .font(.caption)
                .padding(8)
            }
        }
    }

    private func archiveMeeting(_ meeting: Meeting) {
        let segments: [TranscriptSegment]
        if let data = meeting.compressedTranscript,
           let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data {
            segments = (try? JSONDecoder().decode([TranscriptSegment].self, from: decompressed)) ?? []
        } else {
            segments = []
        }

        let markdown = MeetingExporter.exportMarkdown(
            title: meeting.title,
            date: meeting.date,
            segments: segments,
            speakers: meeting.participations
                .compactMap { $0.interlocutor }
                .map { SpeakerInfo(id: $0.id, name: $0.name) },
            topics: meeting.topics.sorted { $0.startTime < $1.startTime }
                .map { TopicInfo(name: $0.name, startTime: $0.startTime, summary: $0.summary) },
            actionItems: meeting.actionItems.map {
                SignalDetector.DetectedAction(
                    description: $0.desc,
                    ownerLabel: $0.owner?.name ?? "",
                    extractedFrom: $0.extractedFrom
                )
            },
            summary: meeting.summary.isEmpty ? nil : meeting.summary
        )
        MeetingExporter.copyToClipboard(markdown)
    }

    private func deleteSpeaker(_ speaker: Interlocutor) {
        modelContext.delete(speaker)
        try? modelContext.save()
    }
}

// MARK: - Speaker List Row

private struct SpeakerListRow: View {
    let speaker: Interlocutor
    let meetingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speaker.name)
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 6) {
                if meetingCount > 0 {
                    Text("\(meetingCount) meeting\(meetingCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !speaker.role.isEmpty {
                    Text("· \(speaker.role)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !speaker.voiceEmbeddings.isEmpty {
                    Image(systemName: "waveform")
                        .font(.system(size: 8))
                        .foregroundStyle(.teal)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Meeting List Row

private struct MeetingListRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title.isEmpty ? "Untitled Meeting" : meeting.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if meeting.duration > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(formatDuration(meeting.duration))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

// MARK: - Meeting Detail View

private struct MeetingDetailView: View {
    let meeting: Meeting
    @Bindable var appState: AppState
    @State private var chatText = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var isThinking = false
    @State private var streamingText = ""

    private var decompressedSegments: [TranscriptSegment] {
        guard let data = meeting.compressedTranscript else { return [] }
        guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data else { return [] }
        return (try? JSONDecoder().decode([TranscriptSegment].self, from: decompressed)) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title.isEmpty ? "Untitled Meeting" : meeting.title)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 8) {
                            Label(meeting.date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                            if meeting.duration > 0 {
                                Label(formatDuration(meeting.duration), systemImage: "clock")
                            }
                            if !meeting.sourceApp.isEmpty && meeting.sourceApp != "Unknown" {
                                Label(meeting.sourceApp, systemImage: "video")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        copyMeetingSummary()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy meeting summary")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Summary
                    if !meeting.summary.isEmpty {
                        SectionBlock(title: "Summary", icon: "doc.text.fill", color: .blue) {
                            MarkdownView(text: meeting.summary)
                        }
                    }

                    // Participants
                    if !meeting.participations.isEmpty {
                        let named = meeting.participations.filter { $0.interlocutor != nil }
                        if !named.isEmpty {
                            SectionBlock(title: "Participants", icon: "person.2.fill", color: .purple) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(named.sorted { $0.talkTime > $1.talkTime }) { p in
                                        ParticipantRow(participation: p)
                                    }
                                }
                            }
                        }
                    }

                    // Topics
                    if !meeting.topics.isEmpty {
                        SectionBlock(title: "Topics", icon: "list.bullet", color: .teal) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(meeting.topics.sorted { $0.startTime < $1.startTime }) { topic in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 5))
                                            .foregroundStyle(.teal)
                                            .padding(.top, 4)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(topic.name)
                                                .font(.system(size: 12, weight: .medium))
                                            if !topic.summary.isEmpty {
                                                Text(topic.summary)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Action Items
                    if !meeting.actionItems.isEmpty {
                        SectionBlock(title: "Action Items", icon: "checkmark.circle", color: .green) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(meeting.actionItems) { item in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(item.status == .done ? .green : .secondary)
                                            .font(.system(size: 12))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.desc)
                                                .font(.system(size: 12))
                                                .strikethrough(item.status == .done)
                                            if let owner = item.owner?.name {
                                                Text(owner)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Q&A with this meeting
            VStack(spacing: 0) {
                if !chatMessages.isEmpty || isThinking {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(chatMessages) { msg in
                                    HistoryChatBubble(message: msg)
                                        .id(msg.id)
                                }
                                if isThinking {
                                    HistoryStreamingView(text: streamingText)
                                        .id("stream")
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .frame(height: 140)
                        .onChange(of: chatMessages.count) { _, _ in
                            if let last = chatMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    Divider().opacity(0.3)
                }

                // Input
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("Ask about this meeting… (\(appState.analysisLLMProvider.displayName))", text: $chatText)
                        .font(.system(size: 12))
                        .textFieldStyle(.plain)
                        .onSubmit { sendQuestion() }

                    if isThinking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            sendQuestion()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(chatText.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.blue))
                        }
                        .buttonStyle(.plain)
                        .disabled(chatText.isEmpty)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private func sendQuestion() {
        let q = chatText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        chatText = ""
        chatMessages.append(ChatMessage(role: .user, content: q))
        isThinking = true
        streamingText = ""

        let meeting = self.meeting
        let segments = decompressedSegments
        let llm = appState.analysisLLMProvider

        Task {
            let isAvail = await llm.isAvailable
            guard isAvail else {
                await MainActor.run {
                    chatMessages.append(ChatMessage(
                        role: .assistant,
                        content: "No LLM available. Load a local model or switch to Claude in the menu bar."
                    ))
                    isThinking = false
                }
                return
            }

            let context = buildMeetingContext(meeting: meeting, segments: segments)
            var messages: [ChatMessage] = [
                ChatMessage(role: .system, content: PromptTemplates.pastMeetingQA),
                ChatMessage(role: .user, content: "Meeting context:\n\n\(context)"),
                ChatMessage(role: .assistant, content: "I have the meeting context. Ask me anything about it."),
            ]
            let recentHistory = Array(chatMessages.suffix(6))
            messages.append(contentsOf: recentHistory)

            do {
                let stream = try await llm.stream(messages: messages)
                var full = ""
                for await chunk in stream {
                    full += chunk
                    await MainActor.run { streamingText = full }
                }
                await MainActor.run {
                    chatMessages.append(ChatMessage(role: .assistant, content: full))
                    streamingText = ""
                    isThinking = false
                }
            } catch {
                await MainActor.run {
                    chatMessages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                    isThinking = false
                }
            }
        }
    }

    private func buildMeetingContext(meeting: Meeting, segments: [TranscriptSegment]) -> String {
        var parts: [String] = []
        parts.append("Title: \(meeting.title)")
        parts.append("Date: \(meeting.date.formatted(date: .complete, time: .shortened))")
        if meeting.duration > 0 {
            parts.append("Duration: \(formatDuration(meeting.duration))")
        }
        if !meeting.summary.isEmpty {
            parts.append("Summary:\n\(meeting.summary)")
        }
        if !meeting.topics.isEmpty {
            let topicLines = meeting.topics.sorted { $0.startTime < $1.startTime }.map { "- \($0.name): \($0.summary)" }
            parts.append("Topics:\n\(topicLines.joined(separator: "\n"))")
        }
        if !meeting.actionItems.isEmpty {
            let actionLines = meeting.actionItems.map { item -> String in
                let ownerSuffix: String
                if let ownerName = item.owner?.name {
                    ownerSuffix = " [\(ownerName)]"
                } else {
                    ownerSuffix = ""
                }
                let owner = ownerSuffix
                return "- \(item.desc)\(owner)"
            }
            parts.append("Action items:\n\(actionLines.joined(separator: "\n"))")
        }
        let named = meeting.participations.filter { $0.interlocutor != nil }
        if !named.isEmpty {
            let pLines = named.sorted { $0.talkTime > $1.talkTime }.map { p -> String in
                let name = p.interlocutor?.name ?? "Unknown"
                return "- \(name): \(Int(p.talkPercent))% talk time"
            }
            parts.append("Participants:\n\(pLines.joined(separator: "\n"))")
        }
        if !segments.isEmpty {
            let maxSegments = min(segments.count, 200) // keep within context limits
            let transcript = segments.suffix(maxSegments).map { "[\($0.speakerLabel)] (\(formatTime($0.startTime))): \($0.text)" }
                .joined(separator: "\n")
            parts.append("Transcript:\n\(transcript)")
        }
        return parts.joined(separator: "\n\n")
    }

    private func copyMeetingSummary() {
        let segments = decompressedSegments
        let markdown = MeetingExporter.exportMarkdown(
            title: meeting.title,
            date: meeting.date,
            segments: segments,
            speakers: meeting.participations
                .compactMap { $0.interlocutor }
                .map { SpeakerInfo(id: $0.id, name: $0.name) },
            topics: meeting.topics.sorted { $0.startTime < $1.startTime }
                .map { TopicInfo(name: $0.name, startTime: $0.startTime, summary: $0.summary) },
            actionItems: meeting.actionItems.map {
                SignalDetector.DetectedAction(
                    description: $0.desc,
                    ownerLabel: $0.owner?.name ?? "",
                    extractedFrom: $0.extractedFrom
                )
            },
            summary: meeting.summary.isEmpty ? nil : meeting.summary
        )
        MeetingExporter.copyToClipboard(markdown)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        return m < 60 ? "\(m) min" : "\(m / 60)h \(m % 60)m"
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Supporting Views

private struct SectionBlock<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct ParticipantRow: View {
    let participation: MeetingParticipation

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(participation.interlocutor?.name ?? "Unknown")
                    .font(.system(size: 12, weight: .medium))
                if participation.talkPercent > 0 {
                    Text("\(Int(participation.talkPercent))% talk time · \(participation.interventionCount) turns")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Sentiment indicator
            if participation.avgSentiment != 0 {
                let sentiment = participation.avgSentiment
                Circle()
                    .fill(sentiment > 0.2 ? .green : sentiment < -0.2 ? .red : .secondary)
                    .frame(width: 8, height: 8)
                    .help(sentiment > 0.2 ? "Positive" : sentiment < -0.2 ? "Negative" : "Neutral")
            }
        }
    }
}

private struct HistoryChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Group {
                if message.role == .assistant {
                    MarkdownView(text: message.content, fontSize: 12)
                } else {
                    Text(message.content)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                message.role == .user
                    ? AnyShapeStyle(.blue.opacity(0.2))
                    : AnyShapeStyle(.secondary.opacity(0.1)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .textSelection(.enabled)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

/// Renders markdown text line-by-line, handling headers, bullets, and bold.
private struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                renderLine(line)
            }
        }
    }

    private var lines: [String] {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("### ") {
            Text(inlineMarkdown(String(trimmed.dropFirst(4))))
                .font(.system(size: fontSize, weight: .semibold))
                .padding(.top, 2)
        } else if trimmed.hasPrefix("## ") {
            Text(inlineMarkdown(String(trimmed.dropFirst(3))))
                .font(.system(size: fontSize + 1, weight: .bold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("# ") {
            Text(inlineMarkdown(String(trimmed.dropFirst(2))))
                .font(.system(size: fontSize + 2, weight: .bold))
                .padding(.top, 6)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 4) {
                Text("•")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(String(trimmed.dropFirst(2))))
                    .font(.system(size: fontSize))
            }
        } else {
            Text(inlineMarkdown(trimmed))
                .font(.system(size: fontSize))
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct HistoryStreamingView: View {
    let text: String
    @State private var dotCount = 1
    @State private var timer: Timer?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.blue.opacity(i < dotCount ? 0.8 : 0.2))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.top, 3)
            Text(text.isEmpty ? "Thinking…" : text)
                .font(.system(size: 12))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(10)
            Spacer(minLength: 40)
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                dotCount = (dotCount % 3) + 1
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
