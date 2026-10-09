#!/usr/bin/env python
"""Run with Python 3 or actual Python 2.7; synthetic loopback fixtures only."""
from __future__ import print_function

import json
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
SCRIPT = os.environ.get("PYTHON_COLLECTOR") or os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "python",
                                     "thunderstorm-collector-py2.py" if MAJOR == 2 else
                                     "thunderstorm-collector.py"))


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        # Only interrupted-socket errors are expected; expose test-server bugs.
        if not isinstance(error, IOError) or getattr(error, "errno", None) not in (32, 54, 104):
            self.errors.append(repr(error))


class PythonRobustness(unittest.TestCase):
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
                    body = b'{}'
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
        command = [sys.executable, "-B", SCRIPT, "--server", "127.0.0.1", "--port",
                   str(self.server.server_port), "--max-age", "0", "--retries", "1",
                   "--no-progress", "--source", "tests"]
        for root in kwargs.get("roots", [self.samples]):
            command.extend(["-d", root])
        command.extend(extra)
        if MAJOR == 2:
            command = [arg.encode("utf-8") if isinstance(arg, unicode) else arg for arg in command]
        return command

    def run_collector(self, *extra, **kwargs):
        process = subprocess.Popen(self.command(*extra, **kwargs), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, cwd=self.root)
        timer = threading.Timer(25, process.kill)
        timer.start()
        try:
            output = process.communicate()[0].decode("utf-8", "replace")
        finally:
            timer.cancel()
        self.assertNotEqual(process.returncode, -9, "collector exceeded 25-second deadline")
        self.output = output
        return process.returncode

    def test_binary_empty_special_and_unicode_source(self):
        for name in ["normal", "semi;colon", 'quote"', "comma,name", "back\\slash", "line\nbreak", u"unicode-\u00e4"]:
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
        self.assertIn("Submitted: 0 Would submit: 1", self.output)

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
        self.file("limit", b"a" * 1024)
        self.file("over", b"b" * 1025)
        self.assertEqual(self.run_collector("--max-size-kb", "1"), 0, self.output)
        self.assertEqual(self.uploads, [b"a" * 1024])

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

    def test_symlinks_and_fifo_not_uploaded(self):
        path = self.file()
        os.symlink(path, self.samples + "/link")
        os.symlink(self.samples, self.samples + "/loop")
        os.mkfifo(self.samples + "/fifo")
        self.assertEqual(self.run_collector(), 0, self.output)
        self.assertEqual(len(self.uploads), 1)

    def test_cloud_root_is_excluded_even_if_explicit(self):
        root = self.root + "/Dropbox"
        os.mkdir(root)
        with open(root + "/secret", "wb") as stream:
            stream.write(b"local")
        self.assertEqual(self.run_collector(roots=[root]), 0, self.output)
        self.assertEqual(self.uploads, [])

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
                            ("--max-size-kb", "0"), ("--max-size-kb", "204801"),
                            ("--server", "http://localhost")]:
            self.assertEqual(self.run_collector(flag, value), 2, self.output)
        self.assertEqual(self.paths, [])

    def test_unreachable_service_is_fatal(self):
        self.file()
        self.assertEqual(self.run_collector("--port", "1"), 2, self.output)

    def test_sigterm_sends_interrupted_not_end(self):
        self.file()
        self.pause = True
        process = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            self.assertTrue(self.started.wait(5), "upload did not begin")
            process.send_signal(signal.SIGTERM)
            self.release.set()
            timer = threading.Timer(15, process.kill)
            timer.start()
            output = process.communicate()[0]
            timer.cancel()
            self.assertEqual(process.returncode, 1, output)
            self.assertEqual([marker["type"] for marker in self.markers], ["begin", "interrupted"])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_legacy_tls_fails_closed_without_verification_api(self):
        try:
            from importlib.util import module_from_spec, spec_from_file_location
            spec = spec_from_file_location("collector_tls_test", SCRIPT)
            module = module_from_spec(spec)
            spec.loader.exec_module(module)
        except ImportError:
            import imp
            module = imp.load_source("collector_tls_test", SCRIPT)
        saved = getattr(module.ssl, "create_default_context", None)
        if saved is not None:
            del module.ssl.create_default_context
        args = type("Args", (object,), dict(tls=True, insecure=False, ca_cert=None))()
        try:
            with self.assertRaises(ValueError):
                module.Collector(args)
        finally:
            if saved is not None:
                module.ssl.create_default_context = saved

    def test_paired_standalone_implementations_do_not_drift(self):
        folder = os.path.dirname(SCRIPT)
        implementations = []
        for name in ("thunderstorm-collector.py", "thunderstorm-collector-py2.py"):
            with open(os.path.join(folder, name)) as stream:
                content = stream.read().split("\n", 1)[1]
            content = re.sub(r"PYTHON_MAJOR = [23]", "PYTHON_MAJOR = X", content)
            content = re.sub(r"MIN_VERSION = \([23], [47]\)", "MIN_VERSION = X", content)
            implementations.append(content)
        self.assertEqual(implementations[0], implementations[1])

    def test_file_changed_during_snapshot_fails_before_network(self):
        try:
            from importlib.util import module_from_spec, spec_from_file_location
            spec = spec_from_file_location("collector_snapshot", SCRIPT)
            module = module_from_spec(spec)
            spec.loader.exec_module(module)
        except ImportError:
            import imp
            module = imp.load_source("collector_snapshot", SCRIPT)
        path = self.file()
        expected = os.lstat(path)
        collector = module.Collector(type("Args", (object,),
                                    dict(tls=False, max_size_kb=2048, max_age=0))())
        original = module.os.fdopen

        class ChangingReader(object):
            def __init__(self, *args):
                self.stream = original(*args)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.stream.close()
            def fileno(self):
                return self.stream.fileno()
            def read(self, limit):
                data = self.stream.read(limit)
                with open(path, "ab") as stream:
                    stream.write(b"changed")
                return data

        module.os.fdopen = ChangingReader
        try:
            with self.assertRaises(ValueError):
                collector.snapshot(path, expected)
            self.assertEqual(self.paths, [])
        finally:
            module.os.fdopen = original


if __name__ == "__main__":
    unittest.main(verbosity=2)
