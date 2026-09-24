# Synthetic SSH Shell recording

`remote-fish.vt` was produced by Fish 3.1.2 with a temporary HOME and the
actual OMG `+ssh` bootstrap passed through the Fish login parser. The fake
transport uses separate client/server PTYs. No real SSH host or user history
is involved; OSC 7/3008 host/cwd metadata is removed by the test runner.

Regenerate with a development OMG build and a Fish 3.1.2 test binary:

```sh
python3 dist/test_ssh_shell_integration.py \
  --omg macos/build/Debug/OMG.app/Contents/MacOS/omg \
  --shell /path/to/fish-3.1.2/bin/fish \
  --capture-dir src/terminal/testdata/omg-shell
```

The core regression test consumes this recording and verifies seven actual
command records, including four distinct, valid `ll` anchors. Prompt repaint,
empty Enter and cancelled input must not become extra commands. Preserve the
file's raw bytes; CR, escape sequences and whitespace are meaningful.
