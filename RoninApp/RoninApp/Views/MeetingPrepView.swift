import SwiftUI
import UniformTypeIdentifiers

struct MeetingPrepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backendService: BackendProcessService
    @EnvironmentObject var copilotVM: LiveCopilotViewModel
    @EnvironmentObject var tutorialVM: TutorialViewModel
    @StateObject private var viewModel = MeetingPrepViewModel()
    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("> MEETING_PREP")
                        .font(.matrixLargeTitle)
                        .foregroundColor(.matrixNeon)
                        .matrixGlow(radius: 8)

                    Spacer()

                    // Compact backend status (shown when all checks pass)
                    if backendService.status.isRunning && backendService.allDependenciesPassed {
                        backendStatusBadge
                    }

                    // Tutorial button
                    Button {
                        tutorialVM.relaunchTutorial()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.title2)
                            .foregroundColor(.matrixDim)
                    }
                    .buttonStyle(.plain)
                    .help("Show Tutorial")

                    // Settings gear button
                    SettingsLink {
                        Image(systemName: "gear")
                            .font(.title2)
                            .foregroundColor(.matrixDim)
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
                }

                // Dependency checklist (shown during startup or when checks are incomplete/failed)
                if !backendService.status.isRunning || !backendService.allDependenciesPassed {
                    DependencyChecklistView(
                        dependencies: backendService.dependencies,
                        onRetry: { backendService.restart() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Meeting Info
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Meeting Title", text: $viewModel.title)
                        .textFieldStyle(MatrixTextFieldStyle())

                    TextField("Meeting Goal (e.g., Negotiate contract terms)", text: $viewModel.goal)
                        .textFieldStyle(MatrixTextFieldStyle())
                }
                .matrixGroupBox(title: "MEETING_INFO")

                // Notes Pack
                VStack(alignment: .leading, spacing: 12) {
                    // Drop zone
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isTargeted ? Color.matrixNeon : Color.matrixBorder,
                            style: StrokeStyle(lineWidth: 2, dash: [6])
                        )
                        .frame(height: 80)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "doc.badge.plus")
                                    .font(.title2)
                                    .foregroundColor(.matrixDim)
                                Text("Drop files here — PDF, Word, Excel, PowerPoint, text")
                                    .font(.matrixCaption)
                                    .foregroundColor(.matrixDim)
                            }
                        }
                        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                            handleDrop(providers: providers)
                            return true
                        }

                    Button("Choose Files...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.allowedContentTypes = MeetingPrepViewModel.supportedNoteTypes
                        if panel.runModal() == .OK {
                            viewModel.addNoteFiles(urls: panel.urls)
                        }
                    }
                    .buttonStyle(MatrixSecondaryButtonStyle())

                    ForEach(viewModel.noteFiles) { file in
                        HStack {
                            Image(systemName: MeetingPrepViewModel.iconForFile(named: file.name))
                                .foregroundColor(.matrixDim)
                            Text(file.name)
                                .font(.matrixBody)
                                .foregroundColor(.matrixText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(file.content.count) chars")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixFaded)
                            Button(role: .destructive) {
                                if let idx = viewModel.noteFiles.firstIndex(where: { $0.id == file.id }) {
                                    viewModel.noteFiles.remove(at: idx)
                                }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.matrixStatusError)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .matrixGroupBox(title: "NOTES_PACK")

                // Constraints
                VStack(alignment: .leading, spacing: 8) {
                    Text("Optional rules the copilot should follow")
                        .font(.matrixCaption)
                        .foregroundColor(.matrixFaded)
                    TextEditor(text: $viewModel.constraints)
                        .font(.matrixBody)
                        .foregroundColor(.matrixBright)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color.matrixBlack)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.matrixBorder, lineWidth: 1)
                        )
                }
                .matrixGroupBox(title: "CONSTRAINTS")

                // Error message with dismiss
                if let error = viewModel.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.matrixWarning)
                        Text(error)
                            .font(.matrixBody)
                            .foregroundColor(.matrixWarning)
                        Spacer()
                        Button {
                            viewModel.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color.matrixWarning.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.matrixWarning.opacity(0.3), lineWidth: 1)
                    )
                }

                // Start Button
                Button(action: {
                    Task {
                        // Save meeting config for native copilot before clearing prep data
                        let config = MeetingConfig(
                            title: viewModel.title,
                            goal: viewModel.goal,
                            constraints: viewModel.constraints,
                            notes: viewModel.noteFiles
                        )
                        copilotVM.meetingConfig = config
                        copilotVM.accumulatedNotes = viewModel.noteFiles.map { $0.content }.joined(separator: "\n")

                        if let response = await viewModel.startMeeting() {
                            appState.sessionId = response.session_id
                            appState.meetingTitle = viewModel.title
                            viewModel.clearPrepData()
                            appState.phase = .live
                        }
                    }
                }) {
                    HStack {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.matrixBlack)
                        } else {
                            Image(systemName: "mic.fill")
                        }
                        Text(viewModel.isLoading ? "Connecting..." : "Start Listening")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MatrixPrimaryButtonStyle())
                .disabled(!viewModel.canStart(backendStatus: backendService.status))
            }
            .padding(32)
        }
        .background(Color.matrixBlack)
        .matrixScanlines()
        .frame(minWidth: 500, minHeight: 500)
        .onAppear {
            viewModel.setAuthToken(backendService.authToken)
        }
        .onChange(of: backendService.authToken) { _, token in
            viewModel.setAuthToken(token)
        }
    }

    @ViewBuilder
    private var backendStatusBadge: some View {
        HStack(spacing: 6) {
            switch backendService.status {
            case .stopped, .starting:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.matrixDim)
                Text(backendService.status.message)
                    .font(.matrixCaption)
                    .foregroundColor(.matrixDim)
            case .running:
                Circle()
                    .fill(Color.matrixStatusActive)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.matrixStatusActive.opacity(0.6), radius: 4)
                Text("Backend online")
                    .font(.matrixCaption)
                    .foregroundColor(.matrixDim)

                // LLM provider indicator
                let provider = LLMSettingsViewModel.currentProvider
                Text("·")
                    .foregroundColor(.matrixFaded)
                Text(provider.shortLabel)
                    .font(.matrixCaption)
                    .foregroundColor(provider.isAppleIntelligence ? .matrixCyan
                                     : provider.isCloud ? .matrixWarning : .matrixNeon)
                    .matrixGlow(radius: 2)
            case .failed(let msg):
                Circle()
                    .fill(Color.matrixStatusError)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.matrixStatusError.opacity(0.6), radius: 4)
                Text(msg)
                    .font(.matrixCaption)
                    .foregroundColor(.matrixStatusError)
                    .lineLimit(1)
                Button("Retry") {
                    backendService.restart()
                }
                .font(.matrixCaption)
                .buttonStyle(MatrixSecondaryButtonStyle())
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    viewModel.addNoteFiles(urls: [url])
                }
            }
        }
    }
}
