import Foundation
import Testing
@testable import Ghostty

struct UndoManagerSafetyTests {
    @Test func undoSafelyExecutesNormalUndo() {
        let undoManager = UndoManager()
        var value = 0
        let target = NSObject()
        undoManager.registerUndo(withTarget: target) { _ in
            value = 42
        }
        #expect(undoManager.canUndo)
        #expect(undoManager.undoSafely())
        #expect(value == 42)
    }

    @Test func undoSafelyCatchesObjectiveCException() {
        let undoManager = UndoManager()
        let target = NSObject()
        undoManager.registerUndo(withTarget: target) { _ in
            NSException(
                name: NSExceptionName("TestException"),
                reason: "Intentional exception for test",
                userInfo: nil
            ).raise()
        }
        #expect(undoManager.canUndo)
        let result = undoManager.undoSafely()
        #expect(!result)
    }

    @Test func redoSafelyCatchesObjectiveCException() {
        let undoManager = UndoManager()
        let target = NSObject()
        undoManager.registerUndo(withTarget: target) { _ in
            undoManager.registerUndo(withTarget: target) { _ in
                NSException(
                    name: NSExceptionName("TestException"),
                    reason: "Intentional redo exception for test",
                    userInfo: nil
                ).raise()
            }
        }
        #expect(undoManager.undoSafely())
        #expect(undoManager.canRedo)
        let result = undoManager.redoSafely()
        #expect(!result)
    }
}
