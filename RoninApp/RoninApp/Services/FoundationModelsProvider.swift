#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os.log

private let logger = Logger(subsystem: "com.ronin.app", category: "FoundationModelsProvider")

/// On-device AI provider using Apple Foundation Models (macOS 26+).
/// All processing stays on-device — no network calls, no API key required.
@available(macOS 26, *)
final class FoundationModelsProvider: @unchecked Sendable {

    // MARK: - Availability

    /// Check if Apple Intelligence is available on this device.
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: - Condensed System Prompts
    //
    // Apple Foundation Models has a ~4096-token context window.
    // These prompts are radically condensed vs the backend versions (~50 words vs ~350).

    private static let copilotInstructions = """
    You are a real-time meeting assistant. Given a transcript excerpt, meeting goal, and constraints, provide structured suggestions. Give exactly 3 responses with different tones (direct, diplomatic, analytical, empathetic), 1-3 follow-up questions, risk flags conflicting with constraints, and relevant facts from notes. Return empty arrays if nothing useful.
    """

    private static let summaryInstructions = """
    Summarize this meeting transcript. Provide an executive summary (3-5 sentences), all key decisions with context, all action items with assignee and deadline if mentioned (empty string otherwise), and all unresolved questions or open issues.
    """

    // MARK: - Copilot Response

    func generateCopilotResponse(
        transcriptWindow: String,
        config: MeetingConfig,
        relevantNotes: String,
        budget: Int
    ) async throws -> CopilotResponse {
        var transcript = transcriptWindow
        if transcript.count > budget {
            transcript = String(transcript.suffix(budget))
        }

        var userPrompt = "MEETING: \(config.title)\nGOAL: \(config.goal)"
        if !config.constraints.isEmpty {
            userPrompt += "\nCONSTRAINTS: \(config.constraints)"
        }
        if !relevantNotes.isEmpty {
            let notesBudget = min(relevantNotes.count, 400)
            userPrompt += "\nNOTES: \(String(relevantNotes.prefix(notesBudget)))"
        }
        userPrompt += "\n\nTRANSCRIPT:\n\(transcript)"

        logger.info("Foundation Models copilot: \(userPrompt.count) chars prompt")

        do {
            let session = LanguageModelSession(
                instructions: Self.copilotInstructions
            )

            let response = try await session.respond(
                to: userPrompt,
                generating: GenerableCopilotResponse.self
            )

            let result = response.content
            logger.info("Foundation Models copilot: got \(result.suggestions.count) suggestions")
            return result.toAppModel()

        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapError(error)
        } catch {
            logger.error("Foundation Models copilot error: \(error.localizedDescription)")
            throw NativeCopilotError.apiError(0, "Apple Intelligence: \(error.localizedDescription)")
        }
    }

    // MARK: - Summary

    func generateSummary(
        transcript: String,
        config: MeetingConfig,
        notes: String,
        budget: Int
    ) async throws -> MeetingSummaryResponse {
        var truncated = transcript
        if truncated.count > budget {
            let headChars = budget / 4
            let tailChars = budget - headChars
            truncated = String(transcript.prefix(headChars))
                + "\n[...]\n"
                + String(transcript.suffix(tailChars))
        }

        var userPrompt = "MEETING: \(config.title)\nGOAL: \(config.goal)"
        if !notes.isEmpty {
            let notesBudget = min(notes.count, 300)
            userPrompt += "\nNOTES: \(String(notes.prefix(notesBudget)))"
        }
        userPrompt += "\n\nTRANSCRIPT:\n\(truncated)"

        logger.info("Foundation Models summary: \(userPrompt.count) chars prompt")

        do {
            let session = LanguageModelSession(
                instructions: Self.summaryInstructions
            )

            let response = try await session.respond(
                to: userPrompt,
                generating: GenerableMeetingSummary.self
            )

            let result = response.content
            logger.info("Foundation Models summary: \(result.decisions.count) decisions, \(result.action_items.count) actions")
            return result.toAppModel()

        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapError(error)
        } catch {
            logger.error("Foundation Models summary error: \(error.localizedDescription)")
            throw NativeCopilotError.apiError(0, "Apple Intelligence: \(error.localizedDescription)")
        }
    }

    // MARK: - Error Mapping

    private static func mapError(_ error: LanguageModelSession.GenerationError) -> NativeCopilotError {
        switch error {
        case .exceededContextWindowSize:
            logger.warning("Foundation Models: context window exceeded")
            return .contextOverflow
        case .rateLimited:
            logger.warning("Foundation Models: rate limited")
            return .rateLimited
        case .guardrailViolation:
            logger.warning("Foundation Models: guardrail violation")
            return .invalidResponse
        @unknown default:
            logger.error("Foundation Models: unknown error: \(error.localizedDescription)")
            return .apiError(0, "Apple Intelligence: \(error.localizedDescription)")
        }
    }
}

#endif

// MARK: - Availability Wrapper (callable from non-macOS-26 code)

/// Allows non-macOS-26 code to check Foundation Models availability without @available annotations.
enum FoundationModelsAvailability {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelsProvider.isAvailable
        }
        #endif
        return false
    }
}
