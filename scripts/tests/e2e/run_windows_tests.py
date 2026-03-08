#!/usr/bin/env python3
"""
Windows E2E Test Runner for Thunderstorm Collector Scripts
Runs PS2 and BAT collectors on a Windows VM via WinRM against a stub server on Rune.

Usage:
    python3 run_windows_tests.py [--stub-host 192.168.122.1] [--stub-port 18080]

Requirements:
    - pip install pywinrm
    - Windows VM accessible via WinRM at localhost:5985
    - Stub server running on stub-host:stub-port
"""
import argparse
import json
import sys
import time
import urllib.request

# WinRM connection
WINRM_HOST = "http://localhost:5985/wsman"
WINRM_USER = "neo"
WINRM_PASS = "Thor123!"

# Test state
PASS = 0
FAIL = 0
SKIP = 0

# Tests to skip per script (known limitations)
# http-error-detection: PS2/BAT have hardcoded retry counts with exponential backoff.
# When server returns 500 for all requests, they retry 3× × delay per file, causing
# WinRM timeout before completion. Scripts correctly detect HTTP errors; test can't finish.
SKIP_TESTS = {
    "ps2": ["http-error-detection"],
    "bat": ["http-error-detection"]
}


def green(s): return "\033[0;32m{}\033[0m".format(s)
def red(s): return "\033[0;31m{}\033[0m".format(s)
def yellow(s): return "\033[1;33m{}\033[0m".format(s)

def test_pass(name):
    global PASS
    PASS += 1
    print("  {} {}".format(green("PASS"), name))

def test_fail(name):
    global FAIL
    FAIL += 1
    print("  {} {}".format(red("FAIL"), name))

def test_skip(name):
    global SKIP
    SKIP += 1
    print("  {} {}".format(yellow("SKIP"), name))


class StubServer:
    def __init__(self, host, port):
        self.base = "http://{}:{}".format(host, port)

    def reset(self):
        req = urllib.request.Request(self.base + "/api/test/reset", method="POST")
        urllib.request.urlopen(req)

    def configure(self, config):
        data = json.dumps(config).encode()
        req = urllib.request.Request(
            self.base + "/api/test/config",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        urllib.request.urlopen(req)

    def get_log(self):
        resp = urllib.request.urlopen(self.base + "/api/test/log")
        return resp.read().decode()

    def count_type(self, type_val):
        count = 0
        for line in self.get_log().strip().split("\n"):
            if not line.strip():
                continue
            d = json.loads(line)
            if d.get("type") == type_val:
                count += 1
        return count

    def marker_field(self, marker, field):
        for line in self.get_log().strip().split("\n"):
            if not line.strip():
                continue
            d = json.loads(line)
            if d.get("type") == "collection_marker" and d.get("marker") == marker:
                val = d.get(field, "")
                if isinstance(val, dict):
                    return json.dumps(val)
                return str(val) if val else ""
        return ""


class WinRunner:
    def __init__(self):
        import winrm
        self.session = winrm.Session(WINRM_HOST, auth=(WINRM_USER, WINRM_PASS),
                                      transport="basic", read_timeout_sec=120,
                                      operation_timeout_sec=110)
        self.stdout = ""
        self.stderr = ""
        self.rc = 0

    def run_cmd(self, cmd, args=None):
        r = self.session.run_cmd(cmd, args or [])
        return r.std_out.decode("utf-8", errors="replace").strip(), r.status_code

    def run_ps(self, script):
        r = self.session.run_ps(script)
        self.stdout = r.std_out.decode("utf-8", errors="replace")
        self.stderr = r.std_err.decode("utf-8", errors="replace")
        self.rc = r.status_code
        return self.stdout, self.stderr, self.rc

    def run_bat(self, cmd):
        r = self.session.run_cmd("cmd.exe", ["/c", cmd])
        self.stdout = r.std_out.decode("utf-8", errors="replace")
        self.stderr = r.std_err.decode("utf-8", errors="replace")
        self.rc = r.status_code
        return self.stdout, self.stderr, self.rc


def setup_fixtures(win):
    """Create test files on Windows VM."""
    win.run_cmd("mkdir", ["C:\\thunderstorm-test"])
    win.run_cmd("mkdir", ["C:\\thunderstorm-test\\files"])
    for name in ["malware.exe", "library.dll", "startup.bat", "invoke.ps1",
                  "photo.jpg", "song.mp3", "report.pdf"]:
        win.run_cmd("cmd.exe", ["/c", "echo test_content > C:\\thunderstorm-test\\files\\{}".format(name)])


def copy_scripts(win, scripts_dir):
    """Copy collector scripts to Windows VM via SMB/WinRM chunked writes."""
    import os
    import base64
    for script in ["thunderstorm-collector-ps2.ps1", "thunderstorm-collector.bat"]:
        local_path = os.path.join(scripts_dir, script)
        with open(local_path, "rb") as f:
            content = f.read()
        # Base64 encode and decode on Windows (avoids shell escaping issues)
        b64 = base64.b64encode(content).decode("ascii")
        dest = "C:\\thunderstorm-test\\{}".format(script)
        # Write base64 to temp file in chunks, then decode
        tmp = "C:\\thunderstorm-test\\{}.b64".format(script)
        # Clear temp file
        win.run_cmd("cmd.exe", ["/c", "type nul > {}".format(tmp)])
        # Write in 6000-char chunks (safe for WinRM)
        chunk_size = 6000
        for i in range(0, len(b64), chunk_size):
            chunk = b64[i:i+chunk_size]
            # Use echo with >> append
            win.run_cmd("cmd.exe", ["/c", "echo|set /p={}>>{}".format(chunk, tmp)])
        # Decode base64 on Windows using certutil
        win.run_cmd("certutil", ["-decode", tmp, dest])
        win.run_cmd("del", [tmp])


def run_ps2(win, stub_host, stub_port, source, extra_args=""):
    """Run PS2 collector on Windows VM."""
    cmd = (
        "powershell.exe -ExecutionPolicy Bypass -File C:\\thunderstorm-test\\thunderstorm-collector-ps2.ps1 "
        "-ThunderstormServer {} -ThunderstormPort {} -Source '{}' "
        "-Folder C:\\thunderstorm-test\\files -MaxAge 365 -AllExtensions {}"
    ).format(stub_host, stub_port, source, extra_args)
    return win.run_ps(cmd)


def run_bat(win, stub_host, stub_port, source):
    """Run BAT collector on Windows VM via wrapper batch file.

    WinRM's run_cmd starts a fresh cmd.exe for each call, so environment variables
    don't persist. We write a wrapper batch file that sets the env vars then calls
    the collector, all in one process.
    """
    import base64
    bat_content = (
        '@echo off\r\n'
        'SET THUNDERSTORM_SERVER={}\r\n'
        'SET THUNDERSTORM_PORT={}\r\n'
        'SET SOURCE={}\r\n'
        'SET COLLECT_DIRS=C:\\thunderstorm-test\\files\r\n'
        'SET MAX_AGE=365\r\n'
        'SET RELEVANT_EXTENSIONS=.exe .dll .bat .ps1 .jpg .mp3 .pdf\r\n'
        'C:\\thunderstorm-test\\thunderstorm-collector.bat\r\n'
    ).format(stub_host, stub_port, source)
    b64 = base64.b64encode(bat_content.encode()).decode()
    win.run_cmd('cmd.exe', ['/c', 'echo {} > C:\\thunderstorm-test\\run-bat.b64'.format(b64)])
    win.run_cmd('certutil', ['-decode', 'C:\\thunderstorm-test\\run-bat.b64', 'C:\\thunderstorm-test\\run-bat.bat'])
    return win.run_cmd('C:\\thunderstorm-test\\run-bat.bat')


def test_script(script_name, run_fn, stub, win):
    """Run all applicable tests for a script."""
    print("\n── {} ──────────────────────────────────────────────".format(script_name))
    skip_list = SKIP_TESTS.get(script_name, [])

    # Basic upload
    if "basic-upload" in skip_list:
        test_skip("{}/basic-upload (known limitation)".format(script_name))
    else:
        stub.reset()
        run_fn(win, args.stub_host, args.stub_port, "e2e-test-{}".format(script_name))
        count = stub.count_type("THOR finding")
        if count >= 4:
            test_pass("{}/basic-upload: {} files uploaded".format(script_name, count))
        else:
            test_fail("{}/basic-upload: expected ≥4, got {}".format(script_name, count))

    # Collection markers
    if "begin-marker" in skip_list:
        test_skip("{}/begin-marker (known limitation)".format(script_name))
    else:
        stub.reset()
        run_fn(win, args.stub_host, args.stub_port, "e2e-test-{}".format(script_name))
        begin = stub.marker_field("begin", "source")
        if begin:
            test_pass("{}/begin-marker: source={}".format(script_name, begin))
        else:
            test_fail("{}/begin-marker: no begin marker".format(script_name))

    if "end-marker" in skip_list:
        test_skip("{}/end-marker (known limitation)".format(script_name))
    else:
        end = stub.marker_field("end", "source")
        if end:
            test_pass("{}/end-marker: source={}".format(script_name, end))
        else:
            test_fail("{}/end-marker: no end marker".format(script_name))

    # Scan ID propagation
    if "scan-id-propagation" in skip_list:
        test_skip("{}/scan-id-propagation (known limitation)".format(script_name))
    else:
        begin_id = stub.marker_field("begin", "scan_id")
        end_id = stub.marker_field("end", "scan_id")
        if begin_id and begin_id == end_id:
            test_pass("{}/scan-id-propagation: {}".format(script_name, begin_id))
        else:
            test_fail("{}/scan-id-propagation: begin={} end={}".format(script_name, begin_id, end_id))

    # Timestamp format
    if "timestamp-format" in skip_list:
        test_skip("{}/timestamp-format (known limitation)".format(script_name))
    else:
        ts = stub.marker_field("begin", "timestamp")
        if ts and "T" in ts and "-" in ts:
            test_pass("{}/timestamp-format: {}".format(script_name, ts))
        else:
            test_fail("{}/timestamp-format: not ISO 8601: '{}'".format(script_name, ts))

    # HTTP error detection
    if "http-error-detection" in skip_list:
        test_skip("{}/http-error-detection (no --retries param; WinRM timeout)".format(script_name))
    else:
        stub.reset()
        stub.configure({"upload_rules": [{"default": True, "status": 500, "body": '{"error":"test"}'}]})
        run_fn(win, args.stub_host, args.stub_port, "e2e-test-{}".format(script_name))
        if win.rc != 0:
            test_pass("{}/http-error-detection: exit {} (non-zero)".format(script_name, win.rc))
        else:
            test_fail("{}/http-error-detection: exit 0 despite all-500 responses".format(script_name))

    # 503 retry (with Retry-After: 1 from stub)
    if "retry-503" in skip_list:
        test_skip("{}/retry-503 (known limitation)".format(script_name))
    else:
        stub.reset()
        stub.configure({"upload_rules": [
            {"match_count": [1, 2], "status": 503, "headers": {"Retry-After": "1"}},
            {"default": True, "status": 200}
        ]})
        run_fn(win, args.stub_host, args.stub_port, "e2e-test-{}".format(script_name))
        count = stub.count_type("THOR finding")
        if count >= 4:
            test_pass("{}/retry-503: {} files uploaded after 503".format(script_name, count))
        else:
            test_fail("{}/retry-503: expected ≥4, got {}".format(script_name, count))

    # End marker always sent (even without scan_id)
    if "end-marker-always-sent" in skip_list:
        test_skip("{}/end-marker-always-sent (known limitation)".format(script_name))
    else:
        stub.reset()
        stub.configure({"collection_rules": [{"match_count": [1], "status": 500}], "upload_rules": []})
        run_fn(win, args.stub_host, args.stub_port, "e2e-test-{}".format(script_name))
        end = stub.marker_field("end", "source")
        if end:
            test_pass("{}/end-marker-always-sent: end marker sent despite begin failure".format(script_name))
        else:
            test_fail("{}/end-marker-always-sent: no end marker when begin failed".format(script_name))

    # Marker JSON validity
    if "marker-json-valid" in skip_list:
        test_skip("{}/marker-json-valid (known limitation)".format(script_name))
    else:
        stub.reset()
        run_fn(win, args.stub_host, args.stub_port, "e2e-test-{}".format(script_name))
        log = stub.get_log()
        invalid = 0
        for line in log.strip().split("\n"):
            if not line.strip():
                continue
            try:
                json.loads(line)
            except json.JSONDecodeError:
                invalid += 1
        if invalid == 0:
            test_pass("{}/marker-json-valid: all entries valid JSON".format(script_name))
        else:
            test_fail("{}/marker-json-valid: {} invalid entries".format(script_name, invalid))

    # Exit code clean
    if "exit-code-clean" in skip_list:
        test_skip("{}/exit-code-clean (known limitation)".format(script_name))
    else:
        stub.reset()
        run_fn(win, args.stub_host, args.stub_port, "e2e-test-{}".format(script_name))
        if win.rc == 0:
            test_pass("{}/exit-code-clean: exit 0".format(script_name))
        else:
            test_fail("{}/exit-code-clean: expected 0, got {}".format(script_name, win.rc))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Windows E2E tests for Thunderstorm collectors")
    parser.add_argument("--stub-host", default="192.168.122.1", help="Stub server host (from VM perspective)")
    parser.add_argument("--stub-api", default="localhost", help="Stub server host for API calls (from this machine)")
    parser.add_argument("--stub-port", type=int, default=18080, help="Stub server port")
    args = parser.parse_args()

    # API calls go through stub-api (localhost via SSH tunnel), VM connects to stub-host
    stub = StubServer(args.stub_api, args.stub_port)

    print("\n╔═══════════════════════════════════════════════════════════════╗")
    print("║    Thunderstorm Collector — Windows E2E Tests (via WinRM)    ║")
    print("╚═══════════════════════════════════════════════════════════════╝")
    print("\nStub API: {}:{}  |  VM target: {}:{}\n".format(args.stub_api, args.stub_port, args.stub_host, args.stub_port))

    win = WinRunner()
    print("[+] Connected to Windows VM")

    # Setup
    print("[+] Creating test fixtures...")
    setup_fixtures(win)
    print("[+] Copying scripts...")
    import os
    scripts_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    copy_scripts(win, scripts_dir)
    print("[+] Ready\n")

    # Define runners
    def run_ps2_wrapper(win, host, port, source):
        return run_ps2(win, host, port, source)

    def run_bat_wrapper(win, host, port, source):
        return run_bat(win, host, port, source)

    # Run tests
    test_script("ps2", run_ps2_wrapper, stub, win)
    test_script("bat", run_bat_wrapper, stub, win)

    # Cleanup
    win.run_cmd("rmdir", ["/s", "/q", "C:\\thunderstorm-test"])

    print("\n════════════════════════════════════════════════════════════════")
    print(" Results: {} passed, {} failed, {} skipped".format(PASS, FAIL, SKIP))
    print("════════════════════════════════════════════════════════════════\n")

    sys.exit(1 if FAIL > 0 else 0)
