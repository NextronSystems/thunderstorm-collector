# Code Review: Thunderstorm Collector Scripts

You are performing a **security-focused code review** of 5 collector scripts for THOR Thunderstorm — a file scanning service. These scripts walk directories, find recent files, and upload them via multipart HTTP POST to a Thunderstorm server.

## Scripts to Review

All in `/home/neo/.openclaw/workspace/projects/thunderstorm-collector-review/scripts/`:

1. `thunderstorm-collector-ash.sh` — POSIX sh/ash edition (771 lines)
2. `thunderstorm-collector.sh` — Bash 3+ edition (726 lines)
3. `thunderstorm-collector.pl` — Perl edition (356 lines)
4. `thunderstorm-collector.py` — Python 3.4+ edition (405 lines)
5. `thunderstorm-collector-py2.py` — Python 2.7 edition (382 lines)

## Review Instructions

Read ALL five scripts carefully. Then produce a single review document covering:

### What to Look For
- **Bugs**: Logic errors, off-by-one, race conditions, incorrect control flow
- **Security**: Command injection, path traversal, unsafe temp file handling, credential exposure
- **Correctness**: Does the code do what it claims? Are edge cases handled?
- **Robustness**: Error handling, graceful degradation, resource cleanup
- **Compatibility**: Does each script work on its target platform? (ash=POSIX sh, bash=3+, perl=5.x, py3=3.4+, py2=2.7)
- **Consistency**: Do all 5 scripts behave the same way for the same inputs? Are there behavioral differences that seem unintentional?
- **Cross-script inconsistencies**: Different defaults, different skip lists, different retry logic, different size units

### What NOT to Do
- **Do NOT hallucinate issues.** If the code is correct, say so. False positives are worse than missed findings.
- **Do NOT suggest style preferences** (variable naming, comment style, etc.) unless they cause actual problems.
- **Do NOT report issues you're unsure about.** Only report findings you can justify with specific line references.

### Output Format

Write your findings to `/home/neo/.openclaw/workspace/projects/thunderstorm-collector-review/review-{MODEL}.md` where `{MODEL}` is your model name (e.g., `review-grok.md` or `review-glm5.md`).

Structure:
```markdown
# Code Review: Thunderstorm Collectors
## Model: [your model name]

## Critical Findings
(Bugs, security issues, or correctness problems that could cause real failures)

## Cross-Script Inconsistencies
(Behavioral differences between the 5 scripts that appear unintentional)

## Minor Findings
(Non-critical but worth noting)

## Per-Script Notes
### thunderstorm-collector-ash.sh
### thunderstorm-collector.sh
### thunderstorm-collector.pl
### thunderstorm-collector.py
### thunderstorm-collector-py2.py

## Summary
(Overall assessment)
```

For each finding, include:
- The script name and line number(s)
- What the issue is
- Why it matters
- Suggested fix (if not obvious)

Be thorough but honest. If a script is solid, say so.
