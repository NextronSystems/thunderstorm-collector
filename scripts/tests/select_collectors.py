#!/usr/bin/env python3
"""Select collectors with the interface required by the shared smoke tests."""

import argparse
import os
from pathlib import Path
import shutil
import sys


# Interface probes distinguish old/new scripts during rollout, not their full capabilities.
SHELL_FLAGS = ("--server", "--port", "--dir", "--max-age", "--source", "--dry-run")
PYTHON_FLAGS = ("--server", "--port", "--dirs", "--max-age", "--source", "--dry-run")
PS_FLAGS = ("ThunderstormServer", "ThunderstormPort", "Folder", "Source", "MaxAge", "MaxSize", "AllExtensions")
BATCH_FLAGS = ("SET _TS=%THUNDERSTORM_SERVER%", "SET _TP=%THUNDERSTORM_PORT%",
               "SET _DIRS=%COLLECT_DIRS%", "SET _MAXSZ=%COLLECT_MAX_SIZE%", "SET _SRC=%SOURCE%")
COLLECTORS = {
    "bash": ("linux", "bash/thunderstorm-collector.sh", SHELL_FLAGS),
    "ash": ("linux", "ash/thunderstorm-collector-ash.sh", SHELL_FLAGS),
    "python3": ("linux", "python/thunderstorm-collector.py", PYTHON_FLAGS),
    "python2": ("linux", "python/thunderstorm-collector-py2.py", PYTHON_FLAGS),
    "perl": ("linux", "perl/thunderstorm-collector.pl", SHELL_FLAGS),
    "ps3": ("windows", "powershell/thunderstorm-collector.ps1", PS_FLAGS),
    "ps2": ("windows", "powershell/thunderstorm-collector-ps2.ps1", PS_FLAGS),
    "batch": ("windows", "batch/thunderstorm-collector.bat", BATCH_FLAGS),
}
DEFAULTS = {
    "linux": ("bash", "ash", "python3", "perl"),
    "windows": ("ps3", "ps2", "batch"),
}
GROUPS = {"python": ("python3",), "powershell": ("ps3",), **DEFAULTS}
BRANCH_GROUPS = {
    "script-bash": ("bash",), "script-ash": ("ash",),
    "script-python": ("python3",), "script-perl": ("perl",),
    "script-windows": DEFAULTS["windows"],
}


def requested_collectors(requested, branch, platform):
    if requested.strip():
        names = []
        for value in requested.split(","):
            value = value.strip()
            if value not in COLLECTORS and value not in GROUPS:
                raise ValueError("Unknown collector selector: {!r}".format(value))
            names.extend(GROUPS.get(value, (value,)))
        strict = True
    else:
        names = None
        for pattern, group in BRANCH_GROUPS.items():
            if pattern in branch:
                names = group
                break
        strict = names is not None
        if names is None:
            names = DEFAULTS[platform]
    return list(dict.fromkeys(name for name in names if COLLECTORS[name][0] == platform)), strict


def select_collectors(scripts_dir, platform, requested="", branch=""):
    names, strict = requested_collectors(requested, branch, platform)
    selected, skipped = [], []
    for name in names:
        _, filename, flags = COLLECTORS[name]
        path = scripts_dir / filename
        reason = None
        if not path.is_file():
            reason = "script is missing"
        else:
            content = path.read_text(encoding="utf-8")
            if not all(flag in content for flag in flags):
                reason = "script still uses the legacy interface"
            elif name == "python2" and not shutil.which("python2"):
                reason = "Python 2 runtime is unavailable; test it on a legacy host"
        if reason:
            if strict:
                raise ValueError("Requested collector {} cannot be tested: {}".format(name, reason))
            skipped.append("{}: {}".format(name, reason))
        else:
            selected.append(name)
    return selected, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=DEFAULTS, required=True)
    parser.add_argument("--scripts-dir", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--requested", default=os.environ.get("REQUESTED_COLLECTORS", ""))
    parser.add_argument("--branch", default=os.environ.get("COLLECTOR_BRANCH", ""))
    parser.add_argument("--github-output", type=Path, default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args()
    try:
        selected, skipped = select_collectors(args.scripts_dir, args.platform, args.requested, args.branch)
    except (ValueError, OSError) as exc:
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 1
    for reason in skipped:
        print("Skipping " + reason)
    print("Selected {} collectors: {}".format(args.platform, ",".join(selected) or "none (legacy collectors remain covered by Collector Tests)"))
    if args.platform == "linux":
        print("Python 2 is not installed by this workflow; its legacy-runtime acceptance is a separate test.")
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write("collectors={}\ncount={}\n".format(",".join(selected), len(selected)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
