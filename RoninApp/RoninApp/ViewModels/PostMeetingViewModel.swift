import AppKit
import Foundation

@MainActor
class PostMeetingViewModel: ObservableObject {
    @Published var summary: MeetingSummaryResponse?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var fullTranscript: String = ""

    // Progress tracking
    @Published var progressPhase: SummaryPhase = .saving
    @Published var elapsedSeconds: Int = 0
    @Published var estimatedTotalSeconds: Int = 20  // Updated dynamically

    enum SummaryPhase: String {
        case saving = "Saving transcript..."
        case analyzing = "Analyzing conversation..."
        case extracting = "Extracting decisions & action items..."
        case formatting = "Building summary..."

        var icon: String {
            switch self {
            case .saving: return "arrow.down.doc"
            case .analyzing: return "brain"
            case .extracting: return "list.bullet.clipboard"
            case .formatting: return "doc.text"
            }
        }

        /// Estimated progress (0.0–1.0) at the start of this phase
        var baseProgress: Double {
            switch self {
            case .saving: return 0.0
            case .analyzing: return 0.15
            case .extracting: return 0.55
            case .formatting: return 0.80
            }
        }
    }

    var meetingTitle: String = ""
    private var lastSessionId: String?
    private var progressTimer: Timer?

    // Native summary generation (Apple Intelligence)
    var nativeCopilotService: NativeCopilotService?
    var meetingConfig: MeetingConfig?
    var meetingNotes: String = ""

    private let backendAPI = BackendAPIService()

    /// Set the auth token received from BackendProcessService.
    func setAuthToken(_ token: String) {
        backendAPI.authToken = token
    }

    func loadSummary(sessionId: String) async {
        isLoading = true
        errorMessage = nil
        lastSessionId = sessionId
        elapsedSeconds = 0
        progressPhase = .saving

        // Start a timer to update elapsed time and cycle phases
        startProgressTimer()

        do {
            // Always call backend to get transcript (and save it to disk)
            let result = try await backendAPI.endMeeting(sessionId: sessionId)
            fullTranscript = result.full_transcript

            // If Apple Intelligence is active, generate summary locally
            if let service = nativeCopilotService, let config = meetingConfig, service.hasProvider {
                progressPhase = .analyzing
                do {
                    var nativeSummary = try await service.generateSummary(
                        transcript: fullTranscript,
                        config: config,
                        notes: meetingNotes
                    )
                    nativeSummary.full_transcript = fullTranscript
                    summary = nativeSummary
                } catch {
                    // Fall back to backend summary if native fails
                    if !result.executive_summary.isEmpty && !result.executive_summary.hasPrefix("No LLM provider") {
                        summary = result
                    } else {
                        errorMessage = "Apple Intelligence summary failed: \(error.localizedDescription)"
                    }
                }
            } else {
                // Backend-generated summary (Local/OpenAI/Anthropic)
                summary = result
            }
        } catch {
            errorMessage = "Failed to generate summary: \(error.localizedDescription)"
        }

        stopProgressTimer()
        isLoading = false
    }

    func retry() async {
        guard let sessionId = lastSessionId else {
            errorMessage = "No session to retry."
            return
        }
        await loadSummary(sessionId: sessionId)
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.elapsedSeconds += 1

                // Advance through phases based on elapsed time
                switch self.elapsedSeconds {
                case 0..<2:
                    self.progressPhase = .saving
                case 2..<8:
                    self.progressPhase = .analyzing
                case 8..<16:
                    self.progressPhase = .extracting
                default:
                    self.progressPhase = .formatting
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Estimated progress (0.0–1.0) combining phase base + elapsed time interpolation
    var estimatedProgress: Double {
        let phaseBase = progressPhase.baseProgress
        let elapsed = Double(elapsedSeconds)
        let estimated = Double(estimatedTotalSeconds)

        // Asymptotic progress: approaches 1.0 but never quite reaches it
        // Uses a logarithmic curve so it slows down as it approaches completion
        let rawProgress = min(elapsed / estimated, 0.95)

        // Blend phase-based and time-based progress
        return max(phaseBase, rawProgress)
    }

    // MARK: - Export

    func exportMarkdown() {
        guard let summary = summary else { return }

        var md = "# \(meetingTitle) - Meeting Summary\n\n"
        md += "## Summary\n\(summary.executive_summary)\n\n"

        if !summary.decisions.isEmpty {
            md += "## Decisions\n"
            for d in summary.decisions {
                md += "- **\(d.decision)**: \(d.context)\n"
            }
            md += "\n"
        }

        if !summary.action_items.isEmpty {
            md += "## Action Items\n"
            for item in summary.action_items {
                var line = "- [ ] \(item.action)"
                if !item.assignee.isEmpty { line += " (@\(item.assignee))" }
                if !item.deadline.isEmpty { line += " — due: \(item.deadline)" }
                md += line + "\n"
            }
            md += "\n"
        }

        if !summary.unresolved.isEmpty {
            md += "## Open Questions\n"
            for q in summary.unresolved {
                md += "- \(q)\n"
            }
            md += "\n"
        }

        if !fullTranscript.isEmpty {
            md += formatTranscriptForExport()
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(meetingTitle.replacingOccurrences(of: " ", with: "-"))-summary.md"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                showSuccess("Exported to \(url.lastPathComponent)")
            } catch {
                errorMessage = "Failed to save file: \(error.localizedDescription)"
            }
        }
    }

    func copyToClipboard() {
        guard let summary = summary else { return }
        var text = "Summary: \(summary.executive_summary)"

        if !summary.decisions.isEmpty {
            text += "\n\nDecisions:\n"
            text += summary.decisions.map { "- \($0.decision)" }.joined(separator: "\n")
        }

        if !summary.action_items.isEmpty {
            text += "\n\nAction Items:\n"
            text += summary.action_items.map { "- \($0.action)" }.joined(separator: "\n")
        }

        if !summary.unresolved.isEmpty {
            text += "\n\nOpen Questions:\n"
            text += summary.unresolved.map { "- \($0)" }.joined(separator: "\n")
        }

        if !fullTranscript.isEmpty {
            text += "\n\n" + formatTranscriptForExport()
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showSuccess("Copied to clipboard")
    }

    // MARK: - Transcript Formatting

    /// Format the full transcript with speaker breakout headers.
    /// Input lines look like: "[07:11:54] Speaker 1: they put in Comedie..."
    /// Output groups consecutive lines under speaker headers.
    private func formatTranscriptForExport() -> String {
        let lines = fullTranscript.components(separatedBy: "\n")

        // Check if any line has speaker labels
        let hasSpeakers = lines.contains { extractSpeaker(from: $0) != nil }

        if !hasSpeakers {
            // No speaker labels — plain transcript
            return "## Full Transcript\n\n\(fullTranscript)\n"
        }

        var md = "## Full Transcript\n\n"
        var currentSpeaker: String?

        for line in lines where !line.isEmpty {
            let speaker = extractSpeaker(from: line)
            if let speaker, speaker != currentSpeaker {
                currentSpeaker = speaker
                md += "\n**\(speaker)**\n\n"
            }
            md += "> \(line)\n"
        }

        return md
    }

    /// Extract speaker label from a transcript line.
    /// Format: "[HH:MM:SS] Speaker N: text..." or "[HH:MM:SS] text..."
    private func extractSpeaker(from line: String) -> String? {
        // Match pattern: [timestamp] Speaker Label: text
        // After "]", look for a speaker label ending with ":"
        guard let bracketEnd = line.firstIndex(of: "]") else { return nil }
        let afterBracket = line[line.index(after: bracketEnd)...]
            .trimmingCharacters(in: .whitespaces)

        // Check for "Speaker N:" pattern
        if let colonIdx = afterBracket.firstIndex(of: ":") {
            let candidate = String(afterBracket[afterBracket.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("Speaker ") {
                return candidate
            }
        }
        return nil
    }

    private func showSuccess(_ message: String) {
        successMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.successMessage = nil
        }
    }
}
