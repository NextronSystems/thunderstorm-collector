# Documentation Style Guide

Rules for every Markdown page in this repository, whether a person or a coding
agent writes it. The goal: a reader finds the command or decision they need
within the first screen, and the full detail is still there when they look for
it.

## Core Rules

1. **Instruction first, reason second.** Start with what to do. Explain why in
   the next sentence or paragraph, not before.
2. **One idea per paragraph.** Aim for 60 words or fewer. Split anything that
   runs past 80 words.
3. **Lists for conditions and options.** When a sentence has more than two
   "if", "or" or "except" parts, turn it into bullets or a table.
4. **One caveat box per page.** State the validation status once, near the
   top. Do not repeat it in every section.
5. **Evidence lives elsewhere.** User guides link to test evidence. They do not
   contain CI run IDs, commit hashes, checksums or PR numbers.
6. **Detail goes below the task.** Edge cases, limits and internals belong in a
   reference section at the end of the page, not before the quick start.

## Page Structure

### Collector guides

Each guide under `scripts/<language>/`, `go/` and `sftp/` uses this order:

```markdown
# <Name> Collector
One or two sentences: what it is and when to use it.

## Requirements          table: runtime, upload tool, permissions
## Quick Start           dry run, then upload; copy-paste ready
## Common Options        table of the options most users need
## Exit Codes            table
## Behavior Details      reference: filters, TLS, retries, markers, limits
## Limitations           bullets
```

Manual acceptance tests go into a separate `TESTING.md` next to the guide and
are linked from the end of the page.

### Integration and assessment guides

```markdown
# <Product>: <Task>
Scope in two or three sentences, then the caveat box.

## Before You Start      access, licenses, what to prepare
## Steps                 numbered; one action per step
## Verify                how to confirm it worked
## Background            why the steps are as they are; sources
```

### Concept and decision pages

Start with the answer: a recommendation table or a short decision list. Put the
reasoning and comparisons after it.

## Caveats and Validation Status

Write the status once per page in a GitHub alert:

```markdown
> [!NOTE]
> Tested on FreeBSD 8.4 and 14.3 VMs. Not yet tested on NetScaler firmware.
> [Test evidence](evidence/netscaler-freebsd.md)
```

In tables, use a status column with these terms only:

| Term | Meaning |
| --- | --- |
| **Tested** | Run against a real Thunderstorm service on that platform |
| **VM-tested** | Run in a virtual machine with that OS, not on the product itself |
| **Automated** | Covered by CI or the test harness only |
| **Not yet tested** | No recorded result |

Avoid stacking qualifiers such as "does not establish", "remains pending" or
"synthetic files" in running text once the status is stated.

Use `> [!WARNING]` only for something that can cause harm: data loss, disabled
certificate checks, unsupported vendor changes. One per section at most.

## Evidence, History and Dates

- **Test evidence** (artifact IDs, checksums, VM details, CI runs) goes to
  `docs/evidence/<topic>.md`. Cite only public sources or tests recorded in
  this repository.
- **Review history** (PR stacks, review rounds, branch names) stays in pull
  requests and commit messages, not in user guides. Dated reports such as
  `SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md` are archives; mark them as such
  in the first line.
- **Release-specific notes** name the version, not the date: "v1.1.0 includes
  …", not "As of 19 October 2026 …".
- **Dates in prose:** `8 October 2026`. In tables and file names: `2026-10-08`.

## Links and Sources

- Link text says where it goes: `[Bash requirements](...)`, not `[here](...)`.
- Put vendor and reference sources at the end of the section on one line:
  `Sources: [Citrix CTX327915](...) · [FreeBSD cron(8)](...)`.
- Link to a section instead of repeating it. If two pages explain the same
  thing, one of them should link to the other.

## Formatting

- **Bold** a key value or decision word (**64 MiB**, **Recommended**), never a
  whole sentence.
- **Tables** for requirements, options, exit codes and comparisons.
- **`<details>`** for long reference blocks a reader rarely needs: full
  `--help` output, checksum tables, test matrices.

  ```markdown
  <details>
  <summary>Full help output</summary>

  ...

  </details>
  ```

- **Headings:** title case for `#` and `##`, sentence case below.
- **Code blocks** are copy-paste ready and tagged (`sh`, `bash`, `cmd`,
  `powershell`, `yaml`, `text`). Use `thunderstorm.example.internal` as the
  example server.
- **Units:** KiB, MiB, GiB for sizes.

## Before You Merge a Docs Change

- [ ] The first screen shows what the page is for and the first command.
- [ ] No paragraph is longer than 80 words.
- [ ] The validation status appears once, not in every section.
- [ ] No PR numbers, commit hashes or CI run IDs outside `docs/evidence/`.
- [ ] Any new caveat replaces an old one instead of adding to it.
