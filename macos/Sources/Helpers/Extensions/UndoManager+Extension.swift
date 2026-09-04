import Foundation

extension UndoManager {
    /// A Boolean value that indicates whether the undo manager is currently performing
    /// either an undo or redo operation.
    var isUndoingOrRedoing: Bool {
        isUndoing || isRedoing
    }

    /// Safely performs undo, catching any Objective-C exceptions raised during execution.
    @discardableResult
    func undoSafely() -> Bool {
        guard canUndo else { return false }
        var error: NSError?
        let success = GhosttyUndoSafely(self, &error)
        if let error {
            Ghostty.logger.error("Undo failed with exception: \(error.localizedDescription, privacy: .public)")
        }
        return success
    }

    /// Safely performs redo, catching any Objective-C exceptions raised during execution.
    @discardableResult
    func redoSafely() -> Bool {
        guard canRedo else { return false }
        var error: NSError?
        let success = GhosttyRedoSafely(self, &error)
        if let error {
            Ghostty.logger.error("Redo failed with exception: \(error.localizedDescription, privacy: .public)")
        }
        return success
    }

    /// Temporarily disables undo registration while executing the provided handler.
    ///
    /// This method provides a convenient way to perform operations without recording them
    /// in the undo stack. It ensures that undo registration is properly re-enabled even
    /// if the handler throws an error.
    func disableUndoRegistration(handler: () -> Void) {
        disableUndoRegistration()
        handler()
        enableUndoRegistration()
    }
}
