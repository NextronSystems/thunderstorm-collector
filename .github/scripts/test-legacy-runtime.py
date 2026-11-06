#!/usr/bin/env python3
"""Exercise the Go 1.9.7 Linux binary; this is not a FreeBSD/appliance test."""
import email.parser
import email.policy
import http.server
import json
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse

binary, config = map(lambda x: str(pathlib.Path(x).resolve()), sys.argv[1:])
requests = []
markers = []
mode = "success"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path == "/api/status", self.path
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        if self.path == "/api/collection":
            # Collection markers: THOR 10 and current THOR 11 answer 404; the
            # "markers" mode answers like a server that supports them.
            assert self.headers["Content-Type"] == "application/json", self.headers
            markers.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            code, body = (200, b'{"scan_id": "run-1"}') if mode == "markers" else (404, b"404 page not found")
            self.send_response(code)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # Go streams multipart bodies using chunked transfer encoding.
        assert self.headers.get("Transfer-Encoding") == "chunked"
        body = bytearray()
        while True:
            length = int(self.rfile.readline().strip(), 16)
            if not length:
                assert self.rfile.readline() == b"\r\n"
                break
            body.extend(self.rfile.read(length))
            assert self.rfile.read(2) == b"\r\n"
        message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
            ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + body
        )
        parts = list(message.iter_parts())
        requests.append((self.path, [(p.get_param("name", header="content-disposition"), p.get_filename(), p.get_payload(decode=True)) for p in parts]))
        code = 503 if mode == "busy" or (mode == "recover" and len(requests) == 1) else 400 if mode == "reject" else 200
        self.send_response(code)
        if code == 503:
            self.send_header("Retry-After", "0")
        self.end_headers()
        self.wfile.write(b"synthetic response")

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="netscaler-runtime-") as tmp:
        root = pathlib.Path(tmp)
        sample = root / "sample file.txt"
        sample.write_bytes(b"synthetic sample\x00\n")
        (root / "skip.bin").write_bytes(b"ignored")
        (root / "link.txt").symlink_to(sample)
        command = [binary, "--template", config, "--path", tmp, "--extension", ".txt", "--source", "netscaler test & source", "--thunderstorm-server", "127.0.0.1", "--port", str(server.server_port), "--debug"]
        dry = subprocess.run(command + ["--dry-run"], capture_output=True, text=True, timeout=15)
        assert dry.returncode == 0 and "Successfully would be sent (dry-run): 1" in dry.stdout, dry.stdout + dry.stderr
        assert not requests, "Dry run sent HTTP requests"
        assert not markers, "Dry run sent collection markers"
        for mode, count, successes, errors in [("success", 1, 1, 0), ("recover", 2, 1, 0), ("busy", 4, 0, 1), ("reject", 1, 0, 1), ("markers", 1, 1, 0)]:
            requests.clear()
            markers.clear()
            run = subprocess.run(command, capture_output=True, text=True, timeout=15)
            # A run in which an upload failed ends with status 1; a run without errors ends with 0.
            assert run.returncode == (1 if errors else 0), (mode, run.returncode, run.stdout + run.stderr)
            assert len(requests) == count, (mode, requests, run.stdout)
            assert "Successfully uploaded: " + str(successes) in run.stdout, run.stdout
            assert "Read/transmission errors: " + str(errors) in run.stdout, run.stdout
            for path, parts in requests:
                target = urllib.parse.urlsplit(path)
                assert target.path == "/api/checkAsync"
                expected_query = {"source": ["netscaler test & source"]}
                if mode == "markers":
                    expected_query["scan_id"] = ["run-1"]
                assert urllib.parse.parse_qs(target.query) == expected_query, target.query
                assert parts == [("file", str(sample), sample.read_bytes())], parts
            if mode == "busy":
                assert "canceling it after 3 retries" in run.stdout, run.stdout
            # A server without the marker endpoint gets one begin marker and
            # nothing else; one that supports it also gets the end marker.
            assert [m["type"] for m in markers] == (["begin", "end"] if mode == "markers" else ["begin"]), markers
            assert all(m["source"] == "netscaler test & source" and m["collector"] == "go" for m in markers), markers
            if mode == "markers":
                assert markers[1]["scan_id"] == "run-1" and markers[1]["stats"]["submitted"] == 1, markers
            print("Go 1.9.7 Linux HTTP integration passed:", mode)
finally:
    server.shutdown()
    server.server_close()
