import SwiftUI

struct GuidancePanelView: View {
    let copilotHistory: [CopilotSnapshot]

    /// Smart auto-scroll: tracks whether user is reading near the bottom
    @State private var isAtBottom = true
    /// Count of new batches since user scrolled away
    @State private var unreadCount = 0

    /// Latest guidance for badge counts in the header
    private var latestGuidance: CopilotGuidance {
        copilotHistory.last?.guidance ?? .empty
    }

    /// Snapshots that have non-empty guidance
    private var nonEmptySnapshots: [CopilotSnapshot] {
        copilotHistory.filter { !$0.guidance.isEmpty }
    }

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
                // Badge counts (from latest guidance)
                guidanceBadges
            }
            .padding(.horizontal, MatrixSpacing.panelPaddingH)
            .padding(.vertical, MatrixSpacing.barPaddingV)

            Divider().overlay(Color.matrixDivider)

            if nonEmptySnapshots.isEmpty {
                emptyState
            } else {
                guidanceScroll
            }
        }
    }

    // MARK: - Scrollable History with Auto-Scroll

    private var guidanceScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(nonEmptySnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        // Batch separator (between batches, not before the first)
                        if index > 0 {
                            batchSeparator(timestamp: snapshot.timestamp)
                        }

                        // Guidance content for this batch
                        guidanceBatchContent(snapshot.guidance)
                            .padding(.horizontal, MatrixSpacing.panelPaddingH)
                            .padding(.vertical, 10)
                    }

                    // Invisible bottom anchor for auto-scroll detection
                    Color.clear
                        .frame(height: 1)
                        .id("guidance-bottom")
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
                        proxy.scrollTo("guidance-bottom", anchor: .bottom)
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
                            proxy.scrollTo("guidance-bottom", anchor: .bottom)
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

    // MARK: - Single Batch Guidance Content

    @ViewBuilder
    private func guidanceBatchContent(_ guidance: CopilotGuidance) -> some View {
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

    // MARK: - Badge Counts (top-right of header, from latest batch)

    @ViewBuilder
    private var guidanceBadges: some View {
        HStack(spacing: 6) {
            if !latestGuidance.followUpQuestions.isEmpty {
                badgePill(count: latestGuidance.followUpQuestions.count, icon: "questionmark.circle", color: .matrixCyan)
            }
            if !latestGuidance.risks.isEmpty {
                badgePill(count: latestGuidance.risks.count, icon: "exclamationmark.triangle", color: .matrixWarning)
            }
            if !latestGuidance.factsFromNotes.isEmpty {
                badgePill(count: latestGuidance.factsFromNotes.count, icon: "doc.text", color: .matrixGreen)
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
