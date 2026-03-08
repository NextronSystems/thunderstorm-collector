#!/usr/bin/env python
# -*- coding: utf-8 -*-
#
# THOR Thunderstorm Collector - Python 2 version
# Florian Roth, Nextron Systems GmbH, 2024
#
# Requires: Python 2.7
# Use thunderstorm-collector.py for Python 3.4+
#
# stdlib only — no third-party dependencies.

from __future__ import print_function

import sys

if sys.version_info[0] != 2:
    sys.exit("[ERROR] This script requires Python 2.7. For Python 3, use thunderstorm-collector.py")

import argparse
import atexit
import httplib
import json
import os
import re
import signal
import socket
import ssl
import time
import uuid
from urllib import quote

# Configuration
schema = "http"
max_age = 14  # in days
max_size_kb = 2048  # in KB (harmonized with other implementations)
sync_mode = False
dry_run = False
retries = 3
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

NETWORK_FS_TYPES = set(["nfs", "nfs4", "cifs", "smbfs", "smb3", "sshfs", "fuse.sshfs",
                        "afp", "webdav", "davfs2", "fuse.rclone", "fuse.s3fs"])
SPECIAL_FS_TYPES = set(["proc", "procfs", "sysfs", "devtmpfs", "devpts",
                        "cgroup", "cgroup2", "pstore", "bpf", "tracefs", "debugfs",
                        "securityfs", "hugetlbfs", "mqueue", "autofs",
                        "fusectl", "rpc_pipefs", "nsfs", "configfs", "binfmt_misc",
                        "selinuxfs", "efivarfs", "ramfs"])
CLOUD_DIR_NAMES = set(["onedrive", "dropbox", ".dropbox", "googledrive", "google drive",
                       "icloud drive", "iclouddrive", "nextcloud", "owncloud", "mega",
                       "megasync", "tresorit", "syncthing"])


def get_excluded_mounts():
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


def _ensure_unicode(path):
    """Decode byte string to unicode for safe string operations."""
    if isinstance(path, bytes):
        return path.decode("utf-8", "replace")
    return path


def is_cloud_path(filepath):
    filepath = _ensure_unicode(filepath)
    segments = filepath.replace("\\", "/").lower().split("/")
    for seg in segments:
        if seg in CLOUD_DIR_NAMES:
            return True
        if seg.startswith("onedrive - ") or seg.startswith("onedrive-") or seg.startswith("nextcloud-"):
            return True
    if "/library/cloudstorage" in filepath.lower():
        return True
    return False


# Composed values
start_time = time.time()

# Stats
num_submitted = 0
num_processed = 0
num_failed = 0
num_total = 0

# Progress reporting
progress_enabled = None
progress_interval = 100
progress_last_time = 0
progress_time_interval = 10

# URL to use for submission
api_endpoint = ""

# Original args
args = {}


def maybe_progress():
    global progress_last_time
    if not progress_enabled or num_total <= 0:
        return
    do_report = (num_processed % progress_interval == 0)
    if not do_report:
        now = time.time()
        if progress_last_time > 0 and (now - progress_last_time) >= progress_time_interval:
            do_report = True
    if not do_report:
        return
    progress_last_time = time.time()
    pct = (num_processed * 100) // num_total if num_total > 0 else 0
    print("[{}/{}] {}% processed".format(num_processed, num_total, pct))


def count_files(dirs):
    total = 0
    for workdir in dirs:
        for dirpath, dirnames, filenames in os.walk(workdir, followlinks=False):
            dirnames[:] = [
                d for d in dirnames
                if os.path.join(dirpath, d) not in hard_skips
                and not os.path.islink(os.path.join(dirpath, d))
                and not is_cloud_path(os.path.join(dirpath, d))
            ]
            total += len(filenames)
    return total


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
            maybe_progress()

            # Skip files
            if skip_file(filepath):
                continue

            # Submit
            submit_sample(filepath)


def skip_file(filepath):
    # Regex skips
    filepath_u = _ensure_unicode(filepath)
    for pattern in skip_elements:
        if re.search(pattern, filepath_u):
            if args.debug:
                print("[DEBUG] Skipping file due to configured skip_file exclusion {}".format(filepath))
            return True

    # Size (max_size_kb is in KB)
    try:
        file_size = os.path.getsize(filepath)
        mtime = os.path.getmtime(filepath)
    except (OSError, IOError):
        if args.debug:
            print("[DEBUG] Skipping unreadable file {}".format(filepath))
        return True

    if file_size > max_size_kb * 1024:
        if args.debug:
            print("[DEBUG] Skipping file due to size {}".format(filepath))
        return True

    # Age
    if mtime < time.time() - (max_age * 86400):
        if args.debug:
            print("[DEBUG] Skipping file due to age {}".format(filepath))
        return True

    return False


def submit_sample(filepath):
    if dry_run:
        print("[DRY-RUN] Would submit {} ...".format(filepath))
        global num_submitted
        num_submitted += 1
        return

    print("[SUBMIT] Submitting {} ...".format(filepath))

    try:
        with open(filepath, "rb") as f:
            data = f.read()
    except Exception as e:
        print("[ERROR] Could not read '{}' - {}".format(filepath, e))
        global num_failed
        num_failed += 1
        return

    boundary = str(uuid.uuid4())

    # Encode filename for Content-Disposition header
    # Use RFC 5987 filename*= for non-ASCII safety; fall back to ASCII-sanitized filename=
    if isinstance(filepath, bytes):
        filepath_u = filepath.decode("utf-8", "replace")
    else:
        filepath_u = filepath
    ascii_safe = filepath_u.encode("ascii", "replace").replace(b'"', b'_').replace(b';', b'_').replace(b'\r', b'_').replace(b'\n', b'_')
    utf8_quoted = quote(filepath_u.encode("utf-8"), safe="")

    # Build multipart/form-data payload manually (no external libs)
    payload = (
        "--{boundary}\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"{filename}\"; filename*=UTF-8''{filename_star}\r\n"
        "Content-Type: application/octet-stream\r\n\r\n"
    ).format(boundary=boundary, filename=ascii_safe, filename_star=utf8_quoted).encode("utf-8")
    payload += data
    payload += "\r\n--{}--\r\n".format(boundary).encode("utf-8")

    headers = {
        "Content-Type": "multipart/form-data; boundary={}".format(boundary),
    }

    attempt = 0
    conn = None
    while attempt < retries:
        try:
            if args.tls:
                # ssl.create_default_context() requires Python 2.7.9+
                # ssl._create_unverified_context() also requires 2.7.9+
                # Fall back to bare HTTPSConnection for older Python 2.7
                if args.insecure:
                    if hasattr(ssl, '_create_unverified_context'):
                        context = ssl._create_unverified_context()
                    else:
                        context = None  # pre-2.7.9: no verification by default
                else:
                    if hasattr(ssl, 'create_default_context'):
                        context = ssl.create_default_context()
                        if args.ca_cert:
                            context.load_verify_locations(args.ca_cert)
                    else:
                        context = None  # pre-2.7.9: limited TLS, no SNI
                if context is not None:
                    conn = httplib.HTTPSConnection(args.server, args.port, context=context, timeout=30)
                else:
                    conn = httplib.HTTPSConnection(args.server, args.port, timeout=30)
            else:
                conn = httplib.HTTPConnection(args.server, args.port, timeout=30)
            conn.request("POST", api_endpoint, body=payload, headers=headers)
            resp = conn.getresponse()
            resp.read()  # drain response body to release socket

        except Exception as e:
            print("[ERROR] Could not submit '{}' - {}".format(filepath, e))
            attempt += 1
            time.sleep(2 << attempt)
            continue
        finally:
            try:
                conn.close()
            except Exception:
                pass

        if resp.status == 503:
            attempt += 1
            if attempt >= retries:
                print("[ERROR] Server busy after {} retries, giving up on '{}'".format(retries, filepath))
                num_failed += 1
                break
            retry_after = resp.getheader("Retry-After", "30")
            try:
                retry_time = int(retry_after)
            except (ValueError, TypeError):
                retry_time = 30
            time.sleep(retry_time)
            continue
        elif resp.status == 200:
            num_submitted += 1
            break
        else:
            print("[ERROR] HTTP return status: {}, reason: {}".format(resp.status, resp.reason))
            attempt += 1
            if attempt >= retries:
                num_failed += 1
                break
            time.sleep(2 << attempt)
            continue
    else:
        # while loop exhausted (connection errors only)
        if attempt >= retries:
            num_failed += 1


def collection_marker(server, port, use_tls, insecure, source, collector_version, marker_type, scan_id=None, stats=None, reason=None, ca_cert=None):
    """POST a begin/end collection marker to /api/collection.
    Returns the scan_id from the response, or None if unsupported/failed."""
    body = {
        "type": marker_type,
        "source": source,
        "collector": "python2/{}".format(collector_version),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if scan_id:
        body["scan_id"] = scan_id
    if stats:
        body["stats"] = stats
    if reason:
        body["reason"] = reason

    conn = None
    try:
        if use_tls:
            if hasattr(ssl, "create_default_context"):
                if insecure:
                    ctx = ssl._create_unverified_context()
                else:
                    ctx = ssl.create_default_context()
                    if ca_cert:
                        ctx.load_verify_locations(ca_cert)
                conn = httplib.HTTPSConnection(server, port, context=ctx, timeout=10)
            else:
                conn = httplib.HTTPSConnection(server, port, timeout=10)
        else:
            conn = httplib.HTTPConnection(server, port, timeout=10)
        payload = json.dumps(body)
        conn.request("POST", "/api/collection", body=payload,
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        resp_body = resp.read()
        data = json.loads(resp_body)
        return data.get("scan_id")
    except Exception as e:
        print("[DEBUG] Collection marker '{}' failed: {}".format(marker_type, e))
        return None
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


# Main
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        prog="thunderstorm-collector-py2.py",
        description="Tool to collect files to send to THOR Thunderstorm (Python 2.7 version). Only uses standard library functions.",
        epilog="Exit codes: 0=clean, 1=partial failure, 2=fatal, 130=SIGINT, 143=SIGTERM",
    )
    parser.add_argument(
        "-d", "--dirs",
        nargs="*",
        default=["/"],
        help="Directories that should be scanned. (Default: /)",
    )
    parser.add_argument(
        "-s", "--server",
        required=True,
        help="FQDN/IP of the THOR Thunderstorm server.",
    )
    parser.add_argument(
        "-p", "--port",
        type=int,
        default=8080,
        help="Port of the THOR Thunderstorm server. (Default: 8080)",
    )
    parser.add_argument(
        "-t", "--tls",
        action="store_true",
        help="Use TLS to connect to the THOR Thunderstorm server.",
    )
    parser.add_argument(
        "-k", "--insecure",
        action="store_true",
        help="Skip TLS verification and proceed without checking.",
    )
    parser.add_argument(
        "--ca-cert",
        default=None,
        help="Custom CA certificate bundle for TLS verification.",
    )
    parser.add_argument(
        "-S", "--source",
        default=socket.gethostname(),
        help="Source identifier to be used in the Thunderstorm submission.",
    )
    parser.add_argument(
        "--max-age", type=int, default=14,
        help="Max file age in days (default: 14)"
    )
    parser.add_argument(
        "--max-size-kb", type=int, default=2048,
        help="Max file size in KB (default: 2048)"
    )
    parser.add_argument(
        "--sync", action="store_true",
        help="Use /api/check (synchronous) instead of /api/checkAsync"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Do not upload, only show what would be submitted"
    )
    parser.add_argument(
        "--retries", type=int, default=3,
        help="Retry attempts per file (default: 3)"
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging.")
    progress_group = parser.add_mutually_exclusive_group()
    progress_group.add_argument("--progress", action="store_true", default=None,
                                help="Force progress reporting (default: auto-detect TTY).")
    progress_group.add_argument("--no-progress", action="store_true",
                                help="Disable progress reporting.")

    parser.add_argument(
        "--log-file",
        default=None,
        help="Log file path (enables file logging; default: stdout only).",
    )

    args = parser.parse_args()

    # Log file setup (write INFO lines to file)
    log_file_handle = None
    def write_log(line):
        """Write timestamped line to log file if enabled."""
        if log_file_handle:
            ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
            log_file_handle.write("{} {}".format(ts, line) + "\n")
            log_file_handle.flush()

    def log_close():
        if log_file_handle:
            log_file_handle.close()

    if args.log_file:
        try:
            log_file_handle = open(args.log_file, "a")
            atexit.register(log_close)
        except IOError as e:
            print("[ERROR] Cannot open log file '{}': {}".format(args.log_file, e))
            sys.exit(2)

    # Apply parsed args to module-level config
    max_age = args.max_age
    max_size_kb = args.max_size_kb
    dry_run = args.dry_run
    retries = args.retries
    sync_mode = args.sync

    if args.tls:
        schema = "https"

    source = ""
    if args.source:
        source = "?source={}".format(quote(args.source))

    api_path = "/api/check" if sync_mode else "/api/checkAsync"
    api_endpoint = "{}://{}:{}{}{}".format(schema, args.server, args.port, api_path, source)

    print("=" * 80)
    print("   Python Thunderstorm Collector (Python 2)")
    print("   Florian Roth, Nextron Systems GmbH, 2024")
    print()
    print("=" * 80)
    print("Target Directory: {}".format(", ".join(args.dirs)))
    print("Thunderstorm Server: {}".format(args.server))
    # Extend hard_skips with mount points of network/special filesystems
    for mp in get_excluded_mounts():
        if mp not in hard_skips:
            hard_skips.append(mp)

    print("Thunderstorm Port: {}".format(args.port))
    print("Using API Endpoint: {}".format(api_endpoint))
    print("Maximum Age of Files: {} days".format(max_age))
    print("Maximum File Size: {} KB".format(max_size_kb))
    print("Excluded directories: {}".format(", ".join(hard_skips[:10]) + (" ..." if len(hard_skips) > 10 else "")))
    if args.source:
        print("Source Identifier: {}".format(args.source))
    print()

    # Resolve progress reporting mode
    if args.no_progress:
        progress_enabled = False
    elif args.progress:
        progress_enabled = True
    else:
        progress_enabled = sys.stdout.isatty()

    print("Starting the walk at: {} ...".format(", ".join(args.dirs)))
    write_log("[INFO] Starting the walk at: {}".format(", ".join(args.dirs)))

    # Count files for progress reporting
    if progress_enabled:
        num_total = count_files(args.dirs)
        print("[INFO] Found {} files to process".format(num_total))
        progress_last_time = time.time()

    # Send collection begin marker (retry once on failure)
    scan_id = collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.source or socket.gethostname(), "0.1",
        "begin",
        ca_cert=args.ca_cert,
    )
    if not scan_id:
        print("[WARN] Begin marker failed, retrying in 2s...", file=sys.stderr)
        time.sleep(2)
        scan_id = collection_marker(
            args.server, args.port, args.tls, args.insecure,
            args.source or socket.gethostname(), "0.1",
            "begin",
            ca_cert=args.ca_cert,
        )
    if scan_id:
        print("[INFO] Collection scan_id: {}".format(scan_id))
        sep = "&" if "?" in api_endpoint else "?"
        api_endpoint = "{}{}scan_id={}".format(api_endpoint, sep, quote(scan_id))

    # Register signal handlers for graceful interruption
    def handle_signal(signum, frame):
        sig_name = "SIGINT" if signum == 2 else "SIGTERM"
        print("\n[WARN] Received {} — sending interrupted marker...".format(sig_name))
        elapsed = int(time.time() - start_time)
        collection_marker(
            args.server, args.port, args.tls, args.insecure,
            args.source or socket.gethostname(), "0.1",
            "interrupted",
            scan_id=scan_id,
            stats={
                "scanned": num_processed,
                "submitted": num_submitted,
                "failed": num_failed,
                "elapsed_seconds": elapsed,
            },
            reason="signal",
            ca_cert=args.ca_cert,
        )
        sys.exit(128 + signum)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    for walkdir in args.dirs:
        process_dir(walkdir)

    # Send collection end marker with stats
    end_date = time.time()
    elapsed = int(end_date - start_time)
    minutes = elapsed // 60
    collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.source or socket.gethostname(), "0.1",
        "end",
        scan_id=scan_id,
        stats={
            "scanned": num_processed,
            "submitted": num_submitted,
            "failed": num_failed,
            "elapsed_seconds": elapsed,
        },
        ca_cert=args.ca_cert,
    )

    print("Thunderstorm Collector Run finished (Checked: {} Submitted: {} Failed: {} Minutes: {})".format(
        num_processed, num_submitted, num_failed, minutes
    ))
    write_log("[INFO] Run finished: processed={} submitted={} failed={} elapsed={}m".format(
        num_processed, num_submitted, num_failed, minutes))
    log_close()

    # Exit codes: 0=clean, 1=partial failure, 2=fatal
    if num_failed > 0:
        sys.exit(1)
