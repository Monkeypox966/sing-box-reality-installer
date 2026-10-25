"""Exercise rollback, locking and metadata parsing in temporary directories."""
import json
from pathlib import Path
import subprocess
import unittest

from helpers import ShellTestCase


class InstallationTests(ShellTestCase):
    def setUp(self):
        super().setUp()
        self.log = self.mockbin / "services.log"
        for command in ("rc-service", "rc-update"):
            stub = self.mockbin / command
            stub.write_text('''#!/bin/sh
printf '%s %s %s\\n' "${0##*/}" "$1" "$2" >>"$TEST_SERVICE_LOG"
if [ "$2" = restart ] && [ "${TEST_RESTART_FAIL:-0}" = 1 ]; then exit 1; fi
''', encoding="utf-8")
            stub.chmod(0o755)
        self.env["TEST_SERVICE_LOG"] = str(self.log)
        self.config_dir = self.mockbin / "config"
        self.config_dir.mkdir()
        self.targets = {
            "BIN_PATH": self.mockbin / "sing-box",
            "SERVICE_PATH": self.mockbin / "service",
            "CONFIG_TARGET": self.config_dir / "config.json",
            "CLIENT_TARGET": self.config_dir / "client-info.txt",
        }
        for path in self.targets.values():
            path.write_text("new content", encoding="utf-8")
        self.settings = 'CONFIG_DIR="$TEST_CONFIG_DIR"; BIN_PATH="$TEST_BIN"; SERVICE_PATH="$TEST_INIT"; '
        self.env.update(TEST_CONFIG_DIR=str(self.config_dir), TEST_BIN=str(self.targets["BIN_PATH"]), TEST_INIT=str(self.targets["SERVICE_PATH"]))

    def backups(self):
        assignments = []
        for name, target in (("BIN_BAK", "BIN_PATH"), ("INIT_BAK", "SERVICE_PATH"), ("CONFIG_BAK", "CONFIG_TARGET"), ("CLIENT_BAK", "CLIENT_TARGET")):
            backup = self.targets[target].with_suffix(".backup")
            backup.write_text("old content", encoding="utf-8")
            self.env["TEST_" + name] = str(backup)
            assignments.append(f'{name}="$TEST_{name}"')
        return "; ".join(assignments) + "; "

    def test_failed_upgrade_restores_all_files_and_previous_service(self):
        self.shell(self.settings + self.backups() + 'SERVICE_WAS_RUNNING=1; SERVICE_WAS_ENABLED=1; rollback')
        for path in self.targets.values():
            self.assertEqual(path.read_text(), "old content")
        self.assertEqual(self.log.read_text().splitlines(), ["rc-service sing-box stop", "rc-service sing-box restart"])
        self.assertEqual(self.targets["CONFIG_TARGET"].stat().st_mode & 0o777, 0o600)

    def test_first_install_failure_removes_new_files_and_registration(self):
        self.shell(self.settings + 'rollback')
        for path in self.targets.values():
            self.assertFalse(path.exists())
        self.assertIn("rc-update del sing-box", self.log.read_text())

    def test_exit_trap_rolls_back_and_preserves_failure_exit_code(self):
        code = self.settings + self.backups() + 'DEPLOYMENT_STARTED=1; trap cleanup EXIT; exit 23'
        with self.assertRaises(subprocess.CalledProcessError) as context:
            self.shell(code)
        self.assertEqual(context.exception.returncode, 23)
        for path in self.targets.values():
            self.assertEqual(path.read_text(), "old content")

    def test_restart_failure_is_reported_without_losing_restored_files(self):
        with self.assertRaises(subprocess.CalledProcessError) as context:
            self.shell(self.settings + self.backups() + 'SERVICE_WAS_RUNNING=1; rollback', TEST_RESTART_FAIL="1")
        self.assertIn("could not restart", context.exception.stderr)
        self.assertEqual(self.targets["BIN_PATH"].read_text(), "old content")

    def test_installation_lock_cannot_be_acquired_twice_and_is_cleaned(self):
        lock = self.mockbin / "install.lock"
        self.shell('INSTALL_LOCK_DIR="$TEST_LOCK"; acquire_install_lock; if acquire_install_lock; then exit 9; fi; cleanup', TEST_LOCK=str(lock))
        self.assertFalse(lock.exists())

    def test_temp_parent_with_spaces_is_not_split(self):
        parent = self.mockbin / "disk with spaces"
        self.shell('is_memory_fs() { return 1; }; MIN_TMP_FREE_KB=0; try_install_tmp_parent "$TEST_PARENT"; test -d "$INSTALL_TMP_DIR"; cleanup', TEST_PARENT=str(parent))
        self.assertEqual(list(parent.iterdir()), [])

    def test_memory_backed_tmp_override_actually_works(self):
        self.shell('is_memory_fs() { return 0; }; MIN_TMP_FREE_KB=0; ALLOW_TMPFS_TMP=1; try_install_tmp_parent /tmp; test -d "$INSTALL_TMP_DIR"; cleanup')

    def test_metadata_parser_matches_exact_asset_in_compact_or_reordered_json(self):
        fixture = self.mockbin / "release.json"
        fixture.write_text(json.dumps({"assets": [{"digest": "sha256:" + "a" * 64, "name": "other.tar.gz"}, {"digest": "sha256:" + "b" * 64, "name": "wanted.tar.gz"}], "tag_name": "v1.14.4"}), encoding="utf-8")
        result = self.shell('extract_release_tag "$TEST_JSON"; extract_asset_digest "$TEST_JSON" wanted.tar.gz', TEST_JSON=str(fixture))
        self.assertEqual(result.stdout.splitlines(), ["1.14.4", "b" * 64])

    def test_proxy_fallback_does_not_accumulate_proxy_prefixes(self):
        wget = self.mockbin / "wget"
        wget.write_text('''#!/bin/sh
for arg do last="$arg"; done
printf '%s\\n' "$last" >>"$TEST_URL_LOG"
case "$last" in https://ghproxy.net/*) exit 0 ;; *) exit 1 ;; esac
''', encoding="utf-8")
        wget.chmod(0o755)
        url_log = self.mockbin / "urls"
        self.shell('ALLOW_PROXY=1; EXPECTED_SHA256=provided; download_asset https://github.com/example/archive.tar.gz "$TEST_OUT"', TEST_URL_LOG=str(url_log), TEST_OUT=str(self.mockbin / "download"))
        original = "https://github.com/example/archive.tar.gz"
        self.assertEqual(url_log.read_text().splitlines(), [original, "https://gh-proxy.com/" + original, "https://ghproxy.net/" + original])


if __name__ == "__main__":
    unittest.main(verbosity=2)
