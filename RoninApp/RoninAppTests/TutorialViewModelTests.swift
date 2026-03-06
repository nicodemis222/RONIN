import XCTest
@testable import Ronin

@MainActor
final class TutorialViewModelTests: XCTestCase {

    private var vm: TutorialViewModel!

    override func setUp() {
        super.setUp()
        // Clear UserDefaults for clean state
        UserDefaults.standard.removeObject(forKey: "ronin.hasCompletedTutorial")
        vm = TutorialViewModel()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ronin.hasCompletedTutorial")
        vm = nil
        super.tearDown()
    }

    // MARK: - Card Data

    func testCardsAreNotEmpty() {
        XCTAssertFalse(vm.cards.isEmpty)
        XCTAssertEqual(vm.cards.count, 5)
    }

    func testEachCardHasRequiredFields() {
        for card in vm.cards {
            XCTAssertFalse(card.icon.isEmpty, "Card \(card.id) missing icon")
            XCTAssertFalse(card.title.isEmpty, "Card \(card.id) missing title")
            XCTAssertFalse(card.body.isEmpty, "Card \(card.id) missing body")
        }
    }

    func testCardIdsAreSequential() {
        for (index, card) in vm.cards.enumerated() {
            XCTAssertEqual(card.id, index)
        }
    }

    // MARK: - Navigation

    func testInitialState() {
        XCTAssertEqual(vm.currentCardIndex, 0)
        XCTAssertFalse(vm.isShowingTutorial)
        XCTAssertTrue(vm.isFirstCard)
        XCTAssertFalse(vm.isLastCard)
    }

    func testNextCardAdvances() {
        vm.nextCard()
        XCTAssertEqual(vm.currentCardIndex, 1)
    }

    func testPreviousCardOnFirstCardStays() {
        XCTAssertEqual(vm.currentCardIndex, 0)
        vm.previousCard()
        XCTAssertEqual(vm.currentCardIndex, 0, "Should not go below 0")
    }

    func testPreviousCardGoesBack() {
        vm.nextCard()
        vm.nextCard()
        XCTAssertEqual(vm.currentCardIndex, 2)
        vm.previousCard()
        XCTAssertEqual(vm.currentCardIndex, 1)
    }

    func testNextCardOnLastCardCompletes() {
        // Navigate to last card
        for _ in 0..<vm.cards.count - 1 {
            vm.nextCard()
        }
        XCTAssertTrue(vm.isLastCard)

        // Next card on last card should complete tutorial
        vm.isShowingTutorial = true
        vm.nextCard()
        XCTAssertFalse(vm.isShowingTutorial)
        XCTAssertTrue(vm.hasCompletedTutorial)
        XCTAssertEqual(vm.currentCardIndex, 0, "Should reset to first card")
    }

    func testIsFirstCardProperty() {
        XCTAssertTrue(vm.isFirstCard)
        vm.nextCard()
        XCTAssertFalse(vm.isFirstCard)
    }

    func testIsLastCardProperty() {
        XCTAssertFalse(vm.isLastCard)
        for _ in 0..<vm.cards.count - 1 {
            vm.nextCard()
        }
        XCTAssertTrue(vm.isLastCard)
    }

    func testCurrentCardReturnsCorrectCard() {
        XCTAssertEqual(vm.currentCard.id, 0)
        vm.nextCard()
        XCTAssertEqual(vm.currentCard.id, 1)
    }

    func testProgressCalculation() {
        // First card: 1/5 = 0.2
        XCTAssertEqual(vm.progress, 1.0 / Double(vm.cards.count), accuracy: 0.001)

        // Second card: 2/5 = 0.4
        vm.nextCard()
        XCTAssertEqual(vm.progress, 2.0 / Double(vm.cards.count), accuracy: 0.001)
    }

    // MARK: - Completion & Persistence

    func testSkipTutorialCompletes() {
        vm.isShowingTutorial = true
        vm.skipTutorial()
        XCTAssertFalse(vm.isShowingTutorial)
        XCTAssertTrue(vm.hasCompletedTutorial)
    }

    func testCompleteTutorialPersists() {
        vm.completeTutorial()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ronin.hasCompletedTutorial"))
    }

    func testCompleteTutorialResetsIndex() {
        vm.nextCard()
        vm.nextCard()
        XCTAssertEqual(vm.currentCardIndex, 2)
        vm.completeTutorial()
        XCTAssertEqual(vm.currentCardIndex, 0)
    }

    // MARK: - First Launch

    func testCheckFirstLaunchShowsTutorial() {
        // hasCompletedTutorial is false by default
        vm.checkFirstLaunch()
        XCTAssertTrue(vm.isShowingTutorial)
    }

    func testCheckFirstLaunchSkipsIfCompleted() {
        vm.hasCompletedTutorial = true
        vm.checkFirstLaunch()
        XCTAssertFalse(vm.isShowingTutorial)
    }

    // MARK: - Relaunch

    func testRelaunchTutorial() {
        vm.hasCompletedTutorial = true
        vm.nextCard()
        vm.nextCard()

        vm.relaunchTutorial()
        XCTAssertTrue(vm.isShowingTutorial)
        XCTAssertEqual(vm.currentCardIndex, 0)
    }
}
