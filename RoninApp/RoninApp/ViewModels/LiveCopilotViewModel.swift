import AppKit
import Foundation
import SwiftUI
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
    @Published var copilotHistory: [CopilotSnapshot] = []

    // Question detection highlight
    @Published var questionDetected: Bool = false
    @Published var lastQuestionSegmentId: UUID?
    private var questionHighlightTimer: DispatchWorkItem?

    /// Latest suggestions (for compact view and badge counts)
    var suggestions: [Suggestion] { copilotHistory.last?.suggestions ?? [] }
    /// Latest guidance (for compact view)
    var guidance: CopilotGuidance { copilotHistory.last?.guidance ?? .empty }
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

    // Native copilot (Apple Intelligence)
    private(set) var nativeCopilotService: NativeCopilotService?
    var meetingConfig: MeetingConfig?
    var accumulatedNotes: String = ""

    /// Whether native (on-device) copilot is active for this session
    var isNativeCopilot: Bool {
        nativeCopilotService != nil
    }

    private var audioService: AudioCaptureService?
    private var wsService: WebSocketService?
    private var timer: Timer?
    private let maxDebugLines = 300
    private var hasEnded = false  // Re-entrancy guard for endMeeting()

    func connect() {
        statusText = "Connecting..."
        addDebug("Starting connection...")

        // Configure native copilot if Apple Intelligence is selected
        let currentProvider = LLMSettingsViewModel.currentProvider
        if currentProvider.isAppleIntelligence {
            let service = NativeCopilotService()
            if service.configureFoundationModels() {
                nativeCopilotService = service
                addDebug("🧠 Apple Intelligence copilot configured (on-device)")
            } else {
                addDebug("⚠️ Apple Intelligence not available — copilot suggestions disabled")
                nativeCopilotService = nil
            }
        } else {
            nativeCopilotService = nil
        }

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
            addDebug("📝 Transcript (\(segment.isFinal ? "final" : "partial")): \"\(segment.text.prefix(60))\"")

            // Streaming transcript: partial segments ALWAYS replace the
            // previous partial (text grows in-place). Speaker check is
            // intentionally removed — speaker identification is non-
            // deterministic (sometimes "", sometimes "Speaker N" for
            // the same audio), so requiring a match caused partials to
            // leak as duplicate lines. Final segments commit the
            // utterance and start a new line.
            if let lastIndex = transcriptSegments.indices.last,
               !transcriptSegments[lastIndex].isFinal {
                // Replace in-place, preserving original id + timestamp for SwiftUI stability
                transcriptSegments[lastIndex] = TranscriptSegment(
                    id: transcriptSegments[lastIndex].id,
                    text: segment.text,
                    timestamp: transcriptSegments[lastIndex].timestamp,
                    speaker: segment.speaker.isEmpty ? transcriptSegments[lastIndex].speaker : segment.speaker,
                    isFinal: segment.isFinal
                )
            } else {
                transcriptSegments.append(segment)
            }

            statusText = "Transcribing..."
            if segment.isQuestion {
                triggerQuestionHighlight(segmentId: segment.id)
            }
            // Trigger native copilot if Apple Intelligence is active
            if nativeCopilotService != nil {
                triggerNativeCopilot()
            }
        case .copilotResponse(let response):
            addDebug("💡 Copilot: \(response.suggestions.count) suggestions, \(response.follow_up_questions.count) questions")
            appendCopilotResponse(response)
        case .error(let msg):
            addDebug("🔴 Backend error: \(msg)")
            errorMessage = msg
            scheduleErrorDismiss()
        }
    }

    /// Append a copilot response to history (shared by backend and native paths).
    private func appendCopilotResponse(_ response: CopilotResponse) {
        let guidance = CopilotGuidance(
            followUpQuestions: response.follow_up_questions,
            risks: response.risks,
            factsFromNotes: response.facts_from_notes
        )
        // Skip empty responses (e.g., from LLM rate-limit errors / 429s)
        guard !response.suggestions.isEmpty || !guidance.isEmpty else {
            addDebug("⚠️ Empty copilot response — skipping")
            return
        }
        let snapshot = CopilotSnapshot(
            timestamp: Date(),
            suggestions: response.suggestions,
            guidance: guidance
        )
        copilotHistory.append(snapshot)
    }

    // MARK: - Native Copilot (Apple Intelligence)

    /// Trigger on-device copilot generation. Debounce/in-flight handled by NativeCopilotService.
    private func triggerNativeCopilot() {
        guard let service = nativeCopilotService,
              let config = meetingConfig else { return }

        // Collect recent transcript (~1.5 minutes worth, ~20 segments/minute)
        let recentCount = min(transcriptSegments.count, 30)
        let recentSegments = transcriptSegments.suffix(recentCount)
        let transcriptWindow = recentSegments.map { $0.text }.joined(separator: "\n")

        guard !transcriptWindow.isEmpty else { return }

        Task {
            do {
                let response = try await service.generateCopilotResponse(
                    transcriptWindow: transcriptWindow,
                    config: config,
                    relevantNotes: accumulatedNotes
                )
                addDebug("🧠 Native copilot: \(response.suggestions.count) suggestions")
                appendCopilotResponse(response)
            } catch let error as NativeCopilotError {
                switch error {
                case .debounced, .inFlight:
                    break // Expected — silently skip
                default:
                    addDebug("⚠️ Native copilot error: \(error.localizedDescription ?? "unknown")")
                }
            } catch {
                addDebug("⚠️ Native copilot error: \(error.localizedDescription)")
            }
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
        nativeCopilotService?.reset()

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

    /// Reset transient state for a new meeting (keeps persisted prefs).
    /// Note: `meetingConfig` and `accumulatedNotes` are preserved — they are
    /// set by MeetingPrepView before the phase transition to `.live` and must
    /// survive the reset that happens in LiveCopilotView's `.onAppear`.
    func resetForNewMeeting() {
        hasEnded = false
        transcriptSegments = []
        copilotHistory = []
        questionDetected = false
        lastQuestionSegmentId = nil
        questionHighlightTimer?.cancel()
        questionHighlightTimer = nil
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
        nativeCopilotService?.reset()
        nativeCopilotService = nil
    }

    // MARK: - Question Highlight

    /// Trigger a pulsing cyan glow on copilot panels when a question is detected.
    /// Consecutive questions cancel/restart the 4-second auto-reset timer.
    private func triggerQuestionHighlight(segmentId: UUID) {
        // Cancel any pending reset
        questionHighlightTimer?.cancel()

        // Activate highlight with fade-in
        lastQuestionSegmentId = segmentId
        withAnimation(.easeIn(duration: 0.3)) {
            questionDetected = true
        }

        addDebug("❓ Question detected — highlighting panels")

        // Schedule auto-reset after 4 seconds
        let resetWork = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.8)) {
                self?.questionDetected = false
            }
        }
        questionHighlightTimer = resetWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: resetWork)
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
