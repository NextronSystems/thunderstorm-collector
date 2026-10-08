#!/usr/bin/env python3
"""Regression tests for selection and harness error paths; no service required."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from select_collectors import COLLECTORS, select_collectors


TESTS_DIR = Path(__file__).resolve().parent


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="collector-selection-")
        self.addCleanup(self.temporary.cleanup)
        self.scripts = Path(self.temporary.name)

    def collector(self, name, modern=True):
        _, filename, flags = COLLECTORS[name]
        path = self.scripts / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(flags) if modern else "legacy collector", encoding="utf-8")

    def test_empty_checkout_is_allowed_in_automatic_mode(self):
        selected, skipped = select_collectors(self.scripts, "linux", branch="master")
        self.assertEqual(selected, [])
        self.assertEqual(len(skipped), 4)

    def test_master_automatically_tests_new_collectors(self):
        self.collector("bash")
        self.collector("perl")
        self.assertEqual(select_collectors(self.scripts, "linux", branch="master")[0], ["bash", "perl"])

    def test_legacy_interface_is_not_sent_new_flags(self):
        self.collector("bash", modern=False)
        self.assertEqual(select_collectors(self.scripts, "linux")[0], [])

    def test_collector_branch_requires_its_script(self):
        with self.assertRaisesRegex(ValueError, "Requested collector bash"):
            select_collectors(self.scripts, "linux", branch="codex/script-bash")

    def test_explicit_legacy_collector_fails(self):
        self.collector("bash", modern=False)
        with self.assertRaisesRegex(ValueError, "legacy interface"):
            select_collectors(self.scripts, "linux", requested="bash")

    def test_typo_fails_instead_of_skipping(self):
        with self.assertRaisesRegex(ValueError, "Unknown collector"):
            select_collectors(self.scripts, "linux", requested="bsh")

    def test_mixed_platform_selection(self):
        self.collector("bash")
        self.assertEqual(select_collectors(self.scripts, "linux", requested="bash,windows")[0], ["bash"])

    def test_duplicates_run_once(self):
        self.collector("python3")
        self.assertEqual(select_collectors(self.scripts, "linux", requested="python,python3")[0], ["python3"])

    def test_python_branch_does_not_claim_python2_coverage(self):
        self.collector("python3")
        self.assertEqual(select_collectors(self.scripts, "linux", branch="codex/script-python")[0], ["python3"])

    def test_explicit_python2_requires_its_runtime(self):
        self.collector("python2")
        with patch("select_collectors.shutil.which", return_value=None):
            with self.assertRaisesRegex(ValueError, "Python 2 runtime"):
                select_collectors(self.scripts, "linux", requested="python2")

    def test_windows_collectors_are_automatically_selected(self):
        for name in ("ps3", "ps2", "batch"):
            self.collector(name)
        self.assertEqual(select_collectors(self.scripts, "windows")[0], ["ps3", "ps2", "batch"])

    def test_windows_branch_is_not_a_linux_failure(self):
        self.assertEqual(select_collectors(self.scripts, "linux", branch="codex/script-windows")[0], [])

    def test_cli_writes_action_outputs(self):
        self.collector("bash")
        output = self.scripts / "outputs"
        result = subprocess.run(
            [sys.executable, str(TESTS_DIR / "select_collectors.py"), "--platform", "linux",
             "--scripts-dir", str(self.scripts), "--requested", "bash", "--github-output", str(output)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(encoding="utf-8"), "collectors=bash\ncount=1\n")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX shell checks")
class ShellSafeguardTests(unittest.TestCase):
    def function(self, filename, name):
        source = (TESTS_DIR / filename).read_text(encoding="utf-8")
        match = re.search(r"^" + re.escape(name) + r"\(\) \{.*?^\}", source, re.M | re.S)
        self.assertIsNotNone(match, "Missing function " + name)
        return match.group(0)

    def run_shell(self, body):
        return subprocess.run(["bash", "-c", "set -euo pipefail\n" + body],
                              capture_output=True, text=True, check=False)

    def test_legacy_suite_rejects_an_unsupported_bash(self):
        entrypoint = TESTS_DIR.parent.parent / "tests" / "test-collectors.sh"
        for interpreter in dict.fromkeys((shutil.which("bash"), "/bin/bash")):
            supported = subprocess.run(
                [interpreter, "-c", "(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))"],
                check=False,
            ).returncode == 0
            result = subprocess.run([interpreter, str(entrypoint), "--help"],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0 if supported else 1, result.stderr)
            if not supported:
                self.assertIn("require Bash 4.3 or newer", result.stderr)

    def test_failed_dry_run_is_not_a_pass(self):
        with tempfile.TemporaryDirectory(prefix="harness-dry-run-") as directory:
            result = self.run_shell(
                "WORK_DIR=" + repr(directory) + "\n"
                "fail() { printf 'FAIL %s\\n' \"$1\"; }\n"
                "jsonl_count() { echo 0; }\n"
                + self.function("run_e2e_compliance.sh", "run_dry_run_test")
                + "\nrun_dry_run_test broken false\n"
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FAIL broken/dry-run: collector exited unsuccessfully", result.stdout)

    def test_failed_reset_stops_the_operational_suite(self):
        result = self.run_shell(
            "STUB_URL=http://localhost\ncurl() { return 22; }\n"
            + self.function("run_operational_tests.sh", "clear_log")
            + "\nclear_log\necho SHOULD_NOT_RUN\n"
        )
        self.assertEqual(result.returncode, 22)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_missing_audit_log_fails_before_assertions(self):
        with tempfile.TemporaryDirectory(prefix="harness-audit-") as directory:
            result = self.run_shell(
                "STUB_LOG=" + repr(str(Path(directory) / "missing.jsonl")) + "\n"
                + self.function("run_filter_tests.sh", "require_stub_log")
                + "\nrequire_stub_log\necho SHOULD_NOT_RUN\n"
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("audit log is missing or unreadable", result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_failed_stub_cannot_be_mistaken_for_an_existing_listener(self):
        with tempfile.TemporaryDirectory(prefix="harness-startup-") as directory:
            result = self.run_shell(
                "WORK_DIR=" + repr(directory) + "\nSTUB_LOG=unused\nSTUB_PORT=19993\n"
                "curl() { return 0; }\nlsof() { echo SHOULD_NOT_RUN; }\n"
                + self.function("run_e2e_compliance.sh", "start_stub")
                + "\nstart_stub /usr/bin/false\n"
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Stub server failed to start", result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_failed_operational_stub_does_not_probe_or_reset_existing_listener(self):
        with tempfile.TemporaryDirectory(prefix="harness-operational-startup-") as directory:
            result = self.run_shell(
                "STUB_PORT=19993\nSTUB_URL=http://127.0.0.1:19993\n"
                "find_stub() { echo /usr/bin/false; }\nfind_rules() { echo unused; }\n"
                "mktemp() { echo " + repr(str(Path(directory) / "audit.jsonl")) + "; }\n"
                "curl() { echo UNRELATED_LISTENER_CONTACTED; return 0; }\n"
                + self.function("run_operational_tests.sh", "start_stub") + "\n"
                + self.function("run_operational_tests.sh", "clear_log")
                + "\nstart_stub\nclear_log\necho SHOULD_NOT_RUN\n"
            )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Stub server failed to start", result.stderr)
        self.assertNotIn("UNRELATED_LISTENER_CONTACTED", result.stdout)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

    def test_cleanup_does_not_need_lsof_or_touch_other_runs(self):
        with tempfile.TemporaryDirectory(prefix="harness-cleanup-") as directory:
            root = Path(directory)
            owned = root / "owned"
            other = root / "other"
            owned.mkdir()
            other.mkdir()
            result = self.run_shell(
                "STUB_PID=''\nRETRY_STUB_PIDS=()\nTEST_TMP_DIR=" + repr(str(owned)) + "\n"
                "lsof() { echo SHOULD_NOT_RUN; return 127; }\n"
                + self.function("run_detection_tests.sh", "stop_stub") + "\n"
                + self.function("run_detection_tests.sh", "cleanup") + "\ncleanup\n"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("SHOULD_NOT_RUN", result.stdout)
            self.assertFalse(owned.exists())
            self.assertTrue(other.is_dir())


if __name__ == "__main__":
    unittest.main(verbosity=2)
