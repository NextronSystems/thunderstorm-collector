#!/usr/bin/env python3
# Minimum Python version: 3.4 (no f-strings, no 3.6+ features)

import argparse
import http.client
import json
import os
import re
import signal
import ssl
import sys
import time
import uuid
import socket
from urllib.parse import quote

# Configuration
schema = "http"
max_age = 14  # in days (overridden by --max-age)
max_size = 2048  # in KB (overridden by --max-size-kb)
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
num_failed = 0
total_files_estimate = 0
upload_in_flight = None  # Path of file currently being uploaded, or None

# URL to use for submission
api_endpoint = ""

# scan_id at module level for signal handler
scan_id = None

# Original args
args = None

# Progress reporting
show_progress = None  # None = auto-detect TTY


def print_error(msg):
    """Print error messages to stderr."""
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def print_progress(processed, total):
    """Print progress indicator if enabled. Shows files examined (not just submitted)."""
    if not show_progress:
        return
    if total > 0 and processed <= total:
        pct = min(100, int(processed * 100 / total))
        sys.stderr.write("\r[{}/{} examined] {}%".format(processed, total, pct))
        sys.stderr.flush()
    else:
        # Total is zero or processed exceeded estimate; show count only
        sys.stderr.write("\r[{} examined]".format(processed))
        sys.stderr.flush()


def is_under_excluded(path):
    """Check if a normalized path is equal to or under any hard_skips entry."""
    norm = os.path.normpath(path)
    for excluded in hard_skips:
        if norm == excluded or norm.startswith(excluded + os.sep):
            return True
    return False


def should_prune_dir(dirpath, dirname):
    """Determine if a subdirectory should be pruned from traversal."""
    full = os.path.join(dirpath, dirname)
    if os.path.islink(full):
        return True
    if is_under_excluded(full):
        return True
    if is_cloud_path(full):
        return True
    return False


def count_files(dirs):
    """Quick count of files for progress reporting."""
    count = 0
    for d in dirs:
        for dirpath, dirnames, filenames in os.walk(d, followlinks=False):
            dirnames[:] = [
                dn for dn in dirnames
                if not should_prune_dir(dirpath, dn)
            ]
            for name in filenames:
                filepath = os.path.join(dirpath, name)
                if os.path.islink(filepath):
                    continue
                count += 1
    return count

# Functions
def send_interrupted_marker():
    """Send an interrupted collection marker with current stats."""
    global scan_id, num_processed, num_submitted, num_failed, current_date, upload_in_flight
    try:
        end_date = time.time()
        elapsed = int(end_date - current_date)
        stats = {
            "scanned": num_processed,
            "submitted": num_submitted,
            "failed": num_failed,
            "elapsed_seconds": elapsed,
        }
        if upload_in_flight is not None:
            stats["in_flight"] = upload_in_flight
        collection_marker(
            args.server, args.port, args.tls, args.insecure,
            args.source, "0.1",
            "interrupted",
            scan_id=scan_id,
            ca_cert=getattr(args, 'ca_cert', None),
            stats=stats,
        )
    except Exception:
        pass


def signal_handler(signum, frame):
    """Handle SIGINT/SIGTERM: send interrupted marker and exit."""
    print_error("\n[INFO] Signal received, sending interrupted marker...")
    send_interrupted_marker()
    sys.exit(1)


def process_dir(workdir):

    for dirpath, dirnames, filenames in os.walk(workdir, followlinks=False):
        # Hard skip directories (modify in-place to prevent descent)
        dirnames[:] = [
            d for d in dirnames
            if not should_prune_dir(dirpath, d)
        ]

        for name in filenames:
            filepath = os.path.join(dirpath, name)

            # Skip symlinks
            if os.path.islink(filepath):
                continue

            if args.debug:
                print_error("[DEBUG] Checking {} ...".format(filepath))

            # Count
            global num_processed
            num_processed += 1

            # Progress
            print_progress(num_processed, total_files_estimate)

            # Skip files
            skip, file_stat = skip_file(filepath)
            if skip:
                continue

            # Submit
            submit_sample(filepath, file_stat)


def skip_file(filepath):
    """Check if a file should be skipped. Returns (True, None) to skip,
    or (False, stat_result) to process."""
    # Regex skips
    for pattern in skip_elements:
        if re.search(pattern, filepath):
            if args.debug:
                print_error(
                    "[DEBUG] Skipping file due to configured skip_file exclusion {}".format(
                        filepath
                    )
                )
            return True, None

    # Stat the file once to avoid TOCTOU races
    try:
        st = os.stat(filepath)
    except (OSError, IOError):
        if args.debug:
            print_error("[DEBUG] Skipping unreadable file {}".format(filepath))
        return True, None

    file_size = st.st_size
    mtime = st.st_mtime

    # Size (max_size is in KB)
    if file_size > max_size * 1024:
        if args.debug:
            print_error("[DEBUG] Skipping file due to size {}".format(filepath))
        return True, None

    # Age
    if mtime < current_date - (max_age * 86400):
        if args.debug:
            print_error("[DEBUG] Skipping file due to age {}".format(filepath))
        return True, None

    return False, st


def _make_connection(server, port, tls, insecure, ca_cert=None, timeout=30):
    """Create an HTTP(S) connection with proper TLS settings."""
    if tls:
        if insecure:
            context = ssl._create_unverified_context()
        elif ca_cert:
            context = ssl.create_default_context(cafile=ca_cert)
        else:
            context = ssl.create_default_context()
        return http.client.HTTPSConnection(server, port, context=context, timeout=timeout)
    else:
        return http.client.HTTPConnection(server, port, timeout=timeout)


def submit_sample(filepath, file_stat=None):
    global num_submitted, num_failed, upload_in_flight

    if dry_run:
        sys.stderr.write("[DRY-RUN] Would submit {} ...\n".format(filepath))
        num_submitted += 1
        return

    sys.stderr.write("[SUBMIT] Submitting {} ...\n".format(filepath))
    upload_in_flight = filepath

    # Get file size for streaming upload (use cached stat if available)
    if file_stat is not None:
        file_size = file_stat.st_size
    else:
        try:
            file_size = os.path.getsize(filepath)
        except (OSError, IOError) as e:
            print_error("[ERROR] Could not stat '{}' - {}".format(filepath, e))
            num_failed += 1
            upload_in_flight = None
            return

    boundary = str(uuid.uuid4())
    headers = {
        "Content-Type": "multipart/form-data; boundary={}".format(boundary),
    }

    # Sanitize filename for multipart header safety
    safe_filename = filepath.replace('"', '_').replace(';', '_').replace('\r', '_').replace('\n', '_')

    # Build multipart preamble (file field header) and epilogue
    preamble = b""

    # file field header
    preamble += (
        "--{boundary}\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
        "Content-Type: application/octet-stream\r\n\r\n"
    ).format(boundary=boundary, filename=safe_filename).encode("utf-8")

    epilogue = "\r\n--{}--\r\n".format(boundary).encode("utf-8")

    content_length = len(preamble) + file_size + len(epilogue)
    headers["Content-Length"] = str(content_length)

    CHUNK_SIZE = 65536

    attempt = 0
    while attempt < retries:
        resp_status = None
        resp_reason = None
        resp_retry_after = None
        file_fully_sent = False
        try:
            conn = _make_connection(
                args.server, args.port, args.tls, args.insecure,
                ca_cert=getattr(args, 'ca_cert', None)
            )
            conn.putrequest("POST", api_endpoint)
            for hdr_name, hdr_val in headers.items():
                conn.putheader(hdr_name, hdr_val)
            conn.endheaders()
            # Send preamble (metadata fields + file header)
            conn.send(preamble)
            # Stream file content in chunks
            with open(filepath, "rb") as f:
                while True:
                    chunk = f.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    conn.send(chunk)
            # Send epilogue
            conn.send(epilogue)
            file_fully_sent = True
            resp = conn.getresponse()
            # Read response body to allow connection reuse / proper close
            resp.read()
            # Store response info before closing connection
            resp_status = resp.status
            resp_reason = resp.reason
            resp_retry_after = resp.getheader("Retry-After", "30")
        except Exception as e:
            print_error("[ERROR] Could not submit '{}' - {}".format(filepath, e))
            attempt += 1
            if attempt < retries:
                backoff = min(2 ** (attempt - 1), 60)
                time.sleep(backoff)
            continue
        finally:
            try:
                conn.close()
            except Exception:
                pass

        # pylint: disable=no-else-continue
        if resp_status == 503:  # Service unavailable
            attempt += 1
            if attempt >= retries:
                print_error("[ERROR] Server busy after {} retries, giving up on '{}'".format(retries, filepath))
                num_failed += 1
                upload_in_flight = None
                return
            try:
                retry_time = min(int(resp_retry_after), 300)  # Cap at 5 minutes
            except (ValueError, TypeError):
                retry_time = 30
            if retry_time < 0:
                retry_time = 30
            time.sleep(retry_time)
            continue
        elif 200 <= resp_status < 300:
            if file_fully_sent:
                num_submitted += 1
            else:
                print_error("[ERROR] File '{}' was not fully sent but server returned {}".format(filepath, resp_status))
                num_failed += 1
            upload_in_flight = None
            return
        else:
            print_error(
                "[ERROR] HTTP return status: {}, reason: {}".format(
                    resp_status, resp_reason
                )
            )
            attempt += 1
            if attempt < retries:
                backoff = min(2 ** (attempt - 1), 60)
                time.sleep(backoff)
            continue

    # All retries exhausted
    num_failed += 1
    upload_in_flight = None


def collection_marker(server, port, tls, insecure, source, collector_version, marker_type, scan_id=None, stats=None, ca_cert=None, retry_on_fail=False):
    """POST a begin/end/interrupted collection marker to /api/collection.
    Returns the scan_id from the response, or None if unsupported/failed.
    If retry_on_fail is True, retries once after 2s on failure (for begin marker)."""
    body = {
        "type": marker_type,
        "source": source,
        "hostname": socket.gethostname(),
        "collector": "python3/{}".format(collector_version),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    # scan_id: None = failure, "" = success with no id, non-empty = valid id
    if scan_id:
        body["scan_id"] = scan_id
    if stats:
        body["stats"] = stats

    attempts = 2 if retry_on_fail else 1
    for attempt in range(attempts):
        try:
            conn = _make_connection(server, port, tls, insecure, ca_cert=ca_cert, timeout=10)
            payload = json.dumps(body).encode("utf-8")
            conn.request("POST", "/api/collection", body=payload,
                         headers={"Content-Type": "application/json"})
            resp = conn.getresponse()
            resp_body = resp.read().decode("utf-8", errors="replace")
            conn.close()
            if 200 <= resp.status < 300:
                if resp_body.strip():
                    try:
                        data = json.loads(resp_body)
                        return data.get("scan_id", "")
                    except (ValueError, KeyError):
                        # Non-JSON or missing scan_id; acceptable for end/interrupted markers
                        return ""
                else:
                    return ""
            elif resp.status == 503 and attempt < attempts - 1:
                retry_after = None
                # Try to get Retry-After header
                if hasattr(resp, 'getheader'):
                    retry_after = resp.getheader("Retry-After")
                if retry_after:
                    try:
                        wait_time = min(int(retry_after), 300)
                        if wait_time < 0:
                            wait_time = 2
                    except (ValueError, TypeError):
                        wait_time = 2
                else:
                    wait_time = 2
                print_error("[WARN] Collection marker '{}' got 503, retrying in {}s...".format(marker_type, wait_time))
                time.sleep(wait_time)
                continue
            elif (400 <= resp.status < 500) or resp.status == 501:
                # 404/501 = endpoint not supported, continue without scan_id but success
                if resp.status == 404 or resp.status == 501:
                    print_error("[WARN] Collection marker '{}' not supported (HTTP {}) — server does not implement /api/collection".format(
                        marker_type, resp.status))
                    return ""
                # Other client errors (4xx) indicate configuration problems — no retry
                print_error("[ERROR] Collection marker '{}' returned HTTP {}".format(marker_type, resp.status))
                return None
            else:
                # Server errors (5xx other than 503) — retry if retry_on_fail
                if attempt < attempts - 1:
                    print_error("[WARN] Collection marker '{}' returned HTTP {}, retrying in 2s...".format(marker_type, resp.status))
                    time.sleep(2)
                    continue
                else:
                    print_error("[ERROR] Collection marker '{}' returned HTTP {}".format(marker_type, resp.status))
                    return None
        except Exception as e:
            if attempt < attempts - 1:
                print_error("[WARN] Collection marker '{}' failed ({}), retrying in 2s...".format(marker_type, e))
                time.sleep(2)
            else:
                print_error("[ERROR] Collection marker '{}' failed: {}".format(marker_type, e))
                return None
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
        nargs="+",
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
    parser.add_argument(
        "--progress",
        action="store_true",
        dest="progress",
        help="Force enable progress reporting."
    )
    parser.add_argument(
        "--no-progress",
        action="store_false",
        dest="progress",
        help="Force disable progress reporting."
    )
    parser.set_defaults(progress=None)
    parser.add_argument("--debug", action="store_true", help="Enable debug logging.")

    args = parser.parse_args()

    # Resolve source lazily (default to hostname)
    if args.source is None:
        args.source = socket.gethostname()

    # Validate numeric arguments
    if args.retries < 1:
        print_error("[ERROR] --retries must be >= 1, got {}".format(args.retries))
        sys.exit(2)
    if args.max_age < 0:
        print_error("[ERROR] --max-age must be >= 0, got {}".format(args.max_age))
        sys.exit(2)
    if args.max_size_kb < 0:
        print_error("[ERROR] --max-size-kb must be >= 0, got {}".format(args.max_size_kb))
        sys.exit(2)

    # Install signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Apply parsed args to module-level config
    max_age = args.max_age
    max_size = args.max_size_kb
    dry_run = args.dry_run
    retries = args.retries
    sync_mode = args.sync

    if args.tls:
        schema = "https"

    # Determine progress mode
    if args.progress is None:
        show_progress = sys.stderr.isatty()
    else:
        show_progress = args.progress

    source_query = "?source={}".format(quote(args.source))

    api_path = "/api/check" if sync_mode else "/api/checkAsync"
    # api_endpoint is the path+query for http.client (not full URL)
    api_endpoint = "{}{}".format(api_path, source_query)
    display_url = "{}://{}:{}{}".format(schema, args.server, args.port, api_endpoint)

    sys.stderr.write("=" * 80 + "\n")
    sys.stderr.write("   Python Thunderstorm Collector\n")
    sys.stderr.write("   Florian Roth, Nextron Systems GmbH, 2024\n")
    sys.stderr.write("\n")
    sys.stderr.write("=" * 80 + "\n")
    # Normalize existing hard_skips
    hard_skips[:] = [os.path.normpath(p) for p in hard_skips]
    # Extend hard_skips with mount points of network/special filesystems
    for mp in get_excluded_mounts():
        norm_mp = os.path.normpath(mp)
        if norm_mp not in hard_skips:
            hard_skips.append(norm_mp)

    sys.stderr.write("Target Directory: {}\n".format(", ".join(args.dirs)))
    sys.stderr.write("Thunderstorm Server: {}\n".format(args.server))
    sys.stderr.write("Thunderstorm Port: {}\n".format(args.port))
    sys.stderr.write("Using API Endpoint: {}\n".format(display_url))
    sys.stderr.write("Maximum Age of Files: {} days\n".format(max_age))
    sys.stderr.write("Maximum File Size: {} KB\n".format(max_size))
    sys.stderr.write("Excluded directories: {}\n".format(", ".join(hard_skips[:10]) + (" ..." if len(hard_skips) > 10 else "")))
    if args.source:
        sys.stderr.write("Source Identifier: {}\n".format(args.source))
    sys.stderr.write("\n")

    # Validate --ca-cert if provided
    if args.ca_cert and not os.path.isfile(args.ca_cert):
        print_error("[ERROR] CA certificate file not found: {}".format(args.ca_cert))
        sys.exit(2)

    # Validate that all requested directories exist
    valid_dirs = []
    for d in args.dirs:
        if not os.path.exists(d):
            print_error("[ERROR] Directory does not exist: {}".format(d))
        elif not os.path.isdir(d):
            print_error("[ERROR] Path is not a directory: {}".format(d))
        else:
            valid_dirs.append(d)
    if not valid_dirs:
        print_error("[ERROR] No valid directories to scan.")
        sys.exit(2)
    if len(valid_dirs) < len(args.dirs):
        print_error("[WARN] Some directories were invalid and will be skipped.")
    args.dirs = valid_dirs

    sys.stderr.write("Starting the walk at: {} ...\n".format(", ".join(args.dirs)))

    # Count files for progress reporting
    if show_progress:
        sys.stderr.write("Counting files for progress reporting...\n")
        total_files_estimate = count_files(args.dirs)
        sys.stderr.write("Estimated files to check: {}\n".format(total_files_estimate))

    # Send collection begin marker (with single retry on failure)
    scan_id = collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.source, "0.1",
        "begin",
        ca_cert=args.ca_cert,
        retry_on_fail=True
    )
    # scan_id: None = failure (fatal), "" = success but no id returned, non-empty = valid id
    if scan_id is None:
        print_error("[ERROR] Failed to send begin collection marker. Cannot reach Thunderstorm server.")
        sys.exit(2)
    if scan_id:
        sys.stderr.write("[INFO] Collection scan_id: {}\n".format(scan_id))
        # Append scan_id to api_endpoint
        if "?" in api_endpoint:
            api_endpoint = "{}&scan_id={}".format(api_endpoint, quote(scan_id))
        else:
            api_endpoint = "{}?scan_id={}".format(api_endpoint, quote(scan_id))

    # Walk directory
    for walkdir in args.dirs:
        process_dir(walkdir)

    # Clear progress line if needed
    if show_progress and total_files_estimate > 0:
        sys.stderr.write("\r" + " " * 40 + "\r")
        sys.stderr.flush()

    # Send collection end marker with stats
    end_date = time.time()
    elapsed = int(end_date - current_date)
    minutes = elapsed // 60
    collection_marker(
        args.server, args.port, args.tls, args.insecure,
        args.source, "0.1",
        "end",
        scan_id=scan_id,
        ca_cert=args.ca_cert,
        stats={
            "scanned": num_processed,
            "submitted": num_submitted,
            "failed": num_failed,
            "elapsed_seconds": elapsed,
        }
    )

    sys.stderr.write(
        "Thunderstorm Collector Run finished (Checked: {} Submitted: {} Failed: {} Minutes: {})\n".format(
            num_processed, num_submitted, num_failed, minutes
        )
    )

    # Exit codes: 0 = success, 1 = partial failure (some uploads failed), 2 = fatal
    if num_failed > 0:
        sys.exit(1)
    sys.exit(0)
