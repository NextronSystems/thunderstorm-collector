#!/usr/bin/env python3
"""Exercise release staging with the real built package, without release credentials."""
import hashlib
import io
import runpy
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
prepare = runpy.run_path(str(Path(__file__).with_name("prepare-release.py")))["prepare"]
packages = list((repo / "go/legacy/dist").glob("*-amd64-freebsd8-netscaler.tar.gz"))
assert len(packages) == 1, "Expect exactly one legacy validation package"
archive = packages[0]
version = archive.name[len("thunderstorm-collector-"):-len("-amd64-freebsd8-netscaler.tar.gz")]
with tempfile.TemporaryDirectory(prefix="legacy-release-") as tmp:
    directory = Path(tmp)
    regular = directory / "thunderstorm-collector-regular.tar.gz"
    regular.write_bytes(b"stand-in for an existing regular artifact")
    try:
        prepare(directory, version, repo / "go/config.yml")
    except ValueError as error:
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
    except ValueError as error:
        assert "checksum" in str(error)
    else:
        raise AssertionError("Release accepted a corrupt legacy package")
    verify_script = str(Path(__file__).with_name("verify-legacy-package.py"))
    prepare_script = str(Path(__file__).with_name("prepare-release.py"))

    def optimized(script, arguments, expected_error=None):
        result = subprocess.run([sys.executable, "-O", script] + list(map(str, arguments)), capture_output=True, text=True)
        if expected_error is None:
            if result.returncode != 0:
                raise AssertionError(result.stderr)
        elif result.returncode == 0 or expected_error not in result.stderr:
            raise AssertionError("Optimized validation did not reject input: " + result.stdout + result.stderr)

    optimized(verify_script, [packaged, repo / "go/config.yml"], "Invalid archive checksum")
    packaged.write_bytes(original)
    # Keep the checksum valid while changing the ELF target. This proves that
    # optimization retains content validation as well as the checksum guard.
    with tarfile.open(fileobj=io.BytesIO(original), mode="r:gz") as source, tarfile.open(packaged, "w:gz") as output:
        for member in source:
            data = source.extractfile(member).read() if member.isfile() else None
            if member.name.endswith("/amd64-freebsd8-netscaler-thunderstorm-collector"):
                data = data[:18] + (183).to_bytes(2, "little") + data[20:]  # AArch64
            output.addfile(member, io.BytesIO(data) if data is not None else None)
    staged_checksum = directory / checksum.name
    staged_checksum.write_text(hashlib.sha256(packaged.read_bytes()).hexdigest() + "  " + archive.name + "\n")
    optimized(verify_script, [packaged, repo / "go/config.yml"], "Expected x86-64 executable")
    packaged.write_bytes(original)
    staged_checksum.unlink()
    optimized(verify_script, [packaged, repo / "go/config.yml"], "FileNotFoundError")
    shutil.copy2(checksum, directory)
    optimized(prepare_script, [directory, "missing-version", repo / "go/config.yml"], "Missing required")
    optimized(prepare_script, [directory, version, repo / "go/config.yml"])
    prepare(directory, version, repo / "go/config.yml")
    manifest = (directory / "SHA256SUMS").read_text()
    assert hashlib.sha256(original).hexdigest() + "  " + archive.name in manifest
    assert hashlib.sha256(regular.read_bytes()).hexdigest() + "  " + regular.name in manifest
    assert regular.read_bytes() == b"stand-in for an existing regular artifact"
    assert "/blob/v" + version + "/go/README.md#citrix-netscaler-and-freebsd-84" in (directory / "release-notes.md").read_text()
print("Release staging passed: required package/checksum, corruption and wrong-architecture rejection (including python -O), existing asset preservation, manifest and version-specific notes")
