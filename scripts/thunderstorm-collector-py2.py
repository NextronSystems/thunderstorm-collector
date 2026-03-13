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
hard_skips = set(
    os.path.normpath(p) for p in [
        "/proc", "/dev", "/sys", "/run",
        "/snap", "/.snapshots",
        "/sys/kernel/debug", "/sys/kernel/slab", "/sys/kernel/tracing",
    ]
)

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


def is_cloud_path(filepath):
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
current_date = time.time()

# Stats
num_submitted = 0
num_processed = 0
num_failed = 0

# Path+query to use for submission (just the path portion, not full URL)
api_endpoint = None

# scan_id for collection markers
scan_id = None

# Whether we were interrupted
interrupted = False

# Original args — use a namespace with defaults so signal_handler won't crash
# if triggered before argparse runs
class _DefaultArgs(object):
    server = "localhost"
    port = 8080
    tls = False
    insecure = False
    ca_cert = None
    source = None
    debug = False

args = _DefaultArgs()

# Progress reporting
progress_enabled = None  # None = auto-detect TTY


def make_connection(server, port, use_tls, insecure, ca_cert=None, timeout=30):
    """Create an HTTP(S) connection with proper TLS settings."""
    if use_tls:
        if insecure:
            if hasattr(ssl, '_create_unverified_context'):
                context = ssl._create_unverified_context()
            else:
                context = None  # pre-2.7.9: no verification by default
        else:
            if hasattr(ssl, 'create_default_context'):
                context = ssl.create_default_context()
                if ca_cert:
                    context.load_verify_locations(ca_cert)
            else:
                if ca_cert:
                    print_stderr("[ERROR] Python runtime lacks ssl.create_default_context(); "
                                 "cannot enforce --ca-cert verification.")
                    sys.exit(2)
                context = None  # pre-2.7.9: limited TLS, no SNI
        if context is not None:
            conn = httplib.HTTPSConnection(server, port, context=context, timeout=timeout)
        else:
            conn = httplib.HTTPSConnection(server, port, timeout=timeout)
    else:
        conn = httplib.HTTPConnection(server, port, timeout=timeout)
    return conn


def print_stderr(msg):
    """Print error messages to stderr."""
    if progress_enabled:
        sys.stderr.write("\r" + " " * 80 + "\r")
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def show_progress(current, filepath):
    """Show progress indicator if enabled."""
    if not progress_enabled:
        return
    # We don't know total ahead of time, so show count
    display_path = filepath[-60:] if len(filepath) > 60 else filepath
    try:
        sys.stderr.write("\r[{0} scanned] Processing: {1} ...{2}".format(
            current, display_path, " " * 10))
        sys.stderr.flush()
    except (UnicodeEncodeError, UnicodeDecodeError):
        # Skip progress display for paths with encoding issues
        pass


def send_interrupted_marker():
    """Send an interrupted collection marker with current stats."""
    global interrupted
    if interrupted:
        return
    interrupted = True
    end_date = time.time()
    elapsed = int(end_date - current_date)
    collection_marker(
        args.server, args.port, args.tls, args.insecure,
        getattr(args, 'ca_cert', None),
        args.source or socket.gethostname(), "0.1",
        "interrupted",
        scan_id=scan_id,
        stats={
            "scanned": num_processed,
            "submitted": num_submitted,
            "failed": num_failed,
            "elapsed_seconds": elapsed,
        }
    )


def signal_handler(signum, frame):
    """Handle SIGINT/SIGTERM gracefully."""
    if interrupted:
        # Already handling a signal; avoid re-entrance
        sys.exit(1)
    # Ignore further signals while we clean up
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    sig_name = "SIGINT" if signum == signal.SIGINT else "SIGTERM"
    print_stderr("\n[INFO] Received {}, sending interrupted marker...".format(sig_name))
    try:
        send_interrupted_marker()
    except Exception as e:
        print_stderr("[ERROR] Failed to send interrupted marker: {}".format(e))
    if progress_enabled:
        sys.stderr.write("\n")
    print("Thunderstorm Collector Run interrupted (Checked: {} Submitted: {} Failed: {})".format(
        num_processed, num_submitted, num_failed
    ))
    sys.exit(1)


def process_dir(workdir):
    global num_processed

    # Skip if the workdir itself is in hard_skips
    if os.path.normpath(workdir) in hard_skips:
        if args.debug:
            print("[DEBUG] Skipping hard-skipped directory {}".format(workdir))
        return

    for dirpath, dirnames, filenames in os.walk(workdir, followlinks=False):
        # Hard skip directories (modify in-place to prevent descent)
        filtered = []
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if os.path.normpath(full) in hard_skips:
                continue
            if os.path.islink(full):
                continue
            if is_cloud_path(full):
                continue
            filtered.append(d)
        dirnames[:] = filtered

        for name in filenames:
            filepath = os.path.join(dirpath, name)

            try:
                # Skip symlinks
                if os.path.islink(filepath):
                    continue
            except (OSError, IOError):
                continue

            if args.debug:
                print("[DEBUG] Checking {} ...".format(filepath))

            # Count
            num_processed += 1

            # Show progress
            show_progress(num_processed, filepath)

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
                print("[DEBUG] Skipping file due to configured skip_file exclusion {}".format(filepath))
            return True

    # Size (max_size_kb is in KB)
    try:
        file_size = os.path.getsize(filepath)
        mtime = os.path.getmtime(filepath)
    except (OSError, IOError):
        if args.debug:
            print_stderr("[DEBUG] Skipping unreadable file {}".format(filepath))
        return True

    if file_size > max_size_kb * 1024:
        if args.debug:
            print("[DEBUG] Skipping file due to size {}".format(filepath))
        return True

    # Age (max_age=0 means no age filtering)
    if max_age > 0 and mtime < current_date - (max_age * 86400):
        if args.debug:
            print("[DEBUG] Skipping file due to age {}".format(filepath))
        return True

    return False


def submit_sample(filepath):
    global num_submitted, num_failed

    if dry_run:
        print("[DRY-RUN] Would submit {} ...".format(filepath))
        num_submitted += 1
        return

    print("[SUBMIT] Submitting {} ...".format(filepath))

    if not api_endpoint:
        print_stderr("[ERROR] API endpoint not configured; cannot submit.")
        num_failed += 1
        return

    HARD_MAX_BYTES = 200 * 1024 * 1024

    boundary = str(uuid.uuid4())

    # Sanitize filename for multipart header safety.
    # Keep full client path in multipart filename for parity with other collectors.
    safe_filename = filepath
    # Remove/replace characters unsafe for Content-Disposition header
    for ch in ['"', ';', '\r', '\n', '\x00', '\t']:
        safe_filename = safe_filename.replace(ch, '_')
    # Ensure filename is not empty after sanitization
    if not safe_filename or safe_filename.strip('.') == '':
        safe_filename = 'unnamed_file'

    hostname = socket.gethostname()
    source = args.source or hostname

    # Build multipart preamble and epilogue (metadata + file header/footer)
    # In Python 2, keep everything as byte strings to avoid UnicodeDecodeError
    # when hostname or filepath contains non-ASCII bytes.
    boundary_bytes = boundary.encode('ascii') if isinstance(boundary, unicode) else boundary

    def _form_field(name, value):
        if isinstance(value, unicode):
            value = value.encode('utf-8', 'replace')
        elif not isinstance(value, bytes):
            value = str(value)
        part = b"--" + boundary_bytes + b"\r\n"
        part += b"Content-Disposition: form-data; name=\"" + name.encode('ascii') + b"\"\r\n\r\n"
        part += value + b"\r\n"
        return part

    preamble = b""
    preamble += _form_field("hostname", hostname)
    preamble += _form_field("source", source)
    preamble += _form_field("filename", filepath)

    safe_filename_bytes = safe_filename.encode('utf-8', 'replace') if isinstance(safe_filename, unicode) else safe_filename
    file_header = b"--" + boundary_bytes + b"\r\n"
    file_header += b"Content-Disposition: form-data; name=\"file\"; filename=\"" + safe_filename_bytes + b"\"\r\n"
    file_header += b"Content-Type: application/octet-stream\r\n\r\n"
    preamble += file_header

    epilogue = b"\r\n--" + boundary_bytes + b"--\r\n"

    # Read entire file into memory (capped at HARD_MAX_BYTES) so we know the exact
    # length before sending, avoiding Content-Length mismatches if the file changes.
    try:
        with open(filepath, "rb") as f:
            file_data = f.read(HARD_MAX_BYTES + 1)
    except (OSError, IOError) as e:
        print_stderr("[ERROR] Could not read '{}' - {}".format(filepath, e))
        num_failed += 1
        return

    if len(file_data) > HARD_MAX_BYTES:
        print_stderr("[ERROR] File '{}' exceeds hard size limit (>{}B)".format(
            filepath, HARD_MAX_BYTES))
        num_failed += 1
        return

    if len(file_data) == 0:
        if args.debug:
            print("[DEBUG] Skipping empty file {}".format(filepath))
        return

    content_length = len(preamble) + len(file_data) + len(epilogue)

    headers = {
        "Content-Type": "multipart/form-data; boundary={}".format(boundary),
        "Content-Length": str(content_length),
    }

    attempt = 0
    max_retry_after = 300  # Cap Retry-After at 5 minutes
    while attempt < retries:
        conn = None
        resp = None
        try:
            conn = make_connection(args.server, args.port, args.tls, args.insecure,
                                   getattr(args, 'ca_cert', None))
            conn.putrequest("POST", api_endpoint)
            for hdr, val in headers.items():
                conn.putheader(hdr, val)
            conn.endheaders()

            # Send: preamble
            conn.send(preamble)

            # Send: file data
            conn.send(file_data)

            # Send: epilogue
            conn.send(epilogue)

            resp = conn.getresponse()
            resp.read()  # Drain response body to allow connection reuse

        except Exception as e:
            print_stderr("[ERROR] Could not submit '{}' - {}".format(filepath, e))
            attempt += 1
            if attempt < retries:
                backoff = min(2 ** attempt, 60)
                time.sleep(backoff)
            continue
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass

        if resp is None:
            attempt += 1
            continue

        if resp.status == 503:
            attempt += 1
            if attempt >= retries:
                print_stderr("[ERROR] Server busy after {} attempts, giving up on '{}'".format(retries, filepath))
                break
            retry_after = resp.getheader("Retry-After", "30")
            try:
                retry_time = min(int(retry_after), max_retry_after)
                if retry_time < 0:
                    retry_time = 30
            except (ValueError, TypeError):
                retry_time = 30
            print_stderr("[WARN] Server busy (503), retrying after {}s ...".format(retry_time))
            time.sleep(retry_time)
            continue
        elif 200 <= resp.status < 300:
            num_submitted += 1
            return
        else:
            print_stderr("[ERROR] HTTP return status: {}, reason: {}".format(resp.status, resp.reason))
            attempt += 1
            if attempt < retries:
                backoff = min(2 ** attempt, 60)
                time.sleep(backoff)
            continue

    # All retries exhausted
    num_failed += 1


def collection_marker(server, port, use_tls, insecure, ca_cert, source, collector_version, marker_type, scan_id=None, stats=None):  # noqa: E501
    """POST a begin/end/interrupted collection marker to /api/collection.
    Returns a tuple (scan_id, success). scan_id may be None even on success.
    For 'begin' markers, retries once after 2s on failure."""
    body = {
        "type": marker_type,
        "source": source,
        "hostname": socket.gethostname(),
        "collector": "python2/{}".format(collector_version),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if scan_id:
        body["scan_id"] = scan_id
    if stats:
        body["stats"] = stats

    max_attempts = 2 if marker_type == "begin" else 1

    for attempt in range(max_attempts):
        conn = None
        try:
            conn = make_connection(server, port, use_tls, insecure, ca_cert, timeout=10)
            payload = json.dumps(body)
            conn.request("POST", "/api/collection", body=payload,
                         headers={"Content-Type": "application/json"})
            resp = conn.getresponse()
            resp_body = resp.read()
        except Exception as e:
            if attempt < max_attempts - 1:
                print_stderr("[WARN] Collection marker '{}' failed: {}, retrying in 2s...".format(marker_type, e))
                time.sleep(2)
                continue
            else:
                print_stderr("[ERROR] Collection marker '{}' failed: {}".format(marker_type, e))
                return (None, False)
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass

        if 200 <= resp.status < 300:
            if resp_body and resp_body.strip():
                try:
                    data = json.loads(resp_body)
                    return (data.get("scan_id"), True)
                except (ValueError, TypeError):
                    if marker_type == "begin":
                        print_stderr("[WARN] Collection marker 'begin' returned non-JSON 200 response")
                    return (None, True)
            else:
                return (None, True)
        else:
            if resp.status in (404, 501):
                print_stderr("[WARN] Collection marker '{}' not supported (HTTP {}) — continuing without scan_id".format(
                    marker_type, resp.status))
                return ("", True)
            print_stderr("[WARN] Collection marker '{}' returned HTTP {}".format(marker_type, resp.status))
            if attempt < max_attempts - 1:
                time.sleep(2)
                continue
            return (None, False)

    return (None, False)  # should never reach here


# Main
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        prog="thunderstorm-collector-py2.py",
        description="Tool to collect files to send to THOR Thunderstorm (Python 2.7 version). Only uses standard library functions.",
    )
    parser.add_argument(
        "-d", "--dirs",
        nargs="+",
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
        "-S", "--source",
        default=None,
        help="Source identifier to be used in the Thunderstorm submission. (Default: hostname)",
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
    parser.add_argument(
        "--ca-cert",
        default=None,
        help="Path to custom CA certificate bundle for TLS verification."
    )
    progress_group = parser.add_mutually_exclusive_group()
    progress_group.add_argument(
        "--progress",
        action="store_true",
        default=False,
        help="Force enable progress reporting."
    )
    progress_group.add_argument(
        "--no-progress",
        action="store_true",
        default=False,
        help="Force disable progress reporting."
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging.")

    args = parser.parse_args()

    # Apply parsed args to module-level config
    max_age = args.max_age
    max_size_kb = args.max_size_kb
    dry_run = args.dry_run
    retries = args.retries
    sync_mode = args.sync

    if max_age < 0:
        print_stderr("[ERROR] --max-age must be non-negative")
        sys.exit(2)
    if max_size_kb <= 0:
        print_stderr("[ERROR] --max-size-kb must be positive")
        sys.exit(2)
    if retries < 1:
        print_stderr("[ERROR] --retries must be at least 1")
        sys.exit(2)

    if args.tls:
        schema = "https"

    # Validate --ca-cert
    if args.ca_cert:
        if not os.path.isfile(args.ca_cert):
            print_stderr("[ERROR] CA certificate file not found: {}".format(args.ca_cert))
            sys.exit(2)

    # Determine progress reporting mode
    if args.progress:
        progress_enabled = True
    elif args.no_progress:
        progress_enabled = False
    else:
        progress_enabled = sys.stderr.isatty()

    # Install signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Build the API path+query (path only, not full URL — httplib needs just the path)
    source_query = ""
    if args.source:
        source_query = "?source={}".format(quote(args.source, safe=''))

    api_path = "/api/check" if sync_mode else "/api/checkAsync"
    api_endpoint = "{}{}".format(api_path, source_query)

    # Full URL for display only
    display_url = "{}://{}:{}{}".format(schema, args.server, args.port, api_endpoint)

    print("=" * 80)
    print("   Python Thunderstorm Collector (Python 2)")
    print("   Florian Roth, Nextron Systems GmbH, 2024")
    print()
    print("=" * 80)
    print("Target Directory: {}".format(", ".join(args.dirs)))
    # Extend hard_skips with mount points of network/special filesystems
    for mp in get_excluded_mounts():
        norm_mp = os.path.normpath(mp)
        hard_skips.add(norm_mp)

    print("Thunderstorm Server: {}".format(args.server))
    print("Thunderstorm Port: {}".format(args.port))
    print("Using API Endpoint: {}".format(display_url))
    print("Maximum Age of Files: {} days".format(max_age))
    print("Maximum File Size: {} KB".format(max_size_kb))
    sorted_skips = sorted(hard_skips)
    print("Excluded directories: {}".format(", ".join(sorted_skips[:10]) + (" ..." if len(sorted_skips) > 10 else "")))
    if args.source:
        print("Source Identifier: {}".format(args.source))
    print()

    print("Starting the walk at: {} ...".format(", ".join(args.dirs)))

    # Send collection begin marker (with single retry on failure)
    scan_id, begin_success = collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.ca_cert,
        args.source or socket.gethostname(), "0.1",
        "begin"
    )
    if not begin_success:
        print_stderr("[ERROR] Failed to establish collection session with server {}:{}. Exiting.".format(
            args.server, args.port))
        sys.exit(2)
    if scan_id:
        print("[INFO] Collection scan_id: {}".format(scan_id))
        # Append scan_id to the endpoint (URL-encoded)
        separator = "&" if "?" in api_endpoint else "?"
        api_endpoint = "{}{}scan_id={}".format(api_endpoint, separator, quote(str(scan_id), safe=''))

    for walkdir in args.dirs:
        if not os.path.isdir(walkdir):
            print_stderr("[WARN] Directory does not exist or is not accessible: {}".format(walkdir))
            continue
        process_dir(walkdir)

    # Clear progress line if needed
    if progress_enabled:
        sys.stderr.write("\r" + " " * 80 + "\r")
        sys.stderr.flush()

    # Send collection end marker with stats
    end_date = time.time()
    elapsed = int(end_date - current_date)
    minutes = elapsed // 60
    _end_scan_id, _end_ok = collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.ca_cert,
        args.source or socket.gethostname(), "0.1",
        "end",
        scan_id=scan_id,
        stats={
            "scanned": num_processed,
            "submitted": num_submitted,
            "failed": num_failed,
            "elapsed_seconds": elapsed,
        }
    )
    if not _end_ok:
        print_stderr("[WARN] Failed to send collection end marker")

    print("Thunderstorm Collector Run finished (Checked: {} Submitted: {} Failed: {} Minutes: {})".format(
        num_processed, num_submitted, num_failed, minutes
    ))

    # Exit codes: 0 = success, 1 = partial failure, 2 = fatal error
    if num_failed > 0:
        sys.exit(1)
    sys.exit(0)
