const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config.zig").Config;
const global = @import("../global.zig");

pub const Options = struct {
    /// Emit machine-readable JSON diagnostics to stdout.
    json: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

pub const HealthStatus = enum {
    healthy,
    warning,
};

pub const AccessibilityReport = struct {
    status: HealthStatus,
    global_keybinds_configured: bool,
    accessibility_trusted: bool,
};

pub const RuntimeSSHReport = struct {
    status: HealthStatus,
    omgd_bundled: bool,
    omgd_revision: ?[]const u8,
    active_sessions: usize,
    total_session_records: usize,
    ssh_control_dir: []const u8,
    ssh_control_dir_exists: bool,
    ssh_control_dir_private: bool,
};

pub const BackupsReport = struct {
    status: HealthStatus,
    backup_files: usize,
    insecure_backups: usize,
};

pub const PortableSettingsReport = struct {
    status: HealthStatus,
    path: []const u8,
    exists: bool,
    private_mode: bool,
    has_ssh_hosts: bool,
    has_agent_policies: bool,
    has_git_diff: bool,
};

pub const DoctorReport = struct {
    status: HealthStatus,
    accessibility: AccessibilityReport,
    runtime_ssh: RuntimeSSHReport,
    agent_backups: BackupsReport,
    portable_settings: PortableSettingsReport,
};

pub const InspectParams = struct {
    home_dir: []const u8,
    executable_dir: ?[]const u8 = null,
    ssh_control_dir: []const u8,
    settings_rel_path: []const u8 = ".config/oh-my-ghostty/settings.json",
    has_global_keybinds: bool,
    accessibility_trusted: bool,
};

/// Inspect OMG host permissions, persistent session runtime, SSH ControlMaster
/// sockets, Agent dotfile `.omg.bak` backups, and portable `settings.json`.
///
///   omg +doctor
///   omg +doctor --json
///
/// Flags:
///
///   * `--json`: output structured JSON diagnostics instead of human-readable text.
pub fn run(gpa: Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var env = try global.environMap();
    defer env.deinit();
    const home_dir = env.get("HOME") orelse "";
    const executable_dir = std.process.executableDirPathAlloc(global.io(), alloc) catch null;
    const ssh_dir = try defaultSSHControlDir(alloc);

    const has_global = detectConfiguredGlobalKeybinds(gpa);
    const ax_trusted = checkMacOSAccessibilityTrusted();

    const settings_rel = if (executable_dir != null and std.mem.indexOf(u8, executable_dir.?, "OMG Dev.app") != null)
        ".config/oh-my-ghostty-dev/settings.json"
    else
        ".config/oh-my-ghostty/settings.json";

    const report = try inspectEnvironment(global.io(), alloc, .{
        .home_dir = home_dir,
        .executable_dir = executable_dir,
        .ssh_control_dir = ssh_dir,
        .settings_rel_path = settings_rel,
        .has_global_keybinds = has_global,
        .accessibility_trusted = ax_trusted,
    });

    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &buffer);
    const stdout = &stdout_writer.interface;

    if (opts.json) {
        try writeReportJSON(stdout, report);
    } else {
        try writeReportText(stdout, report);
    }
    try stdout.flush();

    return if (report.status == .healthy) 0 else 1;
}

fn defaultSSHControlDir(alloc: Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return try alloc.dupe(u8, "");
    }
    const uid = std.c.getuid();
    return try std.fmt.allocPrint(alloc, "/tmp/omg-git-{d}", .{uid});
}

fn detectConfiguredGlobalKeybinds(gpa: Allocator) bool {
    var cfg = Config.load(gpa) catch return false;
    defer cfg.deinit();
    cfg.finalize() catch return false;
    return configHasGlobalKeybinds(&cfg);
}

pub fn configHasGlobalKeybinds(cfg: *const Config) bool {
    var it = cfg.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .leader => {},
            inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
        }
    }
    return false;
}

fn checkMacOSAccessibilityTrusted() bool {
    if (comptime builtin.os.tag != .macos) return true;
    const handle = std.c.dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        .{ .LAZY = true },
    ) orelse return true;
    defer _ = std.c.dlclose(handle);
    const sym = std.c.dlsym(handle, "AXIsProcessTrusted") orelse return true;
    const Fn = *const fn () callconv(.c) u8;
    const func: Fn = @ptrCast(@alignCast(sym));
    return func() != 0;
}

pub fn inspectEnvironment(
    io: std.Io,
    alloc: Allocator,
    params: InspectParams,
) !DoctorReport {
    const ax_status: HealthStatus = if (params.has_global_keybinds and !params.accessibility_trusted)
        .warning
    else
        .healthy;

    const accessibility: AccessibilityReport = .{
        .status = ax_status,
        .global_keybinds_configured = params.has_global_keybinds,
        .accessibility_trusted = params.accessibility_trusted,
    };

    var omgd_bundled = false;
    var omgd_revision: ?[]const u8 = null;
    if (params.executable_dir) |exe_dir| {
        const helper_path = try std.fs.path.resolve(alloc, &.{ exe_dir, "..", "Resources", "session-runtime", "omgd" });
        const rev_path = try std.fs.path.resolve(alloc, &.{ exe_dir, "..", "Resources", "session-runtime", "revision" });
        if (std.Io.Dir.accessAbsolute(io, helper_path, .{})) |_| {
            if (readSmallFileTrimmed(io, alloc, rev_path)) |rev| {
                if (rev.len > 0) {
                    omgd_bundled = true;
                    omgd_revision = rev;
                }
            }
        } else |_| {}
    }

    var active_sessions: usize = 0;
    var total_records: usize = 0;
    if (params.home_dir.len > 0) {
        const run_root = try std.fs.path.join(alloc, &.{ params.home_dir, ".omg", "run" });
        if (std.Io.Dir.openDirAbsolute(io, run_root, .{ .iterate = true })) |run_dir_val| {
            var run_dir = run_dir_val;
            defer run_dir.close(io);
            var state_iter = run_dir.iterate();
            while (state_iter.next(io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                const sessions_rel = try std.fs.path.join(alloc, &.{ entry.name, "sessions" });
                var sessions_dir = run_dir.openDir(io, sessions_rel, .{ .iterate = true }) catch continue;
                defer sessions_dir.close(io);
                var sess_iter = sessions_dir.iterate();
                while (sess_iter.next(io) catch null) |sess_entry| {
                    if (sess_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, sess_entry.name, ".json")) continue;
                    total_records += 1;
                    const stem = sess_entry.name[0 .. sess_entry.name.len - ".json".len];
                    const closed_name = try std.fmt.allocPrint(alloc, "{s}.closed", .{stem});
                    if (sessions_dir.access(io, closed_name, .{})) |_| {
                        continue;
                    } else |_| {}
                    const full_json_path = try std.fs.path.join(alloc, &.{ run_root, sessions_rel, sess_entry.name });
                    if (readSmallFileTrimmed(io, alloc, full_json_path)) |json_bytes| {
                        if (!jsonIndicatesExited(alloc, json_bytes)) {
                            active_sessions += 1;
                        }
                    }
                }
            }
        } else |_| {}
    }

    var ssh_exists = false;
    var ssh_private = true;
    if (params.ssh_control_dir.len > 0) {
        if (std.Io.Dir.openDirAbsolute(io, params.ssh_control_dir, .{})) |dir_val| {
            var dir = dir_val;
            defer dir.close(io);
            ssh_exists = true;
            if (comptime builtin.os.tag != .windows) {
                if (dir.stat(io)) |st| {
                    ssh_private = (st.permissions.toMode() & 0o777) == 0o700;
                } else |_| {
                    ssh_private = false;
                }
            }
        } else |_| {}
    }

    const runtime_ssh: RuntimeSSHReport = .{
        .status = if (ssh_private) .healthy else .warning,
        .omgd_bundled = omgd_bundled,
        .omgd_revision = omgd_revision,
        .active_sessions = active_sessions,
        .total_session_records = total_records,
        .ssh_control_dir = params.ssh_control_dir,
        .ssh_control_dir_exists = ssh_exists,
        .ssh_control_dir_private = ssh_private,
    };

    const agent_rel_paths = [_][]const u8{
        ".claude/settings.json",
        ".codex/config.toml",
        ".codex/hooks.json",
        ".gemini/settings.json",
        ".gemini/config/hooks.json",
        ".cursor/hooks.json",
        ".hermes/config.yaml",
        ".kimi/config.toml",
        ".kimi-code/config.toml",
        ".qwen/settings.json",
        ".factory/settings.json",
        ".qoder/settings.json",
        ".reasonix/settings.json",
    };

    var backup_files: usize = 0;
    var insecure_backups: usize = 0;
    if (params.home_dir.len > 0) {
        for (agent_rel_paths) |rel| {
            const bak_path = try std.fmt.allocPrint(alloc, "{s}/{s}.omg.bak", .{ params.home_dir, rel });
            const file = std.Io.Dir.openFileAbsolute(io, bak_path, .{}) catch continue;
            defer file.close(io);
            backup_files += 1;
            if (comptime builtin.os.tag != .windows) {
                if (file.stat(io)) |st| {
                    if ((st.permissions.toMode() & 0o777) != 0o600) {
                        insecure_backups += 1;
                    }
                } else |_| {
                    insecure_backups += 1;
                }
            }
        }
    }

    const agent_backups: BackupsReport = .{
        .status = if (insecure_backups == 0) .healthy else .warning,
        .backup_files = backup_files,
        .insecure_backups = insecure_backups,
    };

    const settings_path = if (params.home_dir.len > 0)
        try std.fs.path.join(alloc, &.{ params.home_dir, params.settings_rel_path })
    else
        try alloc.dupe(u8, params.settings_rel_path);

    var settings_exists = false;
    var settings_private = true;
    var has_ssh_hosts = false;
    var has_agent_policies = false;
    var has_git_diff = false;
    var settings_valid = true;

    if (params.home_dir.len > 0) {
        if (std.Io.Dir.openFileAbsolute(io, settings_path, .{})) |file| {
            defer file.close(io);
            settings_exists = true;
            if (comptime builtin.os.tag != .windows) {
                if (file.stat(io)) |st| {
                    settings_private = (st.permissions.toMode() & 0o777) == 0o600;
                } else |_| {
                    settings_private = false;
                }
            }
            var reader = file.reader(io, &.{});
            if (reader.interface.allocRemaining(alloc, .limited(1024 * 1024))) |bytes| {
                if (std.json.parseFromSlice(std.json.Value, alloc, bytes, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        has_ssh_hosts = parsed.value.object.contains("sshHosts");
                        has_agent_policies = parsed.value.object.contains("agentPolicies");
                        has_git_diff = parsed.value.object.contains("gitDiff");
                    } else {
                        settings_valid = false;
                    }
                } else |_| {
                    settings_valid = false;
                }
            } else |_| {
                settings_valid = false;
            }
        } else |_| {}
    }

    const portable_settings: PortableSettingsReport = .{
        .status = if (settings_private and settings_valid) .healthy else .warning,
        .path = settings_path,
        .exists = settings_exists,
        .private_mode = settings_private,
        .has_ssh_hosts = has_ssh_hosts,
        .has_agent_policies = has_agent_policies,
        .has_git_diff = has_git_diff,
    };

    const overall: HealthStatus = if (accessibility.status == .warning or
        runtime_ssh.status == .warning or
        agent_backups.status == .warning or
        portable_settings.status == .warning)
        .warning
    else
        .healthy;

    return .{
        .status = overall,
        .accessibility = accessibility,
        .runtime_ssh = runtime_ssh,
        .agent_backups = agent_backups,
        .portable_settings = portable_settings,
    };
}

fn readSmallFileTrimmed(io: std.Io, alloc: Allocator, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const content = reader.interface.allocRemaining(alloc, .limited(256 * 1024)) catch return null;
    return std.mem.trim(u8, content, " \t\r\n");
}

fn jsonIndicatesExited(alloc: Allocator, raw: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    if (parsed.value.object.get("exited")) |exited_val| {
        if (exited_val == .bool) return exited_val.bool;
    }
    return false;
}

pub fn writeReportJSON(writer: *std.Io.Writer, report: DoctorReport) !void {
    try writer.print("{f}\n", .{std.json.fmt(report, .{})});
}

pub fn writeReportText(writer: *std.Io.Writer, report: DoctorReport) !void {
    try writer.print("OMG Doctor ({t})\n\n", .{report.status});

    try writer.print("Accessibility & Global Keybinds: {t}\n", .{report.accessibility.status});
    try writer.print("  - global keybinds configured: {}\n", .{report.accessibility.global_keybinds_configured});
    try writer.print("  - AXIsProcessTrusted        : {}\n", .{report.accessibility.accessibility_trusted});
    if (report.accessibility.global_keybinds_configured and !report.accessibility.accessibility_trusted) {
        try writer.print("  ! Grant Accessibility permission in System Settings > Privacy & Security > Accessibility (or Settings > Plugins > OMG Doctor).\n", .{});
    }

    try writer.print("\nSession Runtime & SSH: {t}\n", .{report.runtime_ssh.status});
    try writer.print("  - omgd bundled              : {}\n", .{report.runtime_ssh.omgd_bundled});
    if (report.runtime_ssh.omgd_revision) |rev| {
        try writer.print("  - omgd revision             : {s}\n", .{rev});
    }
    try writer.print("  - background sessions       : {d} active / {d} recorded\n", .{
        report.runtime_ssh.active_sessions,
        report.runtime_ssh.total_session_records,
    });
    try writer.print("  - SSH ControlMaster dir     : {s} (exists={}, private_0700={})\n", .{
        report.runtime_ssh.ssh_control_dir,
        report.runtime_ssh.ssh_control_dir_exists,
        report.runtime_ssh.ssh_control_dir_private,
    });

    try writer.print("\nAgent Backups (.omg.bak): {t}\n", .{report.agent_backups.status});
    try writer.print("  - private backups           : {d} total ({d} insecure)\n", .{
        report.agent_backups.backup_files,
        report.agent_backups.insecure_backups,
    });

    try writer.print("\nDotfiles-Portable Settings: {t}\n", .{report.portable_settings.status});
    try writer.print("  - file                      : {s} (exists={}, private_0600={})\n", .{
        report.portable_settings.path,
        report.portable_settings.exists,
        report.portable_settings.private_mode,
    });
    try writer.print("  - portable sections         : sshHosts={}, agentPolicies={}, gitDiff={}\n", .{
        report.portable_settings.has_ssh_hosts,
        report.portable_settings.has_agent_policies,
        report.portable_settings.has_git_diff,
    });
}

test "doctor reports TCC warning and audits sessions, backups, and portable settings" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const home_path = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);

    try tmp.dir.createDirPath(testing.io, "bundle/Resources/session-runtime");
    try tmp.dir.createDirPath(testing.io, "bundle/MacOS");
    {
        var f = try tmp.dir.createFile(testing.io, "bundle/Resources/session-runtime/omgd", .{});
        defer f.close(testing.io);
        var buf: [64]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("#!/bin/sh\n");
        try w.interface.flush();
    }
    {
        var f = try tmp.dir.createFile(testing.io, "bundle/Resources/session-runtime/revision", .{});
        defer f.close(testing.io);
        var buf: [64]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("rev-step6\n");
        try w.interface.flush();
    }

    try tmp.dir.createDirPath(testing.io, ".omg/run/state1/sessions");
    {
        var f = try tmp.dir.createFile(testing.io, ".omg/run/state1/sessions/live.json", .{});
        defer f.close(testing.io);
        var buf: [128]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("{\"exited\":false}\n");
        try w.interface.flush();
    }
    {
        var f = try tmp.dir.createFile(testing.io, ".omg/run/state1/sessions/done.json", .{});
        defer f.close(testing.io);
        var buf: [128]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("{\"exited\":true}\n");
        try w.interface.flush();
    }

    try tmp.dir.createDirPath(testing.io, ".claude");
    {
        var f = try tmp.dir.createFile(testing.io, ".claude/settings.json.omg.bak", .{
            .permissions = .fromMode(0o600),
        });
        defer f.close(testing.io);
        try f.setPermissions(testing.io, .fromMode(0o600));
    }

    try tmp.dir.createDirPath(testing.io, ".config/oh-my-ghostty");
    {
        var f = try tmp.dir.createFile(testing.io, ".config/oh-my-ghostty/settings.json", .{
            .permissions = .fromMode(0o600),
        });
        defer f.close(testing.io);
        try f.setPermissions(testing.io, .fromMode(0o600));
        var buf: [256]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("{\"sshHosts\":{},\"agentPolicies\":{},\"gitDiff\":{}}\n");
        try w.interface.flush();
    }

    try tmp.dir.createDirPath(testing.io, "ssh-mux");
    const ssh_mux_path = try std.fs.path.join(alloc, &.{ home_path, "ssh-mux" });
    {
        var d = try std.Io.Dir.openDirAbsolute(testing.io, ssh_mux_path, .{});
        defer d.close(testing.io);
        if (comptime builtin.os.tag != .windows) {
            try d.setPermissions(testing.io, .fromMode(0o700));
        }
    }

    const exe_dir = try std.fs.path.join(alloc, &.{ home_path, "bundle", "MacOS" });
    const report = try inspectEnvironment(testing.io, alloc, .{
        .home_dir = home_path,
        .executable_dir = exe_dir,
        .ssh_control_dir = ssh_mux_path,
        .has_global_keybinds = true,
        .accessibility_trusted = false,
    });

    try testing.expectEqual(HealthStatus.warning, report.status);
    try testing.expectEqual(HealthStatus.warning, report.accessibility.status);
    try testing.expect(report.runtime_ssh.omgd_bundled);
    try testing.expectEqualStrings("rev-step6", report.runtime_ssh.omgd_revision.?);
    try testing.expectEqual(@as(usize, 1), report.runtime_ssh.active_sessions);
    try testing.expectEqual(@as(usize, 2), report.runtime_ssh.total_session_records);
    try testing.expect(report.runtime_ssh.ssh_control_dir_private);
    try testing.expectEqual(@as(usize, 1), report.agent_backups.backup_files);
    try testing.expectEqual(@as(usize, 0), report.agent_backups.insecure_backups);
    try testing.expect(report.portable_settings.exists);
    try testing.expect(report.portable_settings.private_mode);
    try testing.expect(report.portable_settings.has_ssh_hosts);
    try testing.expect(report.portable_settings.has_agent_policies);
    try testing.expect(report.portable_settings.has_git_diff);

    var json_out: std.Io.Writer.Allocating = .init(alloc);
    try writeReportJSON(&json_out.writer, report);
    const parsed = try std.json.parseFromSlice(DoctorReport, alloc, json_out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(HealthStatus.warning, parsed.value.status);
    try testing.expectEqual(@as(usize, 1), parsed.value.runtime_ssh.active_sessions);
}
