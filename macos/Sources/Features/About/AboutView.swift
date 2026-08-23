import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) var openURL

    private let githubURL = OhMyGhosttyVersion.repositoryURL
    private let upstreamURL = OhMyGhosttyVersion.upstreamURL
    private let docsURL = URL(string: "https://ghostty.org/docs")
    private let versions = OhMyGhosttyVersion()

    /// Read build metadata from the bundle.
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? { Bundle.main.infoDictionary?["GhosttyCommit"] as? String }
    private var releaseURL: URL? {
        guard let tag = versions.releaseTag else { return nil }
        return githubURL?
            .appendingPathComponent("releases")
            .appendingPathComponent("tag")
            .appendingPathComponent(tag)
    }
    private var ghosttyRevisionLabel: String {
        guard versions.ghosttyRevision != "unknown" else { return "unknown" }
        return String(versions.ghosttyRevision.prefix(12))
    }

    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    // This creates a background style similar to the Apple "About My Mac" Window
    private struct VisualEffectBackground: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
        let isEmphasized: Bool

        init(material: NSVisualEffectView.Material,
             blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
             isEmphasized: Bool = false) {
            self.material = material
            self.blendingMode = blendingMode
            self.isEmphasized = isEmphasized
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
            nsView.isEmphasized = isEmphasized
        }

        func makeNSView(context: Context) -> NSVisualEffectView {
            let visualEffect = NSVisualEffectView()
            visualEffect.autoresizingMask = [.width, .height]
            return visualEffect
        }
    }

    var body: some View {
        VStack(alignment: .center) {
            CyclingIconView()

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("Oh My Ghostty")
                        .bold()
                        .font(.title)
                    Text("Ghostty-powered terminal with native macOS extensions.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    PropertyRow(label: "OMG Version", text: versions.omg, url: releaseURL)
                    PropertyRow(label: "Ghostty Base", text: versions.ghostty)
                    if versions.ghosttyRevision != "unknown",
                       let url = upstreamURL?
                        .appendingPathComponent("commit")
                        .appendingPathComponent(versions.ghosttyRevision) {
                        PropertyRow(
                            label: "Base Revision",
                            text: ghosttyRevisionLabel,
                            url: url
                        )
                    }
                    if let build {
                        PropertyRow(label: "Build", text: build)
                    }
                    if let commit, commit != "",
                       let url = githubURL?
                        .appendingPathComponent("commit")
                        .appendingPathComponent(commit) {
                        PropertyRow(label: "Build Commit", text: commit, url: url)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button("Docs") {
                            openURL(url)
                        }
                    }
                    if let url = githubURL {
                        Button("GitHub") {
                            openURL(url)
                        }
                    }
                    if let url = upstreamURL {
                        Button("Ghostty") {
                            openURL(url)
                        }
                    }
                }

                if let copy = self.copyright {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 256)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }

    private struct PropertyRow: View {
        private let label: String
        private let text: String
        private let url: URL?

        init(label: String, text: String, url: URL? = nil) {
            self.label = label
            self.text = text
            self.url = url
        }

        @ViewBuilder private var textView: some View {
            Text(text)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .tint(.secondary)
                .opacity(0.8)
                .monospaced()
        }

        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .frame(width: 126, alignment: .trailing)
                    .padding(.trailing, 2)
                if let url {
                    Link(destination: url) {
                        textView
                    }
                } else {
                    textView
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
