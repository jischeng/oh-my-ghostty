import UIKit

final class OMGAcknowledgements: UITableViewController {
    private let projects: [(String, String, String)] = [
        ("Ghostty", "Terminal foundation and VT engine", "https://github.com/ghostty-org/ghostty"),
        ("Termio", "Reused iOS application, terminal rendering and interaction", "https://github.com/termio-sh/termio"),
        ("Remux", "Mobile terminal and shared-session reference", "https://github.com/h3nock/remux"),
        ("Paseo", "Mobile agent conversation and interaction reference", "https://github.com/getpaseo/paseo"),
        ("Orca", "Mobile agent controls and provider reference", "https://github.com/stablyai/orca"),
        ("Visual Studio Code", "Workspace, Git and remote-development reference", "https://github.com/microsoft/vscode"),
        ("CodeEdit / CodeEditSourceEditor", "Desktop native editor component", "https://github.com/CodeEditApp/CodeEditSourceEditor"),
        ("CodeMirror", "Desktop Markdown editor", "https://codemirror.net"),
        ("Mermaid", "Diagram rendering", "https://mermaid.js.org"),
        ("Agent Client Protocol", "Agent adapter ecosystem", "https://agentclientprotocol.com"),
        ("Herdr", "Inline terminal viewer portions adapted for OMG", "https://github.com/herdrdev/herdr-core"),
        ("libghostty-swift", "Original mobile terminal integration", "https://github.com/termio-sh/libghostty-swift"),
        ("Highlightr", "Syntax highlighting", "https://github.com/raspu/Highlightr"),
        ("Nerd Fonts", "Bundled terminal symbol font (Symbols Nerd Font Mono)", "https://github.com/ryanoasis/nerd-fonts"),
    ]
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); title = localized("Acknowledgements") }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { projects.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = projects[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = row.0
        cell.detailTextLabel?.text = row.1
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let url = URL(string: projects[indexPath.row].2) { UIApplication.shared.open(url) }
    }
}
