"""Shared shell fixture; no installers or services are run."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "setup-sing-box.sh"


class ShellTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sing-box-output-test-")
        self.addCleanup(self.temp.cleanup)
        self.mockbin = Path(self.temp.name)
        wget = self.mockbin / "wget"
        wget.write_text('''#!/bin/sh
[ -z "${TEST_REQUEST_LOG:-}" ] || printf '%s\\n' "$1" >>"$TEST_REQUEST_LOG"
case "$1" in
  -4) [ -n "${TEST_IPV4:-}" ] || exit 1; printf '%s' "$TEST_IPV4"; exit "${TEST_HTTP_STATUS:-0}" ;;
  -6) [ -n "${TEST_IPV6:-}" ] || exit 1; printf '%s' "$TEST_IPV6"; exit "${TEST_HTTP_STATUS:-0}" ;;
  *) exit 99 ;;
esac
''', encoding="utf-8")
        wget.chmod(0o755)
        self.env = dict(os.environ, SING_BOX_SETUP_LIBRARY_ONLY="1")
        self.env["PATH"] = str(self.mockbin) + os.pathsep + self.env["PATH"]

    def shell(self, code, **env):
        return subprocess.run(
            ["sh", "-eu", "-c", '. "$1"; ' + code, "test", str(SCRIPT)],
            env=dict(self.env, **env), capture_output=True, text=True, check=True,
        )

