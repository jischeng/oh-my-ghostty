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

    def test_all_macos_validation_requires_both_macos_platform_manifests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_bundle(root)
            with self.assertRaises(FileNotFoundError):
                bundle.validate(root, "aarch64", all_macos=True)
            other = root / "macos-x86_64"
            other.mkdir()
            files = []
            for name in ("omgd", "libghostty-vt.dylib"):
                (other / name).write_bytes(b"fixture")
                files.append({"name": name, "sha256": hashlib.sha256(b"fixture").hexdigest()})
            (other / "manifest.json").write_text(
                json.dumps({"revision": "revision-a", "platform": "macos-x86_64", "files": files})
            )
            bundle.validate(root, "aarch64", all_macos=True)

    def test_macos_only_validation_accepts_an_empty_linux_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_bundle(root)
            for target in ("linux-aarch64", "linux-x86_64"):
                for child in (root / target).iterdir():
                    child.unlink()
                (root / target).rmdir()
            with self.assertRaises(FileNotFoundError):
                bundle.validate(root, "aarch64")
            bundle.validate(root, "aarch64", linux_archs=())

    def test_dev_installer_packages_and_checks_before_overwriting(self):
        script = (Path(__file__).resolve().parents[1] / ".agents/skills/omg-release/scripts/install-dev.sh").read_text()
        self.assertLess(script.index("build-session-runtime.py"), script.index('rm -rf "$target_app"'))
        self.assertLess(script.index("check-session-runtime.py"), script.index('rm -rf "$target_app"'))

    def test_current_source_tree_maps_to_compatible_snapshot_epoch(self):
        repo_root = Path(__file__).resolve().parents[1]
        build_spec = importlib.util.spec_from_file_location(
            "build_runtime", Path(__file__).parent / "macos/build-session-runtime.py"
        )
        build_mod = importlib.util.module_from_spec(build_spec)
        build_spec.loader.exec_module(build_mod)
        compatibility = json.loads(
            (repo_root / "dist/macos/session-runtime-snapshot-compatibility.json").read_text()
        )
        self.assertEqual(
            build_mod.snapshot_revision(build_mod.compute_snapshot_source_digest(repo_root), compatibility),
            "59c5cc7b4d1fe408faf5",
        )

    def test_snapshot_source_digest_ignores_non_wire_files(self):
        build_spec = importlib.util.spec_from_file_location(
            "build_runtime", Path(__file__).parent / "macos/build-session-runtime.py"
        )
        build_mod = importlib.util.module_from_spec(build_spec)
        build_spec.loader.exec_module(build_mod)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            snap = root / "src/terminal/snapshot"
            (snap / "testdata").mkdir(parents=True)
            (root / "include/ghostty/vt").mkdir(parents=True)
            (root / "src/terminal/other").mkdir(parents=True)
            (snap / "envelope.zig").write_text("wire")
            (snap / "AGENTS.md").write_text("docs")
            (snap / "fixture.zig").write_text("fixture")
            (snap / "verify-kaitai.py").write_text("tool")
            (snap / "testdata/case.hex").write_text("data")
            (root / "include/ghostty/vt/header.h").write_text("header")
            (root / "src/terminal/other/page.zig").write_text("other")
            baseline = build_mod.compute_snapshot_source_digest(root)

            (snap / "AGENTS.md").write_text("docs-v2")
            (snap / "fixture.zig").write_text("fixture-v2")
            (snap / "verify-kaitai.py").write_text("tool-v2")
            (snap / "testdata/case.hex").write_text("data-v2")
            (root / "include/ghostty/vt/header.h").write_text("header-v2")
            (root / "src/terminal/other/page.zig").write_text("other-v2")
            self.assertEqual(build_mod.compute_snapshot_source_digest(root), baseline)

            (snap / "envelope.zig").write_text("wire-v2")
            self.assertNotEqual(build_mod.compute_snapshot_source_digest(root), baseline)


if __name__ == "__main__":
    unittest.main()
