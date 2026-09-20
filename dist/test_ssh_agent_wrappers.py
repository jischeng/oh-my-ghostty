"""Behavior tests for generated +ssh identity wrappers (requires mise/zig and shells).
Run: python3 dist/test_ssh_agent_wrappers.py
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RemoteAgentWrappersTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="omg-agent-wrappers-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.bin = cls.directory / "bin"
        cls.bin.mkdir()
        source = (ROOT / "src/cli/ssh.zig").read_text()
        agent = source.split("const RemoteAgent = enum {", 1)[1].split("\n};", 1)[0]
        wrapper = source.split("fn remoteShellCommand(", 1)[1].split("\nfn writeSessionStart", 1)[0]
        driver = cls.directory / "wrappers.zig"
        driver.write_text(
            'const std = @import("std");\n'
            'const Allocator = std.mem.Allocator;\n'
            'const RemoteAgent = enum {' + agent + '\n};\n'
            'fn remoteShellCommand(' + wrapper + '\n'
            'extern "c" fn write(c_int, [*]const u8, usize) isize;\n'
            'pub fn main() !void {\n'
            '  inline for (.{RemoteQuoteStyle.fish, RemoteQuoteStyle.shell}) |style| {\n'
            '    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);\n'
            '    defer output.deinit();\n'
            '    try writeRemoteAgentWrappers(&output.writer, style);\n'
            '    _ = write(1, output.written().ptr, output.written().len);\n'
            '    _ = write(1, "\\x00", 1);\n'
            '  }\n'
            '  const command = remoteShellCommand(std.heap.page_allocator, "cloud", "omg-ssh-test", null, .antigravity, null).?;\n'
            '  _ = write(1, command.ptr, command.len);\n'
            '  _ = write(1, "\\x00", 1);\n'
            '}\n'
        )
        compiled = subprocess.run(
            ["mise", "exec", "zig@0.16.0", "--", "zig", "run", "-lc", str(driver)],
            cwd=ROOT, capture_output=True, check=True, timeout=120,
        )
        fish, shell, cls.bootstrap, _ = compiled.stdout.decode().split("\0")
        cls.scripts = {"fish": fish.lstrip("; "), "bash": shell, "zsh": shell}
        for name in ("agy", "codex"):
            executable = cls.bin / name
            executable.write_text('#!/bin/sh\nprintf "ARG:<%s>\\n" "$@"\nexit 7\n')
            executable.chmod(0o700)

    def test_full_bootstrap_through_each_login_shell(self):
        real_fish = shutil.which("fish")
        if not real_fish:
            self.skipTest("fish not installed")
        # Preserve the actual generated -C argument, but disable interactive
        # startup files and terminate after the restored test agent returns.
        shim = self.bin / "fish"
        shim.write_text('#!/bin/sh\nexec ' + real_fish + ' --no-config -c "$3"\n')
        shim.chmod(0o700)
        try:
            for shell in ("fish", "bash", "zsh"):
                with self.subTest(login_shell=shell):
                    result = self.run_shell(shell, self.bootstrap)
                    self.assertEqual(result.returncode, 7, result.stderr)
                    self.assertIn("omg_agent=antigravity;omg_scope=remote;omg_state=idle", result.stdout)
                    self.assertIn("start=omg-ssh-test;type=remote", result.stdout)
                    self.assertNotIn("Unsupported use", result.stderr)
        finally:
            shim.unlink()

    def run_shell(self, shell, script):
        executable = shutil.which(shell)
        if not executable:
            self.skipTest(f"{shell} not installed")
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/opt/homebrew/bin",
            "HOME": str(self.directory),
            "ZDOTDIR": str(self.directory),
            "XDG_CONFIG_HOME": str(self.directory),
            "SHELL": shutil.which("fish") or "/bin/sh",
        }
        flags = ["--no-config"] if shell == "fish" else ["-f"] if shell == "zsh" else ["--noprofile", "--norc"]
        return subprocess.run([executable, *flags, "-c", script], env=env,
                              capture_output=True, text=True, timeout=15)

    def test_identity_arguments_cleanup_and_exit_status(self):
        for shell, wrapper in self.scripts.items():
            for command, agent in (("agy", "antigravity"), ("codex", "codex")):
                with self.subTest(shell=shell, agent=agent):
                    prompt = ("function __omg_report_pwd; printf 'PROMPT\\n'; end\n" if shell == "fish"
                              else "__omg_report_pwd() { printf 'PROMPT\\n'; }\n")
                    result = self.run_shell(shell, prompt + wrapper + f"\n{command} 'two words' ';literal'\n")
                    self.assertEqual(result.returncode, 7, result.stderr)
                    self.assertRegex(result.stdout, re.escape(f"omg_agent={agent};omg_scope=remote;omg_state=idle"))
                    self.assertTrue(result.stdout.endswith("ARG:<two words>\nARG:<;literal>\nPROMPT\n"), result.stdout)
                    self.assertNotIn("omg_state=done", result.stdout)

    def test_existing_user_function_is_preserved(self):
        for shell, wrapper in self.scripts.items():
            with self.subTest(shell=shell):
                custom = ("function codex; printf 'CUSTOM'; end\n" if shell == "fish"
                          else "codex() { printf 'CUSTOM'; }\n")
                result = self.run_shell(shell, custom + wrapper + "\ncodex\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "CUSTOM")

    def test_existing_user_alias_is_preserved(self):
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell):
                enable = "shopt -s expand_aliases\n" if shell == "bash" else ""
                result = self.run_shell(shell, enable + "alias codex='printf CUSTOM'\n" + self.scripts[shell] + "\neval codex\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "CUSTOM")


if __name__ == "__main__":
    unittest.main()
