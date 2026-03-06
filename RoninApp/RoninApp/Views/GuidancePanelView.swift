import SwiftUI

struct GuidancePanelView: View {
    let guidance: CopilotGuidance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .foregroundColor(.matrixBright)
                Text("> Guidance")
                    .font(.matrixHeadline)
                    .foregroundColor(.matrixBright)
                    .matrixGlow(radius: 4)
                Spacer()
                // Badge counts
                guidanceBadges
            }
            .padding(.horizontal, MatrixSpacing.panelPaddingH)
            .padding(.vertical, MatrixSpacing.barPaddingV)

            Divider().overlay(Color.matrixDivider)

            let isEmpty = guidance.followUpQuestions.isEmpty &&
                          guidance.risks.isEmpty &&
                          guidance.factsFromNotes.isEmpty

            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !guidance.followUpQuestions.isEmpty {
                            GuidanceSection(
                                title: "Follow-up Questions",
                                icon: "questionmark.circle",
                                color: .matrixCyan
                            ) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(guidance.followUpQuestions, id: \.self) { q in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("›")
                                                .font(.matrixGuidanceBold)
                                                .foregroundColor(.matrixCyan.opacity(0.6))
                                            Text(q)
                                                .font(.matrixGuidance)
                                                .foregroundColor(.matrixReadable)
                                                .lineSpacing(MatrixSpacing.guidanceLineSpacing)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }

                        if !guidance.risks.isEmpty {
                            GuidanceSection(
                                title: "Risks / Watch Out",
                                icon: "exclamationmark.triangle",
                                color: .matrixWarning
                            ) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(guidance.risks) { risk in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(risk.warning)
                                                .font(.matrixGuidanceBold)
                                                .foregroundColor(.matrixReadable)
                                                .lineSpacing(MatrixSpacing.guidanceLineSpacing)
                                            Text(risk.context)
                                                .font(.matrixCaption)
                                                .foregroundColor(.matrixDim)
                                                .lineSpacing(4)
                                        }
                                    }
                                }
                            }
                        }

                        if !guidance.factsFromNotes.isEmpty {
                            GuidanceSection(
                                title: "From Your Notes",
                                icon: "doc.text",
                                color: .matrixGreen
                            ) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(guidance.factsFromNotes) { fact in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(fact.fact)
                                                .font(.matrixGuidance)
                                                .foregroundColor(.matrixReadable)
                                                .lineSpacing(MatrixSpacing.guidanceLineSpacing)
                                                .textSelection(.enabled)
                                            Text(fact.source)
                                                .font(.matrixCaption)
                                                .foregroundColor(.matrixDim)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(MatrixSpacing.panelPaddingH)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Badge Counts (top-right of header)

    @ViewBuilder
    private var guidanceBadges: some View {
        HStack(spacing: 6) {
            if !guidance.followUpQuestions.isEmpty {
                badgePill(count: guidance.followUpQuestions.count, icon: "questionmark.circle", color: .matrixCyan)
            }
            if !guidance.risks.isEmpty {
                badgePill(count: guidance.risks.count, icon: "exclamationmark.triangle", color: .matrixWarning)
            }
            if !guidance.factsFromNotes.isEmpty {
                badgePill(count: guidance.factsFromNotes.count, icon: "doc.text", color: .matrixGreen)
            }
        }
    }

    private func badgePill(count: Int, icon: String, color: Color) -> some View {
        Label("\(count)", systemImage: icon)
            .font(.matrixBadge)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 28))
                        .foregroundColor(.matrixFaded)
                    Text("Guidance will appear here")
                        .font(.matrixCaption)
                        .foregroundColor(.matrixFaded)
                }
                Spacer()
            }
            Spacer()
        }
    }
}

struct GuidanceSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.matrixCaption)
                .fontWeight(.bold)
                .foregroundColor(color)
                .matrixGlow(color: color, radius: 3)

            content()
        }
    }
}
