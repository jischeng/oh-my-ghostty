import AppKit
import Combine
import SwiftUI

/// Only this native container assigns the three shell frames. Hosted leaves
/// cannot feed their fitting sizes back into the terminal's available geometry.
struct NativeTerminalShell: NSViewControllerRepresentable {
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    var layoutState: VerticalTabWindowLayoutState?
    var tracksLiveInspectorWidth = false
    let leadingVisible: Bool
    let trailingVisible: Bool
    let chromeBackground: Color
    var fillsCenterUntilSurfaceReady = false
    var trackedSurfaces: [Ghostty.SurfaceView] = []
    var isEditorCoveringSurface: ((UUID) -> Bool)?
    let leading: AnyView
    let center: AnyView
    let trailing: AnyView

    func makeNSViewController(context: Context) -> TerminalShellController {
        TerminalShellController()
    }

    func updateNSViewController(_ controller: TerminalShellController, context: Context) {
        controller.bindLiveInspectorWidth(
            layoutState: layoutState,
            enabled: tracksLiveInspectorWidth
        )
        controller.update(
            leading: AnyView(leading.environment(\.self, context.environment)),
            center: AnyView(center.environment(\.self, context.environment)),
            trailing: AnyView(trailing.environment(\.self, context.environment)),
            layout: .init(leadingWidth: leadingWidth, trailingWidth: trailingWidth,
                          leadingVisible: leadingVisible, trailingVisible: trailingVisible),
            background: NSColor(chromeBackground),
            fillsCenterUntilSurfaceReady: fillsCenterUntilSurfaceReady,
            trackedSurfaces: trackedSurfaces,
            isEditorCoveringSurface: isEditorCoveringSurface
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: TerminalShellController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

struct TerminalShellGeometry {
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    let leadingVisible: Bool
    let trailingVisible: Bool
}

final class TerminalShellController: NSViewController {
    let container = TerminalShellNativeView()
    private weak var observedLayoutState: VerticalTabWindowLayoutState?
    private var tracksLiveInspectorWidth = false
    private var liveInspectorWidthCancellable: AnyCancellable?

    override func loadView() { view = container }

    @MainActor
    func bindLiveInspectorWidth(
        layoutState: VerticalTabWindowLayoutState?,
        enabled: Bool
    ) {
        guard observedLayoutState !== layoutState || tracksLiveInspectorWidth != enabled else { return }
        observedLayoutState = layoutState
        tracksLiveInspectorWidth = enabled
        guard enabled, let layoutState else {
            liveInspectorWidthCancellable = nil
            return
        }
        liveInspectorWidthCancellable = layoutState.inspectorWidthChanges.sink { [weak self] width in
            self?.container.setTrailingWidth(width)
        }
    }

    func update(leading: AnyView, center: AnyView, trailing: AnyView,
                layout: TerminalShellGeometry, background: NSColor = .clear,
                fillsCenterUntilSurfaceReady: Bool = false,
                trackedSurfaces: [Ghostty.SurfaceView] = [],
                isEditorCoveringSurface: ((UUID) -> Bool)? = nil) {
        _ = view
        container.update(leading: leading, center: center, trailing: trailing,
                         layout: layout, background: background,
                         fillsCenterUntilSurfaceReady: fillsCenterUntilSurfaceReady,
                         trackedSurfaces: trackedSurfaces,
                         isEditorCoveringSurface: isEditorCoveringSurface)
    }
}

final class TerminalShellNativeView: NSView {
    private final class SurfaceObservation {
        weak var surface: Ghostty.SurfaceView?
        var layerObservation: NSKeyValueObservation?
        weak var observedLayer: CALayer?
        var contentsObservation: NSKeyValueObservation?

        init(surface: Ghostty.SurfaceView) {
            self.surface = surface
        }

        func invalidate() {
            layerObservation?.invalidate()
            layerObservation = nil
            contentsObservation?.invalidate()
            contentsObservation = nil
            observedLayer = nil
        }
    }

    let chromeBackdrop = CAShapeLayer()
    private(set) var leadingHost: NSHostingView<AnyView>?
    private(set) var trailingHost: NSHostingView<AnyView>?
    let centerHost = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var rootViewUpdateCount = 0
    private var leadingWidth: CGFloat = 0
    private var trailingWidth: CGFloat = 0
    private var leadingVisible = false
    private var trailingVisible = false
    private var fillsCenterUntilSurfaceReady = false
    private var isEditorCoveringSurface: ((UUID) -> Bool)?
    private var surfaceObservations: [ObjectIdentifier: SurfaceObservation] = [:]
    private weak var lastContentResponder: NSView?
    private var windowObservation: NSObjectProtocol?
    private var editorCoverageObservation: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        chromeBackdrop.name = "omg.terminal.chrome.background"
        chromeBackdrop.zPosition = -1
        chromeBackdrop.fillColor = NSColor.clear.cgColor
        layer?.insertSublayer(chromeBackdrop, at: 0)
        centerHost.sizingOptions = []
        addSubview(centerHost)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        chromeBackdrop.contentsScale = window?.backingScaleFactor ?? 1
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        windowObservation = nil
        lastContentResponder = nil
        guard let window else { return }
        windowObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberContentResponder() }
        }
    }

    deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        if let editorCoverageObservation { NotificationCenter.default.removeObserver(editorCoverageObservation) }
        surfaceObservations.values.forEach { $0.invalidate() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        chromeBackdrop.contentsScale = window?.backingScaleFactor ?? 1
    }

    private func rememberContentResponder() {
        if let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: centerHost), !responder.isHiddenOrHasHiddenAncestor {
            lastContentResponder = responder
        }
    }

    func update(leading: AnyView, center: AnyView, trailing: AnyView,
                layout: TerminalShellGeometry, background: NSColor = .clear,
                fillsCenterUntilSurfaceReady: Bool = false,
                trackedSurfaces: [Ghostty.SurfaceView] = [],
                isEditorCoveringSurface: ((UUID) -> Bool)? = nil) {
        self.leadingWidth = layout.leadingWidth
        self.trailingWidth = layout.trailingWidth
        self.leadingVisible = layout.leadingVisible
        self.trailingVisible = layout.trailingVisible
        self.fillsCenterUntilSurfaceReady = fillsCenterUntilSurfaceReady
        self.isEditorCoveringSurface = isEditorCoveringSurface
        syncTrackedSurfaces(fillsCenterUntilSurfaceReady ? trackedSurfaces : [])
        syncEditorCoverageObservation(enabled: fillsCenterUntilSurfaceReady)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chromeBackdrop.fillColor = background.cgColor
        CATransaction.commit()
        rememberContentResponder()
        rootViewUpdateCount += 1
        centerHost.rootView = center
        updateHost(&leadingHost, content: leading, visible: layout.leadingVisible)
        updateHost(&trailingHost, content: trailing, visible: layout.trailingVisible)
        // The existing tab-group sidebar owns one shared live list. Preserve
        // its unregister-on-collapse contract until the separate tab migration.
        if !layout.leadingVisible, let host = leadingHost {
            host.rootView = AnyView(EmptyView())
            host.removeFromSuperview()
            leadingHost = nil
        }
        needsLayout = true
    }

    /// Updates the Inspector width directly in AppKit during a live resize drag
    /// without reassigning `NSHostingView.rootView` on any of the three panes.
    func setTrailingWidth(_ width: CGFloat) {
        guard trailingWidth != width else { return }
        trailingWidth = width
        needsLayout = true
    }

    /// Recomputes `chromeBackdrop.path` immediately after a mounted surface
    /// changes visibility or receives its first IOSurface frame.
    func refreshCenterBackdrop() {
        guard fillsCenterUntilSurfaceReady else { return }
        updateChromeBackdropPath()
    }

    private func syncEditorCoverageObservation(enabled: Bool) {
        if enabled {
            guard editorCoverageObservation == nil else { return }
            editorCoverageObservation = NotificationCenter.default.addObserver(
                forName: EditorWorkspaceStore.surfaceCoverageDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateChromeBackdropPath() }
            }
        } else if let editorCoverageObservation {
            NotificationCenter.default.removeObserver(editorCoverageObservation)
            self.editorCoverageObservation = nil
        }
    }

    private func syncTrackedSurfaces(_ surfaces: [Ghostty.SurfaceView]) {
        let activeIDs = Set(surfaces.map(ObjectIdentifier.init))
        for (id, entry) in surfaceObservations where !activeIDs.contains(id) {
            entry.invalidate()
            surfaceObservations.removeValue(forKey: id)
        }
        for surface in surfaces {
            let id = ObjectIdentifier(surface)
            if let existing = surfaceObservations[id] {
                if existing.observedLayer !== surface.layer {
                    bindContentsObservation(for: surface, entry: existing)
                }
                continue
            }
            let entry = SurfaceObservation(surface: surface)
            entry.layerObservation = surface.observe(\.layer, options: [.new]) { [weak self, weak surface] _, _ in
                let refresh = { [weak self, weak surface] in
                    guard let self, let surface else { return }
                    let key = ObjectIdentifier(surface)
                    if let entry = self.surfaceObservations[key] {
                        self.bindContentsObservation(for: surface, entry: entry)
                    }
                    self.updateChromeBackdropPath()
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { refresh() }
                } else {
                    DispatchQueue.main.async(execute: refresh)
                }
            }
            bindContentsObservation(for: surface, entry: entry)
            surfaceObservations[id] = entry
        }
    }

    private func bindContentsObservation(for surface: Ghostty.SurfaceView, entry: SurfaceObservation) {
        entry.contentsObservation?.invalidate()
        entry.contentsObservation = nil
        guard let layer = surface.layer else {
            entry.observedLayer = nil
            return
        }
        entry.observedLayer = layer
        entry.contentsObservation = layer.observe(\.contents, options: [.new]) { [weak self] _, _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.updateChromeBackdropPath() }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.updateChromeBackdropPath()
                }
            }
        }
    }

    private func updateHost(_ host: inout NSHostingView<AnyView>?, content: AnyView, visible: Bool) {
        if host == nil, visible {
            let created = NSHostingView(rootView: content)
            created.sizingOptions = []
            addSubview(created)
            host = created
        } else {
            // Hidden Inspector still receives visibility=false so its native
            // presenter can stop provider work while keeping the cached views.
            host?.rootView = content
        }
        if !visible, let host, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: host) {
            if let previous = lastContentResponder, previous.window === window,
               previous.isDescendant(of: centerHost), !previous.isHiddenOrHasHiddenAncestor {
                window?.makeFirstResponder(previous)
            } else {
                window?.makeFirstResponder(nil)
            }
        }
        host?.isHidden = !visible
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let left = leadingVisible ? min(max(0, leadingWidth), width) : 0
        let right = trailingVisible ? min(width - left, TerminalShellStyle.presentedInspectorWidth(
            preferred: trailingWidth, totalWidth: width, leadingWidth: left
        ) + TerminalShellStyle.dividerWidth) : 0
        if leadingVisible {
            setFrame(NSRect(x: 0, y: 0, width: left, height: bounds.height), on: leadingHost)
        }
        setFrame(NSRect(x: left, y: 0, width: max(0, width - left - right), height: bounds.height), on: centerHost)
        if trailingVisible {
            setFrame(NSRect(x: width - right, y: 0, width: right, height: bounds.height), on: trailingHost)
        }
        updateChromeBackdropPath(left: left, right: right)
    }

    private func updateChromeBackdropPath() {
        let width = max(0, bounds.width)
        let left = leadingVisible ? min(max(0, leadingWidth), width) : 0
        let right = trailingVisible ? min(width - left, TerminalShellStyle.presentedInspectorWidth(
            preferred: trailingWidth, totalWidth: width, leadingWidth: left
        ) + TerminalShellStyle.dividerWidth) : 0
        updateChromeBackdropPath(left: left, right: right)
    }

    private func updateChromeBackdropPath(left: CGFloat, right: CGFloat) {
        let width = max(0, bounds.width)
        let centerRect = CGRect(x: left, y: 0, width: max(0, width - left - right), height: bounds.height)
        // One color/compositing owner for both sidebars. The center stays empty
        // once a terminal surface presents its own IOSurface so translucent
        // frames are never painted twice, while pre-first-frame panes receive
        // a matching fallback fill to prevent transparent cold-startup flashes.
        let path = CGMutablePath()
        if leadingVisible && left > 0 { path.addRect(.init(x: 0, y: 0, width: left, height: bounds.height)) }
        if trailingVisible && right > 0 {
            path.addRect(.init(x: width - right, y: 0, width: right, height: bounds.height))
        }
        for rect in centerBackdropRects(in: centerRect) {
            path.addRect(rect)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chromeBackdrop.frame = bounds
        chromeBackdrop.path = path
        chromeBackdrop.isHidden = path.isEmpty
        CATransaction.commit()
    }

    private func centerBackdropRects(in centerRect: CGRect) -> [CGRect] {
        guard fillsCenterUntilSurfaceReady, !centerRect.isEmpty else { return [] }
        let surfaces = surfaceObservations.values.compactMap(\.surface)
        let mounted = surfaces.filter { surface in
            surface.isDescendant(of: centerHost)
                && !surface.isHiddenOrHasHiddenAncestor
                && !surface.bounds.isEmpty
        }
        // Before SwiftUI mounts and lays out any terminal surface inside
        // `centerHost`, paint the entire center rect so cold startup never
        // exposes a transparent hole over a non-opaque window.
        guard !mounted.isEmpty else {
            return [centerRect]
        }
        // Once surfaces are mounted, cover only those still waiting for their
        // first IOSurface frame (and not already painted by an error/editor overlay).
        var rects: [CGRect] = []
        for surface in mounted where !isSurfaceCovered(surface) {
            let rect = surface.convert(surface.bounds, to: self).intersection(centerRect)
            if !rect.isNull && !rect.isEmpty {
                rects.append(rect)
            }
        }
        return rects
    }

    private func isSurfaceCovered(_ surface: Ghostty.SurfaceView) -> Bool {
        if surface.layer?.contents != nil { return true }
        if !surface.healthy || surface.error != nil { return true }
        if isEditorCoveringSurface?(surface.id) == true { return true }
        return false
    }

    private func setFrame(_ frame: NSRect, on view: NSView?) {
        guard let view, view.frame != frame else { return }
        view.frame = frame
    }
}

extension NSView {
    @MainActor
    func notifyEnclosingTerminalShellBackdrop() {
        var current = superview
        while let view = current {
            if let shell = view as? TerminalShellNativeView {
                shell.refreshCenterBackdrop()
                return
            }
            current = view.superview
        }
    }
}
