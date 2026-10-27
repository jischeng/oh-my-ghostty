//! Minimal adapter to Ghostty's existing terminal-I/O host type.
//! Session runtime code uses HostIO; upstream names stay at this boundary.
pub const HostIO = @import("termio.zig").Termio;
