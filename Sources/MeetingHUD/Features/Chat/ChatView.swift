import SwiftUI

/// Standalone chat view for use outside the overlay (e.g., separate window).
/// The primary chat experience is now the ChatDrawer in OverlayView.
/// This file is retained for the ChatView API compatibility and potential future use.
struct ChatView: View {
    @Bindable var appState: AppState
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Ask", systemImage: "bubble.left.fill")
                    .font(Theme.Typography.columnHeader)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 6)

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.chatMessages) { msg in
                            ChatBubbleStandalone(message: msg)
                                .id(msg.id)
                        }

                        if appState.isGeneratingResponse {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(appState.streamingResponse.isEmpty ? "Thinking..." : appState.streamingResponse)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .id("streaming")
                        }
                    }
                }
                .onChange(of: appState.chatMessages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: appState.isGeneratingResponse) { _, isGenerating in
                    if isGenerating {
                        scrollToBottom(proxy: proxy, anchor: "streaming")
                    }
                }
            }

            Divider().opacity(0.3).padding(.vertical, 4)

            // Voice transcription status
            if appState.voiceInputManager.isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing...")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }

            // Input field
            HStack(spacing: 6) {
                TextField("Ask about this meeting...", text: $inputText, axis: .vertical)
                    .font(Theme.Typography.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(inputText.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.blue))
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || appState.isGeneratingResponse)
            }
        }
        .padding(12)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await appState.sendChatMessage(text)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, anchor: String? = nil) {
        withAnimation(.easeOut(duration: 0.15)) {
            if let anchor {
                proxy.scrollTo(anchor, anchor: .bottom)
            } else if let last = appState.chatMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Chat Bubble (standalone version)

private struct ChatBubbleStandalone: View {
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
