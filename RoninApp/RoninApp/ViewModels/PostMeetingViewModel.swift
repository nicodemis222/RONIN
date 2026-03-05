import AppKit
import Foundation

@MainActor
class PostMeetingViewModel: ObservableObject {
    @Published var summary: MeetingSummaryResponse?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var fullTranscript: String = ""

    var meetingTitle: String = ""
    private var lastSessionId: String?

    private let backendAPI = BackendAPIService()

    func loadSummary(sessionId: String) async {
        isLoading = true
        errorMessage = nil
        lastSessionId = sessionId

        do {
            summary = try await backendAPI.endMeeting(sessionId: sessionId)
        } catch {
            errorMessage = "Failed to generate summary: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func retry() async {
        guard let sessionId = lastSessionId else {
            errorMessage = "No session to retry."
            return
        }
        await loadSummary(sessionId: sessionId)
    }

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
            md += "## Full Transcript\n```\n\(fullTranscript)\n```\n"
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

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showSuccess("Copied to clipboard")
    }

    private func showSuccess(_ message: String) {
        successMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.successMessage = nil
        }
    }
}
