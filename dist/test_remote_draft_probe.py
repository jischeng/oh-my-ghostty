import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import textwrap
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'macos/Sources/Features/QuickInput/QuickInputRemoteDraftBridge.swift'


class RemoteDraftProbeTests(unittest.TestCase):
    def probe(self, processes, tty='/dev/pts/6'):
        script = textwrap.dedent(SOURCE.read_text().split('static let foregroundProbe = #"""', 1)[1].split('"""#', 1)[0])
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            directory = home / '.local/share/oh-my-ghostty/remote/sessions' / hashlib.sha256(b'session').hexdigest()
            directory.mkdir(parents=True)
            (directory / 'session.json').write_text(json.dumps({'protocol': 1, 'tty': '/dev/pts/6'}))
            output = io.StringIO()
            with patch('pathlib.Path.home', return_value=home), patch('sys.argv', ['probe', 'session', tty]), \
                    patch('subprocess.run', return_value=types.SimpleNamespace(stdout=processes)) as run, \
                    contextlib.redirect_stdout(output):
                exec(compile(script, str(SOURCE), 'exec'), {})
            self.assertEqual(run.call_args.args[0], ['ps', '-t', 'pts/6', '-o', 'pgid=,tpgid=,args='])
            return output.getvalue()

    def test_alias_launched_codex_is_detected_without_returning_prompt(self):
        result = self.probe('100 200 zsh\n200 200 /opt/codex --resume secret-prompt\n300 200 other\n')
        self.assertEqual(result, '/opt/codex\n')

    def test_node_agent_preserves_runtime_identity(self):
        result = self.probe('200 200 node /opt/@openai/codex/bin/codex.js\n')
        self.assertIn('@openai/codex', result)

    def test_shell_does_not_inherit_background_agent(self):
        self.assertEqual(self.probe('100 100 zsh\n200 100 codex\n'), 'zsh\n')

    def test_tty_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            self.probe('200 200 codex', tty='/dev/pts/9')


if __name__ == '__main__':
    unittest.main()
