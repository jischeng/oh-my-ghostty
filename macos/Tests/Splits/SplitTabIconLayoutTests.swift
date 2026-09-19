import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SplitTabIconLayoutTests {
    // MARK: - Single Pane

    @Test func singlePaneReturnsFullSlot() {
        let viewA = MockView()
        let tree = SplitTree<MockView>(view: viewA)
        let slots = SplitTabIconLayout.layout(tree: tree)

        #expect(slots.count == 1)
        #expect(slots[0].rect == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(slots[0].views.count == 1)
        #expect(slots[0].views.first?.id == viewA.id)
        #expect(!slots[0].isFolded)
    }

    @Test func emptyTreeReturnsNoSlots() {
        let tree = SplitTree<MockView>()
        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.isEmpty)
    }

    // MARK: - 2 Panes (左右 Split & 上下 Split)

    @Test func horizontalSplitReturnsLeftAndRightSlots() throws {
        let viewA = MockView()
        let viewB = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .right)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 2)

        #expect(slots[0].rect == CGRect(x: 0, y: 0, width: 0.5, height: 1.0))
        #expect(slots[0].views.first?.id == viewA.id)
        #expect(!slots[0].isFolded)

        #expect(slots[1].rect == CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0))
        #expect(slots[1].views.first?.id == viewB.id)
        #expect(!slots[1].isFolded)
    }

    @Test func verticalSplitReturnsTopAndBottomSlots() throws {
        let viewA = MockView()
        let viewB = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .down)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 2)

        #expect(slots[0].rect == CGRect(x: 0, y: 0, width: 1.0, height: 0.5))
        #expect(slots[0].views.first?.id == viewA.id)
        #expect(!slots[0].isFolded)

        #expect(slots[1].rect == CGRect(x: 0, y: 0.5, width: 1.0, height: 0.5))
        #expect(slots[1].views.first?.id == viewB.id)
        #expect(!slots[1].isFolded)
    }

    // MARK: - 3 Pane：左 1，右侧上下 Split

    @Test func threePanesLeftOneRightTwo() throws {
        // Tree: A on left, B and C on right split vertically
        let viewA = MockView()
        let viewB = MockView()
        let viewC = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .right)
        tree = try tree.inserting(view: viewC, at: viewB, direction: .down)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 3)

        // Slot A: full height on left
        #expect(slots[0].rect == CGRect(x: 0, y: 0, width: 0.5, height: 1.0))
        #expect(slots[0].views.first?.id == viewA.id)
        #expect(!slots[0].isFolded)

        // Slot B: top right quadrant
        #expect(slots[1].rect == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(slots[1].views.first?.id == viewB.id)
        #expect(!slots[1].isFolded)

        // Slot C: bottom right quadrant
        #expect(slots[2].rect == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(slots[2].views.first?.id == viewC.id)
        #expect(!slots[2].isFolded)
    }

    @Test func threePanesTopOneBottomTwo() throws {
        // Tree: A on top, B and C on bottom split horizontally
        let viewA = MockView()
        let viewB = MockView()
        let viewC = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .down)
        tree = try tree.inserting(view: viewC, at: viewB, direction: .right)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 3)

        // Slot A: full width on top
        #expect(slots[0].rect == CGRect(x: 0, y: 0, width: 1.0, height: 0.5))
        #expect(slots[0].views.first?.id == viewA.id)
        #expect(!slots[0].isFolded)

        // Slot B: bottom left quadrant
        #expect(slots[1].rect == CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        #expect(slots[1].views.first?.id == viewB.id)
        #expect(!slots[1].isFolded)

        // Slot C: bottom right quadrant
        #expect(slots[2].rect == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(slots[2].views.first?.id == viewC.id)
        #expect(!slots[2].isFolded)
    }

    // MARK: - 4 Pane：允许的最小完整布局 (2x2)

    @Test func fourPanesTwoByTwo() throws {
        let viewA = MockView()
        let viewB = MockView()
        let viewC = MockView()
        let viewD = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .right)
        tree = try tree.inserting(view: viewC, at: viewA, direction: .down)
        tree = try tree.inserting(view: viewD, at: viewB, direction: .down)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 4)

        // Quadrants: top-left (A), bottom-left (C), top-right (B), bottom-right (D)
        for slot in slots {
            #expect(slot.rect.width == 0.5)
            #expect(slot.rect.height == 0.5)
            #expect(!slot.isFolded)
            #expect(slot.views.count == 1)
        }

        let rects = Set(slots.map { "\($0.rect.minX),\($0.rect.minY)" })
        #expect(rects == ["0.0,0.0", "0.0,0.5", "0.5,0.0", "0.5,0.5"])
    }

    // MARK: - 继续 Split：不再继续缩小，而是在当前位置折叠

    @Test func fivePanesFoldsAtQuadrant() throws {
        let viewA = MockView()
        let viewB = MockView()
        let viewC = MockView()
        let viewD = MockView()
        let viewE = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .right)
        tree = try tree.inserting(view: viewC, at: viewA, direction: .down)
        tree = try tree.inserting(view: viewD, at: viewB, direction: .down)
        // Split viewD further: adding E. D and E cannot split further since width/height would be < 0.5.
        tree = try tree.inserting(view: viewE, at: viewD, direction: .right)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 4)

        // Find the slot containing D and E
        let foldedSlot = slots.first { $0.views.contains { $0.id == viewD.id } }
        #expect(foldedSlot != nil)
        #expect(foldedSlot?.isFolded == true)
        #expect(foldedSlot?.views.count == 2)
        #expect(foldedSlot?.rect == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))

        // The other 3 slots remain unfolded single-pane slots
        let normalSlots = slots.filter { !$0.isFolded }
        #expect(normalSlots.count == 3)
        for slot in normalSlots {
            #expect(slot.views.count == 1)
            #expect(slot.rect.width == 0.5)
            #expect(slot.rect.height == 0.5)
        }
    }

    @Test func threeHorizontalPanesFoldsSecondSlot() throws {
        // A | B | C: splitting B and C horizontally would result in width 0.25 < 0.5
        let viewA = MockView()
        let viewB = MockView()
        let viewC = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .right)
        tree = try tree.inserting(view: viewC, at: viewB, direction: .right)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 2)

        #expect(slots[0].rect == CGRect(x: 0, y: 0, width: 0.5, height: 1.0))
        #expect(!slots[0].isFolded)
        #expect(slots[0].views.count == 1)

        #expect(slots[1].rect == CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0))
        #expect(slots[1].isFolded)
        #expect(slots[1].views.count == 2)
        #expect(slots[1].views.map(\.id) == [viewB.id, viewC.id])
    }

    @Test func threeVerticalPanesFoldsBottomSlot() throws {
        // A / B / C: splitting B and C vertically would result in height 0.25 < 0.5
        let viewA = MockView()
        let viewB = MockView()
        let viewC = MockView()
        var tree = SplitTree<MockView>(view: viewA)
        tree = try tree.inserting(view: viewB, at: viewA, direction: .down)
        tree = try tree.inserting(view: viewC, at: viewB, direction: .down)

        let slots = SplitTabIconLayout.layout(tree: tree)
        #expect(slots.count == 2)

        #expect(slots[0].rect == CGRect(x: 0, y: 0, width: 1.0, height: 0.5))
        #expect(!slots[0].isFolded)
        #expect(slots[0].views.count == 1)

        #expect(slots[1].rect == CGRect(x: 0, y: 0.5, width: 1.0, height: 0.5))
        #expect(slots[1].isFolded)
        #expect(slots[1].views.count == 2)
        #expect(slots[1].views.map(\.id) == [viewB.id, viewC.id])
    }

    // MARK: - Geometric Invariants

    @Test func invariantsHoldAcrossAllLayouts() throws {
        let views = (0..<8).map { _ in MockView() }
        var tree = SplitTree<MockView>(view: views[0])
        tree = try tree.inserting(view: views[1], at: views[0], direction: .right)
        tree = try tree.inserting(view: views[2], at: views[0], direction: .down)
        tree = try tree.inserting(view: views[3], at: views[1], direction: .down)
        tree = try tree.inserting(view: views[4], at: views[3], direction: .right)
        tree = try tree.inserting(view: views[5], at: views[4], direction: .down)
        tree = try tree.inserting(view: views[6], at: views[2], direction: .right)
        tree = try tree.inserting(view: views[7], at: views[0], direction: .right)

        let slots = SplitTabIconLayout.layout(tree: tree)

        // 1. Max 4 slots (2x2)
        #expect(slots.count <= 4)

        // 2. Minimum slot width and height are >= 0.5
        for slot in slots {
            #expect(slot.rect.width >= 0.5 - 0.001)
            #expect(slot.rect.height >= 0.5 - 0.001)
            #expect(slot.rect.minX >= 0)
            #expect(slot.rect.minY >= 0)
            #expect(slot.rect.maxX <= 1.0 + 0.001)
            #expect(slot.rect.maxY <= 1.0 + 0.001)
        }

        // 3. Total area covers exactly 1.0
        let totalArea = slots.reduce(0.0) { $0 + ($1.rect.width * $1.rect.height) }
        #expect(abs(totalArea - 1.0) < 0.001)

        // 4. All 8 views are accounted for in the slots
        let allViewsInSlots = slots.flatMap(\.views)
        #expect(allViewsInSlots.count == 8)
    }
}
