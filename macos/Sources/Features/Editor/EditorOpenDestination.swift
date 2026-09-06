import Foundation

enum EditorOpenDestination: String, CaseIterable, Sendable {
    case currentPane
    case newTab
    case splitRight
    case splitDown
    case splitLeft
    case splitUp

    var title: String {
        switch self {
        case .currentPane: "Current Pane"
        case .newTab: "New Tab"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .splitLeft: "Split Left"
        case .splitUp: "Split Up"
        }
    }

    var splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection {
        switch self {
        case .splitLeft: .left
        case .splitUp: .up
        case .splitDown: .down
        default: .right
        }
    }
}
