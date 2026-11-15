const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config.zig").Config;
const global = @import("../global.zig");

const fstatat_sym = if (builtin.os.tag == .windows) void else if (posix.lfs64_abi) posix.system.fstatat64 else posix.system.fstatat;

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

pub const SignerTrustMode = enum {
    apple_trusted,
    self_signed_admin_trusted,
    self_signed_user_only_trusted,
    self_signed_untrusted,
    ad_hoc_or_development,
    unsigned,
};

pub const SignerTrustReport = struct {
    status: HealthStatus,
    mode: SignerTrustMode,
    bundle_identifier: ?[]const u8 = null,
    team_identifier: ?[]const u8 = null,
    certificate_cn: ?[]const u8 = null,
    certificate_sha1: ?[]const u8 = null,
    is_self_signed_leaf: bool = false,
    trusted_in_admin_domain: bool = false,
    trusted_in_user_domain: bool = false,
    is_code_signing_trusted: bool = false,
    is_non_code_signing_blocked: bool = true,
    has_unscoped_trust: bool = false,
    recommended_fix_command: ?[]const u8 = null,
};

pub const DoctorReport = struct {
    status: HealthStatus,
    accessibility: AccessibilityReport,
    signer_trust: SignerTrustReport,
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
    expected_uid: ?u32 = null,
    signer_trust: ?SignerTrustReport = null,
};

pub fn settingsRelPathForExecutableDir(executable_dir: ?[]const u8) []const u8 {
    const dir = executable_dir orelse return ".config/oh-my-ghostty/settings.json";
    if (std.mem.indexOf(u8, dir, "OMG Dev PTY.app") != null) {
        return ".config/oh-my-ghostty-dev-pty/settings.json";
    }
    if (std.mem.indexOf(u8, dir, "OMG Dev Workspace.app") != null) {
        return ".config/oh-my-ghostty-dev-workspace/settings.json";
    }
    if (std.mem.indexOf(u8, dir, "OMG Dev.app") != null) {
        return ".config/oh-my-ghostty-dev/settings.json";
    }
    return ".config/oh-my-ghostty/settings.json";
}

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
    const signer_trust = checkMacOSSignerTrust(global.io(), alloc, executable_dir);

    const settings_rel = settingsRelPathForExecutableDir(executable_dir);

    const report = try inspectEnvironment(global.io(), alloc, .{
        .home_dir = home_dir,
        .executable_dir = executable_dir,
        .ssh_control_dir = ssh_dir,
        .settings_rel_path = settings_rel,
        .has_global_keybinds = has_global,
        .accessibility_trusted = ax_trusted,
        .signer_trust = signer_trust,
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

fn defaultSignerTrustReport() SignerTrustReport {
    return .{
        .status = .healthy,
        .mode = .ad_hoc_or_development,
    };
}

const MacOSCF = struct {
    handle: *anyopaque,
    release: *const fn (?*const anyopaque) callconv(.c) void,
    get_type_id: *const fn (?*const anyopaque) callconv(.c) c_ulong,
    string_get_type_id: *const fn () callconv(.c) c_ulong,
    string_create: *const fn (?*const anyopaque, [*:0]const u8, u32) callconv(.c) ?*const anyopaque,
    string_get_cstr: *const fn (?*const anyopaque, [*]u8, c_long, u32) callconv(.c) u8,
    url_from_fs: *const fn (?*const anyopaque, [*]const u8, c_long, u8) callconv(.c) ?*const anyopaque,
    data_create: *const fn (?*const anyopaque, [*]const u8, c_long) callconv(.c) ?*const anyopaque,
    data_get_len: *const fn (?*const anyopaque) callconv(.c) c_long,
    data_get_ptr: *const fn (?*const anyopaque) callconv(.c) [*]const u8,
    array_create: *const fn (?*const anyopaque, [*]const ?*const anyopaque, c_long, ?*const anyopaque) callconv(.c) ?*const anyopaque,
    array_get_count: *const fn (?*const anyopaque) callconv(.c) c_long,
    array_get_val: *const fn (?*const anyopaque, c_long) callconv(.c) ?*const anyopaque,
    dict_get_val: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) ?*const anyopaque,
    number_get_val: *const fn (?*const anyopaque, c_long, *anyopaque) callconv(.c) u8,
    array_callbacks: ?*const anyopaque,

    fn loadSym(comptime T: type, handle: *anyopaque, name: [:0]const u8) ?T {
        const sym = std.c.dlsym(handle, name) orelse return null;
        return @ptrCast(@alignCast(sym));
    }

    fn load() ?MacOSCF {
        const h = std.c.dlopen(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            .{ .LAZY = true },
        ) orelse return null;
        errdefer _ = std.c.dlclose(h);
        return .{
            .handle = h,
            .release = loadSym(@TypeOf(@as(MacOSCF, undefined).release), h, "CFRelease") orelse return null,
            .get_type_id = loadSym(@TypeOf(@as(MacOSCF, undefined).get_type_id), h, "CFGetTypeID") orelse return null,
            .string_get_type_id = loadSym(@TypeOf(@as(MacOSCF, undefined).string_get_type_id), h, "CFStringGetTypeID") orelse return null,
            .string_create = loadSym(@TypeOf(@as(MacOSCF, undefined).string_create), h, "CFStringCreateWithCString") orelse return null,
            .string_get_cstr = loadSym(@TypeOf(@as(MacOSCF, undefined).string_get_cstr), h, "CFStringGetCString") orelse return null,
            .url_from_fs = loadSym(@TypeOf(@as(MacOSCF, undefined).url_from_fs), h, "CFURLCreateFromFileSystemRepresentation") orelse return null,
            .data_create = loadSym(@TypeOf(@as(MacOSCF, undefined).data_create), h, "CFDataCreate") orelse return null,
            .data_get_len = loadSym(@TypeOf(@as(MacOSCF, undefined).data_get_len), h, "CFDataGetLength") orelse return null,
            .data_get_ptr = loadSym(@TypeOf(@as(MacOSCF, undefined).data_get_ptr), h, "CFDataGetBytePtr") orelse return null,
            .array_create = loadSym(@TypeOf(@as(MacOSCF, undefined).array_create), h, "CFArrayCreate") orelse return null,
            .array_get_count = loadSym(@TypeOf(@as(MacOSCF, undefined).array_get_count), h, "CFArrayGetCount") orelse return null,
            .array_get_val = loadSym(@TypeOf(@as(MacOSCF, undefined).array_get_val), h, "CFArrayGetValueAtIndex") orelse return null,
            .dict_get_val = loadSym(@TypeOf(@as(MacOSCF, undefined).dict_get_val), h, "CFDictionaryGetValue") orelse return null,
            .number_get_val = loadSym(@TypeOf(@as(MacOSCF, undefined).number_get_val), h, "CFNumberGetValue") orelse return null,
            .array_callbacks = std.c.dlsym(h, "kCFTypeArrayCallBacks"),
        };
    }

    fn deinit(self: MacOSCF) void {
        _ = std.c.dlclose(self.handle);
    }

    fn readCFString(self: MacOSCF, alloc: Allocator, ref: ?*const anyopaque) ?[]const u8 {
        const obj = ref orelse return null;
        if (self.get_type_id(obj) != self.string_get_type_id()) return null;
        var buf: [1024]u8 = undefined;
        if (self.string_get_cstr(obj, &buf, buf.len, 0x08000100) == 0) return null;
        const slice = std.mem.sliceTo(&buf, 0);
        return alloc.dupe(u8, slice) catch null;
    }

    fn readCFDataSlice(self: MacOSCF, ref: ?*const anyopaque) ?[]const u8 {
        const obj = ref orelse return null;
        const raw_len = self.data_get_len(obj);
        if (raw_len < 0) return null;
        const len: usize = @intCast(raw_len);
        const ptr = self.data_get_ptr(obj);
        return ptr[0..len];
    }
};

const MacOSSecurity = struct {
    handle: *anyopaque,
    static_code_create_with_path: *const fn (?*const anyopaque, u32, *?*const anyopaque) callconv(.c) i32,
    code_copy_signing_info: *const fn (?*const anyopaque, u32, *?*const anyopaque) callconv(.c) i32,
    cert_create_with_data: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) ?*const anyopaque,
    cert_copy_data: *const fn (?*const anyopaque) callconv(.c) ?*const anyopaque,
    cert_copy_subject_summary: *const fn (?*const anyopaque) callconv(.c) ?*const anyopaque,
    cert_copy_norm_subject: *const fn (?*const anyopaque) callconv(.c) ?*const anyopaque,
    cert_copy_norm_issuer: *const fn (?*const anyopaque) callconv(.c) ?*const anyopaque,
    trust_settings_copy: *const fn (?*const anyopaque, u32, *?*const anyopaque) callconv(.c) i32,
    policy_get_type_id: *const fn () callconv(.c) c_ulong,
    policy_copy_props: *const fn (?*const anyopaque) callconv(.c) ?*const anyopaque,
    policy_create_with_props: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) ?*const anyopaque,
    policy_create_basic_x509: *const fn () callconv(.c) ?*const anyopaque,
    policy_create_ssl: *const fn (u8, ?*const anyopaque) callconv(.c) ?*const anyopaque,
    trust_create_with_certs: *const fn (?*const anyopaque, ?*const anyopaque, *?*const anyopaque) callconv(.c) i32,
    trust_evaluate_with_error: *const fn (?*const anyopaque, *?*const anyopaque) callconv(.c) u8,
    k_code_info_certs: ?*const anyopaque,
    k_code_info_team: ?*const anyopaque,
    k_code_info_identifier: ?*const anyopaque,
    k_policy_apple_codesigning: ?*const anyopaque,
    k_policy_oid: ?*const anyopaque,

    fn loadCFGlobal(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        const sym = std.c.dlsym(handle, name) orelse return null;
        return @as(*const ?*const anyopaque, @ptrCast(@alignCast(sym))).*;
    }

    fn load() ?MacOSSecurity {
        const h = std.c.dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            .{ .LAZY = true },
        ) orelse return null;
        errdefer _ = std.c.dlclose(h);
        return .{
            .handle = h,
            .static_code_create_with_path = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).static_code_create_with_path), h, "SecStaticCodeCreateWithPath") orelse return null,
            .code_copy_signing_info = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).code_copy_signing_info), h, "SecCodeCopySigningInformation") orelse return null,
            .cert_create_with_data = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).cert_create_with_data), h, "SecCertificateCreateWithData") orelse return null,
            .cert_copy_data = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).cert_copy_data), h, "SecCertificateCopyData") orelse return null,
            .cert_copy_subject_summary = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).cert_copy_subject_summary), h, "SecCertificateCopySubjectSummary") orelse return null,
            .cert_copy_norm_subject = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).cert_copy_norm_subject), h, "SecCertificateCopyNormalizedSubjectSequence") orelse return null,
            .cert_copy_norm_issuer = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).cert_copy_norm_issuer), h, "SecCertificateCopyNormalizedIssuerSequence") orelse return null,
            .trust_settings_copy = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).trust_settings_copy), h, "SecTrustSettingsCopyTrustSettings") orelse return null,
            .policy_get_type_id = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).policy_get_type_id), h, "SecPolicyGetTypeID") orelse return null,
            .policy_copy_props = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).policy_copy_props), h, "SecPolicyCopyProperties") orelse return null,
            .policy_create_with_props = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).policy_create_with_props), h, "SecPolicyCreateWithProperties") orelse return null,
            .policy_create_basic_x509 = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).policy_create_basic_x509), h, "SecPolicyCreateBasicX509") orelse return null,
            .policy_create_ssl = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).policy_create_ssl), h, "SecPolicyCreateSSL") orelse return null,
            .trust_create_with_certs = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).trust_create_with_certs), h, "SecTrustCreateWithCertificates") orelse return null,
            .trust_evaluate_with_error = MacOSCF.loadSym(@TypeOf(@as(MacOSSecurity, undefined).trust_evaluate_with_error), h, "SecTrustEvaluateWithError") orelse return null,
            .k_code_info_certs = loadCFGlobal(h, "kSecCodeInfoCertificates"),
            .k_code_info_team = loadCFGlobal(h, "kSecCodeInfoTeamIdentifier"),
            .k_code_info_identifier = loadCFGlobal(h, "kSecCodeInfoIdentifier"),
            .k_policy_apple_codesigning = loadCFGlobal(h, "kSecPolicyAppleCodeSigning"),
            .k_policy_oid = loadCFGlobal(h, "kSecPolicyOid"),
        };
    }

    fn deinit(self: MacOSSecurity) void {
        _ = std.c.dlclose(self.handle);
    }
};

fn formatSha1Upper(alloc: Allocator, bytes: []const u8) ?[]const u8 {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &digest, .{});
    const out = alloc.alloc(u8, digest.len * 2) catch return null;
    const digits = "0123456789ABCDEF";
    for (digest, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

fn checkMacOSDomainTrust(
    cf: MacOSCF,
    sec: MacOSSecurity,
    cert: *const anyopaque,
    domain: u32,
) struct { has_codesign: bool, has_unscoped: bool } {
    var arr_ref: ?*const anyopaque = null;
    const rc = sec.trust_settings_copy(cert, domain, &arr_ref);
    if (rc != 0) return .{ .has_codesign = false, .has_unscoped = false };
    defer if (arr_ref) |r| cf.release(r);

    const arr = arr_ref orelse return .{ .has_codesign = true, .has_unscoped = true };
    const count = cf.array_get_count(arr);
    if (count == 0) return .{ .has_codesign = true, .has_unscoped = true };

    const k_result = cf.string_create(null, "kSecTrustSettingsResult", 0x08000100);
    defer if (k_result) |r| cf.release(r);
    const k_policy = cf.string_create(null, "kSecTrustSettingsPolicy", 0x08000100);
    defer if (k_policy) |r| cf.release(r);
    const k_app = cf.string_create(null, "kSecTrustSettingsApplication", 0x08000100);
    defer if (k_app) |r| cf.release(r);
    const k_policy_str = cf.string_create(null, "kSecTrustSettingsPolicyString", 0x08000100);
    defer if (k_policy_str) |r| cf.release(r);

    var has_codesign = false;
    var has_unscoped = false;
    var i: c_long = 0;
    while (i < count) : (i += 1) {
        const entry = cf.array_get_val(arr, i) orelse continue;
        var result_val: i32 = 1;
        if (k_result) |kr| {
            if (cf.dict_get_val(entry, kr)) |res_ref| {
                var num: i32 = 1;
                if (cf.number_get_val(res_ref, 3, &num) != 0) {
                    result_val = num;
                }
            }
        }
        if (result_val != 1 and result_val != 2) continue;

        const pol_ref = if (k_policy) |kp| cf.dict_get_val(entry, kp) else null;
        if (pol_ref == null) {
            has_unscoped = true;
            has_codesign = true;
            continue;
        }
        const pol = pol_ref.?;
        var oid_buf: [128]u8 = undefined;
        var oid_slice: ?[]const u8 = null;
        if (cf.get_type_id(pol) == sec.policy_get_type_id()) {
            if (sec.policy_copy_props(pol)) |props| {
                defer cf.release(props);
                if (sec.k_policy_oid) |oid_key| {
                    if (cf.dict_get_val(props, oid_key)) |oid_ref| {
                        if (cf.get_type_id(oid_ref) == cf.string_get_type_id() and
                            cf.string_get_cstr(oid_ref, &oid_buf, oid_buf.len, 0x08000100) != 0)
                        {
                            oid_slice = std.mem.sliceTo(&oid_buf, 0);
                        }
                    }
                }
            }
        } else if (cf.get_type_id(pol) == cf.string_get_type_id() and
            cf.string_get_cstr(pol, &oid_buf, oid_buf.len, 0x08000100) != 0)
        {
            oid_slice = std.mem.sliceTo(&oid_buf, 0);
        }

        if (oid_slice) |oid| {
            if (std.mem.eql(u8, oid, "1.2.840.113635.100.1.16")) {
                const app_scoped = if (k_app) |ka| cf.dict_get_val(entry, ka) != null else false;
                const str_scoped = if (k_policy_str) |ks| cf.dict_get_val(entry, ks) != null else false;
                if (!app_scoped and !str_scoped) {
                    has_codesign = true;
                }
            }
        }
    }

    return .{ .has_codesign = has_codesign, .has_unscoped = has_unscoped };
}

fn evaluateMacOSTrustPolicy(
    cf: MacOSCF,
    sec: MacOSSecurity,
    cert_array: *const anyopaque,
    policy_ref: ?*const anyopaque,
) bool {
    const policy = policy_ref orelse return false;
    var trust_ref: ?*const anyopaque = null;
    if (sec.trust_create_with_certs(cert_array, policy, &trust_ref) != 0) return false;
    const trust = trust_ref orelse return false;
    defer cf.release(trust);
    var err_ref: ?*const anyopaque = null;
    const ok = sec.trust_evaluate_with_error(trust, &err_ref) != 0;
    if (err_ref) |e| cf.release(e);
    return ok;
}

fn inspectMacOSLeafCertificate(
    alloc: Allocator,
    cf: MacOSCF,
    sec: MacOSSecurity,
    leaf_cert: *const anyopaque,
    bundle_id: ?[]const u8,
) SignerTrustReport {
    const der_ref = sec.cert_copy_data(leaf_cert);
    defer if (der_ref) |d| cf.release(d);
    const cert_sha1 = if (cf.readCFDataSlice(der_ref)) |der| formatSha1Upper(alloc, der) else null;

    const cn_ref = sec.cert_copy_subject_summary(leaf_cert);
    defer if (cn_ref) |c| cf.release(c);
    const cert_cn = cf.readCFString(alloc, cn_ref);

    const subj_ref = sec.cert_copy_norm_subject(leaf_cert);
    defer if (subj_ref) |s| cf.release(s);
    const iss_ref = sec.cert_copy_norm_issuer(leaf_cert);
    defer if (iss_ref) |i| cf.release(i);
    const is_self_signed = blk: {
        const s = cf.readCFDataSlice(subj_ref) orelse break :blk false;
        const i = cf.readCFDataSlice(iss_ref) orelse break :blk false;
        break :blk std.mem.eql(u8, s, i);
    };

    const is_release = if (bundle_id) |id| std.mem.eql(u8, id, "com.jischeng.omg") else false;
    if (!is_self_signed) {
        return .{
            .status = if (is_release) .warning else .healthy,
            .mode = .ad_hoc_or_development,
            .bundle_identifier = bundle_id,
            .certificate_cn = cert_cn,
            .certificate_sha1 = cert_sha1,
            .is_self_signed_leaf = false,
        };
    }

    const admin_domain = checkMacOSDomainTrust(cf, sec, leaf_cert, 1);
    const user_domain = checkMacOSDomainTrust(cf, sec, leaf_cert, 0);

    const certs_ptr = [_]?*const anyopaque{leaf_cert};
    const cert_array = cf.array_create(null, &certs_ptr, 1, cf.array_callbacks) orelse {
        return .{
            .status = .warning,
            .mode = .self_signed_untrusted,
            .bundle_identifier = bundle_id,
            .certificate_cn = cert_cn,
            .certificate_sha1 = cert_sha1,
            .is_self_signed_leaf = true,
        };
    };
    defer cf.release(cert_array);

    const cs_pol = if (sec.k_policy_apple_codesigning) |oid| sec.policy_create_with_props(oid, null) else null;
    defer if (cs_pol) |p| cf.release(p);
    const x509_pol = sec.policy_create_basic_x509();
    defer if (x509_pol) |p| cf.release(p);
    const ssl_pol = sec.policy_create_ssl(1, null);
    defer if (ssl_pol) |p| cf.release(p);

    const cs_ok = evaluateMacOSTrustPolicy(cf, sec, cert_array, cs_pol);
    const x509_ok = evaluateMacOSTrustPolicy(cf, sec, cert_array, x509_pol);
    const ssl_ok = evaluateMacOSTrustPolicy(cf, sec, cert_array, ssl_pol);

    const non_cs_blocked = !x509_ok and !ssl_ok;
    const has_unscoped = admin_domain.has_unscoped or user_domain.has_unscoped or x509_ok or ssl_ok;

    const mode: SignerTrustMode = if (admin_domain.has_codesign and cs_ok)
        .self_signed_admin_trusted
    else if (user_domain.has_codesign and cs_ok)
        .self_signed_user_only_trusted
    else
        .self_signed_untrusted;

    const healthy = mode == .self_signed_admin_trusted and cs_ok and non_cs_blocked and !has_unscoped;
    return .{
        .status = if (healthy) .healthy else .warning,
        .mode = mode,
        .bundle_identifier = bundle_id,
        .certificate_cn = cert_cn,
        .certificate_sha1 = cert_sha1,
        .is_self_signed_leaf = true,
        .trusted_in_admin_domain = admin_domain.has_codesign,
        .trusted_in_user_domain = user_domain.has_codesign,
        .is_code_signing_trusted = cs_ok,
        .is_non_code_signing_blocked = non_cs_blocked,
        .has_unscoped_trust = has_unscoped,
        .recommended_fix_command = if (healthy)
            null
        else
            "Open OMG Settings -> Plugins -> OMG Doctor -> Trust Release Signer for Updates (or run: sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain <leaf-cert.der>)",
    };
}

pub fn inspectSignerTrustAtPath(alloc: Allocator, target_path: []const u8) SignerTrustReport {
    if (comptime builtin.os.tag != .macos) return defaultSignerTrustReport();
    const cf = MacOSCF.load() orelse return defaultSignerTrustReport();
    defer cf.deinit();
    const sec = MacOSSecurity.load() orelse return defaultSignerTrustReport();
    defer sec.deinit();

    const url = cf.url_from_fs(
        null,
        target_path.ptr,
        @intCast(target_path.len),
        @intFromBool(std.mem.endsWith(u8, target_path, ".app")),
    ) orelse return defaultSignerTrustReport();
    defer cf.release(url);

    var static_code: ?*const anyopaque = null;
    if (sec.static_code_create_with_path(url, 0, &static_code) != 0 or static_code == null) {
        return .{ .status = .healthy, .mode = .unsigned };
    }
    defer cf.release(static_code.?);

    var info_ref: ?*const anyopaque = null;
    if (sec.code_copy_signing_info(static_code.?, 1 << 1, &info_ref) != 0 or info_ref == null) {
        return .{ .status = .healthy, .mode = .unsigned };
    }
    defer cf.release(info_ref.?);

    const bundle_id = if (sec.k_code_info_identifier) |key|
        cf.readCFString(alloc, cf.dict_get_val(info_ref.?, key))
    else
        null;
    const team_id = if (sec.k_code_info_team) |key|
        cf.readCFString(alloc, cf.dict_get_val(info_ref.?, key))
    else
        null;
    const is_release = if (bundle_id) |id| std.mem.eql(u8, id, "com.jischeng.omg") else false;

    const certs_arr = if (sec.k_code_info_certs) |key| cf.dict_get_val(info_ref.?, key) else null;
    const leaf_cert = if (certs_arr) |arr| (if (cf.array_get_count(arr) > 0) cf.array_get_val(arr, 0) else null) else null;

    if (team_id) |tid| {
        if (tid.len > 0) {
            const cert_cn = if (leaf_cert) |leaf| blk: {
                const ref = sec.cert_copy_subject_summary(leaf);
                defer if (ref) |r| cf.release(r);
                break :blk cf.readCFString(alloc, ref);
            } else null;
            const cert_sha1 = if (leaf_cert) |leaf| blk: {
                const ref = sec.cert_copy_data(leaf);
                defer if (ref) |r| cf.release(r);
                break :blk if (cf.readCFDataSlice(ref)) |der| formatSha1Upper(alloc, der) else null;
            } else null;
            return .{
                .status = .healthy,
                .mode = .apple_trusted,
                .bundle_identifier = bundle_id,
                .team_identifier = tid,
                .certificate_cn = cert_cn,
                .certificate_sha1 = cert_sha1,
                .is_code_signing_trusted = true,
            };
        }
    }

    const leaf = leaf_cert orelse return .{
        .status = if (is_release) .warning else .healthy,
        .mode = .ad_hoc_or_development,
        .bundle_identifier = bundle_id,
    };

    return inspectMacOSLeafCertificate(alloc, cf, sec, leaf, bundle_id);
}

fn checkMacOSSignerTrust(io: std.Io, alloc: Allocator, executable_dir: ?[]const u8) SignerTrustReport {
    if (comptime builtin.os.tag != .macos) return defaultSignerTrustReport();
    if (executable_dir) |exe_dir| {
        if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "MacOS")) {
            if (std.fs.path.dirname(exe_dir)) |contents| {
                if (std.mem.eql(u8, std.fs.path.basename(contents), "Contents")) {
                    if (std.fs.path.dirname(contents)) |app_dir| {
                        if (std.mem.endsWith(u8, app_dir, ".app")) {
                            return inspectSignerTrustAtPath(alloc, app_dir);
                        }
                    }
                }
            }
        }
    }
    const exe_path = std.process.executablePathAlloc(io, alloc) catch return defaultSignerTrustReport();
    return inspectSignerTrustAtPath(alloc, exe_path);
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

    const expected_uid: u32 = if (comptime builtin.os.tag == .windows)
        0
    else
        params.expected_uid orelse @intCast(std.c.getuid());

    var ssh_exists = false;
    var ssh_private = true;
    if (params.ssh_control_dir.len > 0) {
        if (comptime builtin.os.tag != .windows) {
            switch (try posixLstat(alloc, params.ssh_control_dir)) {
                .not_found => {
                    ssh_exists = false;
                    ssh_private = true;
                },
                .inaccessible => {
                    ssh_exists = true;
                    ssh_private = false;
                },
                .stat => |st| {
                    ssh_exists = true;
                    const is_dir = (st.mode & posix.S.IFMT) == posix.S.IFDIR;
                    const is_private = (st.mode & 0o777) == 0o700;
                    const owned_by_user = st.uid == expected_uid;
                    ssh_private = is_dir and is_private and owned_by_user;
                },
            }
        } else if (std.Io.Dir.openDirAbsolute(io, params.ssh_control_dir, .{})) |dir_val| {
            var dir = dir_val;
            defer dir.close(io);
            ssh_exists = true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                ssh_exists = true;
                ssh_private = false;
            },
        }
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
            if (comptime builtin.os.tag != .windows) {
                switch (try posixLstat(alloc, bak_path)) {
                    .not_found => continue,
                    .inaccessible => {
                        backup_files += 1;
                        insecure_backups += 1;
                    },
                    .stat => |st| {
                        backup_files += 1;
                        const is_reg = (st.mode & posix.S.IFMT) == posix.S.IFREG;
                        const is_private = (st.mode & 0o777) == 0o600;
                        const owned_by_user = st.uid == expected_uid;
                        if (!is_reg or !is_private or !owned_by_user) {
                            insecure_backups += 1;
                        }
                    },
                }
            } else {
                const file = std.Io.Dir.openFileAbsolute(io, bak_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => {
                        backup_files += 1;
                        insecure_backups += 1;
                        continue;
                    },
                };
                defer file.close(io);
                backup_files += 1;
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
        var should_read_settings = false;
        if (comptime builtin.os.tag != .windows) {
            switch (try posixLstat(alloc, settings_path)) {
                .not_found => {},
                .inaccessible => {
                    settings_exists = true;
                    settings_private = false;
                    settings_valid = false;
                },
                .stat => |st| {
                    settings_exists = true;
                    const is_reg = (st.mode & posix.S.IFMT) == posix.S.IFREG;
                    const is_private = (st.mode & 0o777) == 0o600;
                    const owned_by_user = st.uid == expected_uid;
                    settings_private = is_reg and is_private and owned_by_user;
                    if (is_reg and owned_by_user) {
                        should_read_settings = true;
                    } else {
                        settings_valid = false;
                    }
                },
            }
        } else {
            should_read_settings = true;
        }

        if (should_read_settings) {
            if (std.Io.Dir.openFileAbsolute(io, settings_path, .{ .follow_symlinks = false })) |file| {
                defer file.close(io);
                settings_exists = true;
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
            } else |err| {
                if (comptime builtin.os.tag == .windows) {
                    if (err != error.FileNotFound) {
                        settings_exists = true;
                        settings_private = false;
                        settings_valid = false;
                    }
                } else {
                    settings_private = false;
                    settings_valid = false;
                }
            }
        }
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

    const signer_trust = params.signer_trust orelse defaultSignerTrustReport();

    const overall: HealthStatus = if (accessibility.status == .warning or
        signer_trust.status == .warning or
        runtime_ssh.status == .warning or
        agent_backups.status == .warning or
        portable_settings.status == .warning)
        .warning
    else
        .healthy;

    return .{
        .status = overall,
        .accessibility = accessibility,
        .signer_trust = signer_trust,
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
    if (parsed.value.object.get("ended")) |ended_val| {
        if (ended_val != .null) return true;
    }
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

    try writer.print("\nRelease Signer Trust: {t}\n", .{report.signer_trust.status});
    try writer.print("  - mode                      : {t}\n", .{report.signer_trust.mode});
    if (report.signer_trust.bundle_identifier) |bid| {
        try writer.print("  - bundle identifier         : {s}\n", .{bid});
    }
    if (report.signer_trust.team_identifier) |tid| {
        try writer.print("  - team identifier           : {s}\n", .{tid});
    }
    if (report.signer_trust.certificate_cn) |cn| {
        try writer.print("  - certificate CN            : {s}\n", .{cn});
    }
    if (report.signer_trust.certificate_sha1) |sha1| {
        try writer.print("  - certificate SHA-1         : {s}\n", .{sha1});
    }
    if (report.signer_trust.is_self_signed_leaf) {
        try writer.print("  - admin domain trusted      : {}\n", .{report.signer_trust.trusted_in_admin_domain});
        try writer.print("  - user domain trusted       : {}\n", .{report.signer_trust.trusted_in_user_domain});
        try writer.print("  - CodeSigning evaluated     : {}\n", .{report.signer_trust.is_code_signing_trusted});
        try writer.print("  - non-CodeSigning blocked   : {}\n", .{report.signer_trust.is_non_code_signing_blocked});
        try writer.print("  - unscoped trust present    : {}\n", .{report.signer_trust.has_unscoped_trust});
    }
    if (report.signer_trust.recommended_fix_command) |cmd| {
        try writer.print("  ! {s}\n", .{cmd});
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
        try w.interface.writeAll("{\"id\":\"live\",\"ended\":null}\n");
        try w.interface.flush();
    }
    {
        var f = try tmp.dir.createFile(testing.io, ".omg/run/state1/sessions/done.json", .{});
        defer f.close(testing.io);
        var buf: [128]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("{\"id\":\"done\",\"ended\":\"exited\",\"exit_code\":0}\n");
        try w.interface.flush();
    }
    {
        var f = try tmp.dir.createFile(testing.io, ".omg/run/state1/sessions/lost.json", .{});
        defer f.close(testing.io);
        var buf: [128]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("{\"id\":\"lost\",\"ended\":\"lost\"}\n");
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
    try testing.expectEqual(@as(usize, 3), report.runtime_ssh.total_session_records);
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

test "doctor jsonIndicatesExited handles omgd ended schema and legacy exited fallback" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!jsonIndicatesExited(alloc, "{\"id\":\"a\",\"ended\":null}"));
    try std.testing.expect(!jsonIndicatesExited(alloc, "{\"id\":\"b\"}"));
    try std.testing.expect(jsonIndicatesExited(alloc, "{\"id\":\"c\",\"ended\":\"exited\",\"exit_code\":0}"));
    try std.testing.expect(jsonIndicatesExited(alloc, "{\"id\":\"d\",\"ended\":\"closed\"}"));
    try std.testing.expect(jsonIndicatesExited(alloc, "{\"id\":\"e\",\"ended\":\"lost\"}"));
    try std.testing.expect(jsonIndicatesExited(alloc, "{\"exited\":true}"));
    try std.testing.expect(!jsonIndicatesExited(alloc, "{\"exited\":false}"));
}

const PosixLstatResult = union(enum) {
    not_found,
    inaccessible,
    stat: struct {
        mode: u32,
        uid: u32,
    },
};

fn posixLstat(alloc: Allocator, path: []const u8) !PosixLstatResult {
    if (comptime builtin.os.tag == .windows) unreachable;
    const path_z = try alloc.dupeZ(u8, path);
    var st = std.mem.zeroes(posix.Stat);
    while (true) {
        switch (posix.errno(fstatat_sym(
            posix.AT.FDCWD,
            path_z.ptr,
            &st,
            posix.AT.SYMLINK_NOFOLLOW,
        ))) {
            .SUCCESS => return .{
                .stat = .{
                    .mode = @intCast(st.mode),
                    .uid = @intCast(st.uid),
                },
            },
            .INTR => continue,
            .NOENT => return .not_found,
            else => return .inaccessible,
        }
    }
}

test "doctor rejects symlinks, wrong-UID squatting, and resolves all dev channel settings paths" {
    const testing = std.testing;
    try testing.expectEqualStrings(
        ".config/oh-my-ghostty-dev-pty/settings.json",
        settingsRelPathForExecutableDir("/Applications/OMG Dev PTY.app/Contents/MacOS"),
    );
    try testing.expectEqualStrings(
        ".config/oh-my-ghostty-dev-workspace/settings.json",
        settingsRelPathForExecutableDir("/Applications/OMG Dev Workspace.app/Contents/MacOS"),
    );
    try testing.expectEqualStrings(
        ".config/oh-my-ghostty-dev/settings.json",
        settingsRelPathForExecutableDir("/Applications/OMG Dev.app/Contents/MacOS"),
    );
    try testing.expectEqualStrings(
        ".config/oh-my-ghostty/settings.json",
        settingsRelPathForExecutableDir("/Applications/OMG.app/Contents/MacOS"),
    );

    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home_path = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);

    try tmp.dir.createDirPath(testing.io, "real-ssh");
    const real_ssh = try std.fs.path.join(alloc, &.{ home_path, "real-ssh" });
    {
        var d = try std.Io.Dir.openDirAbsolute(testing.io, real_ssh, .{});
        defer d.close(testing.io);
        try d.setPermissions(testing.io, .fromMode(0o700));
    }

    // 1) Wrong-UID squatting on real directory -> warning!
    const wrong_uid: u32 = @as(u32, @intCast(std.c.getuid())) +% 1;
    const wrong_uid_report = try inspectEnvironment(testing.io, alloc, .{
        .home_dir = home_path,
        .ssh_control_dir = real_ssh,
        .has_global_keybinds = false,
        .accessibility_trusted = true,
        .expected_uid = wrong_uid,
    });
    try testing.expect(wrong_uid_report.runtime_ssh.ssh_control_dir_exists);
    try testing.expect(!wrong_uid_report.runtime_ssh.ssh_control_dir_private);
    try testing.expectEqual(HealthStatus.warning, wrong_uid_report.runtime_ssh.status);

    // 2) Symlinked ssh_control_dir, symlinked .omg.bak, and symlinked settings.json -> all rejected!
    try tmp.dir.symLink(testing.io, "real-ssh", "symlink-ssh", .{});
    const symlink_ssh = try std.fs.path.join(alloc, &.{ home_path, "symlink-ssh" });

    try tmp.dir.createDirPath(testing.io, ".claude");
    try tmp.dir.createDirPath(testing.io, ".config/oh-my-ghostty");
    {
        var f = try tmp.dir.createFile(testing.io, "target-secret.json", .{
            .permissions = .fromMode(0o600),
        });
        defer f.close(testing.io);
        try f.setPermissions(testing.io, .fromMode(0o600));
        var buf: [128]u8 = undefined;
        var w = f.writer(testing.io, &buf);
        try w.interface.writeAll("{\"sshHosts\":{}}\n");
        try w.interface.flush();
    }
    const target_secret = try std.fs.path.join(alloc, &.{ home_path, "target-secret.json" });
    try tmp.dir.symLink(testing.io, target_secret, ".claude/settings.json.omg.bak", .{});
    try tmp.dir.symLink(testing.io, target_secret, ".config/oh-my-ghostty/settings.json", .{});

    const symlink_report = try inspectEnvironment(testing.io, alloc, .{
        .home_dir = home_path,
        .ssh_control_dir = symlink_ssh,
        .has_global_keybinds = false,
        .accessibility_trusted = true,
    });
    try testing.expect(symlink_report.runtime_ssh.ssh_control_dir_exists);
    try testing.expect(!symlink_report.runtime_ssh.ssh_control_dir_private);
    try testing.expectEqual(HealthStatus.warning, symlink_report.runtime_ssh.status);

    try testing.expectEqual(@as(usize, 1), symlink_report.agent_backups.backup_files);
    try testing.expectEqual(@as(usize, 1), symlink_report.agent_backups.insecure_backups);
    try testing.expectEqual(HealthStatus.warning, symlink_report.agent_backups.status);

    try testing.expect(symlink_report.portable_settings.exists);
    try testing.expect(!symlink_report.portable_settings.private_mode);
    try testing.expect(!symlink_report.portable_settings.has_ssh_hosts);
    try testing.expectEqual(HealthStatus.warning, symlink_report.portable_settings.status);
}

test "doctor reports signer_trust warnings in overall status and inspects real macOS certificates" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home_path = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);

    const untrusted_report = try inspectEnvironment(testing.io, alloc, .{
        .home_dir = home_path,
        .ssh_control_dir = try std.fs.path.join(alloc, &.{ home_path, "missing-ssh" }),
        .has_global_keybinds = false,
        .accessibility_trusted = true,
        .signer_trust = .{
            .status = .warning,
            .mode = .self_signed_untrusted,
            .bundle_identifier = "com.jischeng.omg",
            .certificate_cn = "OMG Release Signing",
            .certificate_sha1 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            .is_self_signed_leaf = true,
            .is_non_code_signing_blocked = true,
            .recommended_fix_command = "sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain cert.der",
        },
    });
    try testing.expectEqual(HealthStatus.warning, untrusted_report.status);
    try testing.expectEqual(SignerTrustMode.self_signed_untrusted, untrusted_report.signer_trust.mode);

    var text_alloc: std.Io.Writer.Allocating = .init(alloc);
    try writeReportText(&text_alloc.writer, untrusted_report);
    const text = text_alloc.written();
    try testing.expect(std.mem.indexOf(u8, text, "Release Signer Trust: warning") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-r trustRoot -p codeSign") != null);

    var json_alloc: std.Io.Writer.Allocating = .init(alloc);
    try writeReportJSON(&json_alloc.writer, untrusted_report);
    try testing.expect(std.mem.indexOf(u8, json_alloc.written(), "\"signer_trust\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_alloc.written(), "\"self_signed_untrusted\"") != null);

    if (comptime builtin.os.tag == .macos) {
        const cf = MacOSCF.load().?;
        defer cf.deinit();
        const sec = MacOSSecurity.load().?;
        defer sec.deinit();

        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "cert.conf",
            .data =
            \\[req]
            \\distinguished_name = dn
            \\x509_extensions = ext
            \\prompt = no
            \\[dn]
            \\CN = OMG Zig Test Signer
            \\[ext]
            \\basicConstraints = critical, CA:FALSE
            \\keyUsage = critical, digitalSignature
            \\extendedKeyUsage = codeSigning
            \\
            ,
        });
        const conf_path = try std.fs.path.join(alloc, &.{ home_path, "cert.conf" });
        const key_path = try std.fs.path.join(alloc, &.{ home_path, "key.pem" });
        const der_path = try std.fs.path.join(alloc, &.{ home_path, "cert.der" });
        const res = try std.process.run(alloc, testing.io, .{
            .argv = &.{
                "/usr/bin/openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                key_path,
                "-outform",
                "DER",
                "-out",
                der_path,
                "-days",
                "1",
                "-config",
                conf_path,
            },
        });
        try testing.expect(res.term == .exited and res.term.exited == 0);

        const der_file = try std.Io.Dir.openFileAbsolute(testing.io, der_path, .{});
        defer der_file.close(testing.io);
        var reader = der_file.reader(testing.io, &.{});
        const der_bytes = try reader.interface.allocRemaining(alloc, .limited(64 * 1024));
        const cf_data = cf.data_create(null, der_bytes.ptr, @intCast(der_bytes.len)).?;
        defer cf.release(cf_data);
        const cert = sec.cert_create_with_data(null, cf_data).?;
        defer cf.release(cert);

        const inspected = inspectMacOSLeafCertificate(alloc, cf, sec, cert, "com.jischeng.omg");
        try testing.expectEqual(HealthStatus.warning, inspected.status);
        try testing.expectEqual(SignerTrustMode.self_signed_untrusted, inspected.mode);
        try testing.expect(inspected.is_self_signed_leaf);
        try testing.expect(!inspected.trusted_in_admin_domain);
        try testing.expect(!inspected.trusted_in_user_domain);
        try testing.expect(!inspected.is_code_signing_trusted);
        try testing.expect(inspected.is_non_code_signing_blocked);
        try testing.expect(!inspected.has_unscoped_trust);
        try testing.expectEqualStrings(formatSha1Upper(alloc, der_bytes).?, inspected.certificate_sha1.?);
    }
}
