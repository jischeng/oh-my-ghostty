import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalTabSelectionRestorationTests {
    @Test func restoresSeventhTabByIdentityRegardlessOfCreationOrder() throws {
        let tabs = (0..<7).map { _ in UUID() }
        let state = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: tabs, selected: tabs[6])], foreground: tabs[6]
        )
        let decoded = try JSONDecoder().decode(TerminalTabSelectionRestoration.Snapshot.self,
                                                from: JSONEncoder().encode(state))
        #expect(decoded.selection(for: Set(tabs.reversed())) == tabs[6])
        #expect(decoded.foreground == tabs[6])
        #expect(decoded.selection(for: Set(tabs.dropLast())) == nil)
        #expect(decoded.selection(for: [UUID()]) == nil)
    }

    @Test func quitCapturesSelectionBeforeTeardownAndCancellationUnfreezesIt() throws {
        let tabs = (0..<7).map { _ in UUID() }
        let seventh = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: tabs, selected: tabs[6])], foreground: tabs[6]
        )
        let first = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: tabs, selected: tabs[0])], foreground: tabs[0]
        )
        var current = seventh
        let service = TerminalTabSelectionRestoration(captureSnapshot: { current })
        service.prepareToQuit()
        current = first // AppKit switches tabs during termination/confirmation.
        #expect(try encodedSnapshot(service) == seventh)
        service.cancelQuit()
        #expect(try encodedSnapshot(service) == first)
    }

    private func encodedSnapshot(_ service: TerminalTabSelectionRestoration) throws
        -> TerminalTabSelectionRestoration.Snapshot {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        service.encode(into: coder)
        coder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        defer { decoder.finishDecoding() }
        let data = try #require(decoder.decodeObject(of: NSData.self,
            forKey: TerminalTabSelectionRestoration.codingKey) as Data?)
        return try JSONDecoder().decode(TerminalTabSelectionRestoration.Snapshot.self, from: data)
    }

    @Test func independentWindowsRestoreTheirOwnSelectedTabs() {
        let first = [UUID(), UUID()]
        let second = [UUID(), UUID(), UUID()]
        let state = TerminalTabSelectionRestoration.Snapshot(groups: [
            .init(members: first, selected: first[1]),
            .init(members: second, selected: second[2]),
        ], foreground: second[2])
        #expect(state.selection(for: Set(first)) == first[1])
        #expect(state.selection(for: Set(second)) == second[2])
        #expect(state.selection(for: Set(first + second)) == nil)
    }

    @Test func invalidSelectedIdentityNeverSelectsAnUnrelatedTab() {
        let members = [UUID(), UUID()]
        let state = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: members, selected: UUID())], foreground: nil
        )
        #expect(state.selection(for: Set(members)) == nil)
    }
}
