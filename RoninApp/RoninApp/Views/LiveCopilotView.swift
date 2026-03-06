import AppKit
import SwiftUI

struct LiveCopilotView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backendService: BackendProcessService
    @EnvironmentObject var viewModel: LiveCopilotViewModel

    // Resizable panel proportions (persisted)
    @AppStorage("ronin.transcriptProportion") private var transcriptProportion: Double = 0.30
    @AppStorage("ronin.guidanceProportion") private var guidanceProportion: Double = 0.27
    // Suggestions gets: 1.0 - transcriptProportion - guidanceProportion

    // Drag state for dividers
    @State private var divider1DragStart: Double?
    @State private var divider2DragStart: Double?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Clean title bar
                titleBar

                Divider().overlay(Color.matrixDivider)

                // Inline error banner (replaces blocking alert)
                if let error = viewModel.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.matrixStatusError)
                        Text(error)
                            .font(.matrixCaption)
                            .foregroundColor(.matrixStatusError)
                            .lineLimit(2)
                        Spacer()
                        Button("Retry") {
                            viewModel.errorMessage = nil
                            viewModel.connect()
                        }
                        .font(.matrixBadge)
                        .buttonStyle(MatrixSecondaryButtonStyle())
                        Button {
                            viewModel.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.matrixStatusError.opacity(0.1))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Collapsible debug console
                if viewModel.showDebugConsole {
                    VStack(spacing: 0) {
                        // Clickable header bar
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.debugConsoleExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: viewModel.debugConsoleExpanded ? "chevron.down" : "chevron.right")
                                    .font(.matrixCaption2)
                                    .foregroundColor(.matrixFaded)
                                Text("Debug Console")
                                    .font(.matrixCaption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.matrixFaded)
                                Text("(\(viewModel.debugLog.count) lines)")
                                    .font(.matrixCaption2)
                                    .foregroundColor(.matrixFaded)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.matrixBar)
                        }
                        .buttonStyle(.plain)

                        if viewModel.debugConsoleExpanded {
                            DebugConsoleView(
                                appLogs: viewModel.debugLog,
                                backendLogs: []
                            )
                            .frame(maxHeight: 120)
                        }
                    }

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
            maxWidth: .infinity,
            minHeight: viewModel.isCompact ? 200 : 300,
            maxHeight: .infinity
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
            viewModel.authToken = backendService.authToken
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
                        Text(suggestion.toneLabel)
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

            // Compact guidance strip — first risk + badge counts
            if !viewModel.guidance.isEmpty {
                HStack(spacing: 8) {
                    // First risk warning (most critical)
                    if let firstRisk = viewModel.guidance.risks.first {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.matrixCaption2)
                            .foregroundColor(.matrixWarning)
                        Text(firstRisk.warning)
                            .font(.matrixCaption2)
                            .foregroundColor(.matrixWarning)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Badge counts
                    if !viewModel.guidance.followUpQuestions.isEmpty {
                        Label("\(viewModel.guidance.followUpQuestions.count)", systemImage: "questionmark.circle")
                            .font(.matrixBadge)
                            .foregroundColor(.matrixCyan)
                    }
                    if !viewModel.guidance.risks.isEmpty {
                        Label("\(viewModel.guidance.risks.count)", systemImage: "exclamationmark.triangle")
                            .font(.matrixBadge)
                            .foregroundColor(.matrixWarning)
                    }
                    if !viewModel.guidance.factsFromNotes.isEmpty {
                        Label("\(viewModel.guidance.factsFromNotes.count)", systemImage: "doc.text")
                            .font(.matrixBadge)
                            .foregroundColor(.matrixGreen)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.matrixSurface.opacity(0.5))

                Divider().overlay(Color.matrixDivider)
            }

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

    // MARK: - Full Content (adaptive 3-panel)

    /// Determines whether panels should stack vertically based on orientation setting.
    private func shouldUseVerticalLayout(in size: CGSize) -> Bool {
        switch viewModel.layoutOrientation {
        case .horizontal: return false
        case .vertical: return true
        case .auto: return size.height > size.width * 1.2
        }
    }

    // MARK: - Full Content (resizable 3-panel)

    /// Minimum proportion for any panel (prevents collapsing below usable size)
    private let minProportion: Double = 0.15
    /// Minimum proportion for the middle (suggestions) panel
    private let minMiddle: Double = 0.20

    private var fullContent: some View {
        GeometryReader { geo in
            let vertical = shouldUseVerticalLayout(in: geo.size)

            if vertical {
                verticalResizableLayout(totalSize: geo.size.height)
            } else {
                horizontalResizableLayout(totalSize: geo.size.width)
            }
        }
    }

    private func horizontalResizableLayout(totalSize: CGFloat) -> some View {
        let dividerWidth = MatrixSpacing.dividerGrabWidth
        let available = totalSize - dividerWidth * 2
        let w1 = max(200, available * transcriptProportion)
        let w3 = max(180, available * guidanceProportion)
        // Suggestions gets the rest
        let w2 = max(220, available - w1 - w3)

        return HStack(spacing: 0) {
            TranscriptPanelView(segments: viewModel.transcriptSegments)
                .frame(width: w1)
                .background(Color.matrixPanel)

            // Divider 1: between Transcript and Suggestions
            PanelDivider(isVertical: true)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if divider1DragStart == nil {
                                divider1DragStart = transcriptProportion
                            }
                            let delta = Double(value.translation.width) / Double(available)
                            let proposed = divider1DragStart! + delta
                            let maxVal = 1.0 - guidanceProportion - minMiddle
                            transcriptProportion = max(minProportion, min(maxVal, proposed))
                        }
                        .onEnded { _ in
                            divider1DragStart = nil
                        }
                )

            SuggestionsPanelView(suggestions: viewModel.suggestions, onCopy: { viewModel.copyText($0) })
                .frame(width: w2)
                .background(Color.matrixPanel)

            // Divider 2: between Suggestions and Guidance
            PanelDivider(isVertical: true)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if divider2DragStart == nil {
                                divider2DragStart = guidanceProportion
                            }
                            let delta = Double(value.translation.width) / Double(available)
                            let proposed = divider2DragStart! - delta // dragging right shrinks guidance
                            let maxVal = 1.0 - transcriptProportion - minMiddle
                            guidanceProportion = max(minProportion, min(maxVal, proposed))
                        }
                        .onEnded { _ in
                            divider2DragStart = nil
                        }
                )

            GuidancePanelView(guidance: viewModel.guidance)
                .frame(minWidth: 180, maxWidth: .infinity)
                .background(Color.matrixPanel)
        }
    }

    private func verticalResizableLayout(totalSize: CGFloat) -> some View {
        let dividerHeight = MatrixSpacing.dividerGrabWidth
        let available = totalSize - dividerHeight * 2
        let h1 = max(100, available * transcriptProportion)
        let h3 = max(80, available * guidanceProportion)
        let h2 = max(100, available - h1 - h3)

        return VStack(spacing: 0) {
            TranscriptPanelView(segments: viewModel.transcriptSegments)
                .frame(height: h1)
                .background(Color.matrixPanel)

            PanelDivider(isVertical: false)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if divider1DragStart == nil {
                                divider1DragStart = transcriptProportion
                            }
                            let delta = Double(value.translation.height) / Double(available)
                            let proposed = divider1DragStart! + delta
                            let maxVal = 1.0 - guidanceProportion - minMiddle
                            transcriptProportion = max(minProportion, min(maxVal, proposed))
                        }
                        .onEnded { _ in divider1DragStart = nil }
                )

            SuggestionsPanelView(suggestions: viewModel.suggestions, onCopy: { viewModel.copyText($0) })
                .frame(height: h2)
                .background(Color.matrixPanel)

            PanelDivider(isVertical: false)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if divider2DragStart == nil {
                                divider2DragStart = guidanceProportion
                            }
                            let delta = Double(value.translation.height) / Double(available)
                            let proposed = divider2DragStart! - delta
                            let maxVal = 1.0 - transcriptProportion - minMiddle
                            guidanceProportion = max(minProportion, min(maxVal, proposed))
                        }
                        .onEnded { _ in divider2DragStart = nil }
                )

            GuidancePanelView(guidance: viewModel.guidance)
                .frame(minHeight: 80, maxHeight: .infinity)
                .background(Color.matrixPanel)
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

// MARK: - Window Drag & Resize Enabler

/// Makes a `.plain` style window draggable and resizable.
/// `.windowStyle(.plain)` strips all macOS window chrome — no title bar,
/// no resize handles. This re-enables both by hooking into the NSWindow:
///  - `isMovableByWindowBackground` lets the user drag anywhere to move
///  - Adding `.resizable` to styleMask gives system resize handles on edges
struct WindowDragEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowDragNSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isMovableByWindowBackground = true
                window.styleMask.insert(.resizable)
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
        window?.styleMask.insert(.resizable)
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
