#!/usr/bin/env python3
"""Bash-specific regressions using synthetic files and a loopback HTTP server."""

import email.policy
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit
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
        self.marker_response = b'{}'
        self.upload_response = b'{}'
        self.redirect = False
        self.markers = []
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
                    response = test.marker_response
                    status = test.end_status if marker["type"] == "end" else test.marker_status
                else:
                    response = test.upload_response
                    status = test.upload_statuses.pop(0) if test.upload_statuses else 200
                    if 200 <= status < 300:
                        headers = ("Content-Type: " + self.headers["Content-Type"] +
                                   "\r\nMIME-Version: 1.0\r\n\r\n").encode()
                        message = BytesParser(policy=email.policy.default).parsebytes(headers + data)
                        test.uploads.extend((part.get_filename(), part.get_payload(decode=True))
                                            for part in message.iter_parts())
                self.send_response(status)
                if test.redirect:
                    self.send_header("Location", "/unapproved-sink")
                if test.diagnostic_header:
                    self.send_header("X-Diagnostic", "HTTP/1.1 200 OK")
                if status == 503:
                    self.send_header("Retry-After", test.retry_after)
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                try:
                    self.wfile.write(response)
                except (BrokenPipeError, ConnectionResetError):
                    pass

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

    def test_newline_root_does_not_scan_its_sibling(self):
        selected = self.root / "selected\n"
        selected.mkdir()
        sibling = self.root / "selected"
        sibling.mkdir()
        (selected / "approved.txt").write_bytes(b"approved")
        (sibling / "outside.txt").write_bytes(b"outside")
        result = self.run_collector(roots=[selected])
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"approved"])

    def test_physical_newline_paths_exclude_internal_files_and_log(self):
        selected = self.root / "selected\n"
        selected.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(selected, target_is_directory=True)
        (selected / "approved.txt").write_bytes(b"approved")
        result = self.run_collector(roots=[alias], log_file=alias / "log\n",
                                    env={"TMPDIR": str(alias), "CDPATH": str(self.root)})
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_payloads([b"approved"])

    def test_only_complete_object_string_marker_ids_are_used(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        invalid = [b'{"metadata":{"scan_id":"nested"}}',
                   b'[{"scan_id":"array"}]', b'{"scan_id":123}',
                   b'{"scan_id":"unterminated}', b'{"scan_id":"ok"}garbage',
                   b'{"scan_id":"one","scan_id":"two"}',
                   b'{"scan_id":"bad\\q"}', b'{"scan_id":"bad\\u0000"}',
                   b'{"scan_id":"bad\\ud800"}', b'{"scan_id":null}',
                   b'{"scan_id":"bad\xff"}', b'{"scan_id":"bad\xc0\x80"}',
                   b'{"scan_id":"bad\x00suffix"}']
        for body in invalid:
            with self.subTest(body=body):
                self.marker_response = body
                self.requests.clear()
                result = self.run_collector()
                self.assertEqual(result.returncode, 0, self.output)
                self.assertFalse(any("scan_id=" in p for p in self.requests), self.requests)

    def test_marker_json_parsing_has_a_separate_size_budget(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        prefix = b'{"scan_id":"bounded-id","metadata":"'
        suffix = b'"}'
        for size in (65536, 65537, 1048576):
            with self.subTest(size=size):
                self.requests = []
                self.marker_response = prefix + b'x' * (size - len(prefix) - len(suffix)) + suffix
                result = self.run_collector()
                self.assertEqual(result.returncode, 0, self.output)
                uploads = [path for path in self.requests if path.startswith("/api/check")]
                self.assertEqual(len(uploads), 1)
                self.assertEqual("scan_id=" in uploads[0], size == 65536)
                if size > 65536:
                    self.assertIn("Ignoring invalid or oversized collection marker JSON", self.output)

    def test_marker_unicode_escapes_are_preserved(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        scan_id = 'scan-\u00e4-\U0001f600-"-\\'
        self.marker_response = json.dumps({"scan_id": scan_id, "metadata": [True, None, 1.2]}).encode()
        result = self.run_collector()
        self.assertEqual(result.returncode, 0, self.output)
        query = next(p for p in self.requests if p.startswith("/api/check"))
        self.assertEqual(parse_qs(urlsplit(query).query)["scan_id"], [scan_id])
        self.assertEqual(self.markers[-1]["scan_id"], scan_id)

    def test_unsupported_marker_body_never_supplies_scan_id(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        self.marker_response = b'{"scan_id":"untrusted-error-id"}'
        for status in [404, 501]:
            with self.subTest(status=status):
                self.marker_status = self.end_status = status
                self.requests.clear()
                result = self.run_collector()
                self.assertEqual(result.returncode, 0, self.output)
                self.assertFalse(any("scan_id=" in p for p in self.requests), self.requests)

    def test_curlrc_cannot_enable_redirects(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        (self.root / ".curlrc").write_text("location\n")
        self.redirect = True
        self.upload_statuses = [307]
        result = self.run_collector(env={"CURL_HOME": str(self.root)})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertNotIn("/unapproved-sink", self.requests)

    @unittest.skipUnless(shutil.which("openssl"), "openssl required for local TLS fixture")
    def test_curlrc_cannot_disable_tls_verification(self):
        key, cert = self.root / "key.pem", self.root / "cert.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(cert), "-days", "1",
                        "-subj", "/CN=localhost"], check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        (self.root / ".curlrc").write_text("insecure\n")
        result = self.run_collector("--ssl", env={"CURL_HOME": str(self.root)})
        self.assertEqual(result.returncode, 2, self.output)
        self.assertEqual(self.requests, [])

    def test_large_responses_are_rejected_for_curl_and_wget(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        transports = [("curl", {})]
        if shutil.which("wget"):
            path = self.tool_path()
            (Path(path) / "wget").symlink_to(shutil.which("wget"))
            transports.append(("wget", {"PATH": path}))
        for name, env in transports:
            for size, status in [(1048576, 200), (1048577, 200), (4 * 1048576, 500)]:
                with self.subTest(transport=name, size=size, status=status):
                    self.upload_response = b"x" * size
                    self.upload_statuses = [status]
                    result = self.run_collector(env=env)
                    self.assertEqual(result.returncode, 0 if size == 1048576 else 1, self.output)
                    if size > 1048576:
                        self.assertIn("submitted=0", self.output)
                    self.assertLess(len(self.output), 20000)
            self.marker_response = b"x" * 1048577
            result = self.run_collector(env=env)
            self.assertEqual(result.returncode, 2, self.output)
            self.marker_response = b'{}'

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

    def test_http_date_retry_after_uses_bounded_fallback_for_both_transports(self):
        (self.samples / "real.txt").write_bytes(b"readable")
        sleeps = self.root / "sleeps"
        path = Path(self.tool_path(sleep='#!/bin/sh\nprintf "%s\\n" "$1" >> "$SLEEPS"\n'))
        transports = ["curl"] + (["wget"] if shutil.which("wget") else [])
        for transport in transports:
            with self.subTest(transport=transport):
                for name in ("curl", "wget"):
                    if (path / name).is_symlink():
                        (path / name).unlink()
                (path / transport).symlink_to(shutil.which(transport))
                sleeps.write_text("")
                self.upload_statuses = [503, 200]
                self.retry_after = "Wed, 21 Oct 2026 07:28:00 GMT"
                result = self.run_collector(env={"PATH": str(path), "SLEEPS": str(sleeps)})
                self.assertEqual(result.returncode, 0, self.output)
                self.assertIn("2", sleeps.read_text().splitlines())
                self.assertNotIn("120", sleeps.read_text().splitlines())

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
printf 'HTTP/1.1 %s Status\\r\\n\\r\\n' "${HTTP_STATUS:-200}" > "$header"
[ -z "$output" ] || printf '{}' > "$output"
exit "${CURL_EXIT:-18}"
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

    def test_404_begin_with_curl_transport_error_is_fatal(self):
        result = self.run_collector(env={"PATH": self.partial_curl_path(),
                                         "FAIL_MARKER": "1", "HTTP_STATUS": "404", "CURL_EXIT": "8"})
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


class BashHelperTests(unittest.TestCase):
    def function(self, name, path=COLLECTOR):
        source = path.read_text()
        match = re.search(r"^" + re.escape(name) + r"\(\) \{.*?^\}", source, re.M | re.S)
        self.assertIsNotNone(match, name)
        return match.group(0)

    def test_mount_escapes_are_decoded_and_pruned_as_literal_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            mount = root / "team [a]*?\\040\tshare\n"
            mount.mkdir()
            (mount / "excluded").write_text("secret")
            (root / "keep").write_text("approved")
            encoded = str(mount).replace("\\", "\\134").replace(" ", "\\040").replace("\t", "\\011").replace("\n", "\\012")
            table = root / "mounts"
            table.write_text("server " + encoded + " nfs rw 0 0\n")
            body = "NETWORK_FS_TYPES=nfs\nSPECIAL_FS_TYPES=proc\n"
            body += self.function("get_excluded_mounts") + "\n" + self.function("escape_find_path")
            body += '\nwhile IFS= read -r -d "" path; do\n'
            body += 'pattern="$(escape_find_path "$path"; printf .)"\n'
            body += 'printf "%s\\0" "$path"\n'
            body += 'find "$2" -path "${pattern%.}" -prune -o -type f -print0\n'
            body += 'done < <(get_excluded_mounts "$1")\n'
            result = subprocess.run([BASH, "-c", body, "test", str(table), str(root)], capture_output=True, check=True)
            records = result.stdout.split(b"\0")
            self.assertEqual(records[0], os.fsencode(mount))
            self.assertNotIn(os.fsencode(mount / "excluded"), records)
            self.assertIn(os.fsencode(root / "keep"), records)

    def test_retry_after_requires_integer_seconds(self):
        with tempfile.TemporaryDirectory() as directory:
            header = Path(directory) / "headers"
            for value, expected in [("0", "0"), ("0003", "3"), ("121", "120"),
                                    ("9" * 100, "120"), ("-1", "2"), ("1foo2", "2"),
                                    ("", "2"), ("Wed, 21 Oct 2026 07:28:00 GMT", "2")]:
                with self.subTest(value=value):
                    header.write_text("HTTP/1.1 503 Busy\r\n  Retry-After: " + value + "\r\n")
                    result = subprocess.run([BASH, "-c", self.function("retry_after_seconds") + '\nretry_after_seconds "$1"',
                                             "test", str(header)], capture_output=True, text=True, check=True)
                    self.assertEqual(result.stdout.strip(), expected)

    def test_default_roots_are_platform_specific_and_existing(self):
        for platform, candidates in [("Darwin", ["/Users", "/tmp", "/var", "/usr"]),
                                     ("Linux", ["/root", "/tmp", "/home", "/var", "/usr"])]:
            with self.subTest(platform=platform):
                body = 'uname() { printf "%s\\n" ' + shlex.quote(platform) + '; }\n'
                body += self.function("default_scan_folders")
                body += '\ndefault_scan_folders\nprintf "%s\\0" "${SCAN_FOLDERS[@]}"\n'
                result = subprocess.run([BASH, "-c", body], capture_output=True, check=True)
                self.assertEqual(result.stdout.split(b"\0")[:-1],
                                 [os.fsencode(path) for path in candidates if os.path.isdir(path)])

    def test_readiness_rechecks_child_after_response(self):
        harness = Path(__file__).with_name("run_tests.sh")
        with tempfile.TemporaryDirectory() as directory:
            body = 'WORK_DIR=' + shlex.quote(directory) + '\n'
            body += 'USE_EXTERNAL=0\nUPLOADS_DIR="$WORK_DIR/uploads"\nAUDIT_LOG="$WORK_DIR/audit"\n'
            body += 'STUB_LOG="$WORK_DIR/stub"\nSTUB_BIN=/usr/bin/false\n'
            body += 'pick_port() { echo 19993; }\nsleep() { :; }\n'
            body += 'kill() { [ ! -e "$WORK_DIR/probed" ]; }\n'
            body += 'curl() { wait "$STUB_PID" || :; touch "$WORK_DIR/probed"; }\n'
            body += self.function("start_stub", harness) + '\nstart_stub\n'
            result = subprocess.run([BASH, "-c", body], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("Stub server did not start", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
