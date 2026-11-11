import AppKit
import IOSurface
import QuartzCore

/// Preserve the pane's last frame while a CLI briefly leaves its TUI
/// for the editor handshake. This covers pixels only; PTY processing continues.
@MainActor
final class QuickInputTerminalSnapshot {
    private final class Overlay: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class WeakSnapshot {
        weak var value: QuickInputTerminalSnapshot?
        init(_ value: QuickInputTerminalSnapshot) { self.value = value }
    }

    private static var activeSnapshots: [ObjectIdentifier: WeakSnapshot] = [:]

    private let surfaceKey: ObjectIdentifier
    private let restoredOpacity: Float
    private var isRemoved = false
    private var overlay: NSImageView?
    private weak var surfaceLayer: CALayer?
    private var timeout: Task<Void, Never>?
    private var redrawRemovalTask: Task<Void, Never>?
    private var frameObserver: NSObjectProtocol?

    init(surface: NSView, maximumDuration: Duration = .seconds(6)) {
        let key = ObjectIdentifier(surface)
        self.surfaceKey = key
        Self.activeSnapshots[key]?.value?.remove()

        let baselineOpacity = surface.layer?.opacity ?? 1
        self.restoredOpacity = baselineOpacity

        guard let image = Self.captureImage(from: surface),
              let parent = surface.superview else {
            self.isRemoved = true
            return
        }

        let overlay = Overlay(frame: surface.frame)
        overlay.image = image
        overlay.imageScaling = .scaleNone
        overlay.imageAlignment = .alignTopLeft
        overlay.autoresizingMask = [.width, .height]

        // Hide the live translucent surface layer underneath the sibling overlay
        // in the same non-animated transaction so Core Animation never composites
        // two translucent terminal frames on top of each other (a + a*(1-a)).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.addSubview(overlay, positioned: .above, relativeTo: surface)
        overlay.layoutSubtreeIfNeeded()
        surface.layer?.opacity = 0
        CATransaction.commit()

        self.overlay = overlay
        self.surfaceLayer = surface.layer
        Self.activeSnapshots[key] = WeakSnapshot(self)

        let capturedSize = surface.bounds.size
        surface.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: surface, queue: .main
        ) { [weak self, weak surface] _ in
            MainActor.assumeIsolated {
                guard let surface, surface.bounds.size != capturedSize else { return }
                // A pre-resize image is no longer a valid representation of
                // this pane. Never stretch it over the new terminal geometry.
                self?.remove()
            }
        }
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: maximumDuration)
            guard !Task.isCancelled else { return }
            self?.remove()
        }
    }

    static func captureImage(from surface: NSView) -> NSImage? {
        if let ioSurface = surface.layer?.contents as? IOSurface,
           ioSurface.width > 0,
           ioSurface.height > 0,
           surface.bounds.width > 0,
           surface.bounds.height > 0 {
            ioSurface.lock(options: .readOnly, seed: nil)
            let byteCount = ioSurface.bytesPerRow * ioSurface.height
            let data = Data(bytes: ioSurface.baseAddress, count: byteCount)
            ioSurface.unlock(options: .readOnly, seed: nil)

            let colorSpace: CGColorSpace = {
                if let plist = IOSurfaceCopyValue(ioSurface, kIOSurfaceColorSpace),
                   let space = CGColorSpace(propertyListPlist: plist) {
                    return space
                }
                return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            }()
            let bitmapInfo = CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
            if let provider = CGDataProvider(data: data as CFData),
               let cgImage = CGImage(
                   width: ioSurface.width,
                   height: ioSurface.height,
                   bitsPerComponent: 8,
                   bitsPerPixel: 32,
                   bytesPerRow: ioSurface.bytesPerRow,
                   space: colorSpace,
                   bitmapInfo: bitmapInfo,
                   provider: provider,
                   decode: nil,
                   shouldInterpolate: false,
                   intent: .defaultIntent
               ) {
                return NSImage(cgImage: cgImage, size: surface.bounds.size)
            }
        }

        if let terminalSurface = surface as? Ghostty.SurfaceView {
            return terminalSurface.asImage
        }
        guard let bitmapRep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else {
            return nil
        }
        surface.cacheDisplay(in: surface.bounds, to: bitmapRep)
        let image = NSImage(size: surface.bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }

    func removeAfterRedraw() {
        guard !isRemoved else { return }
        redrawRemovalTask?.cancel()
        // Retain until the delayed removal even when the import task returns.
        redrawRemovalTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self.remove()
        }
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        timeout?.cancel()
        redrawRemovalTask?.cancel()
        let overlay = self.overlay
        let surfaceLayer = self.surfaceLayer
        let restoredOpacity = self.restoredOpacity
        if overlay != nil || surfaceLayer != nil {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    surfaceLayer?.opacity = restoredOpacity
                    overlay?.removeFromSuperview()
                    CATransaction.commit()
                }
            } else {
                Task { @MainActor in
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    surfaceLayer?.opacity = restoredOpacity
                    overlay?.removeFromSuperview()
                    CATransaction.commit()
                }
            }
        }
    }

    func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        timeout?.cancel()
        timeout = nil
        redrawRemovalTask?.cancel()
        redrawRemovalTask = nil
        if Self.activeSnapshots[surfaceKey]?.value === self {
            Self.activeSnapshots.removeValue(forKey: surfaceKey)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer?.opacity = restoredOpacity
        overlay?.removeFromSuperview()
        CATransaction.commit()
        surfaceLayer = nil
        overlay = nil
    }
}
