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
    // Apple Foundation Models has a ~4096-token context window (~14K chars input).
    // These prompts are radically condensed vs the backend versions (~50 words vs ~350).

    private static let copilotInstructions = """
    You are a real-time meeting assistant. Given a transcript excerpt, meeting goal, and constraints, provide structured suggestions. Give exactly 3 responses with different tones (direct, diplomatic, analytical, empathetic), 1-3 follow-up questions, risk flags conflicting with constraints, and relevant facts from notes. Return empty arrays if nothing useful.
    """

    private static let summaryInstructions = """
    You are an expert meeting analyst. Summarize this transcript thoroughly. Provide: executive summary (5-8 sentences covering topics, outcomes, direction), ALL key decisions (explicit agreements, approvals, scheduling, prioritization — include context for each), ALL action items (assignments, volunteered tasks, follow-ups, requests for info — include assignee name/role and deadline if mentioned, empty string otherwise), and ALL unresolved questions or deferred topics. Read between the lines — heavy dialogue contains implicit decisions and action items. A typical meeting has 5-15 action items and 3-8 decisions. Do NOT under-extract.
    """

    /// Instructions for chunk extraction (map phase of map-reduce).
    /// Kept minimal to maximize transcript capacity within the 4K context.
    private static let chunkExtractionInstructions = """
    Extract key information from this meeting transcript portion. Find: key points discussed, decisions made (explicit or implicit), action items (who does what, by when), and unresolved questions. Be thorough — capture everything.
    """

    /// Instructions for aggregation (reduce phase of map-reduce).
    /// Combines chunk extractions into a final cohesive summary.
    private static let aggregationInstructions = """
    You are an expert meeting analyst. Given extracted information from across an entire meeting, synthesize a final summary. Combine and deduplicate the extractions. Provide: executive summary (5-8 sentences covering the full meeting arc — what was discussed, what was decided, where things stand), ALL unique decisions with context, ALL unique action items with assignees and deadlines, and ALL unresolved questions. Do NOT drop items.
    """

    // MARK: - Context Budget Constants
    //
    // ~4096 tokens total. Instructions ~80 tokens, output ~500-800 tokens.
    // Leaves ~3200-3500 tokens ≈ 12,000-14,000 chars for user prompt.

    /// Max transcript chars per chunk for extraction (map) passes.
    private static let chunkSize = 10_000
    /// Max combined extraction chars for the aggregation (reduce) pass.
    private static let aggregationBudget = 12_000

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

    // MARK: - Summary (Chunked Map-Reduce)
    //
    // Apple Intelligence has a ~4096-token context window, far too small for
    // a full meeting transcript. We use a map-reduce strategy:
    //   1. MAP:    Split transcript into chunks → extract decisions, actions, key points from each
    //   2. REDUCE: Combine all chunk extractions → generate final cohesive summary
    // This ensures the ENTIRE transcript is processed without losing content.

    func generateSummary(
        transcript: String,
        config: MeetingConfig,
        notes: String,
        budget: Int
    ) async throws -> MeetingSummaryResponse {
        // Short transcripts fit in a single pass
        if transcript.count <= Self.chunkSize {
            logger.info("Transcript fits in single pass (\(transcript.count) chars)")
            return try await _singlePassSummary(transcript: transcript, config: config, notes: notes)
        }

        // Long transcripts: chunked map-reduce
        let chunks = Self.splitIntoChunks(transcript, chunkSize: Self.chunkSize)
        logger.info("Chunked map-reduce: \(transcript.count) chars → \(chunks.count) chunks of ~\(Self.chunkSize) chars")

        // MAP phase: extract structured data from each chunk
        var allKeyPoints: [String] = []
        var allDecisions: [Decision] = []
        var allActionItems: [ActionItem] = []
        var allUnresolved: [String] = []

        for (index, chunk) in chunks.enumerated() {
            logger.info("Processing chunk \(index + 1)/\(chunks.count) (\(chunk.count) chars)")
            do {
                let extraction = try await _extractFromChunk(
                    chunk: chunk,
                    chunkIndex: index + 1,
                    totalChunks: chunks.count,
                    config: config
                )
                allKeyPoints.append(contentsOf: extraction.key_points)
                allDecisions.append(contentsOf: extraction.decisions.map { $0.toAppModel() })
                allActionItems.append(contentsOf: extraction.action_items.map { $0.toAppModel() })
                allUnresolved.append(contentsOf: extraction.unresolved)
                logger.info("Chunk \(index + 1): \(extraction.decisions.count) decisions, \(extraction.action_items.count) actions, \(extraction.key_points.count) key points")
            } catch {
                logger.warning("Chunk \(index + 1) extraction failed: \(error.localizedDescription) — skipping")
            }
        }

        // REDUCE phase: aggregate all extractions into final summary
        logger.info("Aggregation phase: \(allDecisions.count) decisions, \(allActionItems.count) actions, \(allKeyPoints.count) key points, \(allUnresolved.count) unresolved")
        return try await _aggregateSummary(
            keyPoints: allKeyPoints,
            decisions: allDecisions,
            actionItems: allActionItems,
            unresolved: allUnresolved,
            config: config,
            notes: notes
        )
    }

    // MARK: - Single-Pass Summary (Short Transcripts)

    private func _singlePassSummary(
        transcript: String,
        config: MeetingConfig,
        notes: String
    ) async throws -> MeetingSummaryResponse {
        var userPrompt = "MEETING: \(config.title)\nGOAL: \(config.goal)"
        if !notes.isEmpty {
            let notesBudget = min(notes.count, 300)
            userPrompt += "\nNOTES: \(String(notes.prefix(notesBudget)))"
        }
        userPrompt += "\n\nTRANSCRIPT:\n\(transcript)"

        logger.info("Foundation Models summary (single pass): \(userPrompt.count) chars prompt")

        do {
            let session = LanguageModelSession(instructions: Self.summaryInstructions)
            let response = try await session.respond(
                to: userPrompt,
                generating: GenerableMeetingSummary.self
            )
            let result = response.content
            logger.info("Summary: \(result.decisions.count) decisions, \(result.action_items.count) actions")
            return result.toAppModel()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapError(error)
        } catch {
            logger.error("Foundation Models summary error: \(error.localizedDescription)")
            throw NativeCopilotError.apiError(0, "Apple Intelligence: \(error.localizedDescription)")
        }
    }

    // MARK: - Chunk Extraction (Map Phase)

    private func _extractFromChunk(
        chunk: String,
        chunkIndex: Int,
        totalChunks: Int,
        config: MeetingConfig
    ) async throws -> GenerableChunkExtraction {
        let userPrompt = """
        MEETING: \(config.title)
        GOAL: \(config.goal)
        [Part \(chunkIndex) of \(totalChunks)]

        TRANSCRIPT:
        \(chunk)
        """

        let session = LanguageModelSession(instructions: Self.chunkExtractionInstructions)
        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: GenerableChunkExtraction.self
            )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapError(error)
        }
    }

    // MARK: - Aggregation (Reduce Phase)

    private func _aggregateSummary(
        keyPoints: [String],
        decisions: [Decision],
        actionItems: [ActionItem],
        unresolved: [String],
        config: MeetingConfig,
        notes: String
    ) async throws -> MeetingSummaryResponse {
        // Format extracted data compactly for the aggregation pass
        var extractionText = "MEETING: \(config.title)\nGOAL: \(config.goal)\n"
        if !notes.isEmpty {
            let notesBudget = min(notes.count, 200)
            extractionText += "NOTES: \(String(notes.prefix(notesBudget)))\n"
        }

        extractionText += "\nKEY POINTS:\n"
        for point in keyPoints {
            extractionText += "• \(point)\n"
        }

        extractionText += "\nDECISIONS:\n"
        for d in decisions {
            extractionText += "• \(d.decision) — \(d.context)\n"
        }

        extractionText += "\nACTION ITEMS:\n"
        for a in actionItems {
            var line = "• \(a.action)"
            if !a.assignee.isEmpty { line += " [assignee: \(a.assignee)]" }
            if !a.deadline.isEmpty { line += " [deadline: \(a.deadline)]" }
            extractionText += line + "\n"
        }

        extractionText += "\nUNRESOLVED:\n"
        for u in unresolved {
            extractionText += "• \(u)\n"
        }

        // Truncate if aggregation input exceeds budget
        if extractionText.count > Self.aggregationBudget {
            logger.warning("Aggregation input too large (\(extractionText.count) chars) — truncating to \(Self.aggregationBudget)")
            extractionText = String(extractionText.prefix(Self.aggregationBudget))
        }

        logger.info("Aggregation prompt: \(extractionText.count) chars")

        do {
            let session = LanguageModelSession(instructions: Self.aggregationInstructions)
            let response = try await session.respond(
                to: extractionText,
                generating: GenerableMeetingSummary.self
            )
            let result = response.content
            logger.info("Aggregated summary: \(result.decisions.count) decisions, \(result.action_items.count) actions")
            return result.toAppModel()
        } catch let error as LanguageModelSession.GenerationError {
            // If aggregation fails (too much extracted data), fall back to
            // returning the raw extractions without an LLM-generated executive summary
            if case .exceededContextWindowSize = error {
                logger.warning("Aggregation exceeded context — returning raw extractions as summary")
                return _buildFallbackSummary(
                    keyPoints: keyPoints,
                    decisions: decisions,
                    actionItems: actionItems,
                    unresolved: unresolved,
                    config: config
                )
            }
            throw Self.mapError(error)
        } catch {
            logger.error("Aggregation error: \(error.localizedDescription)")
            throw NativeCopilotError.apiError(0, "Apple Intelligence: \(error.localizedDescription)")
        }
    }

    /// Fallback when the aggregation pass itself overflows: assemble extracted
    /// data directly into a MeetingSummaryResponse without a second LLM call.
    private func _buildFallbackSummary(
        keyPoints: [String],
        decisions: [Decision],
        actionItems: [ActionItem],
        unresolved: [String],
        config: MeetingConfig
    ) -> MeetingSummaryResponse {
        let summary = "Meeting: \(config.title). Goal: \(config.goal). "
            + "Key topics: \(keyPoints.prefix(5).joined(separator: "; ")). "
            + "\(decisions.count) decisions made and \(actionItems.count) action items identified."
        return MeetingSummaryResponse(
            executive_summary: summary,
            decisions: decisions,
            action_items: actionItems,
            unresolved: unresolved
        )
    }

    // MARK: - Chunk Splitting

    /// Split transcript into chunks at line boundaries, respecting the max chunk size.
    /// Ensures no chunk exceeds `chunkSize` chars and avoids splitting mid-sentence.
    static func splitIntoChunks(_ text: String, chunkSize: Int) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var currentChunk = ""

        for line in lines {
            let candidate = currentChunk.isEmpty ? line : currentChunk + "\n" + line
            if candidate.count > chunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = line
            } else {
                currentChunk = candidate
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
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
