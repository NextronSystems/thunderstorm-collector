#!/usr/bin/env python3
"""Real cmd/WSH/curl regressions on Windows, no licensed service required."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import test_powershell_robustness as shared

SCRIPT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "batch", "thunderstorm-collector.bat"))


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX adapter contract test")
class BatchAdapterTests(unittest.TestCase):
    def test_adapter_exports_configuration_without_rewriting_collector(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix="batch adapter '") as directory:
            root = Path(directory)
            command = root / "fake cmd"
            command.write_text("#!" + sys.executable + '''
import hashlib, json, os, sys
print(json.dumps({"args": sys.argv[1:], "env": dict(os.environ),
                  "sha256": hashlib.sha256(open(os.environ["ADAPTER_COPY"], "rb").read()).hexdigest()}))
''')
            command.chmod(0o755)
            curl = root / "curl.exe"
            curl.write_text("#!/bin/sh\nexit 0\n")
            curl.chmod(0o755)
            copy = root / "collector & sample.bat"
            fixture = root / "input & data!"
            env = dict(os.environ, PROJECT_ROOT=str(repo), TEST_DATA_DIR=str(fixture), MOCK_PORT="19993",
                       MKTEMP_CMD="fixture_mktemp", CP_CMD="cp", RM_CMD="rm", CMD_CMD=str(command),
                       ADAPTER_COPY=str(copy), PATH=str(root) + os.pathsep + os.environ["PATH"])
            adapter = repo / "tests/test-collectors.d/bat"
            body = 'set -e\nfixture_mktemp() { : > "$ADAPTER_COPY"; printf "%s\\n" "$ADAPTER_COPY"; }\n'
            body += 'to_native_path() { printf "%s\\n" "$1"; }\n'
            for name in ("setup_test.sh", "build_command.sh", "cleanup_test.sh"):
                body += ". " + shlex.quote(str(adapter / name)) + "\n"
            body += 'collector_setup\ncommand=$(collector_build_command "")\neval "$command"\ncollector_cleanup\n'
            result = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            captured = json.loads(result.stdout)
            self.assertEqual(captured["args"], ["/d", "/v:off", "/s", "/c", '"' + str(copy) + '"'])
            expected = dict(THUNDERSTORM_SERVER="127.0.0.1", THUNDERSTORM_PORT="19993",
                            COLLECT_DIRS=str(fixture), MAX_AGE="365", COLLECT_MAX_SIZE="3000000",
                            RELEVANT_EXTENSIONS=".txt;.log;.ps1;.tmp", CURL_PATH=str(curl),
                            URL_SCHEME="http", DRY_RUN="0", SYNC="0", UPLOAD_ATTEMPTS="1")
            for key, value in expected.items():
                self.assertEqual(captured["env"][key], value, key)
            self.assertEqual(captured["sha256"], hashlib.sha256(Path(SCRIPT).read_bytes()).hexdigest())
            self.assertFalse(copy.exists())

    def test_adapter_rejects_unsupported_cli_arguments(self):
        adapter = Path(__file__).resolve().parents[2] / "tests/test-collectors.d/bat/build_command.sh"
        result = subprocess.run(["bash", "-c", '. "$1"; collector_build_command --dry-run', "test", str(adapter)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uses environment settings", result.stderr)


@unittest.skipUnless(os.name == "nt", "requires Windows cmd.exe and Windows Script Host")
class BatchRobustness(shared.PowerShellRobustness):
    TLS_FAILURE_CODE = 1

    def command(self, *extra, **kwargs):
        self.environment = dict(os.environ)
        self.environment.pop("CURL_CA_BUNDLE", None)
        self.environment.update({"THUNDERSTORM_SERVER": "127.0.0.1", "THUNDERSTORM_PORT": str(self.server.server_port),
                                 "MAX_AGE": "0", "UPLOAD_ATTEMPTS": "1", "SOURCE": "tests", "URL_SCHEME": "http",
                                 "DRY_RUN": "0", "SYNC": "0", "RELEVANT_EXTENSIONS": "*",
                                 "COLLECT_MAX_SIZE": "2097152", "COLLECT_DIRS": ";".join(kwargs.get("roots", [self.samples])),
                                 "CURL_PATH": shutil.which("curl.exe") or "C:\\missing-curl.exe"})
        temporary = os.path.join(self.root, "temporary")
        os.makedirs(temporary, exist_ok=True)
        self.environment["TEMP"] = self.environment["TMP"] = temporary
        names = {"--port": "THUNDERSTORM_PORT", "--source": "SOURCE", "--max-age": "MAX_AGE",
                 "--max-size-kb": "COLLECT_MAX_SIZE", "--retries": "UPLOAD_ATTEMPTS", "--server": "THUNDERSTORM_SERVER",
                 "--ca-cert": "CURL_CA_BUNDLE"}
        index = 0
        while index < len(extra):
            option = extra[index]
            if option in ("--dry-run", "--sync"):
                self.environment["DRY_RUN" if option == "--dry-run" else "SYNC"] = "1"
                index += 1
            elif option == "--tls":
                self.environment["URL_SCHEME"] = "https"
                index += 1
            else:
                value = extra[index + 1]
                if option == "--max-size-kb":
                    value = str(int(value) * 1048576)
                self.environment[names[option]] = value
                index += 2
        return [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/v:off", "/c", SCRIPT]

    def run_collector(self, *extra, **kwargs):
        command = self.command(*extra, **kwargs)
        process = subprocess.Popen(command, env=self.environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, cwd=self.root)
        self.output = shared.communicate_collector(process).decode("utf-8", "replace")
        self.assertEqual(os.listdir(self.environment["TEMP"]), [], "temporary payloads were not removed")
        self.assertEqual(self.markers, [], "Batch profile must not send unsupported collection markers")
        return process.returncode


    def test_header_configuration_defaults_and_cli_precedence(self):
        for name, size, days in [("fresh.txt", 1, 0), ("twenty-days.txt", 1, 20),
                                 ("forty-days.txt", 1, 40), ("exact.txt", 2097152, 0),
                                 ("oversized.txt", 2097153, 0)]:
            path = self.file(name, b"x" * size)
            stamp = time.time() - days * 86400
            os.utime(path, (stamp, stamp))
        source = Path(SCRIPT).read_text()
        changes = [('var THUNDERSTORM_SERVER = "";', 'var THUNDERSTORM_SERVER = "127.0.0.1";'),
                   ('var COLLECT_DIRS = "";', 'var COLLECT_DIRS = ' + json.dumps(self.samples) + ';'),
                   ('var DRY_RUN = 0;', 'var DRY_RUN = 1;'),
                   ('var URL_SCHEME = "http";', 'var URL_SCHEME = "https";')]
        for old, new in changes:
            self.assertIn(old, source)
            source = source.replace(old, new, 1)
        configured = Path(self.root) / "configured.bat"
        configured.write_text(source)
        environment = dict(os.environ)
        for name in ("THUNDERSTORM_SERVER", "THUNDERSTORM_PORT", "COLLECT_DIRS", "SOURCE",
                     "MAX_AGE", "COLLECT_MAX_SIZE", "RELEVANT_EXTENSIONS", "DRY_RUN", "SYNC",
                     "URL_SCHEME", "CURL_CA_BUNDLE", "UPLOAD_ATTEMPTS", "CURL_PATH"):
            environment.pop(name, None)
        temporary = Path(self.root) / "header-temporary"
        temporary.mkdir()
        environment["TEMP"] = environment["TMP"] = str(temporary)

        def invoke():
            process = subprocess.Popen([os.environ.get("COMSPEC", "cmd.exe"), "/d", "/v:off",
                                        "/c", str(configured)], env=environment, cwd=self.root,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output = shared.communicate_collector(process).decode("utf-8", "replace")
            self.assertEqual(process.returncode, 0, output)
            return output

        output = invoke()
        self.assertIn("max-age=30", output)
        self.assertIn("max-size=2097152 bytes", output)
        self.assert_scan_roots(output, [self.samples])
        for name in ("fresh.txt", "twenty-days.txt", "exact.txt"):
            self.assertIn(name, output)
        for name in ("forty-days.txt", "oversized.txt"):
            self.assertNotIn(name, output)
        self.assertEqual(self.paths, [])

        override = Path(self.root) / "environment root with spaces"
        override.mkdir()
        (override / "only-env.txt").write_bytes(b"env-only")
        environment.update(THUNDERSTORM_SERVER="127.0.0.1", THUNDERSTORM_PORT=str(self.server.server_port),
                           COLLECT_DIRS=str(override), URL_SCHEME="http", DRY_RUN="0",
                           MAX_AGE="0", COLLECT_MAX_SIZE="1024", SOURCE="env-source",
                           CURL_PATH=shutil.which("curl.exe") or "C:\\missing-curl.exe")
        output = invoke()
        self.assert_scan_roots(output, [override])
        self.assertIn("max-age=0", output)
        self.assertIn("max-size=1024 bytes", output)
        self.assertEqual(self.uploads, [b"env-only"])
        self.assertTrue(any("source=env-source" in path for path in self.paths))
        self.assertEqual(list(temporary.iterdir()), [])


    def test_binary_empty_special_and_unicode_source(self):
        names = ["normal", "semi;colon", "comma,name", "bracket[name]", "percent%PATH%", "bang!", "amp&caret^", "unicode-\u00e4"]
        for name in names:
            self.file(name)
        self.file("empty", b"")
        source = "a" * 96 + " + & / \u00e4 %PATH% !"
        self.assertEqual(self.run_collector("--source", source), 0, self.output)
        self.assertEqual(sorted(self.uploads), sorted([b"\x00\xffTHUNDER\n"] * len(names) + [b""]))
        for path in self.paths:
            self.assertEqual(parse_qs(urlsplit(path).query)["source"], [source])
            self.assertNotIn("scan_id=", path)

    def test_unreachable_service_is_fatal(self):
        self.file()
        self.assertEqual(self.run_collector("--port", "1"), 1, self.output)

    def test_dry_run_does_not_need_curl(self):
        self.file()
        with patch("shutil.which", return_value=None):
            self.assertEqual(self.run_collector("--dry-run"), 0, self.output)
        self.assertEqual(self.paths, [])

    def test_missing_curl_fails_before_network(self):
        self.file()
        with patch("shutil.which", return_value=None):
            self.assertEqual(self.run_collector(), 2, self.output)
        self.assertEqual(self.paths, [])

    def test_profiles_share_the_reviewed_core(self):
        self.skipTest("PowerShell-only drift guard")

    def test_failed_end_marker_is_failure(self):
        self.skipTest("Batch deliberately has no collection markers")

    def test_optional_marker_error_body_id_is_ignored(self):
        self.skipTest("Batch deliberately has no collection markers")

    def test_non_object_marker_json_does_not_crash(self):
        self.skipTest("Batch deliberately has no collection markers")

    def test_non_string_scan_id_is_not_used(self):
        self.skipTest("Batch deliberately has no collection markers")

    def test_incomplete_begin_is_fatal(self):
        self.skipTest("Batch deliberately has no collection markers")


if __name__ == "__main__":
    unittest.main(verbosity=2)
