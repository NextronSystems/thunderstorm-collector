#!/usr/bin/env python
"""PowerShell regressions on the selected runtime; synthetic loopback fixtures."""
from __future__ import print_function

import json
import errno
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
try:
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from socketserver import ThreadingMixIn
    from urllib.parse import parse_qs, urlsplit
    from email.parser import BytesParser
except ImportError:
    from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
    from SocketServer import ThreadingMixIn
    from urlparse import parse_qs, urlsplit
    from email.parser import Parser as BytesParser

MAJOR = sys.version_info[0]
RUNTIME = os.environ.get("POWERSHELL_RUNTIME", "powershell.exe" if os.name == "nt" else "pwsh")
SCRIPT = os.environ.get("POWERSHELL_COLLECTOR") or os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "powershell", "thunderstorm-collector.ps1"))


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        # Only interrupted-socket errors are expected; expose test-server bugs.
        if not isinstance(error, IOError) or getattr(error, "errno", None) not in (32, 54, 104, 10053, 10054):
            self.errors.append(repr(error))


class PowerShellRobustness(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="python-collector-")
        self.samples = os.path.join(self.root, "samples")
        os.mkdir(self.samples)
        self.uploads = []
        self.markers = []
        self.paths = []
        self.upload_statuses = []
        self.begin_status = self.end_status = 200
        self.partial = False
        self.partial_marker = False
        self.upload_body = b'{}'
        self.marker_body = {"scan_id": "scan + & /"}
        self.pause = False
        self.started = threading.Event()
        self.release = threading.Event()
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                test.paths.append(self.path)
                if self.path.startswith("/api/collection"):
                    marker = json.loads(data.decode("utf-8"))
                    test.markers.append(marker)
                    status = test.begin_status if marker["type"] == "begin" else test.end_status
                    body = json.dumps(test.marker_body).encode("utf-8")
                    partial = test.partial_marker
                else:
                    status = test.upload_statuses.pop(0) if test.upload_statuses else 200
                    mime = ("Content-Type: " + self.headers["Content-Type"] +
                            "\r\nMIME-Version: 1.0\r\n\r\n").encode("ascii") + data
                    parser = BytesParser()
                    message = parser.parsebytes(mime) if MAJOR == 3 else parser.parsestr(mime)
                    if 200 <= status < 300:
                        test.uploads.extend(part.get_payload(decode=True)
                                            for part in message.get_payload())
                    body = test.upload_body
                    partial = test.partial
                    if test.pause:
                        test.started.set()
                        test.release.wait(8)
                self.send_response(status)
                self.send_header("Content-Length", str(len(body) + (20 if partial else 0)))
                self.send_header("Retry-After", "0")
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.server.errors = []
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def tearDown(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        shutil.rmtree(self.root)
        self.assertEqual(self.server.errors, [], "unexpected test-server exception")

    def file(self, name="sample.bin", data=b"\x00\xffTHUNDER\n"):
        path = os.path.join(self.samples, name)
        with open(path, "wb") as stream:
            stream.write(data)
        return path

    def command(self, *extra, **kwargs):
        options = {"ThunderstormServer": "127.0.0.1", "ThunderstormPort": str(self.server.server_port),
                   "MaxAge": "0", "Retries": "1", "Source": "tests"}
        flags = ["AllExtensions", "NoProgress"]
        names = {"--port": "ThunderstormPort", "--source": "Source", "--max-age": "MaxAge",
                 "--max-size-kb": "MaxSize", "--retries": "Retries", "--server": "ThunderstormServer"}
        index = 0
        while index < len(extra):
            option = extra[index]
            if option in ("--dry-run", "--sync"):
                flags.append("DryRun" if option == "--dry-run" else "Sync")
                index += 1
            else:
                options[names[option]] = extra[index + 1]
                index += 2
        def literal(value):
            return "'" + str(value).replace("'", "''") + "'"
        expression = "& " + literal(SCRIPT)
        for key, value in options.items():
            expression += " -" + key + " " + literal(value)
        expression += " -Folder @(" + ",".join(literal(root) for root in kwargs.get("roots", [self.samples])) + ")"
        expression += " " + " ".join("-" + flag for flag in flags)
        return [RUNTIME, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", expression + "; exit $LASTEXITCODE"]

    def run_collector(self, *extra, **kwargs):
        process = subprocess.Popen(self.command(*extra, **kwargs), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, cwd=self.root)
        timer = threading.Timer(45, process.kill)
        timer.start()
        try:
            output = process.communicate()[0].decode("utf-8", "replace")
        finally:
            timer.cancel()
        self.assertNotEqual(process.returncode, -9, "collector exceeded 45-second deadline: " + output)
        self.output = output
        return process.returncode

    def test_binary_empty_special_and_unicode_source(self):
        for name in ["normal", "semi;colon", "comma,name", "bracket[name]", "percent%PATH%", "bang!", u"unicode-\u00e4"]:
            self.file(name)
        self.file("empty", b"")
        source = "a" * 96 + u" + & / \u00e4"
        self.assertEqual(self.run_collector("--source", source), 0, self.output)
        self.assertEqual(sorted(self.uploads), sorted([b"\x00\xffTHUNDER\n"] * 7 + [b""]))
        self.assertTrue(all(marker["source"] == source for marker in self.markers))
        for path in self.paths:
            if path.startswith("/api/check"):
                query = parse_qs(urlsplit(path).query)
                expected = source.encode("utf-8") if MAJOR == 2 else source
                self.assertEqual(query["source"], [expected])
                self.assertEqual(query["scan_id"], ["scan + & /"])

    def test_dry_run_does_not_contact_unreachable_service(self):
        self.file()
        self.assertEqual(self.run_collector("--dry-run", "--port", "1"), 0, self.output)
        self.assertEqual(self.paths, [])

    def test_zero_age_includes_old_file(self):
        path = self.file()
        os.utime(path, (1577836800, 1577836800))
        self.assertEqual(self.run_collector(), 0, self.output)
        self.assertEqual(len(self.uploads), 1)

    def test_positive_age_excludes_old_file(self):
        path = self.file()
        os.utime(path, (1577836800, 1577836800))
        self.assertEqual(self.run_collector("--max-age", "1"), 0, self.output)
        self.assertEqual(self.uploads, [])

    def test_size_exact_limit(self):
        self.file("limit", b"a" * 1048576)
        self.file("over", b"b" * 1048577)
        self.assertEqual(self.run_collector("--max-size-kb", "1"), 0, self.output)
        self.assertEqual(self.uploads, [b"a" * 1048576])

    def test_missing_root_reports_partial_but_continues(self):
        self.file()
        self.assertEqual(self.run_collector(roots=[self.samples, self.root + "/missing"]), 1, self.output)
        self.assertEqual(len(self.uploads), 1)
        self.assertIn("Scan errors: 1", self.output)

    def test_all_missing_roots_fail_before_network(self):
        self.assertEqual(self.run_collector(roots=[self.root + "/missing"]), 2, self.output)
        self.assertEqual(self.paths, [])

    def test_repeated_directory_options(self):
        self.file()
        other = self.root + "/other"
        os.mkdir(other)
        with open(other + "/other.bin", "wb") as stream:
            stream.write(b"other")
        self.assertEqual(self.run_collector(roots=[self.samples, other]), 0, self.output)
        self.assertEqual(len(self.uploads), 2)

    @unittest.skipUnless(os.name == "posix", "symlink creation permissions are target-dependent on Windows")
    def test_symlinks_not_uploaded(self):
        path = self.file()
        os.symlink(path, self.samples + "/link")
        os.symlink(self.samples, self.samples + "/loop")
        self.assertEqual(self.run_collector(), 0, self.output)
        self.assertEqual(len(self.uploads), 1)

    def test_cloud_root_is_excluded_even_if_explicit(self):
        root = self.root + "/Dropbox"
        os.mkdir(root)
        with open(root + "/secret", "wb") as stream:
            stream.write(b"local")
        self.assertEqual(self.run_collector(roots=[root]), 0, self.output)
        self.assertEqual(self.uploads, [])

    @unittest.skipUnless(os.name == "posix", "Windows ACL/locked-file case is separate")
    def test_unreadable_file_and_directory_nonroot(self):
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            self.skipTest("requires non-root; CI/container must use a non-root user")
        self.file("ok", b"readable")
        blocked = self.file("blocked")
        directory = self.samples + "/blocked-dir"
        os.mkdir(directory)
        os.chmod(blocked, 0)
        os.chmod(directory, 0)
        try:
            self.assertEqual(self.run_collector(), 1, self.output)
            self.assertEqual(self.uploads, [b"readable"])
            self.assertIn("Failed: 1", self.output)
            self.assertIn("Scan errors: 1", self.output)
        finally:
            os.chmod(blocked, 0o600)
            os.chmod(directory, 0o700)

    def test_failed_end_marker_is_failure(self):
        self.file()
        self.end_status = 500
        self.assertEqual(self.run_collector(), 1, self.output)

    def test_optional_marker_error_body_id_is_ignored(self):
        self.file()
        self.begin_status = self.end_status = 404
        self.assertEqual(self.run_collector(), 0, self.output)
        self.assertTrue(all("scan_id=" not in path for path in self.paths if "/api/check" in path))

    def test_non_object_marker_json_does_not_crash(self):
        self.file()
        self.marker_body = []
        self.assertEqual(self.run_collector(), 0, self.output)

    def test_non_string_scan_id_is_not_used(self):
        self.file()
        self.marker_body = {"scan_id": {"invalid": True}}
        self.assertEqual(self.run_collector(), 0, self.output)
        self.assertTrue(all("scan_id=" not in path for path in self.paths if "/api/check" in path))

    def test_incomplete_2xx_upload_is_failure(self):
        self.file()
        self.partial = True
        self.assertEqual(self.run_collector(), 1, self.output)
        self.assertIn("Submitted: 0", self.output)

    def test_oversized_response_is_failure(self):
        self.file()
        self.upload_body = b'x' * 1048577
        self.assertEqual(self.run_collector(), 1, self.output)
        self.assertIn("Submitted: 0", self.output)

    def test_incomplete_begin_is_fatal(self):
        self.file()
        self.partial_marker = True
        self.assertEqual(self.run_collector(), 2, self.output)
        self.assertEqual(self.uploads, [])

    def test_503_retry_budget_and_recovery(self):
        self.file()
        self.upload_statuses = [503, 200]
        self.assertEqual(self.run_collector("--retries", "2"), 0, self.output)
        self.assertEqual(sum("/api/check" in path for path in self.paths), 2)

    def test_503_exhausts_total_attempts(self):
        self.file()
        self.upload_statuses = [503, 503, 200]
        self.assertEqual(self.run_collector("--retries", "2"), 1, self.output)
        self.assertEqual(sum("/api/check" in path for path in self.paths), 2)

    def test_sync_endpoint(self):
        self.file()
        self.assertEqual(self.run_collector("--sync"), 0, self.output)
        self.assertTrue(any(path.startswith("/api/check?") for path in self.paths))

    def test_configuration_bounds_before_network(self):
        for flag, value in [("--port", "0"), ("--port", "65536"), ("--retries", "0"),
                            ("--retries", "11"), ("--max-age", "-1"),
                            ("--max-size-kb", "0"), ("--max-size-kb", "201"),
                            ("--server", "http://localhost")]:
            self.assertEqual(self.run_collector(flag, value), 2, self.output)
        self.assertEqual(self.paths, [])

    def test_unreachable_service_is_fatal(self):
        self.file()
        self.assertEqual(self.run_collector("--port", "1"), 2, self.output)

    def test_redirect_is_failure_and_not_followed(self):
        self.file()
        self.upload_statuses = [302]
        self.assertEqual(self.run_collector(), 1, self.output)
        self.assertIn("Submitted: 0", self.output)
        self.assertEqual(sum("/api/check" in path for path in self.paths), 1)

    def test_profiles_share_the_reviewed_core(self):
        directory = os.path.dirname(SCRIPT)
        with open(os.path.join(directory, "thunderstorm-collector.ps1")) as stream:
            modern = stream.read().replace("#requires -Version 3.0", "").replace("powershell3/0.3", "PROFILE")
        with open(os.path.join(directory, "thunderstorm-collector-ps2.ps1")) as stream:
            legacy = stream.read().replace("#requires -Version 2.0", "").replace("powershell2/0.3", "PROFILE")
        self.assertEqual(modern, legacy)

    @unittest.skipUnless(os.name == "nt", "Windows FileShare.None locking semantics")
    def test_locked_file_does_not_prevent_readable_upload(self):
        self.file("ok.bin", b"readable")
        path = self.file("locked.bin")
        ready = os.path.join(self.root, "lock-ready")
        literal = lambda value: "'" + value.replace("'", "''") + "'"
        expression = "$f=[IO.File]::Open(" + literal(path) + ",'Open','ReadWrite','None'); " + \
            "[IO.File]::WriteAllText(" + literal(ready) + ",'ready'); try { Start-Sleep -Seconds 30 } finally { $f.Close() }"
        process = subprocess.Popen([RUNTIME, "-NoProfile", "-Command", expression],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            deadline = time.time() + 10
            while not os.path.exists(ready) and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(os.path.exists(ready), "lock helper did not become ready")
            self.assertEqual(self.run_collector(), 1, self.output)
            self.assertEqual(self.uploads, [b"readable"])
        finally:
            process.terminate()
            process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
