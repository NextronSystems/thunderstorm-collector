#!/usr/bin/env python3
"""Exercise the actual release build steps, the two compilers and the SFTP
collector, with deterministic compiler stubs."""
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
workflow = (repo / ".github/workflows/release.yml").read_text()


def build_step(name):
    lines = workflow.splitlines()
    marker = "      - name: " + name
    if marker not in lines:
        raise AssertionError("Release build step missing: " + name)
    start = lines.index(marker) + 1
    while start < len(lines) and lines[start] != "        run: |":
        if lines[start].startswith("      - name:"):
            raise AssertionError("Release build command missing: " + name)
        start += 1
    commands = []
    for line in lines[start + 1:]:
        if line and not line.startswith("          "):
            break
        commands.append(line[10:] if line else "")
    if not commands:
        raise AssertionError("Empty release build command: " + name)
    return "\n".join(commands)


fake_go = '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
compiler = os.environ["TEST_RELEASE_COMPILER"]
if args == ["version"]:
    version = "go1.10.8" if compiler == "go1.10" else "go1.26.0"
    print("go version " + version + " linux/amd64")
elif args == ["tool", "dist", "list"]:
    print("linux/amd64\\nfreebsd/amd64" + ("\\nlinux/riscv64" if compiler == "stable" else ""))
elif args == ["env", "GOOS"]:
    print("linux")
elif args == ["env", "GOARCH"]:
    print("amd64")
elif args and args[0] == "build":
    output = Path(args[args.index("-o") + 1])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(compiler + ":" + os.environ["GOOS"] + "/" + os.environ["GOARCH"])
else:
    raise SystemExit("Unexpected test compiler arguments: " + repr(args))
'''

with tempfile.TemporaryDirectory(prefix="release-toolchains-") as tmp:
    root = Path(tmp)
    for name in ("go", "scripts", "sftp", "tools"):
        (root / name).mkdir()
    for name in ("Makefile", "go/Makefile", "sftp/Makefile"):
        shutil.copy2(repo / name, root / name)
    (root / "sftp/README.md").write_text("fixture-sftp-readme\n")
    (root / "sftp/main.go").write_text("fixture-sftp-source\n")
    (root / "go/config.yml").write_text("fixture-config\n")
    (root / "go/main.go").write_text("fixture-source\n")
    (root / "scripts/python").mkdir()
    (root / "scripts/python/thunderstorm-collector.py").write_text("fixture-script\n")
    (root / "tools/go").write_text(fake_go)
    (root / "tools/go").chmod(0o755)
    env = os.environ.copy()
    for key in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL"):
        env.pop(key, None)
    env.update(PATH=str(root / "tools") + os.pathsep + env["PATH"], VERSION="refs/tags/v1.0.2")
    for compiler, name in (("stable", "Build project with Go stable"),
                           ("stable", "Build SFTP collector with Go stable"),
                           ("go1.10", "Build project with Go 1.10")):
        env["TEST_RELEASE_COMPILER"] = compiler
        result = subprocess.run(["bash", "-eu", "-c", build_step(name)], cwd=root, env=env, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
    for target, expected in (("amd64-linux", "go1.10:linux/amd64"),
                             ("amd64-freebsd", "go1.10:freebsd/amd64"),
                             ("riscv64-linux", "stable:linux/riscv64")):
        archive = root / "release" / ("thunderstorm-collector-1.0.2-" + target + ".tar.gz")
        with tarfile.open(archive) as package:
            prefix = "thunderstorm-collector-" + target + "/"
            actual = package.extractfile(prefix + target + "-thunderstorm-collector").read().decode()
            if actual != expected:
                raise AssertionError(target + " packaged " + actual + ", expected " + expected)
            if package.extractfile(prefix + "config.yml").read() != b"fixture-config\n":
                raise AssertionError("Packaged configuration changed")
    # The SFTP packages come from the stable step and survive the Go 1.10 rebuild.
    for arch in ("amd64", "arm64"):
        archive = root / "release" / ("thunderstorm-sftp-collector-1.0.2-" + arch + "-linux.tar.gz")
        with tarfile.open(archive) as package:
            prefix = "thunderstorm-sftp-collector-" + arch + "-linux/"
            actual = package.extractfile(prefix + arch + "-linux-thunderstorm-sftp-collector").read().decode()
            if actual != "stable:linux/" + arch:
                raise AssertionError("SFTP " + arch + " packaged " + actual + ", expected stable:linux/" + arch)
            if package.extractfile(prefix + "README.md").read() != b"fixture-sftp-readme\n":
                raise AssertionError("Packaged SFTP README changed")
    if (root / "release/config-1.0.2.yml").read_bytes() != b"fixture-config\n":
        raise AssertionError("Standalone configuration changed")
    if (root / "release/thunderstorm-collector-1.0.2.py").read_bytes() != b"fixture-script\n":
        raise AssertionError("Script release asset changed")

print("Release compiler selection passed: Go 1.10 for shared targets, stable-only and SFTP packages preserved, config/scripts intact")
