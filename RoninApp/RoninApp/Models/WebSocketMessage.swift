import Foundation

/// Parsed WebSocket message types received from the backend.
enum ParsedWSMessage {
    case transcriptUpdate(TranscriptSegment)
    case copilotResponse(CopilotResponse)
    case error(String)

    /// Parse raw JSON data into a typed message.
    static func parse(from data: Data) -> ParsedWSMessage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "transcript_update":
            guard let payload = json["data"] else { return nil }
            let payloadData = try? JSONSerialization.data(withJSONObject: payload)
            guard let payloadData,
                  let segment = try? JSONDecoder().decode(TranscriptSegment.self, from: payloadData) else {
                return nil
            }
            return .transcriptUpdate(segment)

        case "copilot_response":
            guard let payload = json["data"] else { return nil }
            let payloadData = try? JSONSerialization.data(withJSONObject: payload)
            guard let payloadData,
                  let response = try? JSONDecoder().decode(CopilotResponse.self, from: payloadData) else {
                return nil
            }
            return .copilotResponse(response)

        case "error":
            let dataDict = json["data"] as? [String: Any]
            let message = dataDict?["message"] as? String ?? "Unknown error"
            return .error(message)

        default:
            return nil
        }
    }
}

/// Response payload from the copilot WebSocket message.
struct CopilotResponse: Codable {
    let suggestions: [Suggestion]
    let follow_up_questions: [String]
    let risks: [Risk]
    let facts_from_notes: [NoteFact]

    init(suggestions: [Suggestion], follow_up_questions: [String], risks: [Risk], facts_from_notes: [NoteFact]) {
        self.suggestions = suggestions
        self.follow_up_questions = follow_up_questions
        self.risks = risks
        self.facts_from_notes = facts_from_notes
    }

    enum CodingKeys: String, CodingKey {
        case suggestions
        case follow_up_questions
        case risks
        case facts_from_notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.suggestions = (try? container.decode([Suggestion].self, forKey: .suggestions)) ?? []
        self.follow_up_questions = (try? container.decode([String].self, forKey: .follow_up_questions)) ?? []
        self.risks = (try? container.decode([Risk].self, forKey: .risks)) ?? []
        self.facts_from_notes = (try? container.decode([NoteFact].self, forKey: .facts_from_notes)) ?? []
    }
}
