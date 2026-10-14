import AppKit

// Resolve an actual Regular face instead of relying on a family's default face
// or a numeric NSFontManager weight. Keep the terminal's family and point size.
enum QuickInputTypography {
    static func font(family: String?, size: CGFloat) -> NSFont {
        let manager = NSFontManager.shared
        let base = family.flatMap { family -> NSFont? in
            let regularName = manager.availableMembers(ofFontFamily: family)?.first { member in
                guard let face = member[1] as? String else { return false }
                return ["regular", "book", "normal"].contains(face.lowercased())
            }?.first as? String
            if let regularName, let font = NSFont(name: regularName, size: size) { return font }
            return NSFont(name: family, size: size) ?? manager.font(withFamily: family, traits: [], weight: 5, size: size)
        } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.regular.rawValue],
        ]
        // A Latin-only terminal font otherwise inherits AppKit's implicit CJK
        // cascade, which can select a noticeably heavier face than terminal text.
        if let cjk = NSFont(name: "PingFangSC-Regular", size: size) {
            attributes[.cascadeList] = [cjk.fontDescriptor]
        }
        let regular = manager.convert(base, toNotHaveTrait: [.boldFontMask, .italicFontMask])
        let descriptor = regular.fontDescriptor.addingAttributes(attributes)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
