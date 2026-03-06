import SwiftUI

@MainActor
class TutorialViewModel: ObservableObject {

    // MARK: - Tutorial Card Model

    struct TutorialCard: Identifiable {
        let id: Int
        let icon: String           // SF Symbol name
        let title: String          // Terminal-style header
        let body: String           // Description text
        let detail: String?        // Optional sub-detail
        let accentColor: Color     // Per-card accent
    }

    // MARK: - State

    @Published var isShowingTutorial: Bool = false
    @Published var currentCardIndex: Int = 0

    @Published var hasCompletedTutorial: Bool = UserDefaults.standard.bool(forKey: "ronin.hasCompletedTutorial") {
        didSet { UserDefaults.standard.set(hasCompletedTutorial, forKey: "ronin.hasCompletedTutorial") }
    }

    // MARK: - Cards

    let cards: [TutorialCard] = [
        TutorialCard(
            id: 0,
            icon: "terminal",
            title: "WELCOME_TO_RONIN",
            body: "Your local-first meeting copilot. Real-time transcription, AI-powered suggestions, and post-meeting summaries. Run fully local with LM Studio, or connect to OpenAI for faster responses.",
            detail: "Audio never leaves your Mac. Transcription always runs on-device.",
            accentColor: .matrixNeon
        ),
        TutorialCard(
            id: 1,
            icon: "doc.text.magnifyingglass",
            title: "PHASE_1: MEETING_PREP",
            body: "Before your meeting, set a title, goal, and optional constraints. Drop in notes (.md or .txt) with background info — RONIN will surface relevant facts during the call.",
            detail: "Tip: The more specific your goal, the better the copilot suggestions.",
            accentColor: .matrixGreen
        ),
        TutorialCard(
            id: 2,
            icon: "waveform.circle.fill",
            title: "PHASE_2: LIVE_COPILOT",
            body: "During the meeting, a resizable floating overlay shows live transcription, tone-varied response suggestions, follow-up questions, risk flags, and facts from your notes. Drag panel dividers to adjust layout.",
            detail: "Controls: Mute ⌘⇧M | Pause ⌘⇧P | Compact ⌘⇧C",
            accentColor: .matrixCyan
        ),
        TutorialCard(
            id: 3,
            icon: "doc.richtext",
            title: "PHASE_3: POST_MEETING",
            body: "After ending the meeting, RONIN generates a structured summary with key decisions, action items with assignees, and open questions. Export to Markdown or copy to clipboard.",
            detail: nil,
            accentColor: .matrixLime
        ),
        TutorialCard(
            id: 4,
            icon: "gear",
            title: "SYSTEM_CONFIG",
            body: "Access Settings via ⌘, to switch LLM providers, adjust overlay opacity and layout, set compact mode defaults, and re-launch this tutorial. Use the menu bar icon for quick meeting controls.",
            detail: "Run the tutorial again from Settings > General > Show Tutorial.",
            accentColor: .matrixWarning
        ),
    ]

    // MARK: - Navigation

    var currentCard: TutorialCard { cards[currentCardIndex] }
    var isFirstCard: Bool { currentCardIndex == 0 }
    var isLastCard: Bool { currentCardIndex == cards.count - 1 }
    var progress: Double { Double(currentCardIndex + 1) / Double(cards.count) }

    func nextCard() {
        guard !isLastCard else {
            completeTutorial()
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentCardIndex += 1
        }
    }

    func previousCard() {
        guard !isFirstCard else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentCardIndex -= 1
        }
    }

    func skipTutorial() {
        completeTutorial()
    }

    func completeTutorial() {
        withAnimation(.easeInOut(duration: 0.3)) {
            hasCompletedTutorial = true
            isShowingTutorial = false
            currentCardIndex = 0
        }
    }

    /// Called on app launch to auto-show tutorial for first-time users.
    func checkFirstLaunch() {
        if !hasCompletedTutorial {
            isShowingTutorial = true
        }
    }

    /// Called from Settings to re-show the tutorial.
    func relaunchTutorial() {
        currentCardIndex = 0
        isShowingTutorial = true
    }
}
