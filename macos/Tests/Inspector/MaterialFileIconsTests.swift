import AppKit
import Testing
@testable import Ghostty

@MainActor
struct MaterialFileIconsTests {
    @Test func resolvesLanguageIconsAndCompoundExtensions() {
        for (filename, icon) in [
            ("main.py", "python"), ("App.swift", "swift"), ("build.zig", "zig"),
            ("data.xml", "xml"), ("index.ts", "typescript"), ("index.js", "javascript"),
            ("package.json", "nodejs"), ("types.d.ts", "typescript-def"),
            ("README.md", "readme"), ("unknown.unregistered", "file"),
        ] {
            #expect(MaterialFileIcons.assetName(for: filename, isDirectory: false) == "material-" + icon)
        }
        #expect(MaterialFileIcons.assetName(for: "MAIN.PY", isDirectory: false) == "material-python")
        #expect(MaterialFileIcons.assetName(
            for: "SConstruct", isDirectory: false, isLight: true
        ) == "material-scons_light")
    }

    @Test func directoriesUseExpandedArtwork() {
        #expect(MaterialFileIcons.assetName(for: "unregistered", isDirectory: true) == "material-folder")
        #expect(MaterialFileIcons.assetName(
            for: "unregistered", isDirectory: true, isExpanded: true
        ) == "material-folder-open")
        #expect(MaterialFileIcons.assetName(for: "src", isDirectory: true) == "material-folder-src")
    }

    @Test func bundledAssociationsHaveRenderableArtworkAndLicense() throws {
        let data = try #require(NSDataAsset(name: "material-icon-associations")?.data)
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var icons: Set<String> = ["file", "folder", "folder-open"]
        for variant in [manifest, manifest["light"] as? [String: Any] ?? [:]] {
            for key in ["fileNames", "fileExtensions", "folderNames", "folderNamesExpanded"] {
                let associations = try #require(variant[key] as? [String: String])
                icons.formUnion(associations.values)
            }
        }
        for icon in icons {
            #expect(NSImage(named: "material-" + icon) != nil, "Missing Material icon: \(icon)")
        }
        // Exercise native decoding/rasterization, not merely association lookup.
        let image = try #require(NSImage(named: "material-python"))
        var rect = NSRect(x: 0, y: 0, width: 32, height: 32)
        #expect(image.cgImage(forProposedRect: &rect, context: nil, hints: nil) != nil)
        let license = try #require(NSDataAsset(name: "material-icon-license")?.data)
        #expect(String(data: license, encoding: .utf8)?.contains("The MIT License") == true)
    }
}
