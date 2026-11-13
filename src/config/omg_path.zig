//! Lower-priority macOS Cmd-click candidates. The host checks existence using
//! the source pane's filesystem before a candidate is underlined or opened, so
//! these patterns only need to find plausible spans, never prove a path.
const std = @import("std");
const oni = @import("oniguruma");

pub const quoted_regex =
    \\'(?![A-Za-z][A-Za-z0-9+.-]*:(?![0-9]))[^'"\r\n]+'|"(?![A-Za-z][A-Za-z0-9+.-]*:(?![0-9]))[^"'\r\n]+"|`(?![A-Za-z][A-Za-z0-9+.-]*:(?![0-9]))[^`\r\n]+`
;

const spaced_prefix =
    \\(?<![\w./~:@$+-])(?!(?:\.{3,}|[\w.\-/]*\.{3,}))(?:~/|/(?!/)|\.{1,2}/|[\w.\-]+/)
;

const spaced_token_char =
    \\[^\s/:*?"'<>|`\[\]{};&,\x{2018}-\x{201F}\x{3000}-\x{303F}\x{FF00}-\x{FF65}()]
;

const spaced_seg_token =
    "(?>(?:" ++ spaced_token_char ++ "|\\((?>" ++ spaced_token_char ++ "+)\\))+)";

const spaced_word_no_ext =
    "(?!" ++ spaced_token_char ++ "*\\.[a-z]{2,6}(?=\\s))" ++ spaced_seg_token;

const spaced_next_guard =
    \\(?!https?://|mailto:|file:|ssh://|git://|~/|\.{1,2}/)
;

const unspaced_dir = "(?>" ++ spaced_seg_token ++ "/)";

const spaced_dir =
    "(?>" ++ spaced_seg_token ++ "(?: " ++ spaced_next_guard ++ spaced_seg_token ++ "){1,5}/)";

const spaced_ext_tail =
    spaced_word_no_ext ++ "(?: " ++ spaced_next_guard ++ spaced_word_no_ext ++ "){0,6} " ++
    spaced_next_guard ++ "(?:" ++ spaced_token_char ++ "|\\((?>" ++ spaced_token_char ++ "+)\\))*\\.(?:7z|[A-Za-z][A-Za-z0-9_]{0,11})";

const spaced_title_dir_tail =
    \\[\w\-]+(?: [A-Z][\w\-]*){1,3}
;

const spaced_location_suffix =
    \\(?::[0-9]+(?::[0-9]+)?(?:-L?[0-9]+(?::[0-9]+)?)?|#L?[0-9]+(?:C[0-9]+)?(?:-L?[0-9]+(?:C[0-9]+)?)?)?
;

const spaced_trailing_guard =
    \\(?<![,.])(?![/\w~@$+-]|\.(?=[\w/-]))
;

/// Unquoted rooted/relative paths containing spaces inside directory segments
/// (e.g. `~/Library/Application Support/OMG Dev/workspaces/state.json`) or
/// spaced bundle/file names (e.g. `/Applications/OMG Dev.app`). Every match is
/// still verified against the pane's filesystem before underlining or opening.
pub const spaced_path_regex =
    spaced_prefix ++
    "(?:" ++
    "(?:" ++ unspaced_dir ++ ")*" ++ spaced_dir ++ "(?:" ++ unspaced_dir ++ "|" ++ spaced_dir ++ ")*(?:" ++ spaced_ext_tail ++ "|" ++ spaced_title_dir_tail ++ "|" ++ spaced_seg_token ++ ")?" ++
    "|" ++
    "(?:" ++ unspaced_dir ++ ")*(?:" ++ spaced_ext_tail ++ "|" ++ spaced_title_dir_tail ++ ")" ++
    ")" ++
    spaced_location_suffix ++
    spaced_trailing_guard;

// Plain ls -l (including localized month names), without Nerd Font icons.
// Consume the metadata as context, but \K makes only the filename clickable.
// Do not accept arbitrary bare words: owner/size/date columns stay unlinked.
const listing_regex =
    \\(?m)^[d-][rwxstST-]{9}[+@.]?[ \t]+\d+[ \t]+\S+[ \t]+\S+[ \t]+\S+[ \t]+(?:\S+[ \t]+\d{1,2}[ \t]+(?:\d{1,2}:\d{2}|\d{4})|\d{4}-\d{2}-\d{2}[ \t]+\d{1,2}:\d{2})[ \t]+\K[\w.\-]+/?(?=[ \t]*(?:\r?$|\x00))
;

pub const regex = listing_regex ++ "|" ++
    \\(?<![\w./~:@$+-])(?!/(?![\w./-]))(?!(?:\.{3,}|[\w.\-/]*\.{3,}))(?![0-9]+(?:[A-Za-z]+)?\.[0-9]+)(?:(?:~|/|\.{1,2}/|[\w.\-]+/)[\w./-]*|\.[A-Za-z0-9_][\w.\-]*(?![\w.\-(])|(?![0-9]+\.[0-9]+)[^\s/:*?"'<>|()\x{2018}-\x{201F}\x{3000}-\x{303F}\x{FF00}-\x{FF65}]+\.(?:7z|[A-Za-z][A-Za-z0-9_]{0,7})|(?:Makefile|Dockerfile|Containerfile|Vagrantfile|Gemfile|Rakefile|LICENSE|LICENCE|README)|\.{1,2}|(?<=[📁📂\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}]\s|[📁📂\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}]\s\s)[\w.\-]+)(?::[0-9]+(?::[0-9]+)?(?:-[0-9]+(?::[0-9]+)?)?|#L?[0-9]+(?:-L?[0-9]+)?)?(?![/\w.~@$+-])
;

test "OMG bare path candidates" {
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(quoted_regex ++ "|" ++ regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "README.md", .expected = "README.md" },
        .{ .input = "\"b=Path('/home/user/project/lake_search/ETL/bag_topic_pipeline')\\nfor rel in\"", .expected = "'/home/user/project/lake_search/ETL/bag_topic_pipeline'" },
        .{ .input = "drwx------ 2 chengjisheng chengjisheng 4.0K 10月 12 14:32 adapter", .expected = "adapter" },
        .{ .input = "drwxr-xr-x 12 user group 4096 Oct 12 2025 backend", .expected = "backend" },
        .{ .input = "drwxr-xr-x 2 user group 4096 2026-10-12 14:32 bi_board_server_frontend", .expected = "bi_board_server_frontend" },
        .{ .input = "-rw------- 1 user group 42 Oct 12 14:32 env", .expected = "env" },
        .{ .input = "📁 src", .expected = "src" },
        // Nerd Font icons (eza/lsd) live in the Private Use Area.
        .{ .input = "\u{F07B} nix", .expected = "nix" },
        .{ .input = "\u{F0214} env", .expected = "env" },
        .{ .input = "\u{E5FF}  zig-out", .expected = "zig-out" },
        .{ .input = "chengjisheng 20 Aug 17:45 \u{E779} Makefile", .expected = "Makefile" },
        .{ .input = "'src'", .expected = "'src'" },
        .{ .input = "'README.md'", .expected = "'README.md'" },
        .{ .input = "'App icon.icon'", .expected = "'App icon.icon'" },
        .{ .input = "\"App icon.icon\"", .expected = "\"App icon.icon\"" },
        .{ .input = "'/tmp/App icon.icon'", .expected = "'/tmp/App icon.icon'" },
        .{ .input = "`~/Library/Application Support/OMG Dev/workspaces/state.json`", .expected = "`~/Library/Application Support/OMG Dev/workspaces/state.json`" },
        .{ .input = "`/Applications/OMG Dev.app`", .expected = "`/Applications/OMG Dev.app`" },
        .{ .input = "(README.md)", .expected = "README.md" },
        .{ .input = "README.md:12:3", .expected = "README.md:12:3" },
        .{ .input = "README.md:12-40", .expected = "README.md:12-40" },
        .{ .input = "src/foo.py:1212-1223", .expected = "src/foo.py:1212-1223" },
        .{ .input = "README.md#L12-L40", .expected = "README.md#L12-L40" },
        .{ .input = "'README.md:12-40'", .expected = "'README.md:12-40'" },
        .{ .input = ".gitignore", .expected = ".gitignore" },
        .{ .input = ".pi/test-runs/safety-state-week-20261105/week-monitor/progress.json", .expected = ".pi/test-runs/safety-state-week-20261105/week-monitor/progress.json" },
        .{ .input = "src/subdir/", .expected = "src/subdir/" },
        .{ .input = "中文.md", .expected = "中文.md" },
        .{ .input = "..", .expected = ".." },
        .{ .input = "README.md,", .expected = "README.md" },
        .{ .input = "~/code/file.txt", .expected = "~/code/file.txt" },
        .{ .input = "/tmp/file", .expected = "/tmp/file" },
        .{ .input = "./run.sh", .expected = "./run.sh" },
        .{ .input = "../parent/file.zig", .expected = "../parent/file.zig" },
        .{ .input = "1.txt", .expected = "1.txt" },
        .{ .input = "archive.7z", .expected = "archive.7z" },
        // CJK prose: full-width punctuation ends the candidate.
        .{ .input = "放到了上层（AgentQuickInput.swift 加了", .expected = "AgentQuickInput.swift" },
        .{ .input = "规则（omg_path.zig）", .expected = "omg_path.zig" },
        .{ .input = "见 omg_path.zig。", .expected = "omg_path.zig" },
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
        "1.4M",
        "5.6k",
        "10.2MB",
        "3.14",
        "0.5s",
        "1.2.3",
        ".../Marked",
        "git",
        "status",
        "12:34:56",
        "drwxr-xr-x@",
        "chengjisheng 20 Aug 17:45",
        "/",
        " / ",
        // A method call is not a dotfile.
        ".zIndex(1)",
    }) |input| {
        if (re.search(input, .{})) |result| {
            var match = result;
            match.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "OMG spaced path candidates" {
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(spaced_path_regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{
            .input = "我刚直接查了你本机 ~/Library/Application Support/OMG Dev/workspaces/state.json 和 ~/.omg/run/ 里的会话文件",
            .expected = "~/Library/Application Support/OMG Dev/workspaces/state.json",
        },
        .{
            .input = "现在可以直接在已安装的 /Applications/OMG Dev.app 中一并验收这几项",
            .expected = "/Applications/OMG Dev.app",
        },
        .{
            .input = "Checked ~/Library/Application Support/OMG Dev/workspaces/state.json and README.md",
            .expected = "~/Library/Application Support/OMG Dev/workspaces/state.json",
        },
        .{
            .input = "See ~/Library/Application Support for details",
            .expected = "~/Library/Application Support",
        },
        .{
            .input = "查了 ~/Library/Application Support 里的会话",
            .expected = "~/Library/Application Support",
        },
        .{
            .input = "Edit macos/Sources/Ghostty/Surface View/SurfaceLinkHint.swift:48 now",
            .expected = "macos/Sources/Ghostty/Surface View/SurfaceLinkHint.swift:48",
        },
        .{
            .input = "Xcode at /Volumes/My Shared Files/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
            .expected = "/Volumes/My Shared Files/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
        },
        .{
            .input = "Saved ~/Desktop/Screen Shot 2026-11-13 at 14.30.00.png.",
            .expected = "~/Desktop/Screen Shot 2026-11-13 at 14.30.00.png",
        },
        .{
            .input = "Report (~/Downloads/report (1).pdf) ready",
            .expected = "~/Downloads/report (1).pdf",
        },
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
        "cd /repo && make",
        "https://example.com/a b",
        "~/.omg/run/",
        "Please click Yes/No to continue",
    }) |input| {
        if (re.search(input, .{})) |result| {
            var match = result;
            match.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
