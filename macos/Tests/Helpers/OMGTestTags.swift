import Testing

extension Tag {
    /// Optional tests that require an unlocked desktop and a foreground key window.
    /// Enable explicitly with macos/build.nu --action test --include-desktop-tests.
    @Tag static var interactiveDesktop: Self
}
