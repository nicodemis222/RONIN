import SwiftUI
import AppKit

struct SuggestionsPanelView: View {
    let copilotHistory: [CopilotSnapshot]
    var questionDetected: Bool = false
    var onCopy: ((String) -> Void)?

    /// Smart auto-scroll: tracks whether user is reading near the bottom
    @State private var isAtBottom = true
    /// Count of new batches since user scrolled away
    @State private var unreadCount = 0

    /// Snapshots that have at least one suggestion
    private var nonEmptySnapshots: [CopilotSnapshot] {
        copilotHistory.filter { !$0.suggestions.isEmpty }
    }

    private var totalSuggestions: Int {
        nonEmptySnapshots.reduce(0) { $0 + $1.suggestions.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .foregroundColor(.matrixBright)
                Text("> Responses")
                    .font(.matrixHeadline)
                    .foregroundColor(.matrixBright)
                    .matrixGlow(radius: 4)
                Spacer()
                if totalSuggestions > 0 {
                    Text("\(totalSuggestions)")
                        .font(.matrixBadge)
                        .foregroundColor(.matrixFaded)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.matrixBorder.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, MatrixSpacing.panelPaddingH)
            .padding(.vertical, MatrixSpacing.barPaddingV)

            Divider().overlay(Color.matrixDivider)

            if nonEmptySnapshots.isEmpty {
                emptyState
            } else {
                suggestionsScroll
            }
        }
        .questionHighlight(isActive: questionDetected)
    }

    // MARK: - Scrollable History with Auto-Scroll

    private var suggestionsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(nonEmptySnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        // Batch separator (between batches, not before the first)
                        if index > 0 {
                            batchSeparator(timestamp: snapshot.timestamp)
                        }

                        // Suggestions in this batch
                        VStack(spacing: MatrixSpacing.cardGap) {
                            ForEach(snapshot.suggestions) { suggestion in
                                SuggestionCard(suggestion: suggestion, onCopy: onCopy)
                            }
                        }
                        .padding(.horizontal, MatrixSpacing.panelPaddingH)
                        .padding(.vertical, 10)
                    }

                    // Invisible bottom anchor for auto-scroll detection
                    Color.clear
                        .frame(height: 1)
                        .id("suggestions-bottom")
                        .onAppear {
                            isAtBottom = true
                            unreadCount = 0
                        }
                        .onDisappear {
                            isAtBottom = false
                        }
                }
            }
            .onChange(of: copilotHistory.count) {
                if isAtBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("suggestions-bottom", anchor: .bottom)
                    }
                } else {
                    unreadCount += 1
                }
            }
            // "Jump to latest" floating button
            .overlay(alignment: .bottom) {
                if !isAtBottom && !nonEmptySnapshots.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("suggestions-bottom", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                            Text(unreadCount > 0 ? "↓ \(unreadCount) new" : "Latest")
                        }
                        .font(.matrixBadge)
                        .foregroundColor(.matrixBright)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.matrixSurface.opacity(0.95))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.matrixBorder, lineWidth: 1))
                        .shadow(color: Color.matrixGlow.opacity(0.2), radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: isAtBottom)
                }
            }
        }
    }

    // MARK: - Batch Separator

    private func batchSeparator(timestamp: Date) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.matrixBorder.opacity(0.3))
                .frame(height: 1)
            Text(formatTimestamp(timestamp))
                .font(.matrixCaption2)
                .foregroundColor(.matrixFaded)
            Rectangle()
                .fill(Color.matrixBorder.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.horizontal, MatrixSpacing.panelPaddingH)
        .padding(.vertical, 4)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: date)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28))
                        .foregroundColor(.matrixFaded)
                    Text("Suggestions will appear here")
                        .font(.matrixCaption)
                        .foregroundColor(.matrixFaded)
                }
                Spacer()
            }
            Spacer()
        }
    }
}

struct SuggestionCard: View {
    let suggestion: Suggestion
    var onCopy: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tone badge row
            HStack(spacing: 6) {
                Image(systemName: suggestion.toneIcon)
                    .font(.matrixCaption)
                    .foregroundColor(suggestion.toneColor)

                Text(suggestion.toneLabel)
                    .font(.matrixBadge)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(suggestion.toneColor.opacity(0.15))
                    .foregroundColor(suggestion.toneColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer()

                Button {
                    if let onCopy = onCopy {
                        onCopy(suggestion.text)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(suggestion.text, forType: .string)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.matrixCaption)
                        .foregroundColor(.matrixDim)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }

            // Response text — optimized for deep comprehension reading
            // Research: 15pt, 1.5x line-height, max ~60 CPL for sustained reading
            Text(suggestion.text)
                .font(.matrixResponse)
                .foregroundColor(.matrixReadable)
                .lineSpacing(MatrixSpacing.responseLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: MatrixSpacing.maxReadingWidth, alignment: .leading)
        }
        .matrixCard()
    }
}
