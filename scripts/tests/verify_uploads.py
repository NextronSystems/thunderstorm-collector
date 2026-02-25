#!/usr/bin/env python3

import argparse
import hashlib
import pathlib
import sys
import time


def sha256_of_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def collect_files(root: pathlib.Path):
    return sorted([p for p in root.rglob("*") if p.is_file()])


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify uploaded sample integrity in stub uploads dir.")
    parser.add_argument("--uploads-dir", required=True, help="Directory used as thunderstorm-stub-server --uploads-dir")
    parser.add_argument("--expected-sha256", required=True, help="Expected sha256 hash of each uploaded sample")
    parser.add_argument("--min-count", type=int, required=True, help="Minimum number of uploaded files expected")
    parser.add_argument("--timeout-seconds", type=int, default=60, help="Max time to wait for async uploads")
    args = parser.parse_args()

    uploads_dir = pathlib.Path(args.uploads_dir)
    expected_sha256 = args.expected_sha256.lower()
    deadline = time.time() + args.timeout_seconds

    while time.time() < deadline:
        files = collect_files(uploads_dir)
        if len(files) >= args.min_count:
            bad = []
            for file_path in files:
                actual_sha256 = sha256_of_file(file_path).lower()
                if actual_sha256 != expected_sha256:
                    bad.append((file_path, actual_sha256))

            if bad:
                print("Found uploaded files with unexpected hash:", file=sys.stderr)
                for path, actual in bad:
                    print(f"  {path}: {actual} (expected {expected_sha256})", file=sys.stderr)
                return 1

            print(f"Integrity verified for {len(files)} uploaded files.")
            return 0

        time.sleep(1)

    files = collect_files(uploads_dir)
    print(
        f"Timed out waiting for uploads. Expected at least {args.min_count}, found {len(files)}.",
        file=sys.stderr,
    )
    for file_path in files:
        print(f"  Found: {file_path}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
