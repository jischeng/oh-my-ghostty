#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @testable import GhosttyTerminal
    import AppKit
    import Testing

    @Suite("AppTerminalFocus")
    @MainActor
    struct AppTerminalFocusTests {
        @Test
        func `focus move retries until view enters a window`() async throws {
            var wantsFocus = true
            let binding = makeBinding(value: { wantsFocus }, set: { wantsFocus = $0 })
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))

            synchronize(view, with: binding)
            try await Task.sleep(for: .milliseconds(20))

            let window = makeWindow()
            window.contentView?.addSubview(view)

            try await waitUntil { window.firstResponder === view }
            #expect(wantsFocus)
        }

        @Test
        func `orphaned intended focus is reasserted`() async throws {
            var wantsFocus = true
            let binding = makeBinding(value: { wantsFocus }, set: { wantsFocus = $0 })
            let window = makeWindow()
            let view = AppTerminalView(frame: window.contentView?.bounds ?? .zero)
            window.contentView?.addSubview(view)

            synchronize(view, with: binding)
            try await waitUntil { window.firstResponder === view }

            _ = window.makeFirstResponder(nil)
            try await waitUntil { window.firstResponder === view }

            #expect(wantsFocus)
        }

        @Test
        func `legitimate responder clears old surface intent`() async throws {
            var wantsFocus = true
            let binding = makeBinding(value: { wantsFocus }, set: { wantsFocus = $0 })
            let window = makeWindow()
            let view = AppTerminalView(frame: window.contentView?.bounds ?? .zero)
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
            window.contentView?.addSubview(view)
            window.contentView?.addSubview(field)

            synchronize(view, with: binding)
            try await waitUntil { window.firstResponder === view }

            #expect(window.makeFirstResponder(field))
            try await waitUntil { !wantsFocus }

            #expect(window.firstResponder === field.currentEditor() || window.firstResponder === field)
        }

        @Test
        func `window key callback does not rewrite surface focus intent`() {
            let view = AppTerminalView(frame: .zero)
            var reported: [Bool] = []
            view.onFocusChange = { reported.append($0) }

            view.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

            #expect(reported.isEmpty)
        }

        private func makeBinding(
            value: @escaping () -> Bool,
            set: @escaping (Bool) -> Void
        ) -> TerminalFocusBinding {
            TerminalFocusBinding(read: value, write: set)
        }

        private func synchronize(
            _ view: AppTerminalView,
            with binding: TerminalFocusBinding
        ) {
            // Mirror TerminalViewRepresentable@AppKit's callback plumbing.
            view.onFocusChange = { focused in
                binding.setFocused(focused)
            }
            view.synchronizeFocus(with: binding)
        }

        private func makeWindow() -> NSWindow {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
        }

        private func waitUntil(
            timeout: Duration = .seconds(1),
            condition: @escaping @MainActor () -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !condition() {
                guard clock.now < deadline else {
                    Issue.record("timed out waiting for focus condition")
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
#endif
