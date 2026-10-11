#!/usr/bin/env python3
"""Negative controls for the large-file helper; no network or Perl required."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX harness")
class LargeFileHarnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="perl helper '")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.state = self.root / "state.json"
        self.helper = Path(__file__).with_name("test_perl_large.sh")
        self.stub = self.tool("stub", '''
import json, os, sys, time
args = sys.argv[1:]
log = args[args.index("-log-file") + 1]
with open(log, "w") as stream:
    stream.write(json.dumps({"subject": {"client_filename": "big-perl.tmp", "source": "old-run"}}) + "\\n")
with open(os.environ["HARNESS_STATE"], "w") as stream:
    json.dump({"pid": os.getpid(), "log": log}, stream)
if os.environ.get("FAIL_STUB"):
    sys.exit(1)
while True:
    time.sleep(1)
''')
        self.tool("curl", '''
import os, sys
sys.exit(0 if os.path.exists(os.environ["HARNESS_STATE"]) else 1)
''')
        self.tool("perl", '''
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
mode = os.environ.get("FAKE_COLLECTOR", "good")
with open(os.environ["HARNESS_STATE"]) as stream:
    log = json.load(stream)["log"]
fixture = next(pathlib.Path(args[args.index("--dir") + 1]).iterdir())
payload = fixture.read_bytes()
source = args[args.index("--source") + 1]
subject = {"client_filename": fixture.name, "source": source, "size": len(payload),
           "hashes": {"sha256": hashlib.sha256(payload).hexdigest()}}
if mode == "bad-hash": subject["hashes"]["sha256"] = "wrong"
if mode == "bad-size": subject["size"] = 0
if mode == "old-source": subject["source"] = "old-run"
if mode != "no-upload":
    with open(log, "a") as stream:
        stream.write(json.dumps({"subject": subject}) + "\\n")
sys.exit(7 if mode == "fail-with-upload" else 0)
''')

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def run_helper(self, **extra):
        env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                   TMPDIR=str(self.root), STUB_BIN_PATH=str(self.stub), STUB_PORT="19993",
                   HARNESS_STATE=str(self.state))
        env.pop("STUB_LOG", None)
        env.update(extra)
        result = subprocess.run(["bash", str(self.helper)], env=env, capture_output=True, text=True, timeout=15)
        if self.state.exists():
            state = json.loads(self.state.read_text())
            self.assertFalse(Path(state["log"]).parent.exists(), "owned fixture directory leaked")
            with self.assertRaises(ProcessLookupError, msg="owned stub process leaked"):
                os.kill(state["pid"], 0)
        return result

    def test_current_matching_payload_passes_and_cleans_up(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("exact expected size and SHA-256", result.stdout)

    def test_collector_failure_is_not_hidden_by_tail_even_with_an_upload(self):
        result = self.run_helper(FAKE_COLLECTOR="fail-with-upload")
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertNotIn("PASS:", result.stdout)

    def test_stale_records_cannot_replace_a_new_upload(self):
        result = self.run_helper(FAKE_COLLECTOR="no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected exactly one upload", result.stderr)

    def test_hash_size_and_source_must_match(self):
        for mode in ("bad-hash", "bad-size", "old-source"):
            with self.subTest(mode=mode):
                result = self.run_helper(FAKE_COLLECTOR=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("PASS:", result.stdout)

    def test_dead_stub_is_not_replaced_with_an_unrelated_listener(self):
        result = self.run_helper(FAIL_STUB="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owned stub failed", result.stderr)
        self.assertNotIn("Running Perl collector", result.stdout)

    def test_existing_audit_is_refused_without_changing_it(self):
        old = self.root / "old.jsonl"
        old.write_text("keep-existing-audit\n")
        result = self.run_helper(STUB_LOG=str(old))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(old.read_text(), "keep-existing-audit\n")
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
