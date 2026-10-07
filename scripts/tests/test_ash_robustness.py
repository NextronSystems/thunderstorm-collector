#!/usr/bin/env python3
"""POSIX collector regressions with synthetic files and a loopback HTTP server."""

import email.policy
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import unittest
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


COLLECTOR = Path(os.environ.get("ASH_COLLECTOR", Path(__file__).resolve().parents[1] /
                               "ash/thunderstorm-collector-ash.sh"))
SHELL = shlex.split(os.environ.get("COLLECTOR_SH", shutil.which("dash") or "/bin/sh"))


class AshRobustnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ash-robustness-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.samples = self.root / "samples"
        self.samples.mkdir()
        self.requests = []
        self.uploads = []
        self.markers = []
        self.upload_statuses = []
        self.marker_status = 200
        self.end_status = 200
        self.diagnostic_header = False
        self.partial_upload_response = False
        self.partial_marker_response = False
        self.scan_id = "test-scan-1"
        self.pause_upload = False
        self.upload_started = threading.Event()
        self.release_upload = threading.Event()
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                test.requests.append(self.path)
                response = b'{}'
                if self.path.startswith("/api/collection"):
                    marker = json.loads(data)
                    test.markers.append(marker)
                    status = test.end_status if marker["type"] == "end" else test.marker_status
                    response = json.dumps({"scan_id": test.scan_id}).encode()
                    partial = test.partial_marker_response
                else:
                    status = test.upload_statuses.pop(0) if test.upload_statuses else 200
                    headers = ("Content-Type: " + self.headers["Content-Type"] +
                               "\r\nMIME-Version: 1.0\r\n\r\n").encode()
                    message = BytesParser(policy=email.policy.default).parsebytes(headers + data)
                    if 200 <= status < 300:
                        test.uploads.extend((part.get_filename(), part.get_payload(decode=True))
                                            for part in message.iter_parts())
                    partial = test.partial_upload_response
                    if test.pause_upload:
                        test.upload_started.set()
                        test.release_upload.wait(timeout=5)
                self.send_response(status)
                if test.diagnostic_header:
                    self.send_header("X-Diagnostic", "HTTP/1.1 200 OK")
                if status == 503:
                    self.send_header("Retry-After", "0")
                self.send_header("Content-Length", str(len(response) + (10 if partial else 0)))
                self.end_headers()
                self.wfile.write(response)
                self.close_connection = True

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.stop_server, thread)

    def stop_server(self, thread):
        self.server.shutdown()
        self.server.server_close()
        thread.join(timeout=5)

    def run_collector(self, *args, env=None, roots=None, log_file=None):
        command = SHELL + [str(COLLECTOR), "--server", "127.0.0.1", "--port",
                           str(self.server.server_port), "--no-progress", "--max-age", "365",
                           "--retries", "1"]
        command.extend(["--log-file", str(log_file)] if log_file else ["--no-log-file"])
        for root in roots if roots is not None else [self.samples]:
            command.extend(["--dir", str(root)])
        result = subprocess.run(command + list(args), cwd=self.root,
                                env={**os.environ, "TMPDIR": str(self.root), **(env or {})},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=40)
        self.output = result.stdout
        return result

    def tool_path(self, **replacements):
        tools = self.root / "tools"
        tools.mkdir(exist_ok=True)
        for name in ("awk", "basename", "cat", "date", "dirname", "find", "grep", "head",
                     "hostname", "id", "mktemp", "od", "rm", "sed", "sh", "sleep",
                     "stat", "tail", "timeout", "tr", "uname", "wc"):
            path = shutil.which(name)
            if path and not (tools / name).exists():
                (tools / name).symlink_to(path)
        for name, script in replacements.items():
            path = tools / name
            if path.is_symlink():
                path.unlink()
            path.write_text(script)
            path.chmod(0o755)
        return str(tools)

    def real_tool_path(self, name, **replacements):
        path = self.tool_path(**replacements)
        (Path(path) / name).symlink_to(shutil.which(name))
        return path

    def assert_payloads(self, expected):
        self.assertCountEqual(expected, [payload for _, payload in self.uploads], self.output)

    def test_special_filenames_and_source_preserve_data(self):
        names = ["normal.txt", "semi;colon.txt", "comma,name.txt", 'double"quote.txt',
                 "back\\slash.txt", "-leading.txt", "unicode-\u00e4.txt"]
        for name in names:
            (self.samples / name).write_bytes(b"\x00\xff" + name.encode())
        source = 'source \u00e4 & + " \\ \n\t'
        result = self.run_collector("--source", source)
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"\x00\xff" + name.encode() for name in names])
        for path in self.requests:
            if "/api/check" in path:
                self.assertEqual(parse_qs(urlsplit(path).query)["source"], [source])
                self.assertEqual(parse_qs(urlsplit(path).query)["scan_id"], [self.scan_id])
        self.assertTrue(all(marker["source"] == source for marker in self.markers))

    def test_newline_path_cannot_upload_an_unrelated_file(self):
        (self.root / "victim.txt").write_bytes(b"must stay local")
        (self.samples / "prefix\nvictim.txt").write_bytes(b"unsupported filename")
        (self.samples / "ok.txt").write_bytes(b"readable")
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("scan_errors=1", self.output)
        self.assert_payloads([b"readable"])

    def test_internal_workspace_and_log_are_not_uploaded(self):
        samples = self.root / "self [scan]*?"
        samples.mkdir()
        (samples / "real.txt").write_bytes(b"real payload")
        log = samples / "collector [log]*?.txt"
        result = self.run_collector(roots=[samples], log_file=log, env={"TMPDIR": str(samples)})
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"real payload"])
        self.assertEqual(sorted(p.name for p in samples.iterdir()), [log.name, "real.txt"])

    def test_dry_run_needs_no_network_tool(self):
        (self.samples / "real.txt").write_bytes(b"local")
        result = self.run_collector("--dry-run", env={"PATH": self.tool_path()})
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn("DRY-RUN: would submit", self.output)
        self.assertEqual(self.requests, [])

    def test_missing_root_is_partial_failure(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        result = self.run_collector(roots=[self.samples, self.root / "missing"])
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("scan_errors=1", self.output)
        self.assert_payloads([b"readable"])

    def test_all_roots_missing_fails_even_in_dry_run(self):
        result = self.run_collector("--dry-run", roots=[self.root / "missing"])
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("scan_errors=1", self.output)

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "permissions need non-root")
    def test_unreadable_file_and_directory_preserve_readable_upload(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        blocked = self.samples / "blocked.txt"
        blocked.write_bytes(b"private")
        blocked_dir = self.samples / "blocked-dir"
        blocked_dir.mkdir()
        (blocked_dir / "hidden.txt").write_bytes(b"hidden")
        self.addCleanup(blocked.chmod, 0o600)
        self.addCleanup(blocked_dir.chmod, 0o700)
        blocked.chmod(0)
        blocked_dir.chmod(0)
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("scan_errors=1", self.output)
        self.assertIn("failed=1", self.output)
        self.assert_payloads([b"readable"])

    def test_find_failure_keeps_partial_results_but_fails_run(self):
        sample = self.samples / "real.txt"
        sample.write_bytes(b"readable")
        path = self.real_tool_path("curl", find='#!/bin/sh\nprintf "%s\\n" "$SAMPLE"\necho "fixture error" >&2\nexit 1\n')
        result = self.run_collector(env={"PATH": path, "SAMPLE": str(sample)})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("Incomplete scan", self.output)
        self.assert_payloads([b"readable"])

    def test_symlinks_are_not_uploaded(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        other = self.root / "outside.txt"
        other.write_bytes(b"outside")
        (self.samples / "link.txt").symlink_to(other)
        result = self.run_collector()
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"readable"])

    def test_size_boundary_and_empty_file(self):
        for name, data in [("limit", b"x" * 1024), ("too-big", b"y" * 1025), ("empty", b"")]:
            (self.samples / name).write_bytes(data)
        result = self.run_collector("--max-size-kb", "1")
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn("skipped=1", self.output)
        self.assert_payloads([b"x" * 1024, b""])

    def test_zero_age_disables_age_filter(self):
        (self.samples / "recent").write_bytes(b"recent")
        old = self.samples / "old"
        old.write_bytes(b"old")
        os.utime(old, (1577836800, 1577836800))
        result = self.run_collector("--max-age", "0")
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"recent", b"old"])

    def test_503_retries_within_configured_budget(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.upload_statuses = [503, 200]
        result = self.run_collector("--retries", "2")
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"readable"])
        self.assertEqual(sum("/api/check" in path for path in self.requests), 2)

    def test_permanent_503_exhausts_bounded_budget(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.upload_statuses = [503] * 10
        result = self.run_collector("--retries", "2")
        self.assertEqual(result.returncode, 1, self.output)
        self.assertEqual(sum("/api/check" in path for path in self.requests), 2)
        self.assert_payloads([])

    def test_incomplete_begin_response_is_fatal(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.partial_marker_response = True
        transports = [None]
        if shutil.which("wget"):
            transports.append(self.real_tool_path("wget"))
        for path in transports:
            with self.subTest(path=path):
                result = self.run_collector(env={"PATH": path} if path else None)
                self.assertEqual(result.returncode, 2, self.output)
        self.assert_payloads([])

    def test_failed_upload_does_not_prevent_other_files(self):
        (self.samples / "one.txt").write_bytes(b"one")
        (self.samples / "two.txt").write_bytes(b"two")
        self.upload_statuses = [500, 200]
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("submitted=1", self.output)
        self.assertIn("failed=1", self.output)
        self.assertEqual(len(self.uploads), 1)

    def test_optional_marker_does_not_reuse_error_body_scan_id(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.marker_status = self.end_status = 404
        result = self.run_collector()
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn("not supported (HTTP 404)", self.output)
        self.assertTrue(all("scan_id=" not in path for path in self.requests))
        self.assert_payloads([b"readable"])

    def test_failed_end_marker_is_partial_failure(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.end_status = 500
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("end marker failed", self.output)
        self.assert_payloads([b"readable"])

    def test_mktemp_failure_cannot_reuse_foreign_pid_directory(self):
        foreign = self.root / "thunderstorm.foreign"
        foreign.mkdir()
        (foreign / "keep.txt").write_bytes(b"keep")
        path = self.tool_path(mktemp='#!/bin/sh\nexit 1\n')
        wrapper = 'mv "$TMPDIR/thunderstorm.foreign" "$TMPDIR/thunderstorm.$$"; exec "$@"'
        command = SHELL + ["-c", wrapper, "fixture"] + SHELL + [str(COLLECTOR), "--dry-run",
                    "--no-log-file", "--dir", str(self.samples)]
        result = subprocess.run(command, env={**os.environ, "TMPDIR": str(self.root),
                                             "PATH": path + os.pathsep + os.environ["PATH"]},
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(len(list(self.root.glob("thunderstorm.*/keep.txt"))), 1)

    def test_double_dash_keeps_remaining_directories(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        empty = self.root / "empty"
        empty.mkdir()
        result = self.run_collector("--", str(self.samples), roots=[empty])
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"readable"])

    def test_configuration_bounds_fail_before_network(self):
        for option, value in [("--port", "65536"), ("--retries", "11"),
                              ("--max-age", "999999999999999999999"),
                              ("--max-size-kb", "0"), ("--dir", "line\nbreak")]:
            with self.subTest(option=option, value=value):
                result = self.run_collector(option, value)
                self.assertEqual(result.returncode, 2, self.output)
        self.assertEqual(self.requests, [])

    def test_log_option_last_wins(self):
        log = self.root / "collector.log"
        result = self.run_collector("--dry-run", "--log-file", str(log))
        self.assertEqual(result.returncode, 0, self.output)
        self.assertTrue(log.is_file())

    def test_partial_2xx_curl_response_is_not_success(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.partial_upload_response = True
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("submitted=0", self.output)

    @unittest.skipUnless(shutil.which("wget"), "GNU wget required")
    def test_wget_preserves_binary_payloads_and_special_names(self):
        for name in ['semi;colon', 'comma,name', 'double"quote', 'binary']:
            (self.samples / name).write_bytes(b"\x00\xff" + name.encode())
        result = self.run_collector(env={"PATH": self.real_tool_path("wget")})
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([p.read_bytes() for p in self.samples.iterdir()])

    @unittest.skipUnless(shutil.which("wget"), "GNU wget required")
    def test_wget_header_value_cannot_override_error_status(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.upload_statuses = [500]
        self.diagnostic_header = True
        result = self.run_collector(env={"PATH": self.real_tool_path("wget")})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("HTTP 500", self.output)
        self.assertIn("submitted=0", self.output)

    @unittest.skipUnless(shutil.which("wget"), "GNU wget required")
    def test_wget_failed_body_copy_cannot_upload_truncated_sample(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        result = self.run_collector(env={"PATH": self.real_tool_path("wget", cat='#!/bin/sh\nexit 1\n')})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertEqual(sum("/api/check" in p for p in self.requests), 0)

    @unittest.skipUnless(shutil.which("wget"), "GNU wget required")
    def test_partial_2xx_wget_response_is_not_success(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.partial_upload_response = True
        result = self.run_collector(env={"PATH": self.real_tool_path("wget")})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("submitted=0", self.output)

    def test_busybox_wget_only_fails_closed(self):
        path = self.tool_path(wget='#!/bin/sh\nif [ "$1" = --help ]; then echo "BusyBox wget"; exit 0; fi\necho "HTTP/1.1 200 OK" >&2\n')
        (self.samples / "real.txt").write_bytes(b"\x00binary")
        result = self.run_collector(env={"PATH": path})
        self.assertEqual(result.returncode, 2, self.output)
        self.assertEqual(self.requests, [])

    @unittest.skipUnless(shutil.which("nc") and shutil.which("timeout"), "nc and timeout required")
    def test_nc_uploads_binary_without_collection_markers(self):
        (self.samples / "real.txt").write_bytes(b"\x00\xffreadable")
        result = self.run_collector(env={"PATH": self.real_tool_path("nc")})
        self.assertEqual(result.returncode, 0, self.output)
        self.assertEqual(self.markers, [])
        self.assert_payloads([b"\x00\xffreadable"])

    def test_nc_rejects_incomplete_or_malformed_responses(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        path = self.tool_path(nc='#!/bin/sh\ncat >/dev/null\nprintf "%s" "$NC_RESPONSE"\nexit "${NC_EXIT:-0}"\n')
        for response, code in [("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n", "0"),
                               ("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n", "1"),
                               ("HTTP/1.0 200 OK\r\n\r\n{}", "0"),
                               ("garbage\r\nContent-Length: 0\r\n\r\n", "0")]:
            with self.subTest(response=response, code=code):
                result = self.run_collector(env={"PATH": path, "NC_RESPONSE": response, "NC_EXIT": code})
                self.assertEqual(result.returncode, 1, self.output)
                self.assertIn("submitted=0", self.output)

    def test_https_refuses_nc_only_environment(self):
        path = self.tool_path(nc='#!/bin/sh\nexit 0\n')
        result = self.run_collector("--ssl", env={"PATH": path})
        self.assertEqual(result.returncode, 2, self.output)
        self.assertIn("does not support TLS", self.output)
        self.assertEqual(self.requests, [])

    def test_nc_without_timeout_fails_before_uploads(self):
        path = self.tool_path(nc='#!/bin/sh\nexit 0\n')
        timeout = Path(path) / "timeout"
        if timeout.exists():
            timeout.unlink()
        result = self.run_collector(env={"PATH": path})
        self.assertEqual(result.returncode, 2, self.output)
        self.assertEqual(self.requests, [])

    def test_sigterm_reports_interruption_and_cleans_workspace(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.pause_upload = True
        command = SHELL + [str(COLLECTOR), "--server", "127.0.0.1", "--port",
                           str(self.server.server_port), "--dir", str(self.samples),
                           "--no-log-file", "--no-progress", "--max-age", "0"]
        process = subprocess.Popen(command, cwd=self.root,
                                   env={**os.environ, "TMPDIR": str(self.root)},
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            self.assertTrue(self.upload_started.wait(timeout=10), "upload did not start")
            process.send_signal(signal.SIGTERM)
            self.release_upload.set()
            output, _ = process.communicate(timeout=15)
        finally:
            self.release_upload.set()
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
        self.assertEqual(process.returncode, 1, output)
        self.assertEqual([marker["type"] for marker in self.markers], ["begin", "interrupted"])
        self.assertEqual(list(self.root.glob("thunderstorm.*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
