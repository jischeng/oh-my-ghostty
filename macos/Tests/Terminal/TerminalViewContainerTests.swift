//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    var _shouldReduceTransparency = false
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }

    override var shouldReduceTransparency: Bool {
        _shouldReduceTransparency
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }
    @Test @MainActor
    func radiusBlurMountsActiveBehindWindowVisualEffectViewAndRespectsOpaqueOverrides() async throws {
        let view = MockTerminalViewContainer {
            EmptyView()
        }

        let darkBlur = MockConfig(backgroundBlur: .radius(20), backgroundColor: .black, backgroundOpacity: 0.85)
        view.ghosttyConfigDidChange(darkBlur, preferredBackgroundColor: .black)
        try await Task.sleep(for: .milliseconds(50))

        let blurView = try #require(view.backdropBlurView)
        #expect(view.glassEffectView == nil)
        #expect(blurView.effectView.blendingMode == .behindWindow)
        #expect(blurView.effectView.state == .active)
        #expect(blurView.effectView.material == .hudWindow)
        #expect(abs(blurView.effectView.alphaValue - 1.0) < 0.001)
        #expect(blurView.effectView.appearance?.name == .darkAqua)
        #expect(blurView.hitTest(.zero) == nil)

        // Light background + partial radius + window corner radius update in place.
        view._windowCornerRadius = 12
        let lightHalfBlur = MockConfig(backgroundBlur: .radius(10), backgroundColor: .white, backgroundOpacity: 0.85)
        view.ghosttyConfigDidChange(lightHalfBlur, preferredBackgroundColor: .white)
        try await Task.sleep(for: .milliseconds(50))

        #expect(view.backdropBlurView === blurView)
        #expect(blurView.effectView.appearance?.name == .aqua)
        #expect(abs(blurView.effectView.alphaValue - 0.5) < 0.001)
        #expect(blurView.effectView.layer?.cornerRadius == 12)

        // Window opaque override (e.g. native fullscreen or toggle_background_opacity) removes the blur view.
        view.ghosttyConfigDidChange(lightHalfBlur, preferredBackgroundColor: .white, isWindowOpaque: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.backdropBlurView == nil)

        // Restoring non-opaque re-mounts, while full backgroundOpacity (1.0), disabled blur,
        // or Accessibility Reduce Transparency each tear it down cleanly.
        view.ghosttyConfigDidChange(darkBlur, preferredBackgroundColor: .black, isWindowOpaque: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.backdropBlurView != nil)

        let fullOpacity = MockConfig(backgroundBlur: .radius(20), backgroundColor: .black, backgroundOpacity: 1.0)
        view.ghosttyConfigDidChange(fullOpacity, preferredBackgroundColor: .black)
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.backdropBlurView == nil)

        view._shouldReduceTransparency = true
        view.ghosttyConfigDidChange(darkBlur, preferredBackgroundColor: .black)
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.backdropBlurView == nil)

        view._shouldReduceTransparency = false
        view.ghosttyConfigDidChange(darkBlur, preferredBackgroundColor: .black)
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.backdropBlurView != nil)

        if #available(macOS 26.0, *) {
            let glass = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .black, backgroundOpacity: 0.85)
            view.ghosttyConfigDidChange(glass, preferredBackgroundColor: .black)
            try await Task.sleep(for: .milliseconds(50))
            #expect(view.backdropBlurView == nil)
            #expect(view.glassEffectView != nil)
        }
    }
}
