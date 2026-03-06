import SwiftUI

struct PostMeetingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backendService: BackendProcessService
    @StateObject private var viewModel = PostMeetingViewModel()

    var body: some View {
        ZStack {
            Group {
                if viewModel.isLoading {
                    summaryLoadingView
                } else if let summary = viewModel.summary {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Text("> \(appState.meetingTitle.uppercased())")
                                .font(.matrixLargeTitle)
                                .foregroundColor(.matrixNeon)
                                .matrixGlow(radius: 8)

                            // Executive Summary
                            VStack(alignment: .leading, spacing: 8) {
                                Text(summary.executive_summary)
                                    .font(.matrixBody)
                                    .foregroundColor(.matrixText)
                                    .textSelection(.enabled)
                            }
                            .matrixGroupBox(title: "EXECUTIVE_SUMMARY")

                            if !summary.decisions.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(summary.decisions) { d in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(d.decision)
                                                .font(.matrixBodyBold)
                                                .foregroundColor(.matrixText)
                                            Text(d.context)
                                                .font(.matrixCaption)
                                                .foregroundColor(.matrixDim)
                                        }
                                    }
                                }
                                .matrixGroupBox(title: "KEY_DECISIONS")
                            }

                            if !summary.action_items.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(summary.action_items) { item in
                                        HStack(alignment: .top) {
                                            Image(systemName: "circle")
                                                .font(.matrixCaption)
                                                .foregroundColor(.matrixDim)
                                                .padding(.top, 3)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.action)
                                                    .font(.matrixBody)
                                                    .foregroundColor(.matrixText)
                                                HStack(spacing: 8) {
                                                    if !item.assignee.isEmpty {
                                                        Label(item.assignee, systemImage: "person")
                                                            .font(.matrixCaption)
                                                            .foregroundColor(.matrixFaded)
                                                    }
                                                    if !item.deadline.isEmpty {
                                                        Label(item.deadline, systemImage: "calendar")
                                                            .font(.matrixCaption)
                                                            .foregroundColor(.matrixFaded)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .matrixGroupBox(title: "ACTION_ITEMS")
                            }

                            if !summary.unresolved.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(summary.unresolved, id: \.self) { q in
                                        Label(q, systemImage: "questionmark.circle")
                                            .font(.matrixBody)
                                            .foregroundColor(.matrixCyan)
                                    }
                                }
                                .matrixGroupBox(title: "OPEN_QUESTIONS")
                            }

                            HStack(spacing: 12) {
                                Button("Export to Markdown") {
                                    viewModel.exportMarkdown()
                                }
                                .buttonStyle(MatrixPrimaryButtonStyle())

                                Button("Copy Summary") {
                                    viewModel.copyToClipboard()
                                }
                                .buttonStyle(MatrixSecondaryButtonStyle())

                                Spacer()

                                Button("New Meeting") {
                                    appState.phase = .prep
                                    appState.sessionId = nil
                                }
                                .buttonStyle(MatrixSecondaryButtonStyle())
                            }
                        }
                        .padding(32)
                    }
                } else if let error = viewModel.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.matrixWarning)
                        Text(error)
                            .font(.matrixBody)
                            .foregroundColor(.matrixDim)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 12) {
                            Button("Retry") {
                                Task { await viewModel.retry() }
                            }
                            .buttonStyle(MatrixPrimaryButtonStyle())

                            Button("Back to Prep") {
                                appState.phase = .prep
                            }
                            .buttonStyle(MatrixSecondaryButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Success toast
            if let msg = viewModel.successMessage {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.matrixStatusActive)
                        Text(msg)
                            .font(.matrixCaption)
                            .foregroundColor(.matrixBright)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.matrixSurface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.matrixBorder, lineWidth: 1)
                    )
                    .padding(.top, 12)

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: viewModel.successMessage != nil)
            }
        }
        .background(Color.matrixBlack)
        .matrixScanlines()
        .frame(minWidth: 600, minHeight: 500)
        .onAppear {
            viewModel.meetingTitle = appState.meetingTitle
            viewModel.setAuthToken(backendService.authToken)
            if let sessionId = appState.sessionId {
                Task {
                    await viewModel.loadSummary(sessionId: sessionId)
                }
            }
        }
    }

    // MARK: - Summary Loading View with Progress

    private var summaryLoadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Phase icon with pulse animation
            Image(systemName: viewModel.progressPhase.icon)
                .font(.system(size: 40))
                .foregroundColor(.matrixNeon)
                .matrixGlow(radius: 10)
                .symbolEffect(.pulse, isActive: true)

            Text("Generating meeting summary")
                .font(.matrixHeadline)
                .foregroundColor(.matrixBright)

            // Phase status text
            Text(viewModel.progressPhase.rawValue)
                .font(.matrixBody)
                .foregroundColor(.matrixDim)
                .animation(.easeInOut(duration: 0.3), value: viewModel.progressPhase.rawValue)

            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.matrixBorder.opacity(0.3))
                            .frame(height: 6)

                        // Fill
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [Color.matrixNeon.opacity(0.7), Color.matrixNeon],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * viewModel.estimatedProgress), height: 6)
                            .animation(.easeInOut(duration: 0.8), value: viewModel.estimatedProgress)

                        // Glow on leading edge of fill
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.matrixNeon)
                            .frame(width: 2, height: 6)
                            .offset(x: max(0, geo.size.width * viewModel.estimatedProgress - 2))
                            .shadow(color: Color.matrixNeon.opacity(0.8), radius: 4)
                            .animation(.easeInOut(duration: 0.8), value: viewModel.estimatedProgress)
                    }
                }
                .frame(height: 6)

                // Elapsed time
                Text(elapsedTimeString)
                    .font(.matrixCaption)
                    .foregroundColor(.matrixFaded)
            }
            .frame(maxWidth: 320)

            // Reassurance text after 10 seconds
            if viewModel.elapsedSeconds >= 10 {
                Text("Transcript saved — summary is being generated by LLM")
                    .font(.matrixCaption)
                    .foregroundColor(.matrixFaded)
                    .transition(.opacity)
            }

            // Long wait message after 30 seconds
            if viewModel.elapsedSeconds >= 30 {
                Text("This is taking longer than usual. The LLM may be processing a large transcript.")
                    .font(.matrixCaption)
                    .foregroundColor(.matrixWarning)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.5), value: viewModel.elapsedSeconds)
    }

    private var elapsedTimeString: String {
        let seconds = viewModel.elapsedSeconds
        if seconds < 60 {
            return "\(seconds)s elapsed"
        }
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes)m \(secs)s elapsed"
    }
}
