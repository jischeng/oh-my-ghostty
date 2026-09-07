//! OMG-specific normalization of the macOS host's inherited terminal environment.
const std = @import("std");

pub fn filterInheritedTerminalEnvironment(env: *std.process.Environ.Map) void {
    // Some launchers export an empty NO_COLOR. Presence alone disables colors
    // in tools such as eza. Preserve an explicit nonempty opt-out; surface and
    // config environment overrides are applied after this inherited-env filter.
    if (env.get("NO_COLOR")) |value| {
        if (value.len == 0) _ = env.orderedRemove("NO_COLOR");
    }
}

test "OMG inherited NO_COLOR preserves absence and nonempty opt-out" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("COLORTERM", "truecolor");
    filterInheritedTerminalEnvironment(&env);
    try std.testing.expect(env.get("NO_COLOR") == null);

    try env.put("NO_COLOR", "");
    filterInheritedTerminalEnvironment(&env);
    try std.testing.expect(env.get("NO_COLOR") == null);
    try std.testing.expectEqualStrings("truecolor", env.get("COLORTERM").?);

    for ([_][]const u8{ "1", "0", "true" }) |value| {
        try env.put("NO_COLOR", value);
        filterInheritedTerminalEnvironment(&env);
        try std.testing.expectEqualStrings(value, env.get("NO_COLOR").?);
    }
}
