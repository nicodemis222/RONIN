import Foundation
import os.log

private let logger = Logger(subsystem: "com.ronin.app", category: "NativeCopilotService")

/// Error types for native (on-device) copilot operations.
enum NativeCopilotError: LocalizedError, Equatable {
    case noProvider
    case debounced
    case inFlight
    case rateLimited
    case contextOverflow
    case contextTooSmall
    case invalidResponse
    case jsonParseError
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noProvider:
            return "Apple Intelligence is not available on this device."
        case .debounced:
            return "Request debounced — too soon since last call"
        case .inFlight:
            return "A request is already in progress"
        case .rateLimited:
            return "Apple Intelligence is temporarily rate limited"
        case .contextOverflow:
            return "Transcript too large for on-device model context"
        case .contextTooSmall:
            return "Transcript budget exhausted after retries"
        case .invalidResponse:
            return "Invalid response from Apple Intelligence"
        case .jsonParseError:
            return "Failed to parse AI response"
        case .apiError(_, let message):
            return message
        }
    }

    static func == (lhs: NativeCopilotError, rhs: NativeCopilotError) -> Bool {
        switch (lhs, rhs) {
        case (.noProvider, .noProvider), (.debounced, .debounced), (.inFlight, .inFlight),
             (.rateLimited, .rateLimited), (.contextOverflow, .contextOverflow),
             (.contextTooSmall, .contextTooSmall), (.invalidResponse, .invalidResponse),
             (.jsonParseError, .jsonParseError):
            return true
        case (.apiError(let a, _), .apiError(let b, _)):
            return a == b
        default:
            return false
        }
    }
}

/// Coordinates on-device AI calls via Apple Foundation Models.
/// Handles debounce, in-flight guards, and context overflow retry logic.
/// Summary generation uses chunked map-reduce to process full transcripts
/// despite the ~4096-token context window.
@MainActor
class NativeCopilotService: ObservableObject {

    // MARK: - State

    private var isConfigured = false
    private var lastCallTime: Date?
    private var isInFlight = false

    @Published var providerName: String = ""

    // MARK: - Configuration

    private let debounceInterval: TimeInterval = 10.0

    // Budget for real-time copilot responses.
    // ~4096 tokens total, ~80 tokens instructions, ~600 tokens output
    // → ~3400 tokens ≈ 12,000 chars for user prompt (meeting info + transcript).
    // Copilot prompt overhead (title/goal/notes) ≈ 500 chars, leaving ~11,500 for transcript.
    var copilotBudget: Int = 10_000

    // MARK: - Setup

    /// Configure with Apple Foundation Models (on-device).
    /// Returns true if Foundation Models is available.
    func configureFoundationModels() -> Bool {
        guard FoundationModelsAvailability.isAvailable else {
            logger.warning("Foundation Models not available — provider not set")
            isConfigured = false
            providerName = ""
            return false
        }

        isConfigured = true
        providerName = "Apple Intelligence"
        logger.info("Configured with Apple Foundation Models provider (on-device)")
        return true
    }

    var hasProvider: Bool {
        isConfigured
    }

    // MARK: - Copilot Response

    func generateCopilotResponse(
        transcriptWindow: String,
        config: MeetingConfig,
        relevantNotes: String
    ) async throws -> CopilotResponse {
        guard isConfigured else { throw NativeCopilotError.noProvider }

        // Debounce check
        if let lastCall = lastCallTime, Date().timeIntervalSince(lastCall) < debounceInterval {
            throw NativeCopilotError.debounced
        }

        // In-flight guard
        guard !isInFlight else { throw NativeCopilotError.inFlight }
        isInFlight = true
        lastCallTime = Date()

        defer { isInFlight = false }

        // Context overflow retry: halve budget up to 3 times
        var maxChars = copilotBudget
        for attempt in 0..<3 {
            do {
                return try await _callCopilot(
                    transcriptWindow: transcriptWindow,
                    config: config,
                    relevantNotes: relevantNotes,
                    budget: maxChars
                )
            } catch NativeCopilotError.contextOverflow {
                maxChars /= 2
                if maxChars < 200 { throw NativeCopilotError.contextTooSmall }
                logger.warning("Context overflow — retrying with budget \(maxChars) (attempt \(attempt + 2)/3)")
            }
        }

        throw NativeCopilotError.contextTooSmall
    }

    // MARK: - Summary (Chunked Map-Reduce)
    //
    // The FoundationModelsProvider handles chunking internally.
    // No budget-halving retry needed — the provider splits any transcript
    // into chunks that fit the context window and aggregates the results.

    func generateSummary(
        transcript: String,
        config: MeetingConfig,
        notes: String
    ) async throws -> MeetingSummaryResponse {
        guard isConfigured else { throw NativeCopilotError.noProvider }

        return try await _callSummary(
            transcript: transcript,
            config: config,
            notes: notes
        )
    }

    // MARK: - Private Helpers

    private func _callCopilot(
        transcriptWindow: String,
        config: MeetingConfig,
        relevantNotes: String,
        budget: Int
    ) async throws -> CopilotResponse {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let provider = FoundationModelsProvider()
            return try await provider.generateCopilotResponse(
                transcriptWindow: transcriptWindow,
                config: config,
                relevantNotes: relevantNotes,
                budget: budget
            )
        }
        #endif
        throw NativeCopilotError.noProvider
    }

    private func _callSummary(
        transcript: String,
        config: MeetingConfig,
        notes: String
    ) async throws -> MeetingSummaryResponse {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let provider = FoundationModelsProvider()
            // Budget param kept for API compatibility but chunking
            // is now handled internally by FoundationModelsProvider
            return try await provider.generateSummary(
                transcript: transcript,
                config: config,
                notes: notes,
                budget: 0
            )
        }
        #endif
        throw NativeCopilotError.noProvider
    }

    // MARK: - Reset

    func reset() {
        lastCallTime = nil
        isInFlight = false
    }
}
