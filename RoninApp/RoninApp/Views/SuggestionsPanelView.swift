import SwiftUI
import AppKit

struct SuggestionsPanelView: View {
    let suggestions: [Suggestion]

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
                            SuggestionCard(suggestion: suggestion)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.tone.capitalized)
                    .font(.matrixBadge)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(suggestion.toneColor.opacity(0.15))
                    .foregroundColor(suggestion.toneColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(suggestion.text, forType: .string)
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
