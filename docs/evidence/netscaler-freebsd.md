# NetScaler and FreeBSD Test Evidence

This page records the test evidence for the dedicated **`amd64-freebsd8-netscaler`**
Go collector, built with Go 1.9.7 for Citrix NetScaler appliances on
FreeBSD 8.4/amd64. It identifies the exact artifact that was tested, the VM
environments and the results, so that the status shown in the
[Go collector guide](../../go/README.md#citrix-netscaler-and-freebsd-84) can be
traced. Add future OS or appliance results and their artifact identities here,
so that this evidence stays in one place.

## Compatibility Evidence as of 2026-10-08

| Evidence level | Status for the dedicated legacy build |
| --- | --- |
| Compilation for freebsd/amd64 with Go 1.9.7 | Verified, including static FreeBSD ELF, architecture, executable permissions, package contents and checksums |
| Shared source/runtime on Linux/amd64 with Go 1.9.7 | Automated Go tests and synthetic HTTP checks verified; these do not execute the FreeBSD binary |
| Runtime on FreeBSD 8.4-RELEASE amd64 | Reported successful in a KVM/QEMU VM without a workaround; 253 files uploaded with zero errors |
| Runtime on FreeBSD 14.3-RELEASE amd64 | Reported successful in a KVM/QEMU VM with per-process ASLR disabled; 302 files uploaded with zero errors |
| Runtime on a named NetScaler appliance/firmware | Not yet tested; the VM results do not establish appliance/firmware compatibility |

FreeBSD 8.4 is the target of the dedicated binary. FreeBSD 14.3 is a VM test
environment for the same binary, not a boundary between legacy and recent
NetScaler firmware. The two tests do not establish a supported range from 8.4
through 14.3. Intermediate versions need the same environment checks; the
absence of a test does not itself establish incompatibility.

## How the FreeBSD Binaries Were Tested

The [external test report on PR #51](https://github.com/NextronSystems/thunderstorm-collector/pull/51#issuecomment-6056935463),
supplied on **8 October 2026**, used the same GitHub Actions artifact on both
VMs. These are reported VM results, separate from the automated Linux tests.
The artifact identity and archive checksum were independently checked against
the CI download; the VM runs were performed by the report's author.

| Test environment | Startup | Dry run over `/etc` | Upload to Thunderstorm |
| --- | --- | --- | --- |
| FreeBSD 8.4-RELEASE amd64, r251259 (2013-06-02); KVM/QEMU, qemu64 CPU, RTL8139 NIC, IDE disk | Ran directly, without an ASLR workaround | `--dry-run -p /etc`: 253 files would be sent, zero errors | 253 successful uploads, zero read/transmission errors |
| FreeBSD 14.3-RELEASE amd64; KVM/QEMU, host-passthrough CPU, virtio NIC | Direct start failed with `runtime: address space conflict`; ran with ASLR disabled for the invocation | `--dry-run -p /etc`: 600 files discovered, 302 selected, zero errors | 302 successful uploads, zero errors |

- **Server:** Thunderstorm v10, using THOR 10.7.32 (build 1cabaee) over HTTP
  port 8082.
- **Totals:** 555 scanned samples across both runs, no denied requests and no
  upload errors.
- **Scope:** startup, file collection/filtering and HTTP submission. The tests
  do not establish HTTPS/TLS interoperability or compatibility with a
  particular NetScaler firmware.
- **Input:** `/etc` describes the VM test input. For a first appliance test,
  use a small directory containing synthetic files.
- **Installation media:** the reported FreeBSD 8.4 installation ISO SHA-256 was
  `2fb17d77d4eba34736eb98c142c56546dd73a4e7ac38895bb6c8517949282438`.

### ASLR on FreeBSD 14.3

The FreeBSD 14.3 failure and its per-invocation workaround are consistent with
an ASLR-sensitive legacy runtime. The
[FreeBSD 13.2 release notes](https://www.freebsd.org/releases/13.2R/relnotes/#kernel)
document default ASLR for 64-bit executables and this per-invocation control.
The FreeBSD 8.4 VM ran without the workaround. The command is in the
[Go collector guide](../../go/README.md#aslr-when-testing-on-modern-freebsd).

## Exact Tested Artifact

| Field | Value |
| --- | --- |
| CI run / artifact | [Legacy NetScaler run 37743060852](https://github.com/NextronSystems/thunderstorm-collector/actions/runs/37743060852), artifact `netscaler-freebsd8`, ID `11534377782` |
| PR head at the time of the run | `2af4e908e078674a3821b9f106eaee85a576f97b` |
| Built source commit from `BUILD-INFO.txt` | `ed70dd980d4e4132e319f15090a58f927cd85035` (the PR test-merge commit; clean source tree) |
| Compiler / target | Go 1.9.7 on Linux/amd64; `GOOS=freebsd`, `GOARCH=amd64`, `CGO_ENABLED=0` |
| Archive | `thunderstorm-collector-validation-ed70dd980d4e-amd64-freebsd8-netscaler.tar.gz` |
| Archive SHA-256, verified against its sidecar | `018efbc71a7b0ac5f53b5b376f2e155fa64c542ca98a7eb6e683c29cd8186b92` |
| Executable | `amd64-freebsd8-netscaler-thunderstorm-collector`, 5,644,000 bytes; static, stripped FreeBSD ELF64 x86-64 |
| Executable SHA-256, computed from the downloaded artifact | `3cf8abd09c964095f795dc8f680d646c24e91541e01da605d94c5bc803dee3d4` |
| Go Build ID, matching the report | `24b3731e01aa0df55459eb274cafee81a99d5de4` |

These runtime results apply to the identified artifact. Later builds are not
automatically VM-tested. The `pending` runtime fields in its `BUILD-INFO.txt`
reflect the CI build-time checks, which preceded these external tests; this
page records the subsequent VM evidence.

## Earlier Records and Toolchain Choice

- The repository also records historical Go 1.9.7 use on FreeBSD 8.4 NetScaler
  gateways, without their firmware, architecture or collector revision.
- The [official Go FreeBSD table](https://go.dev/wiki/FreeBSD) supports the
  amd64 toolchain choice.
- No 386 legacy package is promised without a verified target need.

Go 1.9.7 is unsupported; see the
[security warning in the Go collector guide](../../go/README.md#aslr-when-testing-on-modern-freebsd).
