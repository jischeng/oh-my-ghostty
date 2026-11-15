import CoreGraphics
import Foundation

/// Mode-aware mobile viewport and keyboard geometry policy shared between
/// `TerminalViewController` and `OMGMobileCoreTests`:
///
/// 1. **Primary Screen (`!isAlternateScreen`) — Upstream `Termio` `Pan-Don't-Resize`**:
///    - Declared viewport height stays anchored to `host.height + keyboardOverlap`
///      (full unoccluded screen height), emitting **0 `Resize` frames and 0 `SIGWINCH`**
///      across software keyboard show/hide, `TerminalAccessoryBar`, and Chinese Pinyin
///      `44pt` candidate bar transitions.
///    - Surface pans upward locally based on `caretMaxY` so bottom prompts and active
///      input lines stay visible above `keyboardOverlap`.
///
/// 2. **Alternate Screen (`isAlternateScreen`) — Settled Resize + Candidate-Bar Size Lock**:
///    - Coalesces major keyboard transitions (`>= 180ms` settle debounce).
///    - Locks declared PTY rows against `<= 60pt` height deltas while the keyboard is
///      open (`ABC <-> 简体拼音` switch, `44pt` Pinyin candidate bar show/hide,
///      `UITextInputAssistantItem`), absorbing the delta via local `verticalPan`
///      micro-shift (**0 `SIGWINCH` while typing Chinese in Alt-Screen**).
///    - Renders `1:1` (`surfaceScale == 1.0`) top-left anchored whenever this iOS
///      client is the active writer or awaiting its own resize echo — eliminating the
///      `0.46x` postage-stamp `CGAffineTransform` bounce. Downscaling (`fit < 1.0`) is
///      strictly reserved for passive read-only observation of a larger external writer's
///      `sharedGrid`.
///    - Suppresses parting `Resize` declarations during `viewWillDisappear` / `goBack`
///      navigation transitions (`canDeclareViewport == false`).
public struct MobileTerminalViewportPolicy: Equatable, Sendable {
    /// Maximum keyboard-height delta (points) absorbed locally without changing declared
    /// Alt-Screen PTY rows while the keyboard remains visible (`Blink Shell` pattern).
    public static let candidateBarLockTolerance: CGFloat = 60

    /// Minimum quiet interval before declaring a changed Alt-Screen viewport during
    /// keyboard show/hide animations (`>= 180ms`).
    public static let keyboardSettleInterval: TimeInterval = 0.20

    public struct Input: Equatable, Sendable {
        public var hostSize: CGSize
        public var containerWidth: CGFloat
        public var keyboardOverlap: CGFloat
        public var cellSize: CGSize?
        public var cellPixelWidth: Int?
        public var cellPixelHeight: Int?
        public var padding: CGSize
        public var sharedGrid: (rows: UInt16, cols: UInt16)?
        public var caretMaxY: CGFloat?
        public var isAlternateScreen: Bool
        public var isWriter: Bool
        public var isDeviceSession: Bool
        public var canDeclareViewport: Bool

        public init(
            hostSize: CGSize,
            containerWidth: CGFloat,
            keyboardOverlap: CGFloat,
            cellSize: CGSize?,
            cellPixelWidth: Int? = nil,
            cellPixelHeight: Int? = nil,
            padding: CGSize,
            sharedGrid: (rows: UInt16, cols: UInt16)? = nil,
            caretMaxY: CGFloat? = nil,
            isAlternateScreen: Bool,
            isWriter: Bool,
            isDeviceSession: Bool = true,
            canDeclareViewport: Bool = true
        ) {
            self.hostSize = hostSize
            self.containerWidth = containerWidth
            self.keyboardOverlap = max(0, keyboardOverlap)
            self.cellSize = cellSize
            self.cellPixelWidth = cellPixelWidth
            self.cellPixelHeight = cellPixelHeight
            self.padding = padding
            self.sharedGrid = sharedGrid
            self.caretMaxY = caretMaxY
            self.isAlternateScreen = isAlternateScreen
            self.isWriter = isWriter
            self.isDeviceSession = isDeviceSession
            self.canDeclareViewport = canDeclareViewport
        }

        public static func == (lhs: Input, rhs: Input) -> Bool {
            lhs.hostSize == rhs.hostSize
                && lhs.containerWidth == rhs.containerWidth
                && lhs.keyboardOverlap == rhs.keyboardOverlap
                && lhs.cellSize == rhs.cellSize
                && lhs.cellPixelWidth == rhs.cellPixelWidth
                && lhs.cellPixelHeight == rhs.cellPixelHeight
                && lhs.padding == rhs.padding
                && lhs.sharedGrid?.rows == rhs.sharedGrid?.rows
                && lhs.sharedGrid?.cols == rhs.sharedGrid?.cols
                && lhs.caretMaxY == rhs.caretMaxY
                && lhs.isAlternateScreen == rhs.isAlternateScreen
                && lhs.isWriter == rhs.isWriter
                && lhs.isDeviceSession == rhs.isDeviceSession
                && lhs.canDeclareViewport == rhs.canDeclareViewport
        }
    }

    public struct LayoutPlan: Equatable, Sendable {
        public let declaredViewport: RuntimeViewport?
        public let shouldDebounceDeclaration: Bool
        public let surfaceBounds: CGRect
        public let surfaceCenter: CGPoint
        public let surfaceScale: CGFloat
        public let verticalPan: CGFloat
    }

    public private(set) var lockedAltKeyboardOverlap: CGFloat?
    private var lastContainerWidth: CGFloat = 0
    private var lastKeyboardOverlap: CGFloat = 0
    private var initialized = false

    public init() {}

    public mutating func resetLock() {
        lockedAltKeyboardOverlap = nil
    }

    public mutating func evaluate(_ input: Input) -> LayoutPlan {
        let host = input.hostSize
        let overlap = max(0, input.keyboardOverlap)
        let fullHeight = host.height + overlap

        guard host.width > 0, host.height > 0 else {
            return LayoutPlan(
                declaredViewport: nil,
                shouldDebounceDeclaration: false,
                surfaceBounds: .zero,
                surfaceCenter: .zero,
                surfaceScale: 1,
                verticalPan: 0
            )
        }

        let rotated = initialized && abs(input.containerWidth - lastContainerWidth) > 1.0
        let overlapChanged = initialized && abs(overlap - lastKeyboardOverlap) > 0.5
        if rotated {
            lockedAltKeyboardOverlap = nil
        }
        defer {
            initialized = true
            lastContainerWidth = input.containerWidth
            lastKeyboardOverlap = overlap
        }

        if !input.isAlternateScreen {
            lockedAltKeyboardOverlap = nil
            return evaluatePrimaryScreen(input: input, fullHeight: fullHeight)
        } else {
            return evaluateAlternateScreen(
                input: input,
                fullHeight: fullHeight,
                overlapChanged: overlapChanged
            )
        }
    }

    private func evaluatePrimaryScreen(input: Input, fullHeight: CGFloat) -> LayoutPlan {
        let host = input.hostSize
        let overlap = input.keyboardOverlap
        let declaredViewport = input.canDeclareViewport && input.isDeviceSession
            ? Self.fitViewport(
                size: CGSize(width: host.width, height: fullHeight),
                cellSize: input.cellSize,
                cellPixelWidth: input.cellPixelWidth,
                cellPixelHeight: input.cellPixelHeight,
                padding: input.padding
            )
            : nil

        guard input.isDeviceSession,
              let grid = input.sharedGrid,
              let cell = input.cellSize,
              grid.cols > 0, grid.rows > 0 else {
            let pan = Self.primaryHostPan(
                hostHeight: host.height,
                keyboardOverlap: overlap,
                cellHeight: input.cellSize?.height,
                caretMaxY: input.caretMaxY
            )
            let bounds = CGRect(x: 0, y: 0, width: host.width, height: fullHeight)
            return LayoutPlan(
                declaredViewport: declaredViewport,
                shouldDebounceDeclaration: false,
                surfaceBounds: bounds,
                surfaceCenter: CGPoint(x: host.width / 2, y: fullHeight / 2 - pan),
                surfaceScale: 1,
                verticalPan: pan
            )
        }

        let width = CGFloat(grid.cols) * cell.width + 2 * input.padding.width + cell.width / 2
        let height = CGFloat(grid.rows) * cell.height + 2 * input.padding.height + cell.height / 2
        // Active writer renders 1:1; passive viewer letterboxes larger shared grids cleanly.
        let fit: CGFloat = input.isWriter ? 1 : min(1, host.width / width, fullHeight / height)
        let pan: CGFloat
        if overlap > 0 {
            if let caretMaxY = Self.validCaretMaxY(input.caretMaxY) {
                let anchor = (caretMaxY + 2 * cell.height) * fit
                let maxPan = max(0, height * fit - host.height)
                pan = min(max(0, anchor - host.height), maxPan)
            } else {
                pan = min(overlap, max(0, height * fit - host.height))
            }
        } else {
            pan = 0
        }
        let centerX = (input.isWriter && width > host.width) ? width / 2 : host.width / 2
        let centerY = height * fit / 2 - pan
        return LayoutPlan(
            declaredViewport: declaredViewport,
            shouldDebounceDeclaration: false,
            surfaceBounds: CGRect(x: 0, y: 0, width: width, height: height),
            surfaceCenter: CGPoint(x: centerX, y: centerY),
            surfaceScale: fit,
            verticalPan: pan
        )
    }

    private mutating func evaluateAlternateScreen(
        input: Input,
        fullHeight: CGFloat,
        overlapChanged: Bool
    ) -> LayoutPlan {
        let host = input.hostSize
        let overlap = input.keyboardOverlap
        let effectiveViewportHeight: CGFloat
        let extraCandidateOverlap: CGFloat
        let absorbedByCandidateLock: Bool

        if overlap <= 0 {
            lockedAltKeyboardOverlap = nil
            effectiveViewportHeight = host.height
            extraCandidateOverlap = 0
            absorbedByCandidateLock = false
        } else if let locked = lockedAltKeyboardOverlap,
                  abs(overlap - locked) <= Self.candidateBarLockTolerance {
            // Lock PTY rows against <= 60pt IME candidate-bar / language-switch height deltas!
            effectiveViewportHeight = host.height + (overlap - locked)
            extraCandidateOverlap = max(0, overlap - locked)
            absorbedByCandidateLock = true
        } else {
            lockedAltKeyboardOverlap = overlap
            effectiveViewportHeight = host.height
            extraCandidateOverlap = 0
            absorbedByCandidateLock = false
        }

        let declaredViewport = input.canDeclareViewport && input.isDeviceSession
            ? Self.fitViewport(
                size: CGSize(width: host.width, height: effectiveViewportHeight),
                cellSize: input.cellSize,
                cellPixelWidth: input.cellPixelWidth,
                cellPixelHeight: input.cellPixelHeight,
                padding: input.padding
            )
            : nil
        let shouldDebounce = overlapChanged && !absorbedByCandidateLock

        guard input.isDeviceSession,
              let grid = input.sharedGrid,
              let cell = input.cellSize,
              grid.cols > 0, grid.rows > 0 else {
            let surfaceHeight = host.height + extraCandidateOverlap
            let pan: CGFloat
            if extraCandidateOverlap > 0 {
                if let caretMaxY = Self.validCaretMaxY(input.caretMaxY), let cell = input.cellSize {
                    pan = min(extraCandidateOverlap, max(0, caretMaxY + 2 * cell.height - host.height))
                } else {
                    pan = extraCandidateOverlap
                }
            } else {
                pan = 0
            }
            let bounds = CGRect(x: 0, y: 0, width: host.width, height: surfaceHeight)
            return LayoutPlan(
                declaredViewport: declaredViewport,
                shouldDebounceDeclaration: shouldDebounce,
                surfaceBounds: bounds,
                surfaceCenter: CGPoint(x: host.width / 2, y: surfaceHeight / 2 - pan),
                surfaceScale: 1,
                verticalPan: pan
            )
        }

        let width = CGFloat(grid.cols) * cell.width + 2 * input.padding.width + cell.width / 2
        let height = CGFloat(grid.rows) * cell.height + 2 * input.padding.height + cell.height / 2

        if input.isWriter {
            // NEVER scale < 1.0 when writer or awaiting our own pending resize echo:
            // eliminates the 0.46x postage-stamp bounce completely.
            let pan: CGFloat
            if extraCandidateOverlap > 0 {
                if let caretMaxY = Self.validCaretMaxY(input.caretMaxY) {
                    let needed = max(0, caretMaxY + 2 * cell.height - host.height)
                    let cap = max(extraCandidateOverlap, max(0, height - host.height))
                    pan = min(cap, needed)
                } else {
                    pan = extraCandidateOverlap
                }
            } else if overlap > 0, height > host.height + cell.height {
                if let caretMaxY = Self.validCaretMaxY(input.caretMaxY) {
                    let needed = max(0, caretMaxY + 2 * cell.height - host.height)
                    pan = min(overlap, min(needed, max(0, height - host.height)))
                } else {
                    pan = 0
                }
            } else {
                pan = 0
            }
            let centerX = width > host.width ? width / 2 : host.width / 2
            return LayoutPlan(
                declaredViewport: declaredViewport,
                shouldDebounceDeclaration: shouldDebounce,
                surfaceBounds: CGRect(x: 0, y: 0, width: width, height: height),
                surfaceCenter: CGPoint(x: centerX, y: height / 2 - pan),
                surfaceScale: 1,
                verticalPan: pan
            )
        }

        // Passive read-only observer of an external writer's sharedGrid:
        // Fit against full unoccluded height so toggling keyboard never causes scale bounce.
        let fit = min(1, host.width / width, fullHeight / height)
        let pan: CGFloat
        if overlap > 0, let caretMaxY = Self.validCaretMaxY(input.caretMaxY) {
            let anchor = (caretMaxY + 2 * cell.height) * fit
            pan = min(max(0, anchor - host.height), max(0, height * fit - host.height))
        } else {
            pan = 0
        }
        return LayoutPlan(
            declaredViewport: declaredViewport,
            shouldDebounceDeclaration: shouldDebounce,
            surfaceBounds: CGRect(x: 0, y: 0, width: width, height: height),
            surfaceCenter: CGPoint(x: host.width / 2, y: height * fit / 2 - pan),
            surfaceScale: fit,
            verticalPan: pan
        )
    }

    private static func primaryHostPan(
        hostHeight: CGFloat,
        keyboardOverlap: CGFloat,
        cellHeight: CGFloat?,
        caretMaxY: CGFloat?
    ) -> CGFloat {
        guard keyboardOverlap > 0 else { return 0 }
        guard let cellHeight, cellHeight > 0,
              let caretMaxY = validCaretMaxY(caretMaxY) else {
            return keyboardOverlap
        }
        let anchor = caretMaxY + 2 * cellHeight
        return min(keyboardOverlap, max(0, anchor - hostHeight))
    }

    private static func validCaretMaxY(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Identical grid-fitting arithmetic to `TerminalGrid.fitting` (`renderer/size.zig`),
    /// paired with exact backing-pixel dimensions for v2 8-byte `'R'` frames.
    public static func fitViewport(
        size: CGSize,
        cellSize: CGSize?,
        cellPixelWidth: Int?,
        cellPixelHeight: Int?,
        padding: CGSize
    ) -> RuntimeViewport? {
        guard let cell = cellSize, cell.width > 0, cell.height > 0 else { return nil }
        let rawCols = ((size.width - 2 * padding.width) / cell.width).rounded(.down)
        let rawRows = ((size.height - 2 * padding.height) / cell.height).rounded(.down)
        guard rawCols.isFinite, rawRows.isFinite, rawCols >= 1, rawRows >= 1 else { return nil }
        let cols = Int(min(rawCols, CGFloat(RuntimeViewport.maximumColumns)))
        let rows = Int(min(rawRows, CGFloat(RuntimeViewport.maximumRows)))
        return RuntimeViewport.fromCellPixels(
            columns: cols,
            rows: rows,
            cellPixelWidth: cellPixelWidth,
            cellPixelHeight: cellPixelHeight
        )
    }
}

/// Pure gating policy for `StreamTerminalView`'s `CADisplayLink` so parked terminals,
/// hidden views, and backgrounded app states never spin at 60–120 Hz on `RunLoop.main`.
public enum MobileStreamDisplayLinkPolicy {
    public static func shouldPause(
        hasWindow: Bool,
        isHidden: Bool,
        hostAllowsRendering: Bool,
        isAppInBackground: Bool
    ) -> Bool {
        !hasWindow || isHidden || !hostAllowsRendering || isAppInBackground
    }
}

/// Defers background roster/table reloads while a row's swipe contextual action
/// (`tableView.isEditing`) is open so background pushes never cancel swipe-to-close,
/// while allowing explicit user-initiated swipe-close commits through immediately.
public struct MobileSwipeReloadGate: Sendable {
    public enum RefreshDisposition: Equatable, Sendable {
        /// Swipe editing is active; reload is deferred so `UITableView` row counts and
        /// open swipe actions stay undisturbed. Caller must not mutate snapshotted state.
        case deferred
        /// An earlier reload was deferred while swipe editing and can now execute; caller
        /// must run its full snapshot rebuild (`refilter()` / `reload()`).
        case reloadFullSnapshot
        /// No deferred snapshot rebuild is pending; caller may update `renderedCurrentSessionKey`
        /// and call `tableView.reloadData()`.
        case reloadSelectionOnly
    }

    public private(set) var hasDeferredReload = false
    public private(set) var isPerformingSwipeAction = false

    public init() {}

    public mutating func shouldReloadNow(isTableEditing: Bool) -> Bool {
        if isTableEditing && !isPerformingSwipeAction {
            hasDeferredReload = true
            return false
        }
        hasDeferredReload = false
        return true
    }

    public mutating func evaluateSelectionRefresh(isTableEditing: Bool) -> RefreshDisposition {
        if isTableEditing && !isPerformingSwipeAction {
            hasDeferredReload = true
            return .deferred
        }
        if hasDeferredReload {
            return .reloadFullSnapshot
        }
        return .reloadSelectionOnly
    }

    public mutating func beginSwipeAction() {
        isPerformingSwipeAction = true
    }

    public mutating func endSwipeAction() {
        isPerformingSwipeAction = false
    }

    public mutating func consumeDeferredReloadIfReady(isTableEditing: Bool) -> Bool {
        guard hasDeferredReload, !isTableEditing, !isPerformingSwipeAction else {
            return false
        }
        hasDeferredReload = false
        return true
    }
}

/// Pure row-partitioning and row-count layout for `TerminalListViewController` sections.
/// Consumes only the controller's snapshotted `renderedCurrentSessionKey` (updated strictly
/// when `MobileSwipeReloadGate` permits a reload) so `numberOfRowsInSection` and `cellForRowAt`
/// never desync if `store.currentSessionKey` changes while `tableView.isEditing` defers reload.
public enum MobileTerminalSectionLayout {
    public enum RowKind: Equatable, Sendable {
        case active(Int)
        case backgroundHeader
        case detached(Int)
    }

    public static func isActiveSession(
        isBackground: Bool,
        isMobileCreated: Bool,
        sessionKey: String,
        renderedCurrentSessionKey: String?
    ) -> Bool {
        !isBackground || isMobileCreated || sessionKey == renderedCurrentSessionKey
    }

    public static func partition<Session>(
        _ sessions: [Session],
        renderedCurrentSessionKey: String?,
        isBackground: (Session) -> Bool,
        isMobileCreated: (Session) -> Bool,
        key: (Session) -> String
    ) -> (active: [Session], detached: [Session]) {
        var active: [Session] = []
        var detached: [Session] = []
        for session in sessions {
            if isActiveSession(
                isBackground: isBackground(session),
                isMobileCreated: isMobileCreated(session),
                sessionKey: key(session),
                renderedCurrentSessionKey: renderedCurrentSessionKey
            ) {
                active.append(session)
            } else {
                detached.append(session)
            }
        }
        return (active, detached)
    }

    public static func numberOfRows(
        activeCount: Int,
        detachedCount: Int,
        isBackgroundExpanded: Bool
    ) -> Int {
        guard detachedCount > 0 else { return activeCount }
        return activeCount + 1 + (isBackgroundExpanded ? detachedCount : 0)
    }

    public static func rowKind(
        at row: Int,
        activeCount: Int,
        detachedCount: Int,
        isBackgroundExpanded: Bool
    ) -> RowKind? {
        guard row >= 0 else { return nil }
        if row < activeCount {
            return .active(row)
        }
        guard detachedCount > 0 else { return nil }
        if row == activeCount {
            return .backgroundHeader
        }
        guard isBackgroundExpanded else { return nil }
        let childIndex = row - activeCount - 1
        guard childIndex >= 0, childIndex < detachedCount else { return nil }
        return .detached(childIndex)
    }
}
