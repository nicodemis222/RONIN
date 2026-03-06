import XCTest
@testable import Ronin

@MainActor
final class MeetingPrepViewModelTests: XCTestCase {

    private var vm: MeetingPrepViewModel!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ronin.prep.title")
        UserDefaults.standard.removeObject(forKey: "ronin.prep.goal")
        UserDefaults.standard.removeObject(forKey: "ronin.prep.constraints")
        vm = MeetingPrepViewModel()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ronin.prep.title")
        UserDefaults.standard.removeObject(forKey: "ronin.prep.goal")
        UserDefaults.standard.removeObject(forKey: "ronin.prep.constraints")
        vm = nil
        super.tearDown()
    }

    // MARK: - Validation

    func testIsValidWithTitleAndGoal() {
        vm.title = "Sprint Planning"
        vm.goal = "Plan next sprint"
        XCTAssertTrue(vm.isValid)
    }

    func testIsInvalidWithEmptyTitle() {
        vm.title = ""
        vm.goal = "Plan next sprint"
        XCTAssertFalse(vm.isValid)
    }

    func testIsInvalidWithEmptyGoal() {
        vm.title = "Sprint Planning"
        vm.goal = ""
        XCTAssertFalse(vm.isValid)
    }

    func testIsInvalidWithWhitespaceOnly() {
        vm.title = "   "
        vm.goal = "   "
        XCTAssertFalse(vm.isValid)
    }

    func testIsValidConstraintsOptional() {
        vm.title = "Sprint Planning"
        vm.goal = "Plan next sprint"
        vm.constraints = ""
        XCTAssertTrue(vm.isValid, "Constraints should be optional")
    }

    // MARK: - Persistence

    func testTitlePersists() {
        vm.title = "Q4 Review"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ronin.prep.title"), "Q4 Review")
    }

    func testGoalPersists() {
        vm.goal = "Review quarterly metrics"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ronin.prep.goal"), "Review quarterly metrics")
    }

    func testConstraintsPersists() {
        vm.constraints = "Keep under 30 minutes"
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "ronin.prep.constraints"),
            "Keep under 30 minutes"
        )
    }

    func testClearPrepData() {
        vm.title = "Meeting"
        vm.goal = "Goal"
        vm.constraints = "Constraints"

        vm.clearPrepData()

        XCTAssertEqual(vm.title, "")
        XCTAssertEqual(vm.goal, "")
        XCTAssertEqual(vm.constraints, "")
        XCTAssertTrue(vm.noteFiles.isEmpty)
    }

    func testClearPrepDataClearsUserDefaults() {
        vm.title = "Meeting"
        vm.goal = "Goal"
        vm.constraints = "Constraints"

        vm.clearPrepData()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "ronin.prep.title"), "")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ronin.prep.goal"), "")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ronin.prep.constraints"), "")
    }

    // MARK: - Note Management

    func testRemoveNoteAtOffsets() {
        // Can't easily test addNoteFiles without real file URLs,
        // but we can test removeNote with mock NotePayload data
        vm.noteFiles = [
            NotePayload(name: "note1.md", content: "Content 1"),
            NotePayload(name: "note2.md", content: "Content 2"),
            NotePayload(name: "note3.md", content: "Content 3"),
        ]

        vm.removeNote(at: IndexSet(integer: 1))
        XCTAssertEqual(vm.noteFiles.count, 2)
        XCTAssertEqual(vm.noteFiles[0].name, "note1.md")
        XCTAssertEqual(vm.noteFiles[1].name, "note3.md")
    }

    // MARK: - Loading State

    func testInitialLoadingState() {
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Auth Token

    func testSetAuthTokenDoesNotCrash() {
        // Just verify it doesn't crash — actual network behavior would need integration tests
        vm.setAuthToken("test-token-12345")
    }
}
