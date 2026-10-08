#!/usr/bin/env python3
"""Require and verify the legacy package before generating release checksums/notes."""
import hashlib
import os
import re
import runpy
import sys
from pathlib import Path


def prepare(directory, version, config):
    directory = Path(directory)
    version = version.removeprefix("refs/tags/")
    if re.match(r"v[0-9]", version):
        version = version[1:]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
        raise ValueError("Invalid release version")
    required = directory / ("thunderstorm-collector-" + version + "-amd64-freebsd8-netscaler.tar.gz")
    if not required.is_file():
        raise ValueError("Missing required NetScaler legacy release package: " + str(required))
    runpy.run_path(str(Path(__file__).with_name("verify-legacy-package.py")))["verify"](required, config)
    assets = sorted(p for p in directory.iterdir() if p.is_file() and p.name not in ("SHA256SUMS", "release-notes.md"))
    manifest = "".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n" for p in assets)
    (directory / "SHA256SUMS").write_text(manifest)
    repo = os.environ.get("GITHUB_REPOSITORY", "NextronSystems/thunderstorm-collector")
    tag = "v" + version
    docs = "https://github.com/" + repo + "/blob/" + tag
    (directory / "release-notes.md").write_text(
        "Collector selection:\n\n"
        "- **VMware ESXi:** use the Python collector. Nextron reports historical success; exact tested firmware/revisions are not recorded. Check the Python requirements and [script instructions](" + docs + "/scripts/README.md).\n"
        "- **Older NetScaler / FreeBSD 8.4 amd64:** use `" + required.name + "`, built with exactly Go 1.9.7. Regular FreeBSD packages are not interchangeable. Compilation/package checks and Linux-hosted runtime tests are verified. External tests reported on 2026-10-08 succeeded on FreeBSD 8.4 amd64 without a workaround and FreeBSD 14.3 amd64 with ASLR disabled for the invocation; the compatibility notes identify the tested CI artifact. Named NetScaler appliance/firmware validation remains pending. Read the [compatibility notes](" + docs + "/go/README.md#citrix-netscaler-and-freebsd-84) and packaged BUILD-INFO.txt. Go 1.9.7 is unsupported and lacks later runtime/standard-library security fixes.\n"
        "- **Other NetScaler versions:** verify the actual OS, architecture and collector compatibility before selecting a package.\n\n"
        "Verify downloads against `SHA256SUMS`.\n"
    )


if __name__ == "__main__":
    prepare(*sys.argv[1:])
