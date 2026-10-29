import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("runtime_bundle", Path(__file__).parent / "macos/check-session-runtime.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class RuntimeBundleTests(unittest.TestCase):
    def make_bundle(self, root):
        for name in ("omgd", "askpass", "libghostty-vt.dylib"):
            (root / name).write_bytes(b"fixture")
            (root / name).chmod(0o700)
        (root / "revision").write_text("revision-a")
        (root / "snapshot-revision").write_text("snapshot-a")
        for target in ("macos-aarch64", "linux-aarch64", "linux-x86_64"):
            directory = root / target
            directory.mkdir()
            files = []
            for name in ("omgd", "libghostty-vt.dylib"):
                (directory / name).write_bytes(b"fixture")
                files.append({"name": name, "sha256": hashlib.sha256(b"fixture").hexdigest()})
            (directory / "manifest.json").write_text(json.dumps({"revision": "revision-a", "platform": target, "files": files}))

    def test_missing_helper_and_corrupt_platform_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_bundle(root)
            bundle.validate(root, "aarch64")
            (root / "omgd").unlink()
            with self.assertRaises(ValueError):
                bundle.validate(root, "aarch64")
            (root / "omgd").write_bytes(b"fixture")
            (root / "omgd").chmod(0o700)
            (root / "linux-x86_64/omgd").write_bytes(b"corrupt")
            with self.assertRaises(ValueError):
                bundle.validate(root, "aarch64")

    def test_dev_installer_packages_and_checks_before_overwriting(self):
        script = (Path(__file__).resolve().parents[1] / ".agents/skills/omg-release/scripts/install-dev.sh").read_text()
        self.assertLess(script.index("build-session-runtime.py"), script.index('rm -rf "$target_app"'))
        self.assertLess(script.index("check-session-runtime.py"), script.index('rm -rf "$target_app"'))


if __name__ == "__main__":
    unittest.main()
