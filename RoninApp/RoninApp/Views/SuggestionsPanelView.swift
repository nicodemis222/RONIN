import SwiftUI
import AppKit

struct SuggestionsPanelView: View {
    let suggestions: [Suggestion]
    var onCopy: ((String) -> Void)?

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
                if !suggestions.isEmpty {
                    Text("\(suggestions.count)")
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

            if suggestions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: MatrixSpacing.cardGap) {
                        ForEach(suggestions) { suggestion in
                            SuggestionCard(suggestion: suggestion, onCopy: onCopy)
                        }
                    }
                    .padding(MatrixSpacing.panelPaddingH)
                    .padding(.vertical, 10)
                }
            }
        }
    }

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
