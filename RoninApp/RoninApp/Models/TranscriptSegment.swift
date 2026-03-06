import Foundation
import SwiftUI

struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: String
    let speaker: String

    init(id: UUID = UUID(), text: String, timestamp: String, speaker: String = "") {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.speaker = speaker
    }

    enum CodingKeys: String, CodingKey {
        case text, timestamp, speaker
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.text = try container.decode(String.self, forKey: .text)
        self.timestamp = try container.decode(String.self, forKey: .timestamp)
        self.speaker = (try? container.decode(String.self, forKey: .speaker)) ?? ""
    }

    /// Consistent color for each speaker label
    var speakerColor: Color {
        guard !speaker.isEmpty else { return .matrixDim }
        // Extract speaker number and cycle through Matrix theme colors
        let colors: [Color] = [.matrixGreen, .matrixCyan, .matrixLime, .matrixWarning]
        let hash = speaker.hashValue
        return colors[abs(hash) % colors.count]
    }

    /// Short label for compact display (e.g. "S1" from "Speaker 1")
    var speakerShortLabel: String {
        guard !speaker.isEmpty else { return "" }
        let parts = speaker.split(separator: " ")
        if parts.count == 2, let num = parts.last {
            return "S\(num)"
        }
        return String(speaker.prefix(3))
    }

    // MARK: - Question Detection

    /// Heuristic question detection: trailing "?" or interrogative word prefix.
    /// Lightweight O(n) check with early exit — no NLP dependencies.
    var isQuestion: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Direct question mark detection
        if trimmed.hasSuffix("?") { return true }

        // Interrogative word prefix detection (case-insensitive)
        let lower = trimmed.lowercased()
        let interrogatives = [
            "what ", "how ", "why ", "who ", "when ", "where ", "which ",
            "could ", "would ", "should ", "can ", "is ", "are ", "do ",
            "does ", "did ", "will ", "have ", "has ", "shall ",
        ]
        for prefix in interrogatives {
            if lower.hasPrefix(prefix) { return true }
        }
        return false
    }
}
