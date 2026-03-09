import Foundation

/// Response from the backend when ending a meeting.
struct MeetingSummaryResponse: Codable {
    let executive_summary: String
    let decisions: [Decision]
    let action_items: [ActionItem]
    let unresolved: [String]
    var full_transcript: String

    init(executive_summary: String, decisions: [Decision], action_items: [ActionItem], unresolved: [String], full_transcript: String = "") {
        self.executive_summary = executive_summary
        self.decisions = decisions
        self.action_items = action_items
        self.unresolved = unresolved
        self.full_transcript = full_transcript
    }

    enum CodingKeys: String, CodingKey {
        case executive_summary
        case decisions
        case action_items
        case unresolved
        case full_transcript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executive_summary = (try? container.decode(String.self, forKey: .executive_summary)) ?? ""
        self.decisions = (try? container.decode([Decision].self, forKey: .decisions)) ?? []
        self.action_items = (try? container.decode([ActionItem].self, forKey: .action_items)) ?? []
        self.unresolved = (try? container.decode([String].self, forKey: .unresolved)) ?? []
        self.full_transcript = (try? container.decode(String.self, forKey: .full_transcript)) ?? ""
    }
}

struct Decision: Codable, Identifiable {
    let id: UUID
    let decision: String
    let context: String

    init(decision: String, context: String) {
        self.id = UUID()
        self.decision = decision
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case decision, context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.decision = try container.decode(String.self, forKey: .decision)
        self.context = (try? container.decode(String.self, forKey: .context)) ?? ""
    }
}

struct ActionItem: Codable, Identifiable {
    let id: UUID
    let action: String
    let assignee: String
    let deadline: String

    init(action: String, assignee: String, deadline: String) {
        self.id = UUID()
        self.action = action
        self.assignee = assignee
        self.deadline = deadline
    }

    enum CodingKeys: String, CodingKey {
        case action, assignee, deadline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.action = try container.decode(String.self, forKey: .action)
        self.assignee = (try? container.decode(String.self, forKey: .assignee)) ?? ""
        self.deadline = (try? container.decode(String.self, forKey: .deadline)) ?? ""
    }
}
