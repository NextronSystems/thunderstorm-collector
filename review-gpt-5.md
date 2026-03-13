# Code Review: Thunderstorm Collectors
## Model: GPT-5 Codex

## Critical Findings

1. `thunderstorm-collector-ash.sh` (`scripts/thunderstorm-collector-ash.sh:387-390`, `scripts/thunderstorm-collector-ash.sh:464-477`, `scripts/thunderstorm-collector-ash.sh:550-560`)
   Issue: all three ash upload paths (`curl`, `wget`, `nc`) were sending only the `file` part and omitted the `hostname` and `filename` multipart fields.
   Why it matters: this made the POSIX collector diverge from the other implementations and dropped metadata used for audit correlation and path attribution.
   Suggested fix: add `hostname` and `filename` to every multipart encoder. Implemented in this change.

2. `thunderstorm-collector-py2.py` (`scripts/thunderstorm-collector-py2.py:453-455`, `scripts/thunderstorm-collector-py2.py:510-514`)
   Issue: the Python 2 collector treated only HTTP `200` as success for both sample uploads and collection markers.
   Why it matters: even though the local `thunderstormAPI` client and tests expect `200`, hard-coding a single success code is brittle and can cause duplicate submissions if a deployment returns a different successful `2xx` code.
   Suggested fix: accept the full `2xx` range consistently. Implemented in this change.

3. `thunderstorm-collector.ps1` (`scripts/thunderstorm-collector.ps1:744-780`)
   Issue: the PowerShell 3+ upload loop terminated only on HTTP `200`.
   Why it matters: hard-coding a single success code makes the loop needlessly brittle and can resubmit files if a deployment returns a different successful `2xx` code.
   Suggested fix: treat any `2xx` response as success. Implemented in this change.

4. `thunderstorm-collector-ps2.ps1` (`scripts/thunderstorm-collector-ps2.ps1:895-910`)
   Issue: the PowerShell 2 upload loop had the same `200`-only success check.
   Why it matters: it was equally brittle and could resubmit files if a deployment returns a successful non-`200` `2xx` response.
   Suggested fix: treat any `2xx` response as success. Implemented in this change.

5. `thunderstorm-collector.pl` (`scripts/thunderstorm-collector.pl:441-447`)
   Issue: the Perl collector sent the metadata field as `sourcePath` instead of `filename`.
   Why it matters: this broke parity with the server-side field naming expected by the stub server and Thunderstorm itself.
   Suggested fix: rename the field to `filename`. Implemented in this change.

6. `thunderstorm-collector.sh` (`scripts/thunderstorm-collector.sh:72-78`, `scripts/thunderstorm-collector.sh:93-118`, `scripts/thunderstorm-collector.sh:1036-1050`)
   Issue: the Bash collector stored cloud-folder names in a space-delimited string that included multi-word names such as `Google Drive` and `iCloud Drive`.
   Why it matters: the `find` pruning loop split those into separate `Google`, `Drive`, and `iCloud` tokens, which could wrongly exclude unrelated directories with generic names like `Drive`.
   Suggested fix: separate exact single-token names, multi-word names, and prefix patterns before building `find` exclusions. Implemented in this change.

## Cross-Script Inconsistencies

1. `thunderstorm-collector.ps1` (`scripts/thunderstorm-collector.ps1:26-29`, `scripts/thunderstorm-collector.ps1:73-83`) and `thunderstorm-collector-ps2.ps1` (`scripts/thunderstorm-collector-ps2.ps1:26-29`, `scripts/thunderstorm-collector-ps2.ps1:66-74`)
   Issue: both PowerShell collectors still defaulted to `MaxAge=0` and `MaxSize=20 MB`, while the repository documentation and the harmonized collector spec say `14 days` and `2048 KB`.
   Why it matters: operators using PowerShell would silently scan a much larger and older file set than the other collectors.
   Suggested fix: set the PowerShell defaults to `14` days and `2` MB (`2048 KB`) without changing parameter names. Implemented in this change.

## Minor Findings

1. `thunderstorm-collector.ps1` (`scripts/thunderstorm-collector.ps1:28-29`)
   Issue: the PS3 script help text for `.PARAMETER MaxSize` described extensions instead of file size.
   Why it matters: the built-in help output did not match the actual parameter behavior.
   Suggested fix: correct the help text to describe the size limit. Implemented in this change.

## Per-Script Notes

### thunderstorm-collector.sh
- Fixed the cloud-folder pruning bug that could exclude unrelated directories named `Google` or `Drive`.
- No additional correctness or security issues stood out in upload, retry, marker, or cleanup handling.

### thunderstorm-collector-ash.sh
- Fixed missing multipart metadata fields across all upload backends.
- The newline-in-filename limitation remains documented and is consistent with the stated POSIX trade-off.

### thunderstorm-collector.py
- No concrete bugs found that still require changes in the current version.
- The Python 3 collector already handled unreadable files, `Retry-After`, and `2xx` upload success correctly.

### thunderstorm-collector-py2.py
- Fixed `200`-only success handling for uploads and collection markers.
- No additional unambiguous issues remained after that change.

### thunderstorm-collector.pl
- Fixed the multipart metadata field name from `sourcePath` to `filename`.
- The earlier path-walking and retry issues appear to be addressed in the current version.

### thunderstorm-collector.ps1
- Fixed `2xx` async success handling and aligned the default age/size settings with the documented collector defaults.
- No additional transport or marker bugs were justified strongly enough for further edits without Windows runtime testing.

### thunderstorm-collector-ps2.ps1
- Fixed `2xx` async success handling and aligned the default age/size settings with the documented collector defaults.
- The remaining PS2-specific limitations are mostly inherent to the platform and already documented in code comments.

### thunderstorm-collector.bat
- No safe batch-only fix was applied in this pass.
- The script still has documented platform limitations, but I did not find a minimal change I could justify here without risking cmd.exe compatibility regressions.

## Summary

The highest-value defects were protocol mismatches rather than memory-safety bugs: missing multipart metadata in the ash collector, `200`-only success handling in Python 2 and both PowerShell collectors, a mislabeled Perl metadata field, and over-broad cloud-directory pruning in Bash. Those issues were fixed with focused changes that preserve each script's runtime and dependency constraints.
