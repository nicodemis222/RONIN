import Foundation
import SwiftUI

/// A single suggestion from the copilot with a tone classification.
struct Suggestion: Identifiable, Codable {
    let id: UUID
    let tone: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case tone, text
    }

    init(id: UUID = UUID(), tone: String, text: String) {
        self.id = id
        self.tone = tone
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.tone = (try? container.decode(String.self, forKey: .tone)) ?? "direct"
        self.text = try container.decode(String.self, forKey: .text)
    }

    var toneColor: Color {
        switch tone.lowercased() {
        case "direct": return .matrixGreen
        case "diplomatic": return .matrixCyan
        case "analytical": return .matrixLime
        case "empathetic": return .matrixWarning
        case "curious": return .purple
        default: return .matrixDim
        }
    }

    var toneLabel: String {
        tone.prefix(1).uppercased() + tone.dropFirst().lowercased()
    }

    var toneIcon: String {
        switch tone.lowercased() {
        case "direct": return "bolt.fill"
        case "diplomatic": return "hands.sparkles"
        case "analytical": return "chart.bar.fill"
        case "empathetic": return "heart.fill"
        case "curious": return "questionmark.circle.fill"
        default: return "text.bubble"
        }
    }
}

/// A potential risk or concern identified by the copilot.
struct Risk: Identifiable, Codable {
    let id: UUID
    let warning: String
    let context: String

    init(warning: String, context: String) {
        self.id = UUID()
        self.warning = warning
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case warning, context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.warning = try container.decode(String.self, forKey: .warning)
        self.context = (try? container.decode(String.self, forKey: .context)) ?? ""
    }
}

/// A fact extracted from the user's uploaded notes.
struct NoteFact: Identifiable, Codable {
    let id: UUID
    let fact: String
    let source: String

    init(fact: String, source: String) {
        self.id = UUID()
        self.fact = fact
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case fact, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.fact = try container.decode(String.self, forKey: .fact)
        self.source = (try? container.decode(String.self, forKey: .source)) ?? ""
    }
}

/// Aggregated guidance data from a copilot response.
struct CopilotGuidance {
    let followUpQuestions: [String]
    let risks: [Risk]
    let factsFromNotes: [NoteFact]

    var isEmpty: Bool {
        followUpQuestions.isEmpty && risks.isEmpty && factsFromNotes.isEmpty
    }

    static var empty: CopilotGuidance {
        CopilotGuidance(followUpQuestions: [], risks: [], factsFromNotes: [])
    }
}

/// A point-in-time snapshot of copilot output.
struct CopilotSnapshot: Identifiable {
    let id: UUID
    let timestamp: Date
    let suggestions: [Suggestion]
    let guidance: CopilotGuidance

    init(id: UUID = UUID(), timestamp: Date, suggestions: [Suggestion], guidance: CopilotGuidance) {
        self.id = id
        self.timestamp = timestamp
        self.suggestions = suggestions
        self.guidance = guidance
    }
}
