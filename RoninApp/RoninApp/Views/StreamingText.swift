import SwiftUI

/// A text view that reveals new characters with a fast typewriter effect.
///
/// When `text` changes, any new suffix beyond what was already displayed
/// is revealed character-by-character. Already-visible text stays put.
///
/// Uses SwiftUI's `.task(id:)` for lifecycle-safe async animation —
/// no raw Timers that break in LazyVStack recycling.
struct StreamingText: View {
    let text: String
    let isFinal: Bool
    let font: Font
    let foregroundColor: Color
    let lineSpacing: CGFloat

    /// How many characters are currently visible
    @State private var visibleCount: Int = 0
    /// Monotonically increasing revision counter to trigger .task(id:)
    @State private var revision: Int = 0
    /// The text we're animating towards
    @State private var targetText: String = ""
    /// Whether this view has appeared at least once
    @State private var hasAppeared: Bool = false

    /// Characters per second for the typewriter effect
    private static let charsPerSecond: Double = 160
    /// Nanoseconds between each character reveal
    private static let tickNanos: UInt64 = UInt64(1_000_000_000 / charsPerSecond)

    var body: some View {
        Text(displayText)
            .font(font)
            .foregroundColor(foregroundColor)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                targetText = text
                if isFinal || hasAppeared {
                    // Final segments or re-appearing views: show all text instantly
                    visibleCount = text.count
                } else {
                    hasAppeared = true
                    visibleCount = 0
                    revision += 1
                }
            }
            .onChange(of: text) { oldValue, newValue in
                handleTextChange(from: oldValue, to: newValue)
            }
            .task(id: revision) {
                await animateReveal()
            }
    }

    /// The visible portion of the target text
    private var displayText: String {
        if visibleCount >= targetText.count {
            return targetText
        }
        return String(targetText.prefix(visibleCount))
    }

    private func handleTextChange(from oldValue: String, to newValue: String) {
        let previousVisible = visibleCount
        targetText = newValue

        // Check if the new text extends what's already visible
        let oldVisible = String(oldValue.prefix(previousVisible))
        if newValue.hasPrefix(oldVisible) {
            // New text grows from what's visible — keep visibleCount, animate the rest
        } else {
            // Text changed in a non-extending way — snap to common prefix
            visibleCount = Self.commonPrefixCount(oldVisible, newValue)
        }

        if visibleCount < targetText.count {
            revision += 1
        }
    }

    /// Async reveal loop — cancels automatically when revision changes or view disappears
    private func animateReveal() async {
        while visibleCount < targetText.count {
            // Reveal in small bursts for natural word-level pacing
            let remaining = targetText.count - visibleCount
            let burst = max(1, min(remaining, remaining / 6 + 1))
            visibleCount += burst

            do {
                try await Task.sleep(nanoseconds: Self.tickNanos * UInt64(burst))
            } catch {
                // Task cancelled (view disappeared or new revision)
                return
            }
        }
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var aIdx = a.startIndex
        var bIdx = b.startIndex
        while aIdx < a.endIndex && bIdx < b.endIndex && a[aIdx] == b[bIdx] {
            count += 1
            aIdx = a.index(after: aIdx)
            bIdx = b.index(after: bIdx)
        }
        return count
    }
}
