import Foundation

/// Shared compact tree geometry for Files and Git collections.
enum InspectorTreeLayout {
    static let leading: CGFloat = 10
    static let indent: CGFloat = 16
    static let disclosureWidth: CGFloat = 18
    static let iconWidth: CGFloat = 14
    static let iconGap: CGFloat = 6
    static let maximumCompactDepth = 24

    static func chain<Node>(from root: Node, next: (Node) -> Node?) -> [Node] {
        var nodes = [root]
        while nodes.count < maximumCompactDepth, let child = next(nodes[nodes.count - 1]) {
            nodes.append(child)
        }
        return nodes
    }
}
