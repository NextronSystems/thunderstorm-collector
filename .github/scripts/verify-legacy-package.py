#!/usr/bin/env python3
"""Check the delivered archive without executing its foreign-OS binary."""
import hashlib
import re
import struct
import sys
import tarfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(archive, config):
    archive = Path(archive)
    name = archive.name.removesuffix(".tar.gz")
    match = re.fullmatch(r"thunderstorm-collector-([A-Za-z0-9][A-Za-z0-9._-]*)-amd64-freebsd8-netscaler", name)
    require(match, "Unexpected legacy release asset name")
    checksum = archive.with_name(archive.name + ".sha256").read_text().strip()
    require(checksum == hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name, "Invalid archive checksum")
    binary = "amd64-freebsd8-netscaler-thunderstorm-collector"
    expected = {name, *(name + "/" + f for f in (binary, "config.yml", "COMPATIBILITY.txt", "BUILD-INFO.txt"))}
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        require(len(members) == len(expected) and {m.name for m in members} == expected, "Unexpected package contents")
        require(tar.getmember(name).isdir(), "Expected package root directory")
        require(all(m.isfile() for m in members if m.name != name), "Non-regular package member")
        require(tar.getmember(name + "/" + binary).mode & 0o777 == 0o755, "Binary must be executable")
        elf = tar.extractfile(name + "/" + binary).read()
        require(elf[:8] == b"\x7fELF\x02\x01\x01\x09", "Expected little-endian ELF64 FreeBSD ABI")
        require(struct.unpack_from("<HH", elf, 16) == (2, 62), "Expected x86-64 executable")
        offset = struct.unpack_from("<Q", elf, 32)[0]
        size, count = struct.unpack_from("<HH", elf, 54)
        require(size == 56 and count > 0, "Invalid ELF program header")
        for i in range(count):
            segment_type = struct.unpack_from("<I", elf, offset + i * size)[0]
            require(segment_type not in (2, 3), "Unexpected dynamic segment/interpreter")
        require(tar.extractfile(name + "/config.yml").read() == Path(config).read_bytes(), "Config differs from the validated shared config")
        metadata = tar.extractfile(name + "/BUILD-INFO.txt").read().decode()
        required = ["go version go1.9.7 linux/amd64", "GOOS=freebsd", "GOARCH=amd64", "CGO_ENABLED=0", "version=" + match[1], "FreeBSD_8.4_runtime=pending", "NetScaler_appliance_firmware=pending"]
        require(all(line in metadata.splitlines() for line in required), "Missing/wrong build metadata")
        require(re.search(r"^source_commit=[0-9a-f]{40}$", metadata, re.M), "Missing source commit")
        require("unsupported" in tar.extractfile(name + "/COMPATIBILITY.txt").read().decode(), "Missing legacy toolchain warning")
    print("Verified static FreeBSD/amd64 ELF, executable permissions, config, metadata, archive members and SHA-256:", archive.name)


if __name__ == "__main__":
    verify(*sys.argv[1:])
