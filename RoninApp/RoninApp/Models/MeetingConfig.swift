import Foundation

/// Configuration sent to the backend to set up a new meeting.
struct MeetingConfig: Codable {
    let title: String
    let goal: String
    let constraints: String
    let notes: [NotePayload]
}

/// A note file uploaded by the user for meeting context.
struct NotePayload: Codable, Identifiable {
    let id: UUID
    let name: String
    let content: String

    init(name: String, content: String) {
        self.id = UUID()
        self.name = name
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case name, content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.content = try container.decode(String.self, forKey: .content)
    }
}

/// Response from the backend after setting up a meeting.
struct MeetingSetupResponse: Codable {
    let session_id: String
}
