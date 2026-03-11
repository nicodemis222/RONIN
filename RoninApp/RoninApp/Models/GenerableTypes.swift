#if canImport(FoundationModels)
import Foundation
import FoundationModels

// MARK: - @Generable Types for Apple Foundation Models
//
// @Generable structs cannot have UUID fields, Date fields, or custom init.
// These parallel the existing Codable app types but are Foundation Models-compatible.
// Each has a toAppModel() that maps to the corresponding app type with fresh UUIDs.

// MARK: - Copilot Response Types

@available(macOS 26, *)
@Generable
struct GenerableSuggestion {
    @Guide(description: "One of: direct, diplomatic, analytical, empathetic")
    var tone: String
    @Guide(description: "A suggested response the user could say, 1-2 sentences")
    var text: String
}

@available(macOS 26, *)
@Generable
struct GenerableRisk {
    @Guide(description: "Brief warning about a risk that conflicts with meeting constraints or goals")
    var warning: String
    @Guide(description: "Context explaining the risk")
    var context: String
}

@available(macOS 26, *)
@Generable
struct GenerableNoteFact {
    @Guide(description: "A relevant fact from meeting preparation notes. Prefix with 'Need confirmation:' if uncertain.")
    var fact: String
    @Guide(description: "Source of the fact, e.g. 'notes'")
    var source: String
}

@available(macOS 26, *)
@Generable
struct GenerableCopilotResponse {
    @Guide(description: "Exactly 3 suggested responses, each with a different tone")
    var suggestions: [GenerableSuggestion]
    @Guide(description: "1-3 follow-up questions to advance the meeting goal")
    var follow_up_questions: [String]
    @Guide(description: "Risk flags that conflict with constraints or goals. Empty array if none.")
    var risks: [GenerableRisk]
    @Guide(description: "Relevant facts from preparation notes. Empty array if none.")
    var facts_from_notes: [GenerableNoteFact]
}

// MARK: - Chunk Extraction (Map Phase for Long Transcripts)

@available(macOS 26, *)
@Generable
struct GenerableChunkExtraction {
    @Guide(description: "3-5 key points or topics discussed in this portion of the meeting")
    var key_points: [String]
    @Guide(description: "Decisions made in this portion")
    var decisions: [GenerableDecision]
    @Guide(description: "Action items from this portion")
    var action_items: [GenerableActionItem]
    @Guide(description: "Unresolved questions or open issues from this portion")
    var unresolved: [String]
}

// MARK: - Summary Response Types

@available(macOS 26, *)
@Generable
struct GenerableDecision {
    @Guide(description: "What was decided")
    var decision: String
    @Guide(description: "Why this decision was made")
    var context: String
}

@available(macOS 26, *)
@Generable
struct GenerableActionItem {
    @Guide(description: "What needs to be done")
    var action: String
    @Guide(description: "Who is responsible, empty string if unknown")
    var assignee: String
    @Guide(description: "When it's due, empty string if not mentioned")
    var deadline: String
}

@available(macOS 26, *)
@Generable
struct GenerableMeetingSummary {
    @Guide(description: "Executive summary of the meeting in 3-5 sentences")
    var executive_summary: String
    @Guide(description: "All key decisions made during the meeting")
    var decisions: [GenerableDecision]
    @Guide(description: "All action items from the meeting")
    var action_items: [GenerableActionItem]
    @Guide(description: "All unresolved questions or open issues")
    var unresolved: [String]
}

// MARK: - Mapping to App Models

@available(macOS 26, *)
extension GenerableSuggestion {
    func toAppModel() -> Suggestion {
        Suggestion(tone: tone, text: text)
    }
}

@available(macOS 26, *)
extension GenerableRisk {
    func toAppModel() -> Risk {
        Risk(warning: warning, context: context)
    }
}

@available(macOS 26, *)
extension GenerableNoteFact {
    func toAppModel() -> NoteFact {
        NoteFact(fact: fact, source: source)
    }
}

@available(macOS 26, *)
extension GenerableCopilotResponse {
    func toAppModel() -> CopilotResponse {
        CopilotResponse(
            suggestions: suggestions.map { $0.toAppModel() },
            follow_up_questions: follow_up_questions,
            risks: risks.map { $0.toAppModel() },
            facts_from_notes: facts_from_notes.map { $0.toAppModel() }
        )
    }
}

@available(macOS 26, *)
extension GenerableDecision {
    func toAppModel() -> Decision {
        Decision(decision: decision, context: context)
    }
}

@available(macOS 26, *)
extension GenerableActionItem {
    func toAppModel() -> ActionItem {
        ActionItem(action: action, assignee: assignee, deadline: deadline)
    }
}

@available(macOS 26, *)
extension GenerableMeetingSummary {
    func toAppModel() -> MeetingSummaryResponse {
        MeetingSummaryResponse(
            executive_summary: executive_summary,
            decisions: decisions.map { $0.toAppModel() },
            action_items: action_items.map { $0.toAppModel() },
            unresolved: unresolved
        )
    }
}

#endif
