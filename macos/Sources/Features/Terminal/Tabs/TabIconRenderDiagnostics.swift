import AppKit
import SwiftUI

/// Opt-in diagnostics for tab icon rendering in the Debug (OMG Dev) app.
///
/// The sidebar tints a tab logo by masking the icon's alpha channel with the
/// activity colour. A system symbol that is not tinted by that path renders as
/// the symbol's untinted template black instead of the intended secondary
/// label grey, and observed tab icons changed colour after the first click.
///
/// The variants are rendered inside the live sidebar so they share the exact
/// view context of the real icons, then measured from the captured window.
/// Only symbol names, variant names and RGB values are recorded. No terminal
/// contents, titles, paths, commands or process identifiers are read.
@MainActor
enum TabIconRenderDiagnostics {
#if DEBUG
    /// The icons the sidebar can show. The terminal symbol is the one that
    /// renders black when the tint is lost.
    private static let symbolNames = ["terminal"]

    /// The stages of the tab icon pipeline. Each variant adds one production
    /// step, so a stroke colour that changes between two consecutive variants
    /// identifies the step that drops the tint.
    private enum Variant: String, CaseIterable {
        /// The symbol alone, with no tint. The untinted baseline.
        case bareSymbol = "1_bare_symbol"
        /// A symbol tinted on the symbol itself.
        case symbolTint = "2_symbol_tint"
        /// The production shape: a symbol inside a group, tinted outside it.
        case groupTint = "3_group_tint"
        /// A symbol tinted on the symbol itself, through the animation host.
        case hostSymbolTint = "4_host_symbol_tint"
        /// The production group through the animation host.
        case hostGroupTint = "5_host_group_tint"
        /// The full production pipeline with the group tint.
        case fullGroupTint = "6_full_group_tint"
        /// The full production pipeline with the symbol tint.
        case fullSymbolTint = "7_full_symbol_tint"
        /// The production host with the hosting view inheriting the window
        /// appearance, so the symbol is drawn in the window's colour context.
        case hostAppearance = "8_host_appearance"
    }

    static var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "com.jischeng.omg.debug" &&
            ProcessInfo.processInfo.environment["OMG_DEV_TAB_ICON_DIAGNOSTICS"] == "1"
    }

    /// The probe strip is rendered in the sidebar and measured from the
    /// captured window, so every variant is drawn by the same renderer that
    /// draws the real icons.
    static func probeStrip() -> some View {
        HStack(spacing: 4) {
            ForEach(Variant.allCases, id: \.rawValue) { variant in
                variantView(symbol: symbolNames[0], variant: variant)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private static func variantView(symbol: String, variant: Variant) -> some View {
        let symbolImage = Image(systemName: symbol)
            .resizable()
            .scaledToFit()
        let group = Group { symbolImage }
            .foregroundStyle(Color.secondary)
            .frame(width: 18, height: 18)
        let symbolTinted = symbolImage
            .foregroundStyle(Color.secondary)
            .frame(width: 18, height: iconSize)

        switch variant {
        case .bareSymbol:
            symbolImage.frame(width: iconSize, height: iconSize)
        case .symbolTint:
            symbolTinted
        case .groupTint:
            group
        case .hostSymbolTint:
            AgentLogoNativeBreath(content: AnyView(symbolTinted), working: false)
        case .hostGroupTint:
            AgentLogoNativeBreath(content: AnyView(group), working: false)
        case .fullGroupTint:
            group.modifier(AgentLogoStatus(activity: nil, focused: false))
        case .fullSymbolTint:
            symbolTinted.modifier(AgentLogoStatus(activity: nil, focused: false))
        case .hostAppearance:
            AppearanceInheritingHost(content: AnyView(group))
        }
    }

    private static let iconSize: CGFloat = 18

    /// Writes a report to the application support directory.
    static func start() {
        guard isEnabled else { return }
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OMG/TabIconDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let url = directory.appendingPathComponent("report.txt")
        write(url: url, text: "=== launch ===\n" + capture())
        writeSidebarCapture(directory: directory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                write(url: url, text: "\n=== after 4s ===\n" + capture())
                writeSidebarCapture(directory: directory)
            }
        }
    }

    /// Appends a report on demand, so a sample can be taken after the user has
    /// clicked a tab and the icon has settled.
    static func captureAppend() {
        guard isEnabled else { return }
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OMG/TabIconDiagnostics", isDirectory: true)
        let url = directory.appendingPathComponent("report.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        write(url: url, text: existing + "\n=== manual ===\n" + capture())
    }

    /// Reports the environment and the strokes measured from the live windows.
    static func capture() -> String {
        var lines: [String] = []
        lines.append("appAppearance=\(NSApp.appearance?.name.rawValue ?? "nil")")
        lines.append("effectiveAppearance=\(NSApp.effectiveAppearance.name.rawValue)")
        lines.append(contentsOf: iconStrokesInLiveWindows())
        return lines.joined(separator: "\n")
    }

    private static func iconStrokesInLiveWindows() -> [String] {
        var lines: [String] = []
        for window in NSApp.windows {
            guard let contentView = window.contentView,
                  contentView.bounds.width > 0,
                  contentView.bounds.height > 0 else { continue }
            guard let rep = contentView.bitmapImageRepForCachingDisplay(
                in: contentView.bounds
            ) else { continue }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            let strokes = probeStrokes(in: rep)
            guard !strokes.isEmpty else { continue }
            lines.append(
                "window=\(Int(contentView.bounds.width))x\(Int(contentView.bounds.height)) "
                + "appearance=\(window.appearance?.name.rawValue ?? "nil")"
            )
            lines.append(contentsOf: strokes)
        }
        return lines
    }

    /// Locates the probe strip in the captured window and measures the
    /// darkest pixel of each variant cell. The strip sits directly under the
    /// sidebar header, so its row is found by scanning for a run of small
    /// clusters near the top of the sidebar.
    private static func probeStrokes(in rep: NSBitmapImageRep) -> [String] {
        let cellWidth = 22
        let searchHeight = min(400, rep.pixelsHigh)
        let searchWidth = min(240, rep.pixelsWide)
        let background = sidebarBackground(in: rep)

        // The probe row is the first row below the header that holds several
        // separated clusters of non-background pixels.
        var probeRow = -1
        for y in 0..<searchHeight {
            var clusters = 0
            var inCluster = false
            for x in 0..<searchWidth {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                let distance = abs(color.redComponent - background.red)
                    + abs(color.greenComponent - background.green)
                    + abs(color.blueComponent - background.blue)
                if distance > 0.12 {
                    if !inCluster { clusters += 1 }
                    inCluster = true
                } else {
                    inCluster = false
                }
            }
            if clusters >= Variant.allCases.count {
                probeRow = y
                break
            }
        }
        guard probeRow >= 0 else { return [] }

        var lines: [String] = ["probeRow=\(probeRow) cells=\(Variant.allCases.count)"]
        for (index, variant) in Variant.allCases.enumerated() {
            let x0 = index * cellWidth
            guard x0 < rep.pixelsWide else { continue }
            guard let stroke = darkestPixel(
                in: rep,
                xRange: x0..<min(x0 + cellWidth, rep.pixelsWide),
                y: probeRow,
                background: background
            ) else { continue }
            lines.append(
                "variant=\(variant.rawValue) stroke=rgb(\(stroke.red),\(stroke.green),"
                + "\(stroke.blue))"
            )
        }
        return lines
    }

    /// The sidebar background colour, sampled from a quiet corner.
    private static func sidebarBackground(
        in rep: NSBitmapImageRep
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let x = min(4, max(0, rep.pixelsWide - 1))
        let y = min(4, max(0, rep.pixelsHigh - 1))
        if let color = rep.colorAt(x: x, y: y) {
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        return (0.133, 0.141, 0.165)
    }

    private static func darkestPixel(
        in rep: NSBitmapImageRep,
        xRange: Range<Int>,
        y: Int,
        background: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> (red: Int, green: Int, blue: Int)? {
        var darkest: (red: Int, green: Int, blue: Int)?
        var darkestLuminance = Double.greatestFiniteMagnitude
        for x in xRange {
            for yy in max(0, y - 12)...min(rep.pixelsHigh - 1, y + 12) {
                guard let color = rep.colorAt(x: x, y: yy), color.alphaComponent > 0.5 else { continue }
                let distance = abs(color.redComponent - background.red)
                    + abs(color.greenComponent - background.green)
                    + abs(color.blueComponent - background.blue)
                guard distance > 0.12 else { continue }
                let luminance = Double(
                    color.redComponent + color.greenComponent + color.blueComponent
                )
                guard luminance < darkestLuminance else { continue }
                darkestLuminance = luminance
                darkest = (
                    Int((color.redComponent * 255).rounded()),
                    Int((color.greenComponent * 255).rounded()),
                    Int((color.blueComponent * 255).rounded())
                )
            }
        }
        return darkest
    }

    /// Saves the captured window so the probe strip can be inspected.
    private static func writeSidebarCapture(directory: URL) {
        for (index, window) in NSApp.windows.enumerated() {
            guard let contentView = window.contentView,
                  contentView.bounds.width > 0,
                  contentView.bounds.height > 0 else { continue }
            guard let rep = contentView.bitmapImageRepForCachingDisplay(
                in: contentView.bounds
            ) else { continue }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("sidebar-\(index).png")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private static func write(url: URL, text: String) {
        let data = Data(text.utf8)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
#else
    static var isEnabled: Bool { false }
    static func start() {}
    static func captureAppend() {}
    static func capture() -> String { "" }
    @ViewBuilder static func probeStrip() -> some View { EmptyView() }
#endif
}

/// A hosting view whose own hosting view inherits the window appearance, the
/// candidate fix for a symbol that loses its tint inside the native
/// animation host.
private struct AppearanceInheritingHost: NSViewRepresentable {
    let content: AnyView

    func makeNSView(context: Context) -> AppearanceInheritingHostView {
        AppearanceInheritingHostView()
    }

    func updateNSView(_ view: AppearanceInheritingHostView, context: Context) {
        view.setContent(AnyView(content.environment(\.self, context.environment)))
        view.inheritAppearance()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: AppearanceInheritingHostView,
        context: Context
    ) -> CGSize? {
        nsView.hostingView.fittingSize
    }

    static func dismantleNSView(_ view: AppearanceInheritingHostView, coordinator: Void) {}
}

private final class AppearanceInheritingHostView: NSView {
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent(_ content: AnyView) {
        hostingView.rootView = content
    }

    /// Copies the window appearance onto the hosting view so the symbol is
    /// drawn in the window's colour context.
    func inheritAppearance() {
        guard let appearance = window?.appearance else { return }
        if hostingView.appearance?.name != appearance.name {
            hostingView.appearance = appearance
        }
    }
}
