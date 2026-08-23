# OMG App Icon Source

`ghostty-base-1024.png` preserves the recognizable terminal/ghost foundation
from the upstream Ghostty icon under this repository's MIT license.
`generate_app_icon.py` draws OMG's cloud-terminal layer and writes:

- `omg-app-icon-1024.png` (README/design master);
- the complete `macos/Assets.xcassets/OMG.appiconset` macOS icon matrix;
- `AppIconImage.imageset` fallback images used by older macOS/Dock/error UI.

Regenerate on macOS with Pillow installed:

```bash
python3 images/omg/generate_app_icon.py
```

The generated assets are deterministic. Commit the script, base, master, and
all generated sizes together.
