#!/usr/bin/env python3
"""Exercise release staging with the real built package, without release credentials."""
import hashlib
import runpy
import shutil
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
prepare = runpy.run_path(str(Path(__file__).with_name("prepare-release.py")))["prepare"]
packages = list((repo / "go/dist").glob("*-amd64-freebsd8-netscaler.tar.gz"))
assert len(packages) == 1, "Expect exactly one legacy validation package"
archive = packages[0]
version = archive.name[len("thunderstorm-collector-"):-len("-amd64-freebsd8-netscaler.tar.gz")]
with tempfile.TemporaryDirectory(prefix="legacy-release-") as tmp:
    directory = Path(tmp)
    regular = directory / "thunderstorm-collector-regular.tar.gz"
    regular.write_bytes(b"stand-in for an existing regular artifact")
    try:
        prepare(directory, version, repo / "go/config.yml")
    except AssertionError as error:
        assert "Missing required" in str(error)
    else:
        raise AssertionError("Release accepted a missing legacy package")
    shutil.copy2(archive, directory)
    try:
        prepare(directory, version, repo / "go/config.yml")
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("Release accepted a missing checksum")
    checksum = archive.with_name(archive.name + ".sha256")
    shutil.copy2(checksum, directory)
    packaged = directory / archive.name
    original = packaged.read_bytes()
    packaged.write_bytes(original + b"corrupt")
    try:
        prepare(directory, version, repo / "go/config.yml")
    except AssertionError as error:
        assert "checksum" in str(error)
    else:
        raise AssertionError("Release accepted a corrupt legacy package")
    packaged.write_bytes(original)
    prepare(directory, version, repo / "go/config.yml")
    manifest = (directory / "SHA256SUMS").read_text()
    assert hashlib.sha256(original).hexdigest() + "  " + archive.name in manifest
    assert hashlib.sha256(regular.read_bytes()).hexdigest() + "  " + regular.name in manifest
    assert regular.read_bytes() == b"stand-in for an existing regular artifact"
    assert "/blob/v" + version + "/go/legacy/README.md" in (directory / "release-notes.md").read_text()
print("Release staging passed: required package/checksum, corruption rejection, existing asset preservation, manifest and version-specific notes")
