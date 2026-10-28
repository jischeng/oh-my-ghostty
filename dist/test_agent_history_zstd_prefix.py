"""Execute the actual Python helper embedded in Swift with hostile producers."""
import ast
import builtins
import os
from pathlib import Path
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'macos/Sources/Features/Plugins/AgentHistoryRemoteAccess.swift'


def load_helper():
    source = SOURCE.read_text()
    start = source.index('        def read_zstd_prefix(')
    end = source.index('\n        candidates = []', start)
    namespace = {'os': os}
    # Parse/execute just the production function, without remote discovery.
    exec(compile(ast.parse(textwrap.dedent(source[start:end])), str(SOURCE), 'exec'), namespace)
    return namespace['read_zstd_prefix']


class PrefixTests(unittest.TestCase):
    def run_producer(self, body):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / 'zstd'
            pidfile = root / 'pid'
            executable.write_text('#!' + sys.executable + '\n' + textwrap.dedent(body))
            executable.chmod(0o700)
            real_import = builtins.__import__

            def without_module(name, *args, **kwargs):
                if name == 'zstandard': raise ImportError('exercise command fallback')
                return real_import(name, *args, **kwargs)

            with patch.dict(os.environ, PATH=str(root), TEST_PID=str(pidfile)):
                with patch('builtins.__import__', side_effect=without_module):
                    started = time.monotonic()
                    data = load_helper()('/unused/archive.jsonl.zst')
                    elapsed = time.monotonic() - started
            pid = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
            with self.assertRaises(ChildProcessError): os.waitpid(pid, os.WNOHANG)
            return data, elapsed

    def test_infinite_output_is_bounded_and_term_ignoring_producer_is_reaped(self):
        data, elapsed = self.run_producer('''
            import os, signal, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(os.environ['TEST_PID'], 'w').write(str(os.getpid()))
            while True:
                try: os.write(1, b'x' * 65536)
                except BrokenPipeError: time.sleep(60)
        ''')
        self.assertEqual(data, b'x' * (256 * 1024))
        self.assertLess(elapsed, 4)

    def test_silent_producer_times_out_and_is_reaped(self):
        data, elapsed = self.run_producer('''
            import os, signal, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(os.environ['TEST_PID'], 'w').write(str(os.getpid()))
            time.sleep(60)
        ''')
        self.assertEqual(data, b'')
        self.assertLess(elapsed, 8)

    def test_short_stream_preserves_content(self):
        data, _ = self.run_producer('''
            import os
            open(os.environ['TEST_PID'], 'w').write(str(os.getpid()))
            os.write(1, b'{"type":"session_meta"}\\n')
        ''')
        self.assertEqual(data, b'{"type":"session_meta"}\n')


if __name__ == '__main__': unittest.main()
