import XCTest
@testable import Ronin

final class ModelTests: XCTestCase {

    // MARK: - CopilotGuidance

    func testCopilotGuidanceIsEmptyWhenAllEmpty() {
        let guidance = CopilotGuidance.empty
        XCTAssertTrue(guidance.isEmpty)
    }

    func testCopilotGuidanceIsNotEmptyWithQuestions() {
        let guidance = CopilotGuidance(
            followUpQuestions: ["What's the timeline?"],
            risks: [],
            factsFromNotes: []
        )
        XCTAssertFalse(guidance.isEmpty)
    }

    func testCopilotGuidanceIsNotEmptyWithRisks() {
        let guidance = CopilotGuidance(
            followUpQuestions: [],
            risks: [Risk(warning: "Budget risk", context: "Over by 20%")],
            factsFromNotes: []
        )
        XCTAssertFalse(guidance.isEmpty)
    }

    func testCopilotGuidanceIsNotEmptyWithFacts() {
        let guidance = CopilotGuidance(
            followUpQuestions: [],
            risks: [],
            factsFromNotes: [NoteFact(fact: "Q3 revenue was $2M", source: "notes.md")]
        )
        XCTAssertFalse(guidance.isEmpty)
    }

    // MARK: - Suggestion

    func testSuggestionToneColors() {
        let direct = Suggestion(tone: "direct", text: "test")
        XCTAssertEqual(direct.toneColor, .matrixCyan)

        let diplomatic = Suggestion(tone: "diplomatic", text: "test")
        XCTAssertEqual(diplomatic.toneColor, .matrixGreen)

        let analytical = Suggestion(tone: "analytical", text: "test")
        XCTAssertEqual(analytical.toneColor, .matrixLime)

        let empathetic = Suggestion(tone: "empathetic", text: "test")
        XCTAssertEqual(empathetic.toneColor, .matrixAmber)

        // Legacy "curious" maps to analytical color
        let curious = Suggestion(tone: "curious", text: "test")
        XCTAssertEqual(curious.toneColor, .matrixLime)

        let unknown = Suggestion(tone: "unknown", text: "test")
        XCTAssertEqual(unknown.toneColor, .matrixDim)
    }

    func testSuggestionToneLabels() {
        XCTAssertEqual(Suggestion(tone: "direct", text: "").toneLabel, "Direct")
        XCTAssertEqual(Suggestion(tone: "diplomatic", text: "").toneLabel, "Diplomatic")
        XCTAssertEqual(Suggestion(tone: "analytical", text: "").toneLabel, "Analytical")
        XCTAssertEqual(Suggestion(tone: "empathetic", text: "").toneLabel, "Empathetic")
        XCTAssertEqual(Suggestion(tone: "curious", text: "").toneLabel, "Analytical")
    }

    func testSuggestionToneIcons() {
        XCTAssertEqual(Suggestion(tone: "direct", text: "").toneIcon, "arrow.right.circle")
        XCTAssertEqual(Suggestion(tone: "diplomatic", text: "").toneIcon, "hands.sparkles")
        XCTAssertEqual(Suggestion(tone: "analytical", text: "").toneIcon, "chart.bar.xaxis")
        XCTAssertEqual(Suggestion(tone: "empathetic", text: "").toneIcon, "heart.circle")
    }

    func testSuggestionDecodingFromJSON() throws {
        let json = """
        {"tone": "direct", "text": "Let's discuss the budget"}
        """.data(using: .utf8)!

        let suggestion = try JSONDecoder().decode(Suggestion.self, from: json)
        XCTAssertEqual(suggestion.tone, "direct")
        XCTAssertEqual(suggestion.text, "Let's discuss the budget")
        XCTAssertNotNil(suggestion.id) // UUID should be auto-generated
    }

    // MARK: - Risk

    func testRiskDecodingFromJSON() throws {
        let json = """
        {"warning": "Timeline risk", "context": "Project may slip by 2 weeks"}
        """.data(using: .utf8)!

        let risk = try JSONDecoder().decode(Risk.self, from: json)
        XCTAssertEqual(risk.warning, "Timeline risk")
        XCTAssertEqual(risk.context, "Project may slip by 2 weeks")
    }

    // MARK: - NoteFact

    func testNoteFactDecodingFromJSON() throws {
        let json = """
        {"fact": "Revenue was $2M", "source": "quarterly-report.md"}
        """.data(using: .utf8)!

        let fact = try JSONDecoder().decode(NoteFact.self, from: json)
        XCTAssertEqual(fact.fact, "Revenue was $2M")
        XCTAssertEqual(fact.source, "quarterly-report.md")
    }

    // MARK: - Decision

    func testDecisionDecodingFromJSON() throws {
        let json = """
        {"decision": "Go with vendor A", "context": "Lower cost"}
        """.data(using: .utf8)!

        let decision = try JSONDecoder().decode(Decision.self, from: json)
        XCTAssertEqual(decision.decision, "Go with vendor A")
        XCTAssertEqual(decision.context, "Lower cost")
    }

    // MARK: - ActionItem

    func testActionItemDecodingFromJSON() throws {
        let json = """
        {"action": "Send proposal", "assignee": "Alice", "deadline": "2025-03-15"}
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(ActionItem.self, from: json)
        XCTAssertEqual(item.action, "Send proposal")
        XCTAssertEqual(item.assignee, "Alice")
        XCTAssertEqual(item.deadline, "2025-03-15")
    }

    // MARK: - MeetingSummaryResponse

    func testMeetingSummaryResponseDecoding() throws {
        let json = """
        {
            "executive_summary": "Discussed Q4 plans",
            "decisions": [{"decision": "Proceed", "context": "Aligned"}],
            "action_items": [{"action": "Draft doc", "assignee": "Bob", "deadline": ""}],
            "unresolved": ["Budget approval"],
            "full_transcript": "[00:00:01] Hello everyone"
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(MeetingSummaryResponse.self, from: json)
        XCTAssertEqual(summary.executive_summary, "Discussed Q4 plans")
        XCTAssertEqual(summary.decisions.count, 1)
        XCTAssertEqual(summary.action_items.count, 1)
        XCTAssertEqual(summary.unresolved.count, 1)
        XCTAssertEqual(summary.full_transcript, "[00:00:01] Hello everyone")
    }

    // MARK: - CopilotResponse (WebSocket message decoding)

    func testCopilotResponseDecoding() throws {
        let json = """
        {
            "suggestions": [{"tone": "direct", "text": "Ask about timeline"}],
            "follow_up_questions": ["What about Q2?"],
            "risks": [{"warning": "Scope creep", "context": "Adding features"}],
            "facts_from_notes": [{"fact": "Last quarter target was 100", "source": "goals.md"}]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CopilotResponse.self, from: json)
        XCTAssertEqual(response.suggestions.count, 1)
        XCTAssertEqual(response.follow_up_questions.count, 1)
        XCTAssertEqual(response.risks.count, 1)
        XCTAssertEqual(response.facts_from_notes.count, 1)
    }

    // MARK: - TranscriptSegment

    func testTranscriptSegmentInit() {
        let segment = TranscriptSegment(
            text: "Hello everyone",
            timestamp: "00:00:01",
            speaker: "Speaker 1"
        )
        XCTAssertEqual(segment.text, "Hello everyone")
        XCTAssertEqual(segment.timestamp, "00:00:01")
        XCTAssertEqual(segment.speaker, "Speaker 1")
    }

    func testTranscriptSegmentDefaultSpeaker() {
        let segment = TranscriptSegment(text: "Hello", timestamp: "00:00:01")
        XCTAssertEqual(segment.speaker, "")
    }

    func testTranscriptSegmentSpeakerShortLabel() {
        let segment = TranscriptSegment(text: "Hi", timestamp: "00:00:01", speaker: "Speaker 1")
        XCTAssertEqual(segment.speakerShortLabel, "S1")
    }

    func testTranscriptSegmentSpeakerShortLabelEmpty() {
        let segment = TranscriptSegment(text: "Hi", timestamp: "00:00:01", speaker: "")
        XCTAssertEqual(segment.speakerShortLabel, "")
    }

    func testTranscriptSegmentSpeakerColor() {
        let segment = TranscriptSegment(text: "Hi", timestamp: "00:00:01", speaker: "Speaker 1")
        // Should return one of the Matrix theme colors (not the default dim)
        XCTAssertNotEqual(segment.speakerColor, .matrixDim)
    }

    func testTranscriptSegmentEmptySpeakerColor() {
        let segment = TranscriptSegment(text: "Hi", timestamp: "00:00:01", speaker: "")
        XCTAssertEqual(segment.speakerColor, .matrixDim)
    }

    func testTranscriptSegmentDecodingFromJSON() throws {
        let json = """
        {"text": "Hello there", "timestamp": "00:01:30", "speaker": "Speaker 2"}
        """.data(using: .utf8)!

        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)
        XCTAssertEqual(segment.text, "Hello there")
        XCTAssertEqual(segment.timestamp, "00:01:30")
        XCTAssertEqual(segment.speaker, "Speaker 2")
    }

    func testTranscriptSegmentDecodingWithoutSpeaker() throws {
        let json = """
        {"text": "Hello there", "timestamp": "00:01:30"}
        """.data(using: .utf8)!

        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)
        XCTAssertEqual(segment.speaker, "")
    }
}
