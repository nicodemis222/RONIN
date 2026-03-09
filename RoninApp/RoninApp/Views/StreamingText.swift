import SwiftUI

/// A text view that reveals new characters with a fast typewriter effect.
/// When `text` changes, any new suffix beyond what was already displayed
/// is revealed character-by-character. Already-visible text stays put.
struct StreamingText: View {
    let text: String
    let isFinal: Bool
    let font: Font
    let foregroundColor: Color
    let lineSpacing: CGFloat

    /// How many characters are currently visible
    @State private var visibleCount: Int = 0
    /// The text we're animating towards
    @State private var targetText: String = ""
    /// Timer driving the reveal
    @State private var timer: Timer?

    /// Characters per second for the typewriter effect
    private let charsPerSecond: Double = 120

    var body: some View {
        Text(String(targetText.prefix(visibleCount)))
            .font(font)
            .foregroundColor(foregroundColor)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: text) { oldValue, newValue in
                revealDelta(from: oldValue, to: newValue)
            }
            .onAppear {
                // First appearance — if text already has content, reveal it
                targetText = text
                if isFinal {
                    // Final segments show instantly (already committed speech)
                    visibleCount = text.count
                } else {
                    // Partial — animate from nothing
                    visibleCount = 0
                    startTimer()
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }

    private func revealDelta(from oldValue: String, to newValue: String) {
        timer?.invalidate()
        timer = nil

        let previousVisible = visibleCount
        targetText = newValue

        if newValue.hasPrefix(String(oldValue.prefix(previousVisible))) {
            // New text extends what's visible — keep visible prefix, animate the rest
            // visibleCount stays the same, timer will reveal the new chars
        } else {
            // Text changed entirely (new segment) — show what we can match
            let commonLen = commonPrefixLength(String(targetText.prefix(previousVisible)), newValue)
            visibleCount = commonLen
        }

        if visibleCount < targetText.count {
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = 1.0 / charsPerSecond
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                if visibleCount < targetText.count {
                    // Reveal in small bursts for smoother feel
                    let remaining = targetText.count - visibleCount
                    let burst = min(remaining, max(1, remaining / 8))
                    visibleCount += burst
                } else {
                    timer?.invalidate()
                    timer = nil
                }
            }
        }
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        let aChars = Array(a)
        let bChars = Array(b)
        let limit = min(aChars.count, bChars.count)
        while count < limit && aChars[count] == bChars[count] {
            count += 1
        }
        return count
    }
}
