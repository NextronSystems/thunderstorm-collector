#!/usr/bin/env python3

import os
import sys
import time
import getopt
import http.client
import urllib.parse
import re
import uuid

# Configuration
debug = False
targetdir = "/"
server = ""
port = 8080
scheme = "http"
max_age = 14  # in days
max_size = 20  # in megabytes
skip_elements = [r"^\/proc", r"^\/mnt", r"\.dat$", r"\.npm", r"^/vmfs/volumes/"]
hard_skips = ["/proc", "/dev", "/sys"]

# Composed values
api_endpoint = "{}://{}:{}/api/checkAsync".format(scheme, server, port)
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
        if debug:
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
            if debug:
                print(
                    "[DEBUG] Skipping file due to configured skip_file exclusion {}".format(
                        filepath
                    )
                )
            return True

    # Size
    if os.path.getsize(filepath) > max_size * 1024 * 1024:
        if debug:
            print("[DEBUG] Skipping file due to size {}".format(filepath))
        return True

    # Age
    mtime = os.path.getmtime(filepath)
    if mtime < current_date - (max_age * 86400):
        if debug:
            print("[DEBUG] Skipping file due to age {}".format(filepath))
        return True

    return False


def submit_sample(filepath):
    print("[SUBMIT] Submitting {} ...".format(filepath))

    try:
        headers = {
            "Content-Type": "application/octet-stream",
            "Content-Disposition": f"attachment; filename={filepath}",
        }

        with open(filepath, "rb") as f:
            data = f.read()

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

        conn = http.client.HTTPConnection(server, port)
        conn.request("POST", api_endpoint, body=payload, headers=headers)

        resp = conn.getresponse()

        global num_submitted
        num_submitted += 1

        if resp.status != 200:
            print("Error: {}".format(resp.text))

    except Exception as e:
        print("Could not submit '{}' - {}".format(filepath, e))


# Main
if __name__ == "__main__":
    # Parse command line args
    opts, args = getopt.getopt(sys.argv[1:], "d:s:p:", ["debug"])
    for opt, arg in opts:
        if opt in ("-d", "--dir"):
            targetdir = arg
        elif opt in ("-s", "--server"):
            server = arg
        elif opt in ("-p", "--port"):
            port = int(arg)
        elif opt in ("--debug"):
            debug = True

    print("=" * 80)
    print("   Python Thunderstorm Collector")
    print("   Florian Roth, Nextron Systems GmbH, 2024")
    print()
    print("=" * 80)
    print("Target Directory: {}".format(targetdir))
    print("Thunderstorm Server: {}".format(server))
    print("Thunderstorm Port: {}".format(port))
    print("Using API Endpoint: {}".format(api_endpoint))
    print("Maximum Age of Files: {}".format(max_age))
    print("Maximum File Size: {} MB".format(max_size))
    print("Excluded directories: {}".format(", ".join(hard_skips)))
    print()

    print("Starting the walk at: {} ...".format(targetdir))

    # Walk directory
    process_dir(targetdir)

    # End message
    end_date = time.time()
    minutes = int((end_date - current_date) / 60)
    print(
        "Thunderstorm Collector Run finished (Checked: {} Submitted: {} Minutes: {})".format(
            num_processed, num_submitted, minutes
        )
    )
