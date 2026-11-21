const std = @import("std");
const Allocator = std.mem.Allocator;
const edit = @import("edit.zig");

pub const Options = struct {};

/// View files or links from the pane this command runs in.
///
///   omg +view README.md
///   omg +view --split right docs/guide.md
///   omg +view https://example.com
///
/// Markdown opens as a preview, other text in the OMG editor, and images,
/// PDFs and other binary files in their default application. An http(s) link
/// opens in the default browser. Unlike `+edit`, a missing file is an error.
///
/// Flags:
///
///   * `--split <right|down|left|up>`: Open in a new split.
///
///   * `--tab`: Open in a new tab.
///
///   * `--current`: Open over the current pane.
///
/// The macOS app handles this action itself, over its local control socket.
pub fn run(_: Allocator) !u8 {
    return edit.unsupported("+view");
}
