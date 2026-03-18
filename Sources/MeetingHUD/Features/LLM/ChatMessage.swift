import Foundation

/// A single message in a multi-turn LLM conversation.
struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date

    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    init(role: Role, content: String, timestamp: Date = .now) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
