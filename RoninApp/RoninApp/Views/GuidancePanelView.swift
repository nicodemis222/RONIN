import SwiftUI

struct GuidancePanelView: View {
    let guidance: CopilotGuidance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .foregroundColor(.matrixBright)
                Text("> Guidance")
                    .font(.matrixHeadline)
                    .foregroundColor(.matrixBright)
                    .matrixGlow(radius: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(Color.matrixDivider)

            let isEmpty = guidance.followUpQuestions.isEmpty &&
                          guidance.risks.isEmpty &&
                          guidance.factsFromNotes.isEmpty

            if isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "lightbulb")
                            .font(.title)
                            .foregroundColor(.matrixFaded)
                        Text("Guidance will appear here")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixFaded)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !guidance.followUpQuestions.isEmpty {
                            GuidanceSection(
                                title: "Follow-up Questions",
                                icon: "questionmark.circle",
                                color: .matrixCyan
                            ) {
                                ForEach(guidance.followUpQuestions, id: \.self) { q in
                                    Text("  \(q)")
                                        .font(.matrixBody)
                                        .foregroundColor(.matrixText)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if !guidance.risks.isEmpty {
                            GuidanceSection(
                                title: "Risks / Watch Out",
                                icon: "exclamationmark.triangle",
                                color: .matrixWarning
                            ) {
                                ForEach(guidance.risks) { risk in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(risk.warning)
                                            .font(.matrixBodyBold)
                                            .foregroundColor(.matrixText)
                                        Text(risk.context)
                                            .font(.matrixCaption)
                                            .foregroundColor(.matrixDim)
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
                                ForEach(guidance.factsFromNotes) { fact in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fact.fact)
                                            .font(.matrixBody)
                                            .foregroundColor(.matrixText)
                                            .textSelection(.enabled)
                                        Text(fact.source)
                                            .font(.matrixCaption)
                                            .foregroundColor(.matrixDim)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

struct GuidanceSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.matrixCaption)
                .fontWeight(.bold)
                .foregroundColor(color)
                .matrixGlow(color: color, radius: 3)

            content()
        }
    }
}
