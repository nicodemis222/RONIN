import SwiftUI

struct TranscriptPanelView: View {
    let segments: [TranscriptSegment]
    var questionSegmentId: UUID?

    /// Smart auto-scroll: tracks whether user is reading near the bottom
    @State private var isAtBottom = true
    /// Count of new segments since user scrolled away
    @State private var unreadCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundColor(.matrixBright)
                Text("> Transcript")
                    .font(.matrixHeadline)
                    .foregroundColor(.matrixBright)
                    .matrixGlow(radius: 4)
                Spacer()
                // Segment count badge
                if !segments.isEmpty {
                    Text("\(segments.count)")
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

            if segments.isEmpty {
                emptyState
            } else {
                transcriptScroll
            }
        }
    }

    // MARK: - Transcript Scroll with Smart Auto-Scroll

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        let isNewTurn = index == 0 ||
                            segments[index - 1].speaker != segment.speaker

                        transcriptRow(segment: segment, isNewTurn: isNewTurn, isFirst: index == 0)
                            .id(segment.id)
                    }

                    // Invisible bottom anchor for auto-scroll detection
                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                        .onAppear {
                            isAtBottom = true
                            unreadCount = 0
                        }
                        .onDisappear {
                            isAtBottom = false
                        }
                }
                .padding(.horizontal, MatrixSpacing.panelPaddingH)
                .padding(.vertical, 10)
            }
            .onChange(of: segments.count) {
                if isAtBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                } else {
                    unreadCount += 1
                }
            }
            // "Jump to latest" floating button
            .overlay(alignment: .bottom) {
                if !isAtBottom && !segments.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
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

    // MARK: - Transcript Row

    /// A single transcript segment, with visual grouping by speaker turns.
    private func transcriptRow(segment: TranscriptSegment, isNewTurn: Bool, isFirst: Bool) -> some View {
        let isHighlighted = segment.id == questionSegmentId

        return VStack(alignment: .leading, spacing: 0) {
            // Extra gap between different speaker turns (research: 12-16pt)
            if isNewTurn && !isFirst {
                Spacer().frame(height: MatrixSpacing.speakerTurnGap)
            }

            HStack(alignment: .top, spacing: 8) {
                // Timestamp column
                Text(segment.timestamp)
                    .font(.matrixCaption)
                    .foregroundColor(.matrixFaded)
                    .frame(width: 52, alignment: .leading)

                // Speaker label — only on first segment of a turn
                if isNewTurn && !segment.speaker.isEmpty {
                    Text(segment.speakerShortLabel)
                        .font(.matrixBadge)
                        .fontWeight(.bold)
                        .foregroundColor(segment.speakerColor)
                        .frame(width: 26, alignment: .leading)
                } else if !segment.speaker.isEmpty {
                    // Indent to align with text above
                    Spacer().frame(width: 26)
                }

                // Transcript text — optimized for scanning
                Text(segment.text)
                    .font(.matrixTranscript)
                    .foregroundColor(.matrixReadable)
                    .lineSpacing(MatrixSpacing.transcriptLineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Cyan left accent bar on question segments for visual linking
        .overlay(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.matrixCyan)
                    .frame(width: 2)
                    .shadow(color: Color.matrixCyan.opacity(0.4), radius: 3, x: 0, y: 0)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 28))
                        .foregroundColor(.matrixFaded)
                    Text("Listening...")
                        .font(.matrixCaption)
                        .foregroundColor(.matrixFaded)
                }
                Spacer()
            }
            Spacer()
        }
    }
}
