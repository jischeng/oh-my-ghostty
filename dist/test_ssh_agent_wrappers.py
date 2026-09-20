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
        source = (ROOT / "src/cli/ssh.zig").read_text()
        agent = source.split("const RemoteAgent = enum {", 1)[1].split("\n};", 1)[0]
        wrapper = source.split("fn writeRemoteAgentWrappers(", 1)[1].split("\nfn writeRemoteAgentInvocation", 1)[0]
        driver = cls.directory / "wrappers.zig"
        driver.write_text(
            'const std = @import("std");\n'
            'const RemoteQuoteStyle = enum { fish, shell };\n'
            'const RemoteAgent = enum {' + agent + '\n};\n'
            'fn writeRemoteAgentWrappers(' + wrapper + '\n'
            'extern "c" fn write(c_int, [*]const u8, usize) isize;\n'
            'pub fn main() !void {\n'
            '  inline for (.{RemoteQuoteStyle.fish, RemoteQuoteStyle.shell}) |style| {\n'
            '    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);\n'
            '    defer output.deinit();\n'
            '    try writeRemoteAgentWrappers(&output.writer, style);\n'
            '    _ = write(1, output.written().ptr, output.written().len);\n'
            '    _ = write(1, "\\x00", 1);\n'
            '  }\n}\n'
        )
        compiled = subprocess.run(
            ["mise", "exec", "zig@0.16.0", "--", "zig", "run", "-lc", str(driver)],
            cwd=ROOT, capture_output=True, check=True, timeout=120,
        )
        fish, shell, _ = compiled.stdout.decode().split("\0")
        cls.scripts = {"fish": fish.lstrip("; "), "bash": shell, "zsh": shell}
        for name in ("agy", "codex"):
            executable = cls.directory / name
            executable.write_text('#!/bin/sh\nprintf "ARG:<%s>\\n" "$@"\nexit 7\n')
            executable.chmod(0o700)

    def run_shell(self, shell, script):
        executable = shutil.which(shell)
        if not executable:
            self.skipTest(f"{shell} not installed")
        env = {
            "PATH": f"{self.directory}:/usr/bin:/bin:/opt/homebrew/bin",
            "HOME": str(self.directory),
            "ZDOTDIR": str(self.directory),
            "XDG_CONFIG_HOME": str(self.directory),
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
