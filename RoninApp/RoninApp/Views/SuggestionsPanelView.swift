import SwiftUI
import AppKit

struct SuggestionsPanelView: View {
    let suggestions: [Suggestion]
    var onCopy: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .foregroundColor(.matrixBright)
                Text("> Responses")
                    .font(.matrixHeadline)
                    .foregroundColor(.matrixBright)
                    .matrixGlow(radius: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(Color.matrixDivider)

            if suggestions.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.title)
                            .foregroundColor(.matrixFaded)
                        Text("Suggestions will appear here")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixFaded)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(suggestions) { suggestion in
                            SuggestionCard(suggestion: suggestion, onCopy: onCopy)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

struct SuggestionCard: View {
    let suggestion: Suggestion
    var onCopy: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            Text(suggestion.text)
                .font(.matrixBody)
                .foregroundColor(.matrixText)
                .textSelection(.enabled)
        }
        .matrixCard()
    }
}
