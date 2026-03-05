import AppKit
import SwiftUI

struct LiveCopilotView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: LiveCopilotViewModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Clean title bar
                titleBar

                Divider().overlay(Color.matrixDivider)

                if viewModel.showDebugConsole {
                    DebugConsoleView(
                        appLogs: viewModel.debugLog,
                        backendLogs: []
                    )
                    .frame(maxHeight: 200)

                    Divider().overlay(Color.matrixDivider)
                }

                // Main content — compact or full
                if viewModel.isCompact {
                    compactContent
                } else {
                    fullContent
                }

                Divider().overlay(Color.matrixDivider)

                // Control bar
                ControlBarView(
                    isPaused: $viewModel.isPaused,
                    isMuted: $viewModel.isMuted,
                    elapsedTime: viewModel.formattedTime,
                    onPause: { viewModel.togglePause() },
                    onMute: { viewModel.toggleMute() },
                    onEnd: { viewModel.showEndConfirmation = true }
                )
            }

            // "Copied" toast
            if viewModel.showCopiedToast {
                VStack {
                    Spacer()
                    Text("Copied to clipboard")
                        .font(.matrixCaption)
                        .fontWeight(.bold)
                        .foregroundColor(.matrixBright)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.matrixSurface)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.matrixBorder, lineWidth: 1)
                        )
                        .padding(.bottom, 50)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.showCopiedToast)
            }
        }
        .frame(
            minWidth: viewModel.isCompact ? 350 : 750,
            minHeight: viewModel.isCompact ? 200 : 300
        )
        .opacity(viewModel.isHovering ? 1.0 : viewModel.overlayOpacity)
        .foregroundColor(.matrixText)
        .background(Color.matrixBlack.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.matrixBorder.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color.matrixGlow.opacity(0.15), radius: 12)
        .matrixScanlines()
        .background(WindowDragEnabler())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.isHovering = hovering
            }
        }
        .onAppear {
            viewModel.meetingTitle = appState.meetingTitle
            viewModel.resetForNewMeeting()
            viewModel.connect()
        }
        .onDisappear {
            // Don't disconnect if just hiding overlay — only disconnect if meeting ends
            if appState.phase != .live {
                DispatchQueue.main.async {
                    viewModel.disconnect()
                }
            }
        }
        .onChange(of: appState.phase) { _, newPhase in
            if newPhase != .live {
                DispatchQueue.main.async {
                    viewModel.endMeeting()
                }
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("Dismiss") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog("End Meeting?", isPresented: $viewModel.showEndConfirmation) {
            Button("End Meeting", role: .destructive) {
                // Defer everything to next run-loop tick to avoid
                // "Publishing changes from within view updates"
                DispatchQueue.main.async {
                    viewModel.endMeeting()
                    appState.phase = .postMeeting
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will stop recording and generate a meeting summary.")
        }
    }

    // MARK: - Clean Title Bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.6), radius: 4)

            Text(appState.meetingTitle)
                .font(.matrixHeadline)
                .foregroundColor(.matrixBright)
                .lineLimit(1)

            // Audio level meter
            AudioLevelView(level: viewModel.audioLevel, isMuted: viewModel.isMuted)
                .frame(width: 40, height: 12)

            Spacer()

            // Elapsed time
            Text(viewModel.formattedTime)
                .font(.matrixBody)
                .foregroundColor(.matrixDim)

            if viewModel.isPaused {
                Text("PAUSED")
                    .font(.matrixBadge)
                    .foregroundColor(.matrixStatusPaused)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.matrixStatusPaused.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Compact/Full toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewModel.toggleCompact()
                }
            }) {
                Image(systemName: viewModel.isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .foregroundColor(.matrixDim)
            }
            .buttonStyle(.plain)
            .help(viewModel.isCompact ? "Expand to full view" : "Compact view")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.matrixBar)
    }

    private var statusDotColor: Color {
        if viewModel.isPaused { return .matrixStatusPaused }
        if viewModel.isConnected { return .matrixStatusActive }
        return .matrixStatusError
    }

    // MARK: - Compact Content

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Latest suggestion
            if let suggestion = viewModel.suggestions.first {
                HStack(alignment: .top, spacing: 8) {
                    Text(suggestion.text)
                        .font(.matrixBody)
                        .foregroundColor(.matrixText)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    Spacer(minLength: 4)

                    VStack(spacing: 4) {
                        Text(suggestion.tone.capitalized)
                            .font(.matrixBadge)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(suggestion.toneColor.opacity(0.15))
                            .foregroundColor(suggestion.toneColor)
                            .clipShape(RoundedRectangle(cornerRadius: 3))

                        Button {
                            viewModel.copyText(suggestion.text)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundColor(.matrixFaded)
                        Text("Suggestions will appear here")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixFaded)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }

            Divider().overlay(Color.matrixDivider)

            // Last few transcript lines
            VStack(alignment: .leading, spacing: 2) {
                let recentSegments = viewModel.transcriptSegments.suffix(3)
                if recentSegments.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixFaded)
                        Text("Listening...")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixFaded)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(Array(recentSegments)) { segment in
                        HStack(alignment: .top, spacing: 6) {
                            Text(segment.timestamp)
                                .font(.matrixCaption2)
                                .foregroundColor(.matrixFaded)
                                .frame(width: 40, alignment: .leading)

                            if !segment.speaker.isEmpty {
                                Text(segment.speakerShortLabel)
                                    .font(.matrixBadge)
                                    .foregroundColor(segment.speakerColor)
                                    .frame(width: 20, alignment: .leading)
                            }

                            Text(segment.text)
                                .font(.matrixCaption)
                                .lineLimit(1)
                                .foregroundColor(.matrixDim)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Full Content (3-panel)

    private var fullContent: some View {
        HStack(spacing: 0) {
            TranscriptPanelView(segments: viewModel.transcriptSegments)
                .frame(minWidth: 250)

            Divider().overlay(Color.matrixDivider)

            SuggestionsPanelView(suggestions: viewModel.suggestions)
                .frame(minWidth: 280)

            Divider().overlay(Color.matrixDivider)

            GuidancePanelView(guidance: viewModel.guidance)
                .frame(minWidth: 220)
        }
    }
}

// MARK: - Debug Console

struct DebugConsoleView: View {
    let appLogs: [String]
    let backendLogs: [String]

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                TabButton(title: "App Log (\(appLogs.count))", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                TabButton(title: "Backend Log File", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                Spacer()

                Text("~/Library/Logs/Ronin/backend.log")
                    .font(.matrixCaption2)
                    .foregroundColor(.matrixFaded)
                    .padding(.trailing, 8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let lines = selectedTab == 0 ? appLogs : backendLogs
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.matrixCaption2)
                                .foregroundColor(logColor(for: line))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: appLogs.count) { _, _ in
                    if selectedTab == 0, let last = appLogs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.matrixBlack)
    }

    private func logColor(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("error") { return .matrixStatusError }
        if line.contains("WARNING") || line.contains("warn") { return .matrixWarning }
        return .matrixDim
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.matrixCaption2)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.matrixNeon.opacity(0.2) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .matrixNeon : .matrixFaded)
    }
}

// MARK: - Window Drag Enabler

/// Makes a `.plain` style window draggable by its background.
/// Without this, windows with `.windowStyle(.plain)` have no title bar
/// and cannot be moved by the user.
struct WindowDragEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowDragNSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isMovableByWindowBackground = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private class WindowDragNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isMovableByWindowBackground = true
    }
}

// Audio level mini-meter
struct AudioLevelView: View {
    let level: Float
    let isMuted: Bool

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.matrixBorder.opacity(0.3))
                .overlay(alignment: .leading) {
                    if !isMuted {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: max(2, geo.size.width * CGFloat(min(level * 10, 1.0))))
                    }
                }
        }
    }

    private var barColor: Color {
        if level > 0.08 { return .matrixStatusError }
        if level > 0.04 { return .matrixWarning }
        return .matrixNeon
    }
}
