#!/usr/bin/env python3
"""Bash-specific regressions using synthetic files and a loopback HTTP server."""

import email.policy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


COLLECTOR = Path(os.environ.get("BASH_COLLECTOR", Path(__file__).resolve().parents[1] /
                               "bash/thunderstorm-collector.sh"))
BASH = os.environ.get("COLLECTOR_BASH", shutil.which("bash"))


class BashRobustnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bash-robustness-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.samples = self.root / "samples"
        self.samples.mkdir()
        self.requests = []
        self.uploads = []
        self.upload_statuses = []
        self.marker_status = 200
        self.end_status = 200
        self.retry_after = "0"
        self.diagnostic_header = False
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
                    status = test.end_status if marker["type"] == "end" else test.marker_status
                else:
                    status = test.upload_statuses.pop(0) if test.upload_statuses else 200
                    if 200 <= status < 300:
                        headers = ("Content-Type: " + self.headers["Content-Type"] +
                                   "\r\nMIME-Version: 1.0\r\n\r\n").encode()
                        message = BytesParser(policy=email.policy.default).parsebytes(headers + data)
                        test.uploads.extend((part.get_filename(), part.get_payload(decode=True))
                                            for part in message.iter_parts())
                self.send_response(status)
                if test.diagnostic_header:
                    self.send_header("X-Diagnostic", "HTTP/1.1 200 OK")
                if status == 503:
                    self.send_header("Retry-After", test.retry_after)
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.stop_server, thread)

    def stop_server(self, thread):
        self.server.shutdown()
        self.server.server_close()
        thread.join(timeout=5)

    def run_collector(self, *args, env=None, roots=None, log_file=None):
        command = [BASH, str(COLLECTOR), "--server", "127.0.0.1", "--port",
                   str(self.server.server_port), "--no-progress",
                   "--max-age", "0", "--retries", "1"]
        command.extend(["--log-file", str(log_file)] if log_file else ["--no-log-file"])
        for root in roots or [self.samples]:
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
                     "hostname", "id", "mktemp", "od", "rm", "sed", "sleep", "stat",
                     "tail", "tr", "uname", "wc"):
            path = shutil.which(name)
            if path:
                (tools / name).symlink_to(path)
        for name, script in replacements.items():
            path = tools / name
            if path.is_symlink():
                path.unlink()
            path.write_text(script)
            path.chmod(0o755)
        return str(tools)

    def assert_payloads(self, expected):
        self.assertCountEqual(expected, [payload for _, payload in self.uploads], self.output)

    def test_special_filenames_preserve_every_payload(self):
        names = ["ordinary.txt", "semi;colon.txt", "comma,name.txt", 'double"quote.txt',
                 "back\\slash.txt", "line\nbreak.txt", "-leading.txt"]
        for name in names:
            (self.samples / name).write_bytes(("payload:" + name).encode())
        result = self.run_collector()
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([("payload:" + name).encode() for name in names])

    def test_internal_files_and_log_are_not_uploaded(self):
        samples = self.root / "self [scan]"
        samples.mkdir()
        (samples / "real.txt").write_bytes(b"real payload")
        log = samples / "collector [log].txt"
        result = self.run_collector(roots=[samples], log_file=log, env={"TMPDIR": str(samples)})
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"real payload"])
        self.assertTrue(log.is_file())
        self.assertEqual(sorted(p.name for p in samples.iterdir()), [log.name, "real.txt"])

    def test_dry_run_needs_no_network_tool(self):
        (self.samples / "real.txt").write_bytes(b"local")
        result = self.run_collector("--dry-run", env={"PATH": self.tool_path()})
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn("DRY-RUN: would submit", self.output)
        self.assertEqual(self.requests, [])

    def test_missing_root_is_partial_failure_not_success(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        result = self.run_collector(roots=[self.samples, self.root / "missing"])
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("scan_errors=1", self.output)
        self.assert_payloads([b"readable"])

    def test_all_roots_missing_is_failure_even_in_dry_run(self):
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
        path = self.tool_path(find='#!/bin/sh\nprintf "%s\\0" "$SAMPLE"\necho "fixture error" >&2\nexit 1\n')
        (Path(path) / "curl").symlink_to(shutil.which("curl"))
        result = self.run_collector(env={"PATH": path, "SAMPLE": str(sample)})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("Incomplete scan", self.output)
        self.assert_payloads([b"readable"])

    def test_symlink_targets_are_not_uploaded(self):
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

    def test_503_does_not_consume_normal_retry_budget(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.upload_statuses = [503, 200]
        result = self.run_collector()
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"readable"])
        self.assertEqual(sum("/api/check" in path for path in self.requests), 2)

    def test_permanent_503_is_bounded(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.upload_statuses = [503] * 10
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertEqual(sum("/api/check" in path for path in self.requests), 5)
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

    def test_header_value_cannot_override_error_status(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.upload_statuses = [500]
        self.diagnostic_header = True
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("HTTP 500", self.output)
        self.assertIn("submitted=0", self.output)

    def test_optional_marker_endpoint(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.marker_status = self.end_status = 404
        result = self.run_collector()
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn("not supported (HTTP 404)", self.output)
        self.assert_payloads([b"readable"])

    def test_failed_end_marker_reports_partial_failure(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.end_status = 500
        result = self.run_collector()
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("end marker failed", self.output)
        self.assert_payloads([b"readable"])

    def test_temp_failure_does_not_delete_preexisting_pid_directory(self):
        foreign = self.root / "thunderstorm.foreign"
        foreign.mkdir()
        (foreign / "keep.txt").write_bytes(b"keep")
        path = self.tool_path(mktemp='#!/bin/sh\nexit 1\n')
        wrapper = 'mv "$TMPDIR/thunderstorm.foreign" "$TMPDIR/thunderstorm.$$"; exec "$@"'
        command = [BASH, "-c", wrapper, "fixture", BASH, str(COLLECTOR), "--dry-run",
                   "--no-log-file", "--dir", str(self.samples)]
        result = subprocess.run(command, env={**os.environ, "TMPDIR": str(self.root),
                                             "PATH": path + os.pathsep + os.environ["PATH"]},
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(len(list(self.root.glob("thunderstorm.*/keep.txt"))), 1)

    def test_double_dash_keeps_remaining_directories(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        (self.root / "empty").mkdir()
        result = self.run_collector("--", str(self.samples), roots=[self.root / "empty"])
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"readable"])

    def partial_curl_path(self):
        return self.tool_path(curl='''#!/bin/sh
header=""; output=""; endpoint=""; previous=""
for arg do
    case "$previous" in -D) header="$arg" ;; -o) output="$arg" ;; esac
    case "$arg" in http://*|https://*) endpoint="$arg" ;; esac
    previous="$arg"
done
case "$endpoint" in
    */api/collection)
        [ "$FAIL_MARKER" = 1 ] || exec "$CURL_REAL" "$@"
        ;;
esac
printf 'HTTP/1.1 200 OK\\r\\n\\r\\n' > "$header"
[ -z "$output" ] || printf '{}' > "$output"
exit 18
''')

    def test_2xx_upload_with_failed_transport_is_not_success(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        result = self.run_collector(env={"PATH": self.partial_curl_path(),
                                         "CURL_REAL": shutil.which("curl"), "FAIL_MARKER": "0"})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("submitted=0", self.output)
        self.assertIn("failed=1", self.output)

    def test_2xx_begin_marker_with_failed_transport_is_fatal(self):
        result = self.run_collector(env={"PATH": self.partial_curl_path(),
                                         "CURL_REAL": shutil.which("curl"), "FAIL_MARKER": "1"})
        self.assertEqual(result.returncode, 2, self.output)
        self.assertIn("begin marker failed after retry", self.output)

    @unittest.skipUnless(shutil.which("wget"), "GNU wget is required for fallback test")
    def test_wget_preserves_special_filename_payloads(self):
        path = self.tool_path()
        (Path(path) / "wget").symlink_to(shutil.which("wget"))
        for name in ['semi;colon.txt', 'comma,name.txt', 'double"quote.txt', 'binary']:
            (self.samples / name).write_bytes(b"\x00\xff" + name.encode())
        result = self.run_collector(env={"PATH": path})
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([p.read_bytes() for p in self.samples.iterdir()])

    @unittest.skipUnless(shutil.which("wget"), "GNU wget is required for fallback test")
    def test_failed_wget_body_copy_cannot_upload_truncated_sample(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        path = self.tool_path(cat='#!/bin/sh\nexit 1\n')
        (Path(path) / "wget").symlink_to(shutil.which("wget"))
        result = self.run_collector(env={"PATH": path})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertEqual(sum("/api/check" in p for p in self.requests), 0)
        self.assertIn("failed=1", self.output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
