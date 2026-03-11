import AppKit
import Foundation
import UniformTypeIdentifiers

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

    enum ExportFormat: String, CaseIterable {
        case markdown = "Markdown (.md)"
        case plainText = "Plain Text (.txt)"
        case csv = "CSV (.csv)"
        case docx = "Word (.docx)"

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            case .csv: return "csv"
            case .docx: return "docx"
            }
        }

        var contentType: UTType {
            switch self {
            case .markdown: return .plainText
            case .plainText: return .plainText
            case .csv: return .commaSeparatedText
            case .docx: return UTType("org.openxmlformats.wordprocessingml.document") ?? .data
            }
        }

        var icon: String {
            switch self {
            case .markdown: return "doc.richtext"
            case .plainText: return "doc.text"
            case .csv: return "tablecells"
            case .docx: return "doc.fill"
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

    // MARK: - Participants

    /// Extract unique speaker labels from the transcript.
    func extractParticipants() -> [String] {
        let lines = fullTranscript.components(separatedBy: "\n")
        var seen = Set<String>()
        var ordered: [String] = []

        for line in lines {
            if let speaker = extractSpeaker(from: line), !seen.contains(speaker) {
                seen.insert(speaker)
                ordered.append(speaker)
            }
        }
        return ordered
    }

    // MARK: - Meeting Date

    private var meetingDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }

    // MARK: - Export

    func exportFile(format: ExportFormat) {
        guard let summary = summary else { return }

        let slug = meetingTitle.replacingOccurrences(of: " ", with: "-")
        let filename = "\(slug)-summary.\(format.fileExtension)"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = filename

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .markdown:
                try buildMarkdown(summary: summary).write(to: url, atomically: true, encoding: .utf8)
            case .plainText:
                try buildPlainText(summary: summary).write(to: url, atomically: true, encoding: .utf8)
            case .csv:
                try buildCSV(summary: summary).write(to: url, atomically: true, encoding: .utf8)
            case .docx:
                try buildDocxXML(summary: summary).write(to: url, atomically: true, encoding: .utf8)
            }
            showSuccess("Exported to \(url.lastPathComponent)")
        } catch {
            errorMessage = "Failed to save file: \(error.localizedDescription)"
        }
    }

    func copyToClipboard() {
        guard let summary = summary else { return }
        let text = buildPlainText(summary: summary)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showSuccess("Copied to clipboard")
    }

    // MARK: - Markdown Export

    private func buildMarkdown(summary: MeetingSummaryResponse) -> String {
        let participants = extractParticipants()
        var md = "# \(meetingTitle) - Meeting Summary\n\n"
        md += "**Date:** \(meetingDateString)\n\n"

        md += "---\n\n"

        // Executive Summary
        md += "## Executive Summary\n\n"
        md += "\(summary.executive_summary)\n\n"

        // Participants
        if !participants.isEmpty {
            md += "## Participants\n\n"
            for p in participants {
                md += "- \(p)\n"
            }
            md += "\n"
        }

        // Key Decisions
        if !summary.decisions.isEmpty {
            md += "## Key Decisions\n\n"
            for (i, d) in summary.decisions.enumerated() {
                md += "\(i + 1). **\(d.decision)**"
                if !d.context.isEmpty {
                    md += "\n   - _Context:_ \(d.context)"
                }
                md += "\n\n"
            }
        }

        // Action Items
        if !summary.action_items.isEmpty {
            md += "## Action Items\n\n"
            md += "| # | Action | Assignee | Deadline |\n"
            md += "|---|--------|----------|----------|\n"
            for (i, item) in summary.action_items.enumerated() {
                let assignee = item.assignee.isEmpty ? "—" : item.assignee
                let deadline = item.deadline.isEmpty ? "—" : item.deadline
                md += "| \(i + 1) | \(item.action) | \(assignee) | \(deadline) |\n"
            }
            md += "\n"
        }

        // Open Questions
        if !summary.unresolved.isEmpty {
            md += "## Open Questions\n\n"
            for q in summary.unresolved {
                md += "- \(q)\n"
            }
            md += "\n"
        }

        // Appendix: Full Transcript
        if !fullTranscript.isEmpty {
            md += "---\n\n"
            md += "## Appendix: Full Meeting Transcript\n\n"
            md += formatTranscriptForMarkdown()
        }

        return md
    }

    // MARK: - Plain Text Export

    private func buildPlainText(summary: MeetingSummaryResponse) -> String {
        let participants = extractParticipants()
        let separator = String(repeating: "=", count: 60)
        let thinSep = String(repeating: "-", count: 60)
        var text = ""

        text += "\(meetingTitle.uppercased()) - MEETING SUMMARY\n"
        text += "Date: \(meetingDateString)\n"
        text += "\(separator)\n\n"

        // Executive Summary
        text += "EXECUTIVE SUMMARY\n"
        text += "\(thinSep)\n"
        text += "\(summary.executive_summary)\n\n"

        // Participants
        if !participants.isEmpty {
            text += "PARTICIPANTS\n"
            text += "\(thinSep)\n"
            for p in participants {
                text += "  - \(p)\n"
            }
            text += "\n"
        }

        // Key Decisions
        if !summary.decisions.isEmpty {
            text += "KEY DECISIONS\n"
            text += "\(thinSep)\n"
            for (i, d) in summary.decisions.enumerated() {
                text += "  \(i + 1). \(d.decision)\n"
                if !d.context.isEmpty {
                    text += "     Context: \(d.context)\n"
                }
            }
            text += "\n"
        }

        // Action Items
        if !summary.action_items.isEmpty {
            text += "ACTION ITEMS\n"
            text += "\(thinSep)\n"
            for (i, item) in summary.action_items.enumerated() {
                text += "  \(i + 1). \(item.action)\n"
                if !item.assignee.isEmpty {
                    text += "     Assignee: \(item.assignee)\n"
                }
                if !item.deadline.isEmpty {
                    text += "     Deadline: \(item.deadline)\n"
                }
            }
            text += "\n"
        }

        // Open Questions
        if !summary.unresolved.isEmpty {
            text += "OPEN QUESTIONS\n"
            text += "\(thinSep)\n"
            for q in summary.unresolved {
                text += "  - \(q)\n"
            }
            text += "\n"
        }

        // Appendix: Full Transcript
        if !fullTranscript.isEmpty {
            text += "\(separator)\n"
            text += "APPENDIX: FULL MEETING TRANSCRIPT\n"
            text += "\(separator)\n\n"
            text += fullTranscript
            text += "\n"
        }

        return text
    }

    // MARK: - CSV Export

    private func buildCSV(summary: MeetingSummaryResponse) -> String {
        var csv = ""

        // Meeting info
        csv += "Meeting Summary\n"
        csv += csvRow(["Title", meetingTitle])
        csv += csvRow(["Date", meetingDateString])
        csv += "\n"

        // Executive Summary
        csv += csvRow(["Executive Summary"])
        csv += csvRow([summary.executive_summary])
        csv += "\n"

        // Participants
        let participants = extractParticipants()
        if !participants.isEmpty {
            csv += csvRow(["Participants"])
            for p in participants {
                csv += csvRow([p])
            }
            csv += "\n"
        }

        // Key Decisions
        if !summary.decisions.isEmpty {
            csv += csvRow(["Key Decisions"])
            csv += csvRow(["#", "Decision", "Context"])
            for (i, d) in summary.decisions.enumerated() {
                csv += csvRow(["\(i + 1)", d.decision, d.context])
            }
            csv += "\n"
        }

        // Action Items
        if !summary.action_items.isEmpty {
            csv += csvRow(["Action Items"])
            csv += csvRow(["#", "Action", "Assignee", "Deadline"])
            for (i, item) in summary.action_items.enumerated() {
                csv += csvRow(["\(i + 1)", item.action, item.assignee, item.deadline])
            }
            csv += "\n"
        }

        // Open Questions
        if !summary.unresolved.isEmpty {
            csv += csvRow(["Open Questions"])
            for q in summary.unresolved {
                csv += csvRow([q])
            }
        }

        return csv
    }

    private func csvRow(_ fields: [String]) -> String {
        fields.map { csvEscape($0) }.joined(separator: ",") + "\n"
    }

    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: - DOCX Export (WordprocessingML XML)

    private func buildDocxXML(summary: MeetingSummaryResponse) -> String {
        // Generate a flat XML WordprocessingML document.
        // Word, Pages, and LibreOffice can open this directly as .docx.
        let participants = extractParticipants()

        var body = ""

        // Title
        body += wordParagraph(meetingTitle, style: "Heading1")
        body += wordParagraph("Meeting Summary", style: "Heading2")
        body += wordParagraph("Date: \(meetingDateString)")
        body += wordParagraph("")

        // Executive Summary
        body += wordParagraph("Executive Summary", style: "Heading2")
        for paragraph in summary.executive_summary.components(separatedBy: "\n") where !paragraph.isEmpty {
            body += wordParagraph(paragraph)
        }
        body += wordParagraph("")

        // Participants
        if !participants.isEmpty {
            body += wordParagraph("Participants", style: "Heading2")
            for p in participants {
                body += wordListItem(p)
            }
            body += wordParagraph("")
        }

        // Key Decisions
        if !summary.decisions.isEmpty {
            body += wordParagraph("Key Decisions", style: "Heading2")
            for (i, d) in summary.decisions.enumerated() {
                body += wordParagraph("\(i + 1). \(d.decision)", bold: true)
                if !d.context.isEmpty {
                    body += wordParagraph("    Context: \(d.context)")
                }
            }
            body += wordParagraph("")
        }

        // Action Items
        if !summary.action_items.isEmpty {
            body += wordParagraph("Action Items", style: "Heading2")
            for (i, item) in summary.action_items.enumerated() {
                var line = "\(i + 1). \(item.action)"
                if !item.assignee.isEmpty { line += " [Assignee: \(item.assignee)]" }
                if !item.deadline.isEmpty { line += " [Deadline: \(item.deadline)]" }
                body += wordParagraph(line)
            }
            body += wordParagraph("")
        }

        // Open Questions
        if !summary.unresolved.isEmpty {
            body += wordParagraph("Open Questions", style: "Heading2")
            for q in summary.unresolved {
                body += wordListItem(q)
            }
            body += wordParagraph("")
        }

        // Appendix: Full Transcript
        if !fullTranscript.isEmpty {
            body += wordParagraph("")
            body += wordParagraph("Appendix: Full Meeting Transcript", style: "Heading2")
            for line in fullTranscript.components(separatedBy: "\n") {
                body += wordParagraph(line)
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <?mso-application progid="Word.Document"?>
        <w:wordDocument xmlns:w="http://schemas.microsoft.com/office/word/2003/wordml"
                        xmlns:wx="http://schemas.microsoft.com/office/word/2003/auxHint">
        <w:body>\(body)</w:body>
        </w:wordDocument>
        """
    }

    private func wordParagraph(_ text: String, style: String? = nil, bold: Bool = false) -> String {
        let escaped = xmlEscape(text)
        var pPr = ""
        if let style {
            pPr += "<w:pStyle w:val=\"\(style)\"/>"
        }
        var rPr = ""
        if bold {
            rPr = "<w:rPr><w:b/></w:rPr>"
        }
        let pPrBlock = pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>"
        return "<w:p>\(pPrBlock)<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
    }

    private func wordListItem(_ text: String) -> String {
        wordParagraph("- \(text)")
    }

    private func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Transcript Formatting

    /// Format the full transcript with speaker breakout headers for Markdown.
    /// Input lines look like: "[07:11:54] Speaker 1: they put in Comedie..."
    /// Output groups consecutive lines under speaker headers.
    private func formatTranscriptForMarkdown() -> String {
        let lines = fullTranscript.components(separatedBy: "\n")

        // Check if any line has speaker labels
        let hasSpeakers = lines.contains { extractSpeaker(from: $0) != nil }

        if !hasSpeakers {
            return "\(fullTranscript)\n"
        }

        var md = ""
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
