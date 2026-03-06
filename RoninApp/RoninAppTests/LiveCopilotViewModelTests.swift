import XCTest
@testable import Ronin

@MainActor
final class LiveCopilotViewModelTests: XCTestCase {

    private var vm: LiveCopilotViewModel!

    override func setUp() {
        super.setUp()
        // Clear persisted state
        UserDefaults.standard.removeObject(forKey: "ronin.isCompact")
        UserDefaults.standard.removeObject(forKey: "ronin.overlayOpacity")
        UserDefaults.standard.removeObject(forKey: "ronin.layoutOrientation")
        vm = LiveCopilotViewModel()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ronin.isCompact")
        UserDefaults.standard.removeObject(forKey: "ronin.overlayOpacity")
        UserDefaults.standard.removeObject(forKey: "ronin.layoutOrientation")
        vm = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertTrue(vm.transcriptSegments.isEmpty)
        XCTAssertTrue(vm.suggestions.isEmpty)
        XCTAssertTrue(vm.guidance.isEmpty)
        XCTAssertFalse(vm.isPaused)
        XCTAssertFalse(vm.isMuted)
        XCTAssertEqual(vm.elapsedTime, 0)
        XCTAssertFalse(vm.isConnected)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.audioLevel, 0)
        XCTAssertFalse(vm.showCopiedToast)
        XCTAssertFalse(vm.showEndConfirmation)
    }

    // MARK: - Toggle Pause

    func testTogglePause() {
        XCTAssertFalse(vm.isPaused)
        vm.togglePause()
        XCTAssertTrue(vm.isPaused)
        XCTAssertEqual(vm.statusText, "Paused")
        vm.togglePause()
        XCTAssertFalse(vm.isPaused)
    }

    // MARK: - Toggle Mute

    func testToggleMute() {
        XCTAssertFalse(vm.isMuted)
        vm.toggleMute()
        XCTAssertTrue(vm.isMuted)
        vm.toggleMute()
        XCTAssertFalse(vm.isMuted)
    }

    // MARK: - Toggle Compact

    func testToggleCompact() {
        XCTAssertFalse(vm.isCompact)
        vm.toggleCompact()
        XCTAssertTrue(vm.isCompact)
    }

    func testCompactPersistsToUserDefaults() {
        vm.isCompact = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ronin.isCompact"))
        vm.isCompact = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "ronin.isCompact"))
    }

    // MARK: - Overlay Opacity

    func testOverlayOpacityDefaultValue() {
        // When no value is stored, default should be 0.95
        XCTAssertEqual(vm.overlayOpacity, 0.95, accuracy: 0.01)
    }

    func testOverlayOpacityPersists() {
        vm.overlayOpacity = 0.7
        XCTAssertEqual(UserDefaults.standard.double(forKey: "ronin.overlayOpacity"), 0.7, accuracy: 0.01)
    }

    // MARK: - Layout Orientation

    func testLayoutOrientationDefault() {
        XCTAssertEqual(vm.layoutOrientation, .auto)
    }

    func testLayoutOrientationPersists() {
        vm.layoutOrientation = .vertical
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "ronin.layoutOrientation"),
            "vertical"
        )
    }

    func testLayoutOrientationAllCases() {
        let cases = LiveCopilotViewModel.LayoutOrientation.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertTrue(cases.contains(.auto))
        XCTAssertTrue(cases.contains(.horizontal))
        XCTAssertTrue(cases.contains(.vertical))
    }

    func testLayoutOrientationLabels() {
        XCTAssertEqual(LiveCopilotViewModel.LayoutOrientation.auto.label, "Auto")
        XCTAssertEqual(LiveCopilotViewModel.LayoutOrientation.horizontal.label, "Horizontal")
        XCTAssertEqual(LiveCopilotViewModel.LayoutOrientation.vertical.label, "Vertical")
    }

    // MARK: - Reset For New Meeting

    func testResetForNewMeeting() {
        // Set various state
        vm.isPaused = true
        vm.isMuted = true
        vm.elapsedTime = 120
        vm.isConnected = true
        vm.errorMessage = "some error"
        vm.audioLevel = 0.5
        vm.showCopiedToast = true
        vm.debugConsoleExpanded = true
        vm.audioChunksSent = 50
        vm.wsMessagesReceived = 30
        vm.showEndConfirmation = true

        vm.resetForNewMeeting()

        XCTAssertFalse(vm.isPaused)
        XCTAssertFalse(vm.isMuted)
        XCTAssertEqual(vm.elapsedTime, 0)
        XCTAssertFalse(vm.isConnected)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.audioLevel, 0)
        XCTAssertEqual(vm.statusText, "Connecting...")
        XCTAssertFalse(vm.showCopiedToast)
        XCTAssertFalse(vm.debugConsoleExpanded)
        XCTAssertEqual(vm.audioChunksSent, 0)
        XCTAssertEqual(vm.wsMessagesReceived, 0)
        XCTAssertFalse(vm.showEndConfirmation)
    }

    func testResetKeepsPersistedPrefs() {
        vm.isCompact = true
        vm.overlayOpacity = 0.6
        vm.layoutOrientation = .vertical

        vm.resetForNewMeeting()

        // These should NOT be reset
        XCTAssertTrue(vm.isCompact)
        XCTAssertEqual(vm.overlayOpacity, 0.6, accuracy: 0.01)
        XCTAssertEqual(vm.layoutOrientation, .vertical)
    }

    // MARK: - Copy Text

    func testCopyTextSetsPasteboard() {
        vm.copyText("Hello world")
        let pasteboardContent = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasteboardContent, "Hello world")
    }

    func testCopyTextShowsToast() {
        vm.copyText("test")
        XCTAssertTrue(vm.showCopiedToast)
    }

    // MARK: - Formatted Time

    func testFormattedTimeZero() {
        vm.elapsedTime = 0
        XCTAssertEqual(vm.formattedTime, "00:00")
    }

    func testFormattedTimeMinutesAndSeconds() {
        vm.elapsedTime = 125 // 2 minutes 5 seconds
        XCTAssertEqual(vm.formattedTime, "02:05")
    }

    func testFormattedTimeLong() {
        vm.elapsedTime = 3661 // 61 minutes 1 second
        XCTAssertEqual(vm.formattedTime, "61:01")
    }

    // MARK: - End Meeting Re-entrancy

    func testEndMeetingIsIdempotent() {
        // Calling endMeeting multiple times shouldn't crash
        vm.endMeeting()
        vm.endMeeting()
        vm.endMeeting()
        // If we get here without crashing, the re-entrancy guard works
    }

    // MARK: - isMeetingActive

    func testIsMeetingActiveWhenConnecting() {
        vm.statusText = "Connecting..."
        XCTAssertTrue(vm.isMeetingActive)
    }

    func testIsMeetingActiveWhenConnected() {
        vm.isConnected = true
        vm.statusText = "Listening..."
        XCTAssertTrue(vm.isMeetingActive)
    }

    func testIsMeetingInactiveWhenDisconnected() {
        vm.isConnected = false
        vm.statusText = "Disconnected"
        XCTAssertFalse(vm.isMeetingActive)
    }

    // MARK: - Diagnostic Summary

    func testDiagnosticSummaryFormat() {
        vm.isConnected = true
        vm.audioChunksSent = 100
        vm.wsMessagesReceived = 50

        let summary = vm.diagnosticSummary
        XCTAssertTrue(summary.contains("connected"))
        XCTAssertTrue(summary.contains("100"))
        XCTAssertTrue(summary.contains("50"))
    }

    // MARK: - Debug Log

    func testDebugLogInitiallyEmpty() {
        XCTAssertTrue(vm.debugLog.isEmpty)
    }

    func testDebugConsoleExpandedDefault() {
        XCTAssertFalse(vm.debugConsoleExpanded)
    }
}
