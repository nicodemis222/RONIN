import SwiftUI

struct TutorialOverlayView: View {
    @EnvironmentObject var tutorialVM: TutorialViewModel

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.matrixBlack.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button (top-right)
                HStack {
                    Spacer()
                    if !tutorialVM.isLastCard {
                        Button("[ SKIP ]") {
                            tutorialVM.skipTutorial()
                        }
                        .buttonStyle(.plain)
                        .font(.matrixCaption)
                        .foregroundColor(.matrixFaded)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)

                Spacer()

                // Card content
                tutorialCardView(tutorialVM.currentCard)

                Spacer()

                // Progress bar + navigation
                VStack(spacing: 16) {
                    // Terminal-style segmented progress
                    HStack(spacing: 4) {
                        ForEach(tutorialVM.cards) { card in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    card.id <= tutorialVM.currentCardIndex
                                        ? tutorialVM.currentCard.accentColor
                                        : Color.matrixBorder
                                )
                                .frame(height: 3)
                                .shadow(
                                    color: card.id == tutorialVM.currentCardIndex
                                        ? tutorialVM.currentCard.accentColor.opacity(0.5)
                                        : .clear,
                                    radius: 4
                                )
                        }
                    }
                    .padding(.horizontal, 80)

                    // Card counter
                    Text("[\(tutorialVM.currentCardIndex + 1)/\(tutorialVM.cards.count)]")
                        .font(.matrixCaption)
                        .foregroundColor(.matrixFaded)

                    // Navigation buttons
                    HStack(spacing: 16) {
                        if !tutorialVM.isFirstCard {
                            Button("< Back") {
                                tutorialVM.previousCard()
                            }
                            .buttonStyle(MatrixSecondaryButtonStyle())
                        }

                        Button(tutorialVM.isLastCard ? "[ BEGIN ]" : "Next >") {
                            tutorialVM.nextCard()
                        }
                        .buttonStyle(MatrixPrimaryButtonStyle())
                    }

                    // Keyboard hint
                    Text("Arrow keys to navigate · Enter to continue · Esc to skip")
                        .font(.matrixCaption2)
                        .foregroundColor(.matrixFaded)
                        .padding(.top, 4)
                }
                .padding(.bottom, 40)
            }
        }
        .transition(.opacity)
        .onKeyPress(.rightArrow) {
            tutorialVM.nextCard()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            tutorialVM.previousCard()
            return .handled
        }
        .onKeyPress(.return) {
            tutorialVM.nextCard()
            return .handled
        }
        .onKeyPress(.escape) {
            tutorialVM.skipTutorial()
            return .handled
        }
    }

    // MARK: - Card View

    @ViewBuilder
    private func tutorialCardView(_ card: TutorialViewModel.TutorialCard) -> some View {
        VStack(spacing: 20) {
            // Icon with glow
            Image(systemName: card.icon)
                .font(.system(size: 48))
                .foregroundColor(card.accentColor)
                .matrixGlow(color: card.accentColor, radius: 12)

            // Title (terminal-style)
            Text("> \(card.title)")
                .font(.matrixLargeTitle)
                .foregroundColor(card.accentColor)
                .matrixGlow(color: card.accentColor, radius: 6)

            // Body
            Text(card.body)
                .font(.matrixBody)
                .foregroundColor(.matrixText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .lineSpacing(4)

            // Detail (dimmer, optional)
            if let detail = card.detail {
                Text(detail)
                    .font(.matrixCaption)
                    .foregroundColor(.matrixDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .padding(32)
        .background(Color.matrixSurface.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(card.accentColor.opacity(0.3), lineWidth: 1)
        )
        .frame(maxWidth: 560)
    }
}
