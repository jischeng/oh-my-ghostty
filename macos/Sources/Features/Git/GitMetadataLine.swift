import AppKit

final class GitMetadataLine: NSView {
    struct Item { let text: String; let value: String; let label: String }
    private let first = InspectorClickCopyText()
    private let second = InspectorClickCopyText()
    private let separator = NSTextField(labelWithString: "·")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        separator.font = .systemFont(ofSize: 10)
        separator.textColor = .tertiaryLabelColor
        separator.alignment = .center
        [first, separator, second].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ first: Item, second: Item?) {
        self.first.configure(text: first.text, value: first.value, label: first.label)
        self.second.isHidden = second == nil
        separator.isHidden = second == nil
        if let second { self.second.configure(text: second.text, value: second.value, label: second.label) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let firstWidth = min(first.naturalWidth, second.isHidden ? bounds.width : max(28, bounds.width * 0.44))
        first.frame = NSRect(x: 0, y: 0, width: firstWidth, height: bounds.height)
        separator.frame = NSRect(x: firstWidth, y: 0, width: 12, height: bounds.height)
        second.frame = NSRect(x: firstWidth + 12, y: 0,
                              width: min(second.naturalWidth, max(1, bounds.width - firstWidth - 12)), height: bounds.height)
    }
}
