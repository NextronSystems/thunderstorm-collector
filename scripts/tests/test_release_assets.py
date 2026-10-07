#!/usr/bin/env python3
"""Verify release packaging in an isolated fixture, without building Go binaries."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MAKEFILE = Path(__file__).resolve().parents[2] / "Makefile"
SCRIPTS = (
    "bash/thunderstorm-collector.sh",
    "ash/thunderstorm-collector-ash.sh",
    "python/thunderstorm-collector.py",
    "python/thunderstorm-collector-py2.py",
    "perl/thunderstorm-collector.pl",
    "powershell/thunderstorm-collector.ps1",
    "powershell/thunderstorm-collector-ps2.ps1",
    "batch/thunderstorm-collector.bat",
)


@unittest.skipUnless(os.name == "posix" and shutil.which("make"), "POSIX make required")
class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="collector-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "go").mkdir()
        (self.root / "go" / "config.yml").write_text("fixture-config\n", encoding="utf-8")

    def fixture(self, path, content="fixture-script\n"):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return target

    def run_make(self, target, version="vtest"):
        env = os.environ.copy()
        for key in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL"):
            env.pop(key, None)
        result = subprocess.run(
            ["make", "--no-print-directory", "-f", str(MAKEFILE), target, "VERSION=" + version],
            cwd=self.root, env=env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return {path.name for path in (self.root / "release").iterdir()}

    def test_each_collector_becomes_an_individual_asset(self):
        expected = set()
        for relative in SCRIPTS:
            path = self.fixture("scripts/" + relative)
            expected.add(path.stem + "-test" + path.suffix)
        self.assertEqual(self.run_make("release-scripts"), expected)
        self.assertFalse(any(name.endswith(".zip") for name in expected))

    def test_licenses_backups_tests_and_caches_are_never_packaged(self):
        self.fixture("scripts/bash/thunderstorm-collector.sh")
        for relative in ("thunderstorm-collector-private.lic", "thunderstorm-collector.sh.bak",
                         "thunderstorm-collector-notes.md", "tests/thunderstorm-collector.sh",
                         "python/__pycache__/thunderstorm-collector.py"):
            self.fixture("scripts/" + relative, "not-a-real-license-or-collector\n")
        self.assertEqual(self.run_make("release-scripts"), {"thunderstorm-collector-test.sh"})

    def test_tag_ref_versions_are_normalized(self):
        self.fixture("scripts/bash/thunderstorm-collector.sh")
        self.assertEqual(self.run_make("release-scripts", "refs/tags/v1.2.3"),
                         {"thunderstorm-collector-1.2.3.sh"})

    def test_full_release_keeps_the_standalone_config_asset(self):
        self.fixture("go/Makefile", "release:\n\tmkdir -p dist\n\tprintf binary > dist/thunderstorm-collector-arm64-darwin.tar.gz\n")
        self.fixture("scripts/bash/thunderstorm-collector.sh")
        self.assertEqual(self.run_make("release"), {
            "config-test.yml", "thunderstorm-collector-test.sh",
            "thunderstorm-collector-test-arm64-darwin.tar.gz",
        })
        self.assertEqual((self.root / "release/config-test.yml").read_text(encoding="utf-8"), "fixture-config\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
