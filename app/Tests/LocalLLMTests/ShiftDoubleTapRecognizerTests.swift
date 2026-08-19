import XCTest
@testable import LocalLLM

final class ShiftDoubleTapRecognizerTests: XCTestCase {
    func testQuickSecondPressTriggersOnRelease() {
        var recognizer = ShiftDoubleTapRecognizer()

        XCTAssertEqual(recognizer.update(shiftDown: true, hasOtherModifiers: false, at: 10), .none)
        XCTAssertEqual(recognizer.update(shiftDown: false, hasOtherModifiers: false, at: 10.05), .none)
        XCTAssertEqual(
            recognizer.update(shiftDown: true, hasOtherModifiers: false, at: 10.2),
            .secondPressBegan
        )
        XCTAssertTrue(recognizer.isSecondPressDown)
        XCTAssertEqual(
            recognizer.update(shiftDown: false, hasOtherModifiers: false, at: 10.25),
            .secondPressReleased
        )
        XCTAssertFalse(recognizer.isSecondPressDown)
    }

    func testSlowSecondPressStartsANewSequence() {
        var recognizer = ShiftDoubleTapRecognizer()

        _ = recognizer.update(shiftDown: true, hasOtherModifiers: false, at: 10)
        _ = recognizer.update(shiftDown: false, hasOtherModifiers: false, at: 10.05)

        XCTAssertEqual(
            recognizer.update(shiftDown: true, hasOtherModifiers: false, at: 10.5),
            .none
        )
    }

    func testOtherModifierCancelsSecondPress() {
        var recognizer = ShiftDoubleTapRecognizer()
        _ = recognizer.update(shiftDown: true, hasOtherModifiers: false, at: 10)
        _ = recognizer.update(shiftDown: false, hasOtherModifiers: false, at: 10.05)
        _ = recognizer.update(shiftDown: true, hasOtherModifiers: false, at: 10.2)

        XCTAssertEqual(
            recognizer.update(shiftDown: true, hasOtherModifiers: true, at: 10.3),
            .secondPressCancelled
        )
        XCTAssertFalse(recognizer.isSecondPressDown)
    }
}
