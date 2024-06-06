#!/usr/bin/env python3

import argparse
import http.client
import os
import re
import ssl
import sys
import time
import urllib.parse
import uuid

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


# Functions
def process_dir(workdir):
    startdir = os.getcwd()
    os.chdir(workdir)

    for name in os.listdir("."):
        filepath = os.path.join(workdir, name)

        # Hard skips
        if filepath in hard_skips:
            continue

        # Skip symlinks
        # TODO: revisit on how to upload symlinks to thunderstorm
        if os.path.islink(filepath):
            continue

        # Directory
        if os.path.isdir(filepath):
            process_dir(filepath)
            continue

        # File
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

    os.chdir(startdir)


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
        "Content-Disposition": f"attachment; filename={filepath}",
    }

    try:

        with open(filepath, "rb") as f:
            data = f.read()

    except Exception as e:
        print("[ERROR] Could not read '{}' - {}".format(filepath, e))
        return

    boundary = str(uuid.uuid4())
    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }

    # Create multipart/form-data payload
    payload = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filepath}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode("utf-8")
    payload += data
    payload += f"\r\n--{boundary}--\r\n".encode("utf-8")

    retries = 0
    while retries < 3:
        try:
            if args.tls:
                if args.insecure:
                    context = ssl._create_unverified_context()
                else:
                    context = ssl._create_default_https_context()
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

        if resp.status == 503: # Service unavailable
            retry_time = resp.headers.get("Retry-After", 30)
            time.sleep(retry_time)
            continue
        elif resp.status == 200:
            break
        print(
            "[ERROR] HTTP return status: {}, reason: {}".format(
                resp.status, resp.reason
            )
        )

    global num_submitted
    num_submitted += 1


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
        default="/",
        help="Directories that should be scanned. (Default: /)",
    )
    parser.add_argument(
        "-s", "--server", required=True, help="FQDN/IP of the THOR Thunderstorm server."
    )
    parser.add_argument(
        "-p", "--port", help="Port of the THOR Thunderstorm server. (Default: 8080)"
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
    parser.add_argument("--debug", action="store_true", help="Enable debug logging.")

    global args
    args = parser.parse_args()

    if args.tls:
        schema = "https"

    global api_endpoint
    api_endpoint = "{}://{}:{}/api/checkAsync".format(schema, args.server, args.port)

    print("=" * 80)
    print("   Python Thunderstorm Collector")
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
    print()

    print("Starting the walk at: {} ...".format(", ".join(args.dirs)))

    # Walk directory
    for dir in args.dirs:
        process_dir(dir)

    # End message
    end_date = time.time()
    minutes = int((end_date - current_date) / 60)
    print(
        "Thunderstorm Collector Run finished (Checked: {} Submitted: {} Minutes: {})".format(
            num_processed, num_submitted, minutes
        )
    )
