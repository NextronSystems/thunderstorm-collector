#!/usr/bin/env python3
"""Exercise the Go 1.9.7 Linux binary; this is not a FreeBSD/appliance test."""
import email.parser
import email.policy
import http.server
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse

binary, config = map(lambda x: str(pathlib.Path(x).resolve()), sys.argv[1:])
requests = []
mode = "success"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path == "/api/status", self.path
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
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
        for mode, count, successes, errors in [("success", 1, 1, 0), ("recover", 2, 1, 0), ("busy", 4, 0, 1), ("reject", 1, 0, 1)]:
            requests.clear()
            run = subprocess.run(command, capture_output=True, text=True, timeout=15)
            assert run.returncode == 0, run.stdout + run.stderr
            assert len(requests) == count, (mode, requests, run.stdout)
            assert "Successfully uploaded: " + str(successes) in run.stdout, run.stdout
            assert "Read/transmission errors: " + str(errors) in run.stdout, run.stdout
            for path, parts in requests:
                target = urllib.parse.urlsplit(path)
                assert target.path == "/api/checkAsync"
                assert urllib.parse.parse_qs(target.query) == {"source": ["netscaler test & source"]}
                assert parts == [("file", str(sample), sample.read_bytes())], parts
            if mode == "busy":
                assert "canceling it after 3 retries" in run.stdout, run.stdout
            print("Go 1.9.7 Linux HTTP integration passed:", mode)
finally:
    server.shutdown()
    server.server_close()
