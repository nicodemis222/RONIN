import SwiftUI

struct PostMeetingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backendService: BackendProcessService
    @StateObject private var viewModel = PostMeetingViewModel()

    var body: some View {
        ZStack {
            Group {
                if viewModel.isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.matrixNeon)
                        Text("Generating meeting summary...")
                            .font(.matrixHeadline)
                            .foregroundColor(.matrixDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
