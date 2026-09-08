//! Lower-priority macOS Cmd-click candidates. The host checks existence using
//! the source pane's filesystem before opening; ordinary words may be candidates.
const std = @import("std");
const oni = @import("oniguruma");

pub const quoted_regex =
    \\'(?![A-Za-z][A-Za-z0-9+.-]*:)[^'\r\n]+'|"(?![A-Za-z][A-Za-z0-9+.-]*:)[^"\r\n]+"
;

pub const regex =
    \\(?<![\w./~:@$+-])(?!(?:\.{3,}|[\w.\-/]*\.{3,}))(?:(?:~|/|\.{1,2}/|[\w.\-]+/)[\w./-]*|\.[A-Za-z0-9_][\w.\-]*|[^\s/:*?"'<>|()]+\.[A-Za-z0-9_]{1,8}|(?:Makefile|Dockerfile|Containerfile|Vagrantfile|Gemfile|Rakefile|LICENSE|LICENCE|README)|\.{1,2}|(?<=[📁📂]\s)[\w.\-]+)(?::[0-9]+(?::[0-9]+)?)?(?![/\w.~@$+-])
;

test "OMG bare path candidates" {
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(quoted_regex ++ "|" ++ regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "README.md", .expected = "README.md" },
        .{ .input = "📁 src", .expected = "src" },
        .{ .input = "'src'", .expected = "'src'" },
        .{ .input = "'README.md'", .expected = "'README.md'" },
        .{ .input = "'App icon.icon'", .expected = "'App icon.icon'" },
        .{ .input = "\"App icon.icon\"", .expected = "\"App icon.icon\"" },
        .{ .input = "'/tmp/App icon.icon'", .expected = "'/tmp/App icon.icon'" },
        .{ .input = "(README.md)", .expected = "README.md" },
        .{ .input = "README.md:12:3", .expected = "README.md:12:3" },
        .{ .input = ".gitignore", .expected = ".gitignore" },
        .{ .input = "src/subdir/", .expected = "src/subdir/" },
        .{ .input = "中文.md", .expected = "中文.md" },
        .{ .input = "..", .expected = ".." },
        .{ .input = "README.md,", .expected = "README.md" },
        .{ .input = "~/code/file.txt", .expected = "~/code/file.txt" },
        .{ .input = "/tmp/file", .expected = "/tmp/file" },
        .{ .input = "./run.sh", .expected = "./run.sh" },
        .{ .input = "../parent/file.zig", .expected = "../parent/file.zig" },
    };
    for (cases) |case| {
        var match = try re.search(case.input, .{});
        defer match.deinit();
        try std.testing.expectEqualStrings(
            case.expected,
            case.input[@intCast(match.starts()[0])..@intCast(match.ends()[0])],
        );
    }
    for ([_][]const u8{
        "https://example.com/file",
        "'https://example.com/file'",
        "\"mailto:user@example.com\"",
        "mailto:user@example.com",
        "$HOME",
        "--option",
        "chegnjisheng",
        "main",
        "20:35",
        ".../Marked",
        "git",
        "status",
        "12:34:56",
    }) |input| {
        if (re.search(input, .{})) |result| {
            var match = result;
            match.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
