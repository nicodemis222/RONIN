import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.ronin.app", category: "LiveCopilot")

@MainActor
class LiveCopilotViewModel: ObservableObject {

    // MARK: - Layout Orientation

    enum LayoutOrientation: String, CaseIterable, Identifiable {
        case auto = "auto"
        case horizontal = "horizontal"
        case vertical = "vertical"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .horizontal: return "Horizontal"
            case .vertical: return "Vertical"
            }
        }
    }
    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var suggestions: [Suggestion] = []
    @Published var guidance: CopilotGuidance = .empty
    @Published var isPaused: Bool = false
    @Published var isMuted: Bool = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var audioLevel: Float = 0
    @Published var statusText: String = "Connecting..."
    @Published var showCopiedToast: Bool = false

    // Debug diagnostics
    @Published var debugLog: [String] = []
    @Published var showDebugConsole: Bool = false
    @Published var debugConsoleExpanded: Bool = false
    @Published var audioChunksSent: Int = 0
    @Published var wsMessagesReceived: Int = 0
    @Published var wsCloseCode: String = ""

    // UX state (persisted)
    @Published var isCompact: Bool = UserDefaults.standard.bool(forKey: "ronin.isCompact") {
        didSet { UserDefaults.standard.set(isCompact, forKey: "ronin.isCompact") }
    }
    @Published var overlayOpacity: Double = {
        let stored = UserDefaults.standard.double(forKey: "ronin.overlayOpacity")
        return stored > 0 ? stored : 0.95
    }() {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "ronin.overlayOpacity") }
    }
    @Published var layoutOrientation: LayoutOrientation = {
        if let raw = UserDefaults.standard.string(forKey: "ronin.layoutOrientation"),
           let value = LayoutOrientation(rawValue: raw) {
            return value
        }
        return .auto
    }() {
        didSet { UserDefaults.standard.set(layoutOrientation.rawValue, forKey: "ronin.layoutOrientation") }
    }
    @Published var overlayVisible: Bool = true
    @Published var showEndConfirmation: Bool = false
    @Published var isHovering: Bool = false

    /// Whether a meeting is currently active (connected or connecting)
    var isMeetingActive: Bool {
        isConnected || statusText == "Connecting..."
    }

    var meetingTitle: String = ""
    var authToken: String = ""  // Set from BackendProcessService before connect()

    private var audioService: AudioCaptureService?
    private var wsService: WebSocketService?
    private var timer: Timer?
    private let maxDebugLines = 300
    private var hasEnded = false  // Re-entrancy guard for endMeeting()

    func connect() {
        statusText = "Connecting..."
        addDebug("Starting connection...")

        // Tear down any previous connection before creating a new one
        // (prevents orphaned WebSocket connections that block the backend slot)
        wsService?.disconnect()
        wsService = nil
        audioService?.stopCapture()
        audioService = nil
        timer?.invalidate()
        timer = nil

        // WebSocket — pass auth token for authentication
        guard let wsURL = URL(string: "ws://127.0.0.1:8000/ws/audio") else {
            addDebug("❌ Failed to construct WebSocket URL")
            errorMessage = "Internal error: invalid WebSocket URL"
            return
        }
        addDebug("WebSocket URL: \(wsURL)")
        wsService = WebSocketService(url: wsURL, authToken: authToken)

        wsService?.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                self?.statusText = "Listening..."
                self?.errorMessage = nil
                self?.addDebug("✅ WebSocket connected")
            }
        }

        wsService?.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.wsMessagesReceived += 1
                self?.handleMessage(message)
            }
        }

        wsService?.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                self?.statusText = "Disconnected"
                self?.addDebug("❌ WebSocket disconnected")
            }
        }

        wsService?.onError = { [weak self] error in
            Task { @MainActor in
                self?.statusText = error
                self?.errorMessage = error
                self?.addDebug("⚠️ WS Error: \(error)")
                self?.scheduleErrorDismiss()
            }
        }

        wsService?.connect()

        // Audio with permission check
        addDebug("Setting up audio capture...")
        audioService = AudioCaptureService()
        audioService?.onAudioChunk = { [weak self] data in
            self?.wsService?.sendAudio(data)
            Task { @MainActor in
                guard let self = self else { return }
                self.audioChunksSent += 1
                if self.audioChunksSent <= 3 || self.audioChunksSent % 50 == 0 {
                    self.addDebug("Audio chunk #\(self.audioChunksSent) sent (\(data.count) bytes)")
                }
            }
        }
        audioService?.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                self?.addDebug("🔴 Audio error: \(error)")
            }
        }
        audioService?.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        audioService?.requestPermissionAndStart()
        addDebug("Audio capture: requestPermissionAndStart() called")

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isPaused else { return }
                self.elapsedTime += 1
            }
        }
    }

    private func handleMessage(_ message: ParsedWSMessage) {
        switch message {
        case .transcriptUpdate(let segment):
            addDebug("📝 Transcript: \"\(segment.text.prefix(60))\"")
            transcriptSegments.append(segment)
            statusText = "Transcribing..."
        case .copilotResponse(let response):
            addDebug("💡 Copilot: \(response.suggestions.count) suggestions, \(response.follow_up_questions.count) questions")
            suggestions = response.suggestions
            guidance = CopilotGuidance(
                followUpQuestions: response.follow_up_questions,
                risks: response.risks,
                factsFromNotes: response.facts_from_notes
            )
        case .error(let msg):
            addDebug("🔴 Backend error: \(msg)")
            errorMessage = msg
            scheduleErrorDismiss()
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            audioService?.pause()
            statusText = "Paused"
        } else {
            audioService?.resume()
            statusText = isConnected ? "Listening..." : "Disconnected"
        }
    }

    func toggleMute() {
        isMuted.toggle()
        audioService?.setMuted(isMuted)
    }

    /// End the meeting. Safe to call multiple times (re-entrancy guarded).
    /// Always defers @Published changes to the next run-loop tick to avoid
    /// "Publishing changes from within view updates" when called from
    /// SwiftUI confirmation dialogs, .onChange, or .onDisappear.
    func endMeeting() {
        guard !hasEnded else {
            addDebug("endMeeting() called — already ended, skipping")
            return
        }
        hasEnded = true

        // Tear down services immediately (these are not @Published)
        audioService?.stopCapture()
        wsService?.disconnect()
        timer?.invalidate()
        timer = nil

        // Defer @Published changes to next run-loop tick
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.addDebug("endMeeting() completed")
        }
    }

    func disconnect() {
        endMeeting()
    }

    func toggleCompact() {
        isCompact.toggle()
    }

    /// Reset transient state for a new meeting (keeps persisted prefs)
    func resetForNewMeeting() {
        hasEnded = false
        transcriptSegments = []
        suggestions = []
        guidance = .empty
        isPaused = false
        isMuted = false
        elapsedTime = 0
        isConnected = false
        errorMessage = nil
        audioLevel = 0
        statusText = "Connecting..."
        showCopiedToast = false
        debugLog = []
        debugConsoleExpanded = false
        audioChunksSent = 0
        wsMessagesReceived = 0
        wsCloseCode = ""
        showEndConfirmation = false
    }

    /// Auto-dismiss error banner after 8 seconds
    private func scheduleErrorDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.errorMessage = nil
        }
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showCopiedToast = false
        }
    }

    var formattedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Debug

    private func addDebug(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)"
        logger.debug("\(line)")
        debugLog.append(line)
        if debugLog.count > maxDebugLines {
            debugLog.removeFirst(debugLog.count - maxDebugLines)
        }
    }

    var diagnosticSummary: String {
        """
        WS: \(isConnected ? "connected" : "disconnected") | \
        Audio chunks: \(audioChunksSent) | \
        WS messages: \(wsMessagesReceived) | \
        Transcripts: \(transcriptSegments.count)
        """
    }
}
