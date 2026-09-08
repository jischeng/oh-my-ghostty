//! OMG-specific normalization of the macOS host's inherited terminal environment.
const std = @import("std");

pub fn filterInheritedTerminalEnvironment(env: *std.process.Environ.Map) void {
    // OMG is a color-capable terminal host. Launchers and agent runners often
    // inherit NO_COLOR even though the user did not opt out of terminal colors;
    // remove the inherited marker so tools such as eza keep their color output.
    // Surface and config environment overrides are applied after this filter,
    // so an explicit per-terminal opt-out remains available.
    _ = env.orderedRemove("NO_COLOR");
}

test "OMG inherited NO_COLOR is removed while other environment survives" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("COLORTERM", "truecolor");
    filterInheritedTerminalEnvironment(&env);
    try std.testing.expect(env.get("NO_COLOR") == null);

    try env.put("NO_COLOR", "");
    filterInheritedTerminalEnvironment(&env);
    try std.testing.expect(env.get("NO_COLOR") == null);
    try std.testing.expectEqualStrings("truecolor", env.get("COLORTERM").?);

    for ([_][]const u8{ "", "1", "0", "true" }) |value| {
        try env.put("NO_COLOR", value);
        filterInheritedTerminalEnvironment(&env);
        try std.testing.expect(env.get("NO_COLOR") == null);
    }
}
