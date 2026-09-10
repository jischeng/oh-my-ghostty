import AppKit
import SwiftUI
import CodeEditTextView
import Testing
@testable import Ghostty

@MainActor
struct GitDiffHighlightTests {
    @Test(arguments: [false, true]) func changedLinesRemainHighlightedAfterScrolling(realCase: Bool) async throws {
        let lines = (0..<420).map { "\($0) Each record contains trip_completed, trip_end_time_us and trip_end_time_cn, with additional metadata for wrapping." }
        var text = lines.joined(separator: "\n")
        if realCase {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/omg-real-diff-case.json")) else { return }
            let values = try JSONDecoder().decode([String: String].self, from: data)
            text = try #require(values["after"])
            let presentation = GitDiffPresentation(before: values["before"] ?? "", after: text, patch: values["patch"] ?? "")
            #expect(presentation.isConsistent && presentation.afterHighlights[324] == true && presentation.afterHighlights[325] == true)
        }
        let host = NSHostingView(rootView: CodeEditorView(text: .constant(text),
            fileURL: URL(fileURLWithPath: "/api-reference.md"), diffLines: [324: true, 325: true],
            isEditable: false, isActive: true, terminalTheme: .oneDark))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 540, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func find(_ view: NSView) -> TextView? {
            if let text = view as? TextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try #require(find(host))
        let clip = try #require(editor.enclosingScrollView?.contentView)
        for target in [320, 0, 320] {
            let line = try #require(editor.layoutManager.textLineForIndex(target))
            clip.scroll(to: .init(x: 0, y: line.yPos))
            editor.enclosingScrollView?.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let overlay = try #require(editor.layer?.sublayers?.first { $0.name == "omg.diff-line-overlay" })
            let paths = overlay.sublayers?.compactMap { ($0 as? CAShapeLayer)?.path } ?? []
            if target == 0 {
                #expect(paths.allSatisfy { $0.isEmpty })
                continue
            }
            for index in [324, 325] {
                let changed = try #require(editor.layoutManager.textLineForIndex(index))
                let point = CGPoint(x: 100, y: changed.yPos + changed.height / 2)
                #expect(editor.visibleRect.contains(point), "Regression fixture must show the changed line")
                #expect(paths.contains { $0.contains(point) }, "Visible changed line \(index + 1) must be tinted after scrolling")
            }
            if realCase, FileManager.default.fileExists(atPath: "/tmp/omg-git-render"),
               let context = CGContext(data: nil, width: Int(host.bounds.width * 2), height: Int(host.bounds.height * 2),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.scaleBy(x: 2, y: 2)
                host.layer?.render(in: context)
                if let image = context.makeImage() {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "/tmp/omg-real-diff-highlight.png"))
                }
            }
        }
    }
}
