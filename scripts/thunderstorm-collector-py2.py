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
import os
import re
import socket
import ssl
import time
import uuid
from urllib import quote

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
hard_skips = ["/proc", "/dev", "/sys"]

# Composed values
current_date = time.time()

# Stats
num_submitted = 0
num_processed = 0

# URL to use for submission
api_endpoint = ""

# Original args
args = {}


def process_dir(workdir):
    for dirpath, dirnames, filenames in os.walk(workdir, followlinks=False):
        # Hard skip directories (modify in-place to prevent descent)
        dirnames[:] = [
            d for d in dirnames
            if os.path.join(dirpath, d) not in hard_skips
            and not os.path.islink(os.path.join(dirpath, d))
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
                print("[DEBUG] Skipping file due to configured skip_file exclusion {}".format(filepath))
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

    try:
        with open(filepath, "rb") as f:
            data = f.read()
    except Exception as e:
        print("[ERROR] Could not read '{}' - {}".format(filepath, e))
        return

    boundary = str(uuid.uuid4())

    # Sanitize filename for multipart header safety
    safe_filename = filepath.replace('"', '_').replace(';', '_').replace('\r', '_').replace('\n', '_')

    # Build multipart/form-data payload manually (no external libs)
    payload = (
        "--{boundary}\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
        "Content-Type: application/octet-stream\r\n\r\n"
    ).format(boundary=boundary, filename=safe_filename).encode("utf-8")
    payload += data
    payload += "\r\n--{}--\r\n".format(boundary).encode("utf-8")

    headers = {
        "Content-Type": "multipart/form-data; boundary={}".format(boundary),
    }

    retries = 0
    while retries < 3:
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
                    else:
                        context = None  # pre-2.7.9: limited TLS, no SNI
                if context is not None:
                    conn = httplib.HTTPSConnection(args.server, args.port, context=context)
                else:
                    conn = httplib.HTTPSConnection(args.server, args.port)
            else:
                conn = httplib.HTTPConnection(args.server, args.port)
            conn.request("POST", api_endpoint, body=payload, headers=headers)
            resp = conn.getresponse()

        except Exception as e:
            print("[ERROR] Could not submit '{}' - {}".format(filepath, e))
            retries += 1
            time.sleep(2 << retries)
            continue

        if resp.status == 503:
            retries += 1
            if retries >= 10:
                print("[ERROR] Server busy after 10 retries, giving up on '{}'".format(filepath))
                break
            retry_after = resp.getheader("Retry-After", "30")
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
            print("[ERROR] HTTP return status: {}, reason: {}".format(resp.status, resp.reason))
            retries += 1
            time.sleep(2 << retries)
            continue


# Main
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        prog="thunderstorm-collector-py2.py",
        description="Tool to collect files to send to THOR Thunderstorm (Python 2.7 version). Only uses standard library functions.",
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
        "-S", "--source",
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
    print("   Python Thunderstorm Collector (Python 2)")
    print("   Florian Roth, Nextron Systems GmbH, 2024")
    print()
    print("=" * 80)
    print("Target Directory: {}".format(", ".join(args.dirs)))
    print("Thunderstorm Server: {}".format(args.server))
    print("Thunderstorm Port: {}".format(args.port))
    print("Using API Endpoint: {}".format(api_endpoint))
    print("Maximum Age of Files: {}".format(max_age))
    print("Maximum File Size: {} MB".format(max_size))
    print("Excluded directories: {}".format(", ".join(hard_skips)))
    if args.source:
        print("Source Identifier: {}".format(args.source))
    print()

    print("Starting the walk at: {} ...".format(", ".join(args.dirs)))

    for walkdir in args.dirs:
        process_dir(walkdir)

    end_date = time.time()
    minutes = int((end_date - current_date) / 60)
    print("Thunderstorm Collector Run finished (Checked: {} Submitted: {} Minutes: {})".format(
        num_processed, num_submitted, minutes
    ))
