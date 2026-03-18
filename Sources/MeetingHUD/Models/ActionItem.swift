import Foundation
import SwiftData

/// An action item extracted from meeting conversation by the LLM.
@Model
final class ActionItem {
    var id: UUID
    var desc: String
    var dueDate: Date?
    var status: Status
    var extractedFrom: String

    /// The person responsible for this action item.
    var owner: Interlocutor?

    /// The meeting this action item was extracted from.
    var meeting: Meeting?

    /// Completion status of the action item.
    enum Status: String, Codable {
        case pending
        case done
        case overdue
    }

    init(
        desc: String,
        dueDate: Date? = nil,
        extractedFrom: String = "",
        owner: Interlocutor? = nil,
        meeting: Meeting? = nil
    ) {
        self.id = UUID()
        self.desc = desc
        self.dueDate = dueDate
        self.status = .pending
        self.extractedFrom = extractedFrom
        self.owner = owner
        self.meeting = meeting
    }

    /// Check if this action item is overdue and update status accordingly.
    func checkOverdue() -> Bool {
        guard status == .pending, let due = dueDate else { return false }
        return due < .now
    }
}
