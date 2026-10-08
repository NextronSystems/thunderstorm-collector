#!/usr/bin/env python3
"""Real cmd/WSH/curl regressions on Windows, no licensed service required."""
import os
import shutil
import subprocess
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import test_powershell_robustness as shared

SCRIPT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "batch", "thunderstorm-collector.bat"))


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
        timer = threading.Timer(45, process.kill)
        timer.start()
        try:
            self.output = process.communicate()[0].decode("utf-8", "replace")
        finally:
            timer.cancel()
        self.assertNotEqual(process.returncode, -9, "collector exceeded 45-second deadline")
        self.assertEqual(os.listdir(self.environment["TEMP"]), [], "temporary payloads were not removed")
        self.assertEqual(self.markers, [], "Batch profile must not send unsupported collection markers")
        return process.returncode

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
