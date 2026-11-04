// Adapted from termio-sh/termio 81965875. See LICENSE.termio.
import Foundation
enum Termiod {
    public enum InputEvent: Equatable, Sendable {
        case key(Key)
        /// Pasted text. `more` marks a piece of a paste too large for one
        /// frame that has pieces after it; termiod makes them one paste.
        case paste(String, more: Bool = false)
        case mouse(Mouse)
        case wheel(Wheel)
        case focus(Bool)

        public enum Action: String, Encodable, Sendable {
            case press, release, `repeat`, motion
        }

        public struct Key: Equatable, Sendable {
            public var action: Action
            public var key: String
            /// libghostty's modifier bits.
            public var mods: UInt16
            public var consumedMods: UInt16
            /// What the layout typed; never a control code or a function key.
            public var text: String?
            public var unshifted: UInt32
            public var composing: Bool

            public init(action: Action = .press, key: String, mods: UInt16 = 0, consumedMods: UInt16 = 0,
                        text: String? = nil, unshifted: UInt32 = 0, composing: Bool = false) {
                self.action = action
                self.key = key
                self.mods = mods
                self.consumedMods = consumedMods
                self.text = text
                self.unshifted = unshifted
                self.composing = composing
            }
        }

        /// A point in pixels from the grid's top-left corner, in the cell size
        /// the client draws.
        public struct Pointer: Equatable, Sendable {
            public var x: Float
            public var y: Float
            public var cellWidth: UInt32
            public var cellHeight: UInt32

            public init(x: Float, y: Float, cellWidth: UInt32, cellHeight: UInt32) {
                self.x = x
                self.y = y
                self.cellWidth = cellWidth
                self.cellHeight = cellHeight
            }
        }

        public struct Mouse: Equatable, Sendable {
            public var action: Action
            /// 1 left, 2 right, 3 middle, 4 to 11 the rest; nil for plain motion.
            public var button: UInt8?
            public var mods: UInt16
            public var at: Pointer
            /// Whether any button is down once this event has happened.
            public var buttonsHeld: Bool

            public init(action: Action, button: UInt8?, mods: UInt16, at: Pointer, buttonsHeld: Bool) {
                self.action = action
                self.button = button
                self.mods = mods
                self.at = at
                self.buttonsHeld = buttonsHeld
            }
        }

        /// Whole rows and columns, negative up and left.
        public struct Wheel: Equatable, Sendable {
            public var rows: Int32
            public var columns: Int32
            public var mods: UInt16
            public var at: Pointer

            public init(rows: Int32, columns: Int32, mods: UInt16, at: Pointer) {
                self.rows = rows
                self.columns = columns
                self.mods = mods
                self.at = at
            }
        }

        /// Whether sending this is typing, which takes the write token as
        /// typing into the embedded surface does. Not a modifier pressed on its
        /// own, a release, a key the input method is composing, plain motion,
        /// or a focus change: none of them sends the program a byte.
        public var claimsWriter: Bool {
            switch self {
            case .key(let key):
                return key.action != .release && !key.composing && !Self.modifierKeys.contains(key.key)
            case .paste, .wheel:
                return true
            case .mouse(let mouse):
                return mouse.action == .press
            case .focus:
                return false
            }
        }

        private static let modifierKeys: Set<String> = [
            "shift_left", "shift_right", "control_left", "control_right", "alt_left", "alt_right",
            "meta_left", "meta_right", "caps_lock", "fn", "fn_lock",
        ]

    }
}

public struct TerminalGrid: Equatable, Sendable, Codable {
    public let rows: UInt16
    public let cols: UInt16

    public init(rows: UInt16, cols: UInt16) {
        self.rows = rows
        self.cols = cols
    }

    /// Ghostty config uses typographic points, then floors padding to pixels.
    /// Convert back to view points before comparing it with a view's bounds.
    public static func paddingInViewPoints(
        configuredPoints: CGFloat, contentScale: CGFloat, dpi: CGFloat
    ) -> CGFloat {
        (configuredPoints * contentScale * dpi / 72).rounded(.down) / contentScale
    }

    /// How many whole cells a rectangle of this size can show — a client's
    /// *viewport*, the thing the host sizes sessions by.
    ///
    /// libghostty's own arithmetic, deliberately: floor of the space left after
    /// padding on both sides (`renderer/size.zig`, `GridSize.update`). A client
    /// measuring its viewport differently would declare a grid its own surface
    /// then disagrees with by a column, and the pane would letterbox against
    /// itself forever.
    ///
    /// Both clients must use this one function rather than each keeping its own
    /// copy: the Mac pane and the phone's terminal host both have to answer "how
    /// much could I show" the same way, because a session moves between them
    /// (`docs/design/20260901-pty-size-is-not-the-write-token.md` §6.1).
    ///
    /// `nil` is no viewport at all — a window that has not laid out, a cell size
    /// that is not there yet, or a rectangle too small for one cell. The host
    /// counts that for nobody rather than treating it as a stand-in.
    public static func fitting(
        _ size: CGSize, cell: CGSize, paddingX: CGFloat, paddingY: CGFloat
    ) -> TerminalGrid? {
        guard cell.width > 0, cell.height > 0 else { return nil }
        let cols = ((size.width - 2 * paddingX) / cell.width).rounded(.down)
        let rows = ((size.height - 2 * paddingY) / cell.height).rounded(.down)
        // A pane mid-teardown reports zero, and a NaN cell size would otherwise
        // trap on the way to `UInt16`.
        guard cols.isFinite, rows.isFinite, cols >= 1, rows >= 1 else { return nil }
        return TerminalGrid(
            rows: UInt16(clamping: Int(min(rows, 10_000))),
            cols: UInt16(clamping: Int(min(cols, 10_000))))
    }
}
