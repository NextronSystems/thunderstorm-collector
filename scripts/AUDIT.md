# Script Collector Audit — Bugs, Inconsistencies & Hardening Opportunities

Audit of all four script collectors against the bash collector (`script-robustness` branch)
and the Go collector as reference implementation.

---

## 🔴 Bugs

### 1. Python: `source` parameter not URL-encoded
**File:** `thunderstorm-collector.py`, line ~148
```python
source = f"?source={args.source}"
```
**Impact:** Source names with spaces, `&`, `#`, or other URL-special characters will corrupt the
query string or silently truncate the source value at the server.

**Compare:** The bash collector has `urlencode()`, the Go collector uses `url.QueryEscape()`,
PowerShell uses `[uri]::EscapeDataString()`. Python is the only one missing this.

**Fix:**
```python
from urllib.parse import quote
source = f"?source={quote(args.source)}"
```

---

### 2. Python: `Content-Disposition` filename not sanitized
**File:** `thunderstorm-collector.py`, `submit_sample()`
```python
f'Content-Disposition: form-data; name="file"; filename="{filepath}"\r\n'
```
**Impact:** Filenames containing `"`, `\r`, `\n`, or `;` will break the multipart header,
causing malformed requests or server-side parse errors. The same filepath is inserted raw.

**Compare:** Bash has `sanitize_filename_for_multipart()`. Python and Perl do not sanitize.

**Fix:**
```python
safe = filepath.replace('"', '_').replace(';', '_').replace('\\', '/')
```

---

### 3. Python: `num_submitted` incremented even on failure
**File:** `thunderstorm-collector.py`, `submit_sample()`, line ~100
```python
# Inside the retry loop, after conn.request():
...
global num_submitted
num_submitted += 1   # ← This runs even if all retries failed
```
**Impact:** The final "Submitted" count is inflated — every file that enters `submit_sample()`
is counted, regardless of whether it was actually accepted. Makes monitoring/reporting unreliable.

**Compare:** Bash only increments on `submit_file` returning 0. Go tracks success/failure separately.

**Fix:** Move the increment inside the `elif resp.status == 200: break` branch.

---

### 4. Python: `os.chdir()` in `process_dir()` is dangerous
**File:** `thunderstorm-collector.py`, `process_dir()`
```python
os.chdir(workdir)
...
os.chdir(startdir)
```
**Impact:** `os.chdir()` changes the process-global working directory. If an exception occurs
between the two `chdir()` calls, the CWD is left in an arbitrary directory. Also makes the
function non-thread-safe (though single-threaded currently). If `workdir` disappears mid-walk
(temp files), the function will crash and orphan the CWD.

**Compare:** Bash uses `find -print0` (no chdir). Go uses `filepath.Walk()`. Perl also uses
`chdir()` with the same risk.

**Fix:** Use `os.path.join()` with absolute paths instead of `chdir()`. Or use `os.scandir()`/
`os.walk()` which don't require changing CWD.

---

### 5. Perl: String comparison used for numeric size check
**File:** `thunderstorm-collector.pl`, line ~100
```perl
if ( ( $size / 1024 / 1024 ) gt $max_size ) {
```
**Impact:** `gt` is the string comparison operator, not numeric. This does lexicographic
comparison: `"9" gt "10"` is **true** (because `"9"` > `"1"` lexically). So a 9MB file
would be skipped with `max_size=10`. Files between 1-9 MB would be incorrectly compared
against multi-digit limits.

**Fix:**
```perl
if ( ( $size / 1024 / 1024 ) > $max_size ) {
```

---

### 6. Perl: String comparison for age check
**File:** `thunderstorm-collector.pl`, line ~107
```perl
if ( $mdate lt ( $current_date - ($max_age * 86400) ) ) {
```
**Impact:** Same issue — `lt` is string comparison. Works coincidentally for large epoch
timestamps (since they're all the same length currently), but will break in edge cases
and is semantically wrong.

**Fix:**
```perl
if ( $mdate < ( $current_date - ($max_age * 86400) ) ) {
```

---

### 7. Perl: `source` parameter not URL-encoded
**File:** `thunderstorm-collector.pl`, line ~47
```perl
$source = "?source=$source";
```
**Impact:** Same as Python bug #1. Source names with spaces or special characters corrupt the URL.

**Fix:**
```perl
use URI::Escape;
$source = "?source=" . uri_escape($source);
```
Or without additional module:
```perl
$source =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
$source = "?source=$source";
```

---

### 8. Perl: `num_submitted` incremented even on failure
**File:** `thunderstorm-collector.pl`, `submitSample()`, line ~127
```perl
$num_submitted++;
```
**Impact:** Incremented inside the eval block after `$ua->post()`, but before checking
`$req->is_success`. Also incremented even if the request threw an exception caught by
`eval`. The final count is inflated.

**Fix:** Only increment when `$successful` is true:
```perl
if ($successful) {
    $num_submitted++;
    last;
}
```

---

### 9. Python: `retry_time` from header is a string, passed to `sleep()` without conversion
**File:** `thunderstorm-collector.py`, `submit_sample()`
```python
retry_time = resp.headers.get("Retry-After", 30)
time.sleep(retry_time)
```
**Impact:** `resp.headers.get()` returns a **string** (e.g. `"30"`). `time.sleep()` accepts
a string in Python 3 and will raise `TypeError`. The fallback value `30` is an int and would
work, but the actual header value will crash.

**Fix:**
```python
retry_time = int(resp.headers.get("Retry-After", 30))
```

---

### 10. Python: `--port` has no default value
**File:** `thunderstorm-collector.py`, argparse definition
```python
parser.add_argument("-p", "--port", help="Port of the THOR Thunderstorm server. (Default: 8080)")
```
**Impact:** Despite the help text saying "Default: 8080", no `default=` is set. If `--port`
is omitted, `args.port` is `None`, and the URL becomes `http://server:None/api/checkAsync`.
The HTTP connection will fail with a confusing error.

**Fix:**
```python
parser.add_argument("-p", "--port", type=int, default=8080, ...)
```

---

## 🟡 Inconsistencies Between Collectors

### 11. Filename in multipart: basename vs full path
| Collector | Filename sent |
|-----------|---------------|
| **Bash** (fixed) | Full path (`/usr/sbin/nft`) |
| **Go** | Full path (`filepath.Abs`) |
| **Python** | Full path (but unsanitized) |
| **Perl** | Basename only (LWP::UserAgent default) |
| **PowerShell** | Full path (`$_.FullName`) |
| **Batch** | Relative path (`%%F` from `FOR /R .`) |

The Perl collector uses `LWP::UserAgent->post()` with `[ "file" => [ $filepath ] ]`, but
LWP sends only the basename by default. This means the server audit log loses the original path.

**Fix for Perl:**
```perl
Content => [ "file" => [ $filepath, $filepath ] ],
# Second arg to arrayref is the filename override
```

---

### 12. Max-age defaults vary wildly
| Collector | Default max-age |
|-----------|----------------|
| Bash | 14 days |
| Go | none (all files) |
| Python | 14 days |
| Perl | **3 days** |
| PowerShell | **0** (disabled) |
| Batch | **30 days** |

Not necessarily a bug, but worth harmonizing. A 3-day default in Perl is very aggressive
and will miss most files in forensic scenarios.

---

### 13. Max-size defaults vary
| Collector | Default max-size |
|-----------|-----------------|
| Bash | 2 MB |
| Go | 100 MB |
| Python | 20 MB |
| Perl | 10 MB |
| PowerShell | 20 MB |
| Batch | ~3 MB |

The Go collector is 50x more generous than bash. Forensic users scanning for large
executables may miss files with the script collectors.

---

### 14. Retry behavior varies
| Collector | 503 retry | Error retry | Backoff |
|-----------|-----------|-------------|---------|
| Bash | Yes (Retry-After) | 3 retries, exp backoff | 2×2^n |
| Go | Yes (Retry-After) | 3 retries, exp backoff | 4×2^n |
| Python | Yes (but crashes, bug #9) | 3 retries, exp backoff | 2×2^n |
| Perl | No 503 handling | 4 retries, exp backoff | 2×2^n |
| PowerShell | Yes (Retry-After) | 3 retries, exp backoff | 2×2^n |
| Batch | **No retry at all** | No | No |

**Perl** doesn't handle HTTP 503 at all — it will count a 503 as a "success" because
`$req->is_success` is false but `$num_submitted` is incremented anyway (bug #8), and
it doesn't sleep or retry.

---

## 🔵 Hardening Opportunities

### 15. Python: No validation of CLI arguments
No checks for empty server, invalid port, negative max-age, etc. Contrast with bash
which validates all numeric params.

### 16. Perl: No `--max-age` or `--max-size` CLI flags
These are hardcoded variables (`$max_age = 3`, `$max_size = 10`) with no command-line
override. Users must edit the script to change them.

### 17. Perl: `chdir()` without error recovery
Same as Python bug #4. If `chdir` fails partway through recursion, the CWD is corrupted
for all subsequent operations. The `chdir($startdir) or die` at the end of the loop is
inside the foreach, not a finally/cleanup block.

### 18. Python: `os.listdir()` instead of `os.walk()`
The manual recursion with `os.listdir()` + `os.chdir()` reimplements what `os.walk()` does
safely. Switching would eliminate bug #4 and simplify the code.

### 19. Batch: Fire-and-forget uploads (`START /B curl`)
```batch
START /B curl -F file=@%%F ... -o nul -s ...
```
Uploads run as background processes with output discarded. No error checking, no retry,
no submission count. If the server is down, every upload silently fails.

### 20. PowerShell: Extensions hardcoded in script body, overwriting parameter
```powershell
param( ... [string[]]$Extensions ... )
# Then later in "Presets":
[string[]]$Extensions = @('.asp','.vbs', ...)  # Overwrites the param!
```
The parameter `$Extensions` from the command line is **overwritten** by the preset
assignment on line ~117. Users cannot actually filter by extension via the CLI.

### 21. PowerShell: Infinite retry on 503
```powershell
while ( $($StatusCode) -ne 200 ) {
    ...
    if ( $StatusCode -eq 503 ) {
        # sleeps and retries forever
    }
}
```
There's no retry limit for 503. If the server is permanently overloaded, the collector
hangs on a single file indefinitely. Non-503 errors have a 3-retry limit, but 503 does not.

---

## Summary

| Severity | Count | Collectors affected |
|----------|-------|-------------------|
| 🔴 Bug | 10 | Python (5), Perl (4), PowerShell (1) |
| 🟡 Inconsistency | 4 | All |
| 🔵 Hardening | 7 | Python (3), Perl (2), Batch (1), PowerShell (1) |

### Priority fixes (high impact, low effort):
1. **Python: URL-encode source** — one line
2. **Python: fix port default** — one line
3. **Python: fix Retry-After type** — one line
4. **Perl: `gt`→`>` and `lt`→`<`** — two characters each
5. **Perl: URL-encode source** — one line
6. **Python/Perl: fix submitted count** — move increment
7. **PowerShell: Extensions preset overwrites param** — remove preset or use `if (!$PSBoundParameters.ContainsKey('Extensions'))`
