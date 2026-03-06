import SwiftUI

@MainActor
class AppState: ObservableObject {
    enum Phase {
        case prep
        case live
        case postMeeting
    }

    @Published var phase: Phase = .prep
    @Published var sessionId: String?
    @Published var meetingTitle: String = ""
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var backendService: BackendProcessService?

    func applicationWillTerminate(_ notification: Notification) {
        // Use synchronous stop — blocks until the Python process is dead.
        // This prevents orphaned backend processes when the app exits.
        AppDelegate.backendService?.stopSync()
    }
}

@main
struct RoninApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var backendService = BackendProcessService()
    @StateObject private var copilotViewModel = LiveCopilotViewModel()
    @StateObject private var tutorialViewModel = TutorialViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Main window
        WindowGroup("Ronin") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(backendService)
                .environmentObject(copilotViewModel)
                .environmentObject(tutorialViewModel)
                .onAppear {
                    AppDelegate.backendService = backendService
                    backendService.observeSettingsChanges()
                    backendService.start()
                }
        }

        // Floating copilot overlay
        WindowGroup(id: "copilot-overlay") {
            LiveCopilotView()
                .environmentObject(appState)
                .environmentObject(backendService)
                .environmentObject(copilotViewModel)
        }
        .windowLevel(.floating)
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 400)

        // Menu bar icon for discrete control
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
                .environmentObject(copilotViewModel)
        } label: {
            Image(systemName: menuBarIconName)
        }

        // Global keyboard shortcuts
        .commands {
            RoninCommands(appState: appState, copilotViewModel: copilotViewModel)
        }

        // Settings window (Cmd+,)
        Settings {
            SettingsView()
                .environmentObject(copilotViewModel)
                .environmentObject(tutorialViewModel)
        }
    }

    private var menuBarIconName: String {
        guard appState.phase == .live else { return "waveform" }
        if copilotViewModel.isPaused { return "pause.circle" }
        return "waveform.circle.fill"
    }
}

// MARK: - Menu Bar Menu

struct MenuBarMenu: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var vm: LiveCopilotViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var isMeetingActive: Bool {
        appState.phase == .live
    }

    var body: some View {
        // Meeting status
        if isMeetingActive {
            Text(vm.isPaused ? "Paused — \(vm.formattedTime)" : "Recording — \(vm.formattedTime)")
        } else {
            Text("No active meeting")
        }

        Divider()

        // Overlay visibility
        Button(vm.overlayVisible ? "Hide Overlay" : "Show Overlay") {
            toggleOverlay()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(!isMeetingActive)

        Button(vm.isCompact ? "Full Mode" : "Compact Mode") {
            vm.toggleCompact()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(!isMeetingActive)

        // Layout orientation submenu
        Menu("Layout") {
            ForEach(LiveCopilotViewModel.LayoutOrientation.allCases) { orientation in
                Button {
                    vm.layoutOrientation = orientation
                } label: {
                    HStack {
                        Text(orientation.label)
                        if vm.layoutOrientation == orientation {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .disabled(!isMeetingActive)

        Divider()

        // Meeting controls
        Button(vm.isMuted ? "Unmute" : "Mute") {
            vm.toggleMute()
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!isMeetingActive)

        Button(vm.isPaused ? "Resume" : "Pause") {
            vm.togglePause()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!isMeetingActive)

        Divider()

        Button("End Meeting") {
            vm.showEndConfirmation = true
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!isMeetingActive)

        Divider()

        Button("Debug Console") {
            vm.showDebugConsole.toggle()
        }

        Divider()

        // Opacity submenu with current-value indicator
        Menu("Overlay Opacity (\(Int(vm.overlayOpacity * 100))%)") {
            ForEach([1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4], id: \.self) { value in
                Button {
                    vm.overlayOpacity = value
                } label: {
                    HStack {
                        Text("\(Int(value * 100))%")
                        if abs(vm.overlayOpacity - value) < 0.01 {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Divider()

        Button("Quit Ronin") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func toggleOverlay() {
        if vm.overlayVisible {
            dismissWindow(id: "copilot-overlay")
            vm.overlayVisible = false
        } else {
            openWindow(id: "copilot-overlay")
            vm.overlayVisible = true
        }
    }
}

// MARK: - Global Keyboard Shortcuts

struct RoninCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var copilotViewModel: LiveCopilotViewModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Toggle Debug Console") {
                copilotViewModel.showDebugConsole.toggle()
            }
            .keyboardShortcut("d", modifiers: .command)
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var copilotViewModel: LiveCopilotViewModel
    @EnvironmentObject var tutorialVM: TutorialViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch appState.phase {
            case .prep:
                ZStack {
                    MeetingPrepView()

                    if tutorialVM.isShowingTutorial {
                        TutorialOverlayView()
                            .environmentObject(tutorialVM)
                            .transition(.opacity)
                    }
                }
                .onAppear {
                    tutorialVM.checkFirstLaunch()
                }
            case .live:
                // Minimal live view — overlay + menu bar are the primary interfaces
                VStack(spacing: 20) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.matrixNeon)
                        .matrixGlow(radius: 12)
                        .symbolEffect(.pulse, isActive: !copilotViewModel.isPaused)

                    Text("Meeting in progress")
                        .font(.matrixTitle)
                        .foregroundColor(.matrixDim)

                    Text(copilotViewModel.formattedTime)
                        .font(.matrixTitle)
                        .foregroundColor(.matrixBright)
                        .matrixGlow(radius: 4)

                    Text("Use the floating overlay or menu bar icon to control the meeting.")
                        .font(.matrixCaption)
                        .foregroundColor(.matrixFaded)
                        .multilineTextAlignment(.center)

                    Button("End Meeting") {
                        copilotViewModel.showEndConfirmation = true
                    }
                    .buttonStyle(MatrixDestructiveButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.matrixBlack)
                .confirmationDialog("End Meeting?", isPresented: $copilotViewModel.showEndConfirmation) {
                    Button("End Meeting", role: .destructive) {
                        // Defer everything to next run-loop tick to avoid
                        // "Publishing changes from within view updates"
                        DispatchQueue.main.async { [self] in
                            copilotViewModel.endMeeting()
                            dismissWindow(id: "copilot-overlay")
                            copilotViewModel.overlayVisible = false
                            appState.phase = .postMeeting
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will stop recording and generate a meeting summary.")
                }
            case .postMeeting:
                PostMeetingView()
            }
        }
        .onChange(of: appState.phase) { _, newPhase in
            if newPhase == .live {
                copilotViewModel.overlayVisible = true
                openWindow(id: "copilot-overlay")
                // Auto-minimize main window so the overlay + menu bar are primary
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApplication.shared.windows.first { $0.title == "Ronin" }?.miniaturize(nil)
                }
            } else if newPhase == .postMeeting {
                dismissWindow(id: "copilot-overlay")
                copilotViewModel.overlayVisible = false
                // Restore main window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApplication.shared.windows.first { $0.title == "Ronin" }?.deminiaturize(nil)
                }
            }
        }
    }
}
