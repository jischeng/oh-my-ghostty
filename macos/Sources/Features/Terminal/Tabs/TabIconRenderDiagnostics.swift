import AppKit
import SwiftUI

/// Opt-in diagnostics for tab icon rendering in the Debug (OMG Dev) app.
///
/// The sidebar tints a tab logo by masking the icon's alpha channel with the
/// activity colour. A system symbol that is not tinted by that path renders as
/// the symbol's untinted template black instead of the intended secondary
/// label grey.
///
/// This measures the rendered stroke colour of the same symbol across the
/// stages of the production pipeline, so the stage that drops the tint can be
/// identified. The variants run inside the live application process, so the
/// real appearance and colour environment apply.
///
/// Only symbol names, measured RGB values and variant names are recorded. No
/// terminal contents, titles, paths, commands or process identifiers are read.
@MainActor
enum TabIconRenderDiagnostics {
#if DEBUG
    /// The icons the sidebar can show. The terminal symbol is the one that
    /// renders black when the tint is lost.
    private static let symbolNames = ["terminal"]

    /// Measured stroke colours are classified so a report stays comparable
    /// between runs and between machines.
    private enum Classification: String {
        case untintedBlack
        case labelGrey
        case accent
        case other

        init(red: Int, green: Int, blue: Int) {
            let isBlack = red < 40 && green < 40 && blue < 40
            let isGrey = abs(red - green) < 12 && abs(green - blue) < 12 && red > 100
            let isAccent = blue > 150 && blue - red > 60
            if isBlack {
                self = .untintedBlack
            } else if isAccent {
                self = .accent
            } else if isGrey {
                self = .labelGrey
            } else {
                self = .other
            }
        }
    }

    static var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "com.jischeng.omg.debug" &&
            ProcessInfo.processInfo.environment["OMG_DEV_TAB_ICON_DIAGNOSTICS"] == "1"
    }

    /// Writes a report to the application support directory. The report is
    /// sampled at launch, once the sidebar has rendered, and again after a
    /// short delay so a first-frame difference and a settled difference can be
    /// compared.
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                write(url: url, text: "\n=== after 3s ===\n" + capture())
                writeSidebarCapture(directory: directory)
            }
        }
    }

    /// Saves the captured sidebar column as a PNG so the sampled bands can be
    /// compared with what the user sees.
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

    private static func write(url: URL, text: String) {
        let data = Data(text.utf8)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Renders every pipeline stage for every symbol and returns the measured
    /// stroke colour of each.
    static func capture() -> String {
        var lines: [String] = []
        lines.append("appAppearance=\(NSApp.appearance?.name.rawValue ?? "nil")")
        lines.append("effectiveAppearance=\(NSApp.effectiveAppearance.name.rawValue)")
        lines.append("windowAppearance=\(NSApp.keyWindow?.appearance?.name.rawValue ?? "nil")")

        for symbol in symbolNames {
            for variant in Variant.allCases {
                lines.append(
                    "symbol=\(symbol) variant=\(variant.rawValue) "
                    + describeVariant(symbol: symbol, variant: variant)
                )
            }
        }

        lines.append(contentsOf: liveWindowIconReport())
        return lines.joined(separator: "\n")
    }

    /// The stages of the tab icon pipeline. Each variant adds one production
    /// step, so a stroke colour that changes between two consecutive variants
    /// identifies the step that drops the tint.
    private enum Variant: String, CaseIterable {
        /// The symbol alone, with no tint. The untinted baseline.
        case bareSymbol = "1_bare_symbol"
        /// The symbol tinted directly, without an enclosing group.
        case directTint = "2_direct_tint"
        /// The production shape: a symbol inside a group, tinted outside it.
        case productionGroup = "3_production_group"
        /// The production group rendered through the native animation host.
        case productionHost = "4_production_host"
        /// The full production pipeline including the activity tint overlay.
        case fullPipeline = "5_full_pipeline"
    }

    private static let iconSize: CGFloat = 18

    /// Renders a variant and describes it in one step, so a variant that
    /// renders but yields no opaque pixel is reported as empty instead of
    /// being skipped.
    private static func describeVariant(symbol: String, variant: Variant) -> String {
        let renderer = ImageRenderer(content: variantView(symbol: symbol, variant: variant))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return "status=render_failed" }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var darkest: (red: Int, green: Int, blue: Int)?
        var darkestLuminance = Double.greatestFiniteMagnitude
        var opaquePixels = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y),
                      color.alphaComponent > 0.5 else { continue }
                opaquePixels += 1
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
        guard let darkest else {
            return "status=empty size=\(cgImage.width)x\(cgImage.height)"
        }
        let classification = Classification(
            red: darkest.red, green: darkest.green, blue: darkest.blue
        )
        return "stroke=rgb(\(darkest.red),\(darkest.green),\(darkest.blue)) "
            + "class=\(classification.rawValue) opaque=\(opaquePixels)"
    }

    @ViewBuilder
    private static func variantView(symbol: String, variant: Variant) -> some View {
        let symbolImage = Image(systemName: symbol)
            .resizable()
            .scaledToFit()
        let group = Group { symbolImage }
            .foregroundStyle(Color.secondary)
            .frame(width: iconSize, height: iconSize)

        switch variant {
        case .bareSymbol:
            symbolImage.frame(width: iconSize, height: iconSize)
        case .directTint:
            symbolImage
                .foregroundStyle(Color.secondary)
                .frame(width: iconSize, height: iconSize)
        case .productionGroup:
            group
        case .productionHost:
            AgentLogoNativeBreath(
                content: AnyView(group),
                working: false
            )
        case .fullPipeline:
            group
                .modifier(AgentLogoStatus(activity: nil, focused: false))
        }
    }

    /// Reports the icon column of the live windows so the measured variants can
    /// be compared against what is actually on screen.
    private static func liveWindowIconReport() -> [String] {
        var lines: [String] = []
        for window in NSApp.windows {
            guard let contentView = window.contentView,
                  contentView.bounds.width > 0,
                  contentView.bounds.height > 0 else { continue }
            guard let rep = contentView.bitmapImageRepForCachingDisplay(
                in: contentView.bounds
            ) else { continue }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            let strokes = iconColumnStrokes(in: rep)
            guard !strokes.isEmpty else { continue }
            lines.append(
                "window=\(Int(contentView.bounds.width))x\(Int(contentView.bounds.height)) "
                + "appearance=\(window.appearance?.name.rawValue ?? "nil")"
            )
            lines.append(contentsOf: strokes)
        }
        return lines
    }

    /// Samples the captured window and reports the darkest pixel of each band
    /// in the leading column, where the sidebar tab icons sit. A band that
    /// holds a black icon reports an untinted stroke.
    private static func iconColumnStrokes(in rep: NSBitmapImageRep) -> [String] {
        let bandWidth = 80
        let bandHeight = 30
        let xLimit = min(bandWidth, rep.pixelsWide)
        let yLimit = min(bandHeight * 12, rep.pixelsHigh)
        var lines: [String] = []
        var band = 0
        while band * bandHeight < yLimit {
            var darkest: (red: Int, green: Int, blue: Int)?
            var darkestLuminance = Double.greatestFiniteMagnitude
            for y in (band * bandHeight)..<min((band + 1) * bandHeight, yLimit) {
                for x in 0..<xLimit {
                    guard let color = rep.colorAt(x: x, y: y),
                          color.alphaComponent > 0.5 else { continue }
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
            guard let darkest else {
                band += 1
                continue
            }
            let classification = Classification(
                red: darkest.red, green: darkest.green, blue: darkest.blue
            )
            lines.append(
                "band=\(band) stroke=rgb(\(darkest.red),\(darkest.green),\(darkest.blue)) "
                + "class=\(classification.rawValue)"
            )
            band += 1
        }
        return lines
    }
#else
    static var isEnabled: Bool { false }
    static func start() {}
    static func capture() -> String { "" }
#endif
}
