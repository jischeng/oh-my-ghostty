# OMG 0.9.0

OMG 0.9.0 adds an extensible Info Inspector with SSH port forwarding on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`).

## Highlights

- Adds an Info pane beside Files in the Right Inspector, with reserved typed sections for future machine status and resource information.
- Forwards a remote port or validated `host:port` target through the active OpenSSH configuration, preferring the same local port and selecting an available local port only when necessary.
- Groups forwarding lifecycle by a stable remote sshd host-key fingerprint, with machine ID fallback, so aliases, direct addresses, and ProxyJump routes to the same server share one forwarding state.
- Restores forwarding intent with restored SSH panes, keeps it alive while any matching server connection remains, and stops all forwarding processes when OMG exits or is forcibly terminated.
- Shows forwarded targets and local addresses in a compact list with explicit browser, copy, and stop actions, detailed SSH failures, and bounded remote loopback process discovery.
- Supports ordinary SSH reconnects in surviving panes, including sessions where a shell wrapper is no longer present after a network disconnect.
- Localizes the Info pane, forwarding workflow, actions, status, and failure messages in English and Simplified Chinese using the live OMG language setting.

## Verification

- Info Inspector registration, typed content, port/`host:port` parsing, IPv6 targets, persistence migration, stable server identity, lifecycle cleanup, reconnect handling, process discovery, error reporting, and localization tests pass.
- The complete serialized macOS app-hosted suite, SwiftLint, Zig formatting/tests, JSON/schema, Plist, XIB, and OMG documentation validation pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `15`.

## Distribution status

The attached arm64, x86_64, and universal DMGs are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
