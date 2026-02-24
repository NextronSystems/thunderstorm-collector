#!/usr/bin/env python3
# Minimum Python version: 3.4 (no f-strings, no 3.6+ features)

import argparse
import http.client
import json
import os
import re
import ssl
import time
import uuid
import socket
from urllib.parse import quote

# Configuration
schema = "http"
max_age = 14  # in days
max_size = 20  # in megabytes
skip_elements = [
    r"^\/proc",
    r"^\/mnt",
    r"\.dat$",
    r"\.npm",
    r"\.vmdk$",
    r"\.vswp$",
    r"\.nvram$",
    r"\.vmsd$",
    r"\.lck$",
]
hard_skips = [
    "/proc", "/dev", "/sys", "/run",
    "/snap", "/.snapshots",
    "/sys/kernel/debug", "/sys/kernel/slab", "/sys/kernel/tracing",
]

# Network and special filesystem types to exclude via /proc/mounts
NETWORK_FS_TYPES = {"nfs", "nfs4", "cifs", "smbfs", "smb3", "sshfs", "fuse.sshfs",
                    "afp", "webdav", "davfs2", "fuse.rclone", "fuse.s3fs"}
SPECIAL_FS_TYPES = {"proc", "procfs", "sysfs", "devtmpfs", "devpts",
                    "cgroup", "cgroup2", "pstore", "bpf", "tracefs", "debugfs",
                    "securityfs", "hugetlbfs", "mqueue", "autofs",
                    "fusectl", "rpc_pipefs", "nsfs", "configfs", "binfmt_misc",
                    "selinuxfs", "efivarfs", "ramfs"}

# Cloud storage folder names (lowercase for comparison)
CLOUD_DIR_NAMES = {"onedrive", "dropbox", ".dropbox", "googledrive", "google drive",
                   "icloud drive", "iclouddrive", "nextcloud", "owncloud", "mega",
                   "megasync", "tresorit", "tresorit drive", "syncthing"}


def get_excluded_mounts():
    """Parse /proc/mounts and return mount points for network/special filesystems."""
    excluded = []
    try:
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3:
                    mount_point, fs_type = parts[1], parts[2]
                    if fs_type in NETWORK_FS_TYPES or fs_type in SPECIAL_FS_TYPES:
                        excluded.append(mount_point)
    except (IOError, OSError):
        pass
    return excluded


def is_cloud_path(filepath):
    """Check if a path contains a known cloud storage folder name."""
    segments = filepath.replace("\\", "/").lower().split("/")
    for seg in segments:
        if seg in CLOUD_DIR_NAMES:
            return True
        # Dynamic patterns: "onedrive - orgname", "onedrive-tenant", "nextcloud-account"
        if seg.startswith("onedrive - ") or seg.startswith("onedrive-") or seg.startswith("nextcloud-"):
            return True
    # macOS: ~/Library/CloudStorage
    if "/library/cloudstorage" in filepath.lower():
        return True
    return False


# Composed values
current_date = time.time()

# Stats
num_submitted = 0
num_processed = 0

# URL to use for submission
api_endpoint = ""

# Original args
args = {}

# Functions
def process_dir(workdir):
    for dirpath, dirnames, filenames in os.walk(workdir, followlinks=False):
        # Hard skip directories (modify in-place to prevent descent)
        dirnames[:] = [
            d for d in dirnames
            if os.path.join(dirpath, d) not in hard_skips
            and not os.path.islink(os.path.join(dirpath, d))
            and not is_cloud_path(os.path.join(dirpath, d))
        ]

        for name in filenames:
            filepath = os.path.join(dirpath, name)

            # Skip symlinks
            if os.path.islink(filepath):
                continue

            if args.debug:
                print("[DEBUG] Checking {} ...".format(filepath))

            # Count
            global num_processed
            num_processed += 1

            # Skip files
            if skip_file(filepath):
                continue

            # Submit
            submit_sample(filepath)


def skip_file(filepath):
    # Regex skips
    for pattern in skip_elements:
        if re.search(pattern, filepath):
            if args.debug:
                print(
                    "[DEBUG] Skipping file due to configured skip_file exclusion {}".format(
                        filepath
                    )
                )
            return True

    # Size
    if os.path.getsize(filepath) > max_size * 1024 * 1024:
        if args.debug:
            print("[DEBUG] Skipping file due to size {}".format(filepath))
        return True

    # Age
    mtime = os.path.getmtime(filepath)
    if mtime < current_date - (max_age * 86400):
        if args.debug:
            print("[DEBUG] Skipping file due to age {}".format(filepath))
        return True

    return False


def submit_sample(filepath):
    print("[SUBMIT] Submitting {} ...".format(filepath))

    headers = {
        "Content-Type": "application/octet-stream",
        "Content-Disposition": "attachment; filename={}".format(filepath),
    }

    try:

        with open(filepath, "rb") as f:
            data = f.read()

    except Exception as e:
        print("[ERROR] Could not read '{}' - {}".format(filepath, e))
        return

    boundary = str(uuid.uuid4())
    headers = {
        "Content-Type": "multipart/form-data; boundary={}".format(boundary),
    }

    # Sanitize filename for multipart header safety
    safe_filename = filepath.replace('"', '_').replace(';', '_').replace('\r', '_').replace('\n', '_')

    # Create multipart/form-data payload
    payload = (
        "--{boundary}\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
        "Content-Type: application/octet-stream\r\n\r\n"
    ).format(boundary=boundary, filename=safe_filename).encode("utf-8")
    payload += data
    payload += "\r\n--{}--\r\n".format(boundary).encode("utf-8")

    retries = 0
    while retries < 3:
        try:
            if args.tls:
                if args.insecure:
                    context = ssl._create_unverified_context()
                else:
                    context = ssl.create_default_context()
                conn = http.client.HTTPSConnection(args.server, args.port, context=context)
            else:
                conn = http.client.HTTPConnection(args.server, args.port)
            conn.request("POST", api_endpoint, body=payload, headers=headers)

            resp = conn.getresponse()

        except Exception as e:
            print("[ERROR] Could not submit '{}' - {}".format(filepath, e))
            retries += 1
            time.sleep(2 << retries)
            continue

        # pylint: disable=no-else-continue
        if resp.status == 503: # Service unavailable
            retries += 1
            if retries >= 10:
                print("[ERROR] Server busy after 10 retries, giving up on '{}'".format(filepath))
                break
            retry_after = resp.headers.get("Retry-After", "30")
            try:
                retry_time = int(retry_after)
            except (ValueError, TypeError):
                retry_time = 30
            time.sleep(retry_time)
            continue
        elif resp.status == 200:
            global num_submitted
            num_submitted += 1
            break
        else:
            print(
                "[ERROR] HTTP return status: {}, reason: {}".format(
                    resp.status, resp.reason
                )
            )
            retries += 1
            time.sleep(2 << retries)
            continue


def collection_marker(server, port, tls, insecure, source, collector_version, marker_type, scan_id=None, stats=None):
    """POST a begin/end collection marker to /api/collection.
    Returns the scan_id from the response, or None if unsupported/failed."""
    body = {
        "type": marker_type,
        "source": source,
        "collector": "python3/{}".format(collector_version),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if scan_id:
        body["scan_id"] = scan_id
    if stats:
        body["stats"] = stats

    try:
        if tls:
            ctx = ssl._create_unverified_context() if insecure else ssl.create_default_context()
            conn = http.client.HTTPSConnection(server, port, context=ctx, timeout=10)
        else:
            conn = http.client.HTTPConnection(server, port, timeout=10)
        payload = json.dumps(body).encode("utf-8")
        conn.request("POST", "/api/collection", body=payload,
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        resp_body = resp.read().decode("utf-8", errors="replace")
        data = json.loads(resp_body)
        return data.get("scan_id")
    except Exception:
        return None


# Main
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        prog="thunderstorm-collector.py",
        description="Tool to collect files to sent to THOR Thunderstorm. Only uses standard library functions of Python.",
    )
    parser.add_argument(
        "-d",
        "--dirs",
        nargs="*",
        default=["/"],
        help="Directories that should be scanned. (Default: /)",
    )
    parser.add_argument(
        "-s", "--server", required=True, help="FQDN/IP of the THOR Thunderstorm server."
    )
    parser.add_argument(
        "-p", "--port", type=int, default=8080, help="Port of the THOR Thunderstorm server. (Default: 8080)"
    )
    parser.add_argument(
        "-t",
        "--tls",
        action="store_true",
        help="Use TLS to connect to the THOR Thunderstorm server.",
    )
    parser.add_argument(
        "-k",
        "--insecure",
        action="store_true",
        help="Skip TLS verification and proceed without checking.",
    )
    parser.add_argument(
        "-S",
        "--source",
        default=socket.gethostname(),
        help="Source identifier to be used in the Thunderstorm submission.",
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging.")

    args = parser.parse_args()

    if args.tls:
        schema = "https"

    source = ""
    if args.source:
        source = "?source={}".format(quote(args.source))

    api_endpoint = "{}://{}:{}/api/checkAsync{}".format(schema, args.server, args.port, source)

    print("=" * 80)
    print("   Python Thunderstorm Collector")
    print("   Florian Roth, Nextron Systems GmbH, 2024")
    print()
    print("=" * 80)
    # Extend hard_skips with mount points of network/special filesystems
    for mp in get_excluded_mounts():
        if mp not in hard_skips:
            hard_skips.append(mp)

    print("Target Directory: {}".format(", ".join(args.dirs)))
    print("Thunderstorm Server: {}".format(args.server))
    print("Thunderstorm Port: {}".format(args.port))
    print("Using API Endpoint: {}".format(api_endpoint))
    print("Maximum Age of Files: {}".format(max_age))
    print("Maximum File Size: {} MB".format(max_size))
    print("Excluded directories: {}".format(", ".join(hard_skips[:10]) + (" ..." if len(hard_skips) > 10 else "")))
    print("Source Identifier: {}".format(args.source)) if args.source else None
    print()

    print("Starting the walk at: {} ...".format(", ".join(args.dirs)))

    # Send collection begin marker
    scan_id = collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.source or socket.gethostname(), "0.1",
        "begin"
    )
    if scan_id:
        print("[INFO] Collection scan_id: {}".format(scan_id))
        api_endpoint = "{}&scan_id={}".format(api_endpoint, quote(scan_id))

    # Walk directory
    for walkdir in args.dirs:
        process_dir(walkdir)

    # Send collection end marker with stats
    end_date = time.time()
    elapsed = int(end_date - current_date)
    minutes = elapsed // 60
    collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.source or socket.gethostname(), "0.1",
        "end",
        scan_id=scan_id,
        stats={
            "scanned": num_processed,
            "submitted": num_submitted,
            "elapsed_seconds": elapsed,
        }
    )

    print(
        "Thunderstorm Collector Run finished (Checked: {} Submitted: {} Minutes: {})".format(
            num_processed, num_submitted, minutes
        )
    )
