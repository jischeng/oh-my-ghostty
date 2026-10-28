# OMG 0.18.0 · Ghostty 1.3.2-dev

OMG 0.18.0 introduces named workspaces and a native SSH session runtime, alongside improvements to Agent History and the Git inspector.

- Organize terminal tabs into named workspaces and switch between them while keeping terminal processes alive.
- Use native SSH sessions with reconnect and explicit session close. The app bundles the local relay and remote runtime artifacts for supported macOS and Linux architectures. Existing remote sessions remain pinned to their runtime revision; older hosts may lack durable close support.
- Browse Agent History with directory and time filters, improved remote discovery, compressed Codex history and Antigravity summaries.
- Improve Git history and branch presentation, keep Info available independently of plugin installation, and update the Copilot icon.

OMG version: **0.18.0**. Ghostty base: **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`.

The application is persistently self-signed and **not notarized**. macOS Gatekeeper may block its first launch; users who trust the download can review it in System Settings → Privacy & Security. Permission migration and full TCC upgrade experiments were not run.
