#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Florian Roth / Nextron Systems
# Standalone collector; keep the paired Python implementation behavior in sync.
from __future__ import print_function

import argparse
import json
import os
import re
import signal
import socket
import ssl
import stat
import sys
import time
import uuid

try:
    import http.client as http_client
    from urllib.parse import quote
except ImportError:
    import httplib as http_client
    from urllib import quote

PYTHON_MAJOR = 2
MIN_VERSION = (2, 7)
VERSION = "0.2"
MAX_RESPONSE = 1024 * 1024
hard_skips = ["/proc", "/dev", "/sys", "/run", "/snap", "/.snapshots"]
skip_elements = [r"^/mnt(?:/|$)", r"\.dat$", r"\.npm", r"\.vmdk$",
                 r"\.vswp$", r"\.nvram$", r"\.vmsd$", r"\.lck$"]
NETWORK_FS_TYPES = set(["nfs", "nfs4", "cifs", "smbfs", "smb3", "sshfs",
                        "fuse.sshfs", "afp", "webdav", "davfs2",
                        "fuse.rclone", "fuse.s3fs"])
SPECIAL_FS_TYPES = set(["proc", "procfs", "sysfs", "devtmpfs", "devpts",
                        "cgroup", "cgroup2", "pstore", "bpf", "tracefs",
                        "debugfs", "securityfs", "hugetlbfs", "mqueue",
                        "autofs", "fusectl", "rpc_pipefs", "nsfs",
                        "configfs", "binfmt_misc", "selinuxfs", "efivarfs"])
CLOUD_DIR_NAMES = set(["onedrive", "dropbox", ".dropbox", "googledrive",
                      "google drive", "icloud drive", "iclouddrive",
                      "nextcloud", "owncloud", "mega", "megasync",
                      "tresorit", "tresorit drive", "syncthing"])

try:
    text_type = unicode
except NameError:
    text_type = str


def _text(value):
    if isinstance(value, text_type):
        return value
    return value.decode("utf-8", "replace")


def _bytes(value):
    if isinstance(value, text_type):
        return value.encode("utf-8", "surrogateescape" if sys.version_info[0] == 3 else "replace")
    return value


def log(message):
    # Terminal encodings must not turn an unusual filename into a fatal error.
    data = _text(message) + "\n"
    encoded = data.encode(getattr(sys.stderr, "encoding", None) or "utf-8", "backslashreplace")
    if sys.version_info[0] == 3:
        sys.stderr.write(encoded.decode(getattr(sys.stderr, "encoding", None) or "utf-8"))
    else:
        sys.stderr.write(encoded)
    sys.stderr.flush()


def _decode_proc_mount_path(path):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), path)


def get_excluded_mounts():
    excluded = []
    try:
        with open("/proc/mounts", "r") as stream:
            for line in stream:
                fields = line.split()
                if len(fields) >= 3 and fields[2] in NETWORK_FS_TYPES | SPECIAL_FS_TYPES:
                    excluded.append(_decode_proc_mount_path(fields[1]))
    except (IOError, OSError):
        pass
    return excluded


def is_under_excluded(path):
    path = os.path.normpath(path)
    return any(path == p or path.startswith(p.rstrip(os.sep) + os.sep) for p in hard_skips)


def is_cloud_path(path):
    normalized = _text(path).replace("\\", "/").lower()
    return ("/library/cloudstorage" in normalized or
            any(part in CLOUD_DIR_NAMES or part.startswith(("onedrive - ", "onedrive-", "nextcloud-"))
                for part in normalized.split("/")))


def _build_multipart_preamble(boundary, filepath):
    name = _bytes(filepath).replace(b"\\", b"/")
    for char in (b'"', b";", b"\r", b"\n", b"\x00", b"\t"):
        name = name.replace(char, b"_")
    return (b"--" + _bytes(boundary) +
            b'\r\nContent-Disposition: form-data; name="file"; filename="' +
            name + b'"\r\nContent-Type: application/octet-stream\r\n\r\n')


def read_response(response):
    body = response.read(MAX_RESPONSE + 1)
    if len(body) > MAX_RESPONSE:
        raise ValueError("response exceeds 1 MiB limit")
    length = response.getheader("Content-Length")
    if length is not None and (not length.isdigit() or int(length) != len(body)):
        raise ValueError("incomplete or invalid Content-Length response")
    return body


class Collector(object):
    def __init__(self, args):
        self.args = args
        self.started_at = time.time()
        self.scanned = self.submitted = self.failed = self.skipped = self.scan_errors = 0
        self.scan_id = None
        self.started = False
        self.in_flight = None
        self.context = None
        if args.tls:
            if args.insecure:
                if hasattr(ssl, "_create_unverified_context"):
                    self.context = ssl._create_unverified_context()
            elif not hasattr(ssl, "create_default_context"):
                raise ValueError("runtime cannot verify TLS; upgrade it or explicitly use --insecure")
            else:
                self.context = ssl.create_default_context(cafile=args.ca_cert)

    def connection(self, timeout):
        if self.args.tls:
            if self.context is not None:
                return http_client.HTTPSConnection(self.args.server, self.args.port,
                                                  context=self.context, timeout=timeout)
            return http_client.HTTPSConnection(self.args.server, self.args.port, timeout=timeout)
        return http_client.HTTPConnection(self.args.server, self.args.port, timeout=timeout)

    def stats(self):
        result = dict(scanned=self.scanned, submitted=self.submitted, failed=self.failed,
                      skipped=self.skipped, scan_errors=self.scan_errors,
                      elapsed_seconds=int(time.time() - self.started_at))
        if self.in_flight is not None:
            result["in_flight"] = _text(self.in_flight)
        return result

    def marker(self, kind):
        if self.args.dry_run:
            return True
        payload = dict(type=kind, source=self.args.source,
                       hostname=_text(socket.gethostname()),
                       collector="python{}/{}".format(PYTHON_MAJOR, VERSION),
                       timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        if self.scan_id:
            payload["scan_id"] = self.scan_id
        if kind != "begin":
            payload["stats"] = self.stats()
        attempts = 2 if kind == "begin" else 1
        for attempt in range(attempts):
            connection = None
            try:
                connection = self.connection(10)
                connection.request("POST", "/api/collection",
                                   body=json.dumps(payload).encode("utf-8"),
                                   headers={"Content-Type": "application/json"})
                response = connection.getresponse()
                body = read_response(response)
                if response.status in (404, 501):
                    log("[WARN] Collection markers unsupported (HTTP {})".format(response.status))
                    return True
                if 200 <= response.status < 300:
                    if kind == "begin":
                        try:
                            data = json.loads(body.decode("utf-8"))
                            value = data.get("scan_id") if isinstance(data, dict) else None
                            if isinstance(value, text_type) and value:
                                self.scan_id = value
                        except (ValueError, UnicodeError):
                            pass
                    return True
                raise ValueError("HTTP {}".format(response.status))
            except (IOError, OSError, ValueError, http_client.HTTPException) as error:
                log("[ERROR] Collection {}: {}".format(kind, error))
            finally:
                if connection is not None:
                    connection.close()
            if attempt + 1 < attempts:
                time.sleep(2)
        return False

    def interrupted(self, signum, frame):
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        log("[WARN] Collection interrupted")
        if self.started and not self.args.dry_run:
            self.marker("interrupted")
        raise SystemExit(1)

    def traversal_error(self, error):
        self.scan_errors += 1
        log("[ERROR] Cannot traverse: {}".format(error))

    def excluded(self, path):
        return is_under_excluded(path) or is_cloud_path(path)

    def eligible(self, metadata):
        return (metadata.st_size <= self.args.max_size_kb * 1024 and
                (self.args.max_age == 0 or
                 metadata.st_mtime >= self.started_at - self.args.max_age * 86400))

    def snapshot(self, path, expected):
        # Read before connecting. A short read or changed file cannot become a 2xx success.
        flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NONBLOCK", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or (before.st_dev, before.st_ino) != (expected.st_dev, expected.st_ino):
                raise ValueError("file replaced or no longer regular")
            if not self.eligible(before):
                return None
            data = stream.read(self.args.max_size_kb * 1024 + 1)
            after = os.fstat(stream.fileno())
            if (len(data) != before.st_size or before.st_size != after.st_size or
                    before.st_mtime != after.st_mtime):
                raise ValueError("file changed while reading")
            return data

    def upload(self, path, metadata):
        if self.args.dry_run:
            log("[DRY-RUN] Would submit {}".format(_text(path)))
            self.submitted += 1
            return
        self.in_flight = path
        try:
            data = self.snapshot(path, metadata)
        except (IOError, OSError, ValueError) as error:
            log("[ERROR] Cannot read {}: {}".format(_text(path), error))
            self.failed += 1
            self.in_flight = None
            return
        if data is None:
            self.skipped += 1
            self.in_flight = None
            return
        boundary = uuid.uuid4().hex
        preamble = _build_multipart_preamble(boundary, path)
        epilogue = b"\r\n--" + _bytes(boundary) + b"--\r\n"
        endpoint = "/api/check" if self.args.sync else "/api/checkAsync"
        endpoint += "?source=" + quote(_bytes(self.args.source), safe="")
        if self.scan_id:
            endpoint += "&scan_id=" + quote(_bytes(self.scan_id), safe="")
        headers = {"Content-Type": "multipart/form-data; boundary=" + boundary,
                   "Content-Length": str(len(preamble) + len(data) + len(epilogue))}
        for attempt in range(self.args.retries):
            connection = None
            delay = min(2 ** attempt, 60)
            try:
                connection = self.connection(30)
                connection.putrequest("POST", endpoint)
                for key, value in headers.items():
                    connection.putheader(key, value)
                connection.endheaders()
                connection.send(preamble)
                connection.send(data)
                connection.send(epilogue)
                response = connection.getresponse()
                read_response(response)
                if 200 <= response.status < 300:
                    self.submitted += 1
                    self.in_flight = None
                    return
                if response.status == 503:
                    try:
                        delay = max(0, min(int(response.getheader("Retry-After", "2")), 120))
                    except (ValueError, TypeError):
                        delay = 2
                log("[ERROR] Upload {}: HTTP {}".format(_text(path), response.status))
            except (IOError, OSError, ValueError, http_client.HTTPException) as error:
                log("[ERROR] Upload {}: {}".format(_text(path), error))
            finally:
                if connection is not None:
                    connection.close()
            if attempt + 1 < self.args.retries:
                time.sleep(delay)
        self.failed += 1
        self.in_flight = None

    def walk(self, root):
        if self.excluded(root):
            log("[SKIP] Excluded root {}".format(_text(root)))
            return
        for directory, directories, files in os.walk(root, followlinks=False,
                                                    onerror=self.traversal_error):
            directories[:] = [name for name in directories
                              if not os.path.islink(os.path.join(directory, name)) and
                              not self.excluded(os.path.join(directory, name))]
            for name in files:
                path = os.path.join(directory, name)
                self.scanned += 1
                try:
                    metadata = os.lstat(path)
                except (IOError, OSError) as error:
                    self.failed += 1
                    log("[ERROR] Cannot stat {}: {}".format(_text(path), error))
                    continue
                if (not stat.S_ISREG(metadata.st_mode) or
                        any(re.search(pattern, path) for pattern in skip_elements) or
                        not self.eligible(metadata)):
                    self.skipped += 1
                    continue
                self.upload(path, metadata)
                if self.args.progress:
                    log("[{} examined]".format(self.scanned))

    def run(self):
        roots = []
        for path in self.args.dirs:
            path = os.path.realpath(os.path.abspath(path))
            if not os.path.isdir(path):
                self.scan_errors += 1
                log("[ERROR] Missing or invalid directory {}".format(_text(path)))
            else:
                roots.append(path)
        if not roots:
            return 2
        hard_skips.extend(os.path.normpath(p) for p in get_excluded_mounts())
        signal.signal(signal.SIGINT, self.interrupted)
        signal.signal(signal.SIGTERM, self.interrupted)
        if not self.marker("begin"):
            return 2
        self.started = True
        for root in roots:
            self.walk(root)
        end_ok = self.marker("end")
        log("Thunderstorm Collector Run finished (Checked: {} Submitted: {} Failed: {} "
            "Skipped: {} Scan errors: {} Seconds: {})".format(
                self.scanned, self.submitted, self.failed, self.skipped,
                self.scan_errors, int(time.time() - self.started_at)))
        return 1 if self.failed or self.scan_errors or not end_ok else 0


def main():
    if sys.version_info[0] != PYTHON_MAJOR or sys.version_info[:2] < MIN_VERSION:
        log("[ERROR] Requires Python {}; select the matching collector".format(
            ".".join(str(part) for part in MIN_VERSION)))
        return 2
    parser = argparse.ArgumentParser(description="Standard-library THOR Thunderstorm collector")
    parser.add_argument("-s", "--server", required=True, help="Server hostname or IP, not a URL")
    parser.add_argument("-p", "--port", type=int, default=8080)
    parser.add_argument("-d", "--dirs", "--dir", nargs="+", action="append")
    parser.add_argument("-t", "--tls", action="store_true")
    parser.add_argument("-k", "--insecure", action="store_true")
    parser.add_argument("--ca-cert")
    parser.add_argument("-S", "--source", default=socket.gethostname())
    parser.add_argument("--max-age", type=int, default=14, help="Days; 0 disables age filtering")
    parser.add_argument("--max-size-kb", type=int, default=2048, help="KiB; maximum 204800")
    parser.add_argument("--retries", type=int, default=3, help="Total attempts, including the first")
    parser.add_argument("--sync", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--progress", dest="progress", action="store_true")
    parser.add_argument("--no-progress", dest="progress", action="store_false")
    parser.set_defaults(progress=sys.stderr.isatty())
    args = parser.parse_args()
    args.dirs = [path for group in args.dirs for path in group] if args.dirs else [os.path.abspath(os.sep)]
    args.source = _text(args.source)
    if (not 1 <= args.port <= 65535 or not 0 <= args.max_age <= 36500 or
            not 1 <= args.max_size_kb <= 204800 or not 1 <= args.retries <= 10):
        parser.error("port 1..65535, max-age 0..36500, max-size-kb 1..204800, retries 1..10 required")
    if not args.server or re.search(r"[\s/\x00]", args.server):
        parser.error("--server must be a hostname or IP, not a URL")
    if (args.insecure or args.ca_cert) and not args.tls:
        parser.error("--insecure/--ca-cert require --tls")
    try:
        return Collector(args).run()
    except (IOError, OSError, ValueError, ssl.SSLError) as error:
        log("[ERROR] Configuration or startup: {}".format(error))
        return 2


if __name__ == "__main__":
    sys.exit(main())
