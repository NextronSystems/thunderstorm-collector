# Collector Recommendations by Product and Platform

Pick a collector for a system that cannot run THOR directly, or when selected
files should be analysed on a central Thunderstorm server. Last reviewed:
**11 October 2026**.

> [!NOTE]
> Recommendations are inferred from vendor documentation and the collector
> requirements. Most rows are **Not yet tested** on the product: candidates,
> not supported combinations. A shell or a matching CPU does not prove that
> execution is permitted, or that kernel, utilities and file visibility fit.
> Status applies to the revisions in the linked records.
> [Status terms and test records](#test-evidence)

## How to Choose a Collector

1. **THOR runs on the system and local scanning is permitted:** use THOR. A
   file collector does not reproduce all endpoint-scanning capabilities. See
   [Direct THOR Scanning and ARM64](#direct-thor-scanning-and-arm64).
2. **Find the product** in the tables below. Follow the vendor-approved
   procedure and confirm the actual firmware, OS and CPU before collection.
3. **A shell is available:** run the preferred collector if its
   [runtime requirements](#collector-files-and-runtime-requirements) are met,
   otherwise the alternative. For Go, match the
   [published binary targets](#published-go-binary-targets) against the
   [compatibility boundaries](#compatibility-boundaries).
4. **Only SSH with SFTP is available:** read the files from another system;
   see [When Only SSH/SFTP Is Available](#when-only-sshsftp-is-available).
5. **Nothing may run and there is no SFTP:** export the files and upload them
   from a workstation; see
   [external collection](#external-collection-and-file-visibility).

Current downloads: [main download guide](../README.md#download-a-collector).

## Preferred Collectors and Alternatives

- `os/arch` names a Go build target, not a product certification.
- Tables are ordered roughly by how common the product is, with related
  products kept together. The order is editorial, not a market-share or
  exploitation ranking.
- "External collection" means exporting approved files with the product's
  own procedure and uploading them from a workstation.

### Common Operating Systems and Infrastructure

| Product or scope | Preferred | Alternative | Status |
| --- | --- | --- | --- |
| **Windows**, including legacy x86/x64 | Go `windows/386` or `windows/amd64`; `windows/arm64` on a compatible ARM64 OS | PowerShell 3+, or the separate PS2 collector | PowerShell, Batch: **Automated** |
| **Linux** servers and workstations, including older distributions | Go matching the OS/CPU, commonly `linux/amd64`, `linux/386` or `linux/arm64` | Bash, Python or POSIX sh/ash | **Automated**; Python also **Tested** |
| **Linux older than the Go floor**, such as 2.6.18 or RHEL 4-era systems | POSIX sh/ash, if its utilities and an upload transport work | Bash 3.2+ or Python 2.7 if available; otherwise the [SFTP collector](../sftp/README.md) from another system, or external collection | Not yet tested |
| **macOS**, Intel and Apple Silicon | Go `darwin/amd64` or `darwin/arm64`, where central collection is wanted | Bash or Python with an installed runtime | Bash, Python: **Tested** |
| **VMware ESXi** | Python 3; the separate Python 2.7 file only where required and compatible | [SFTP collector](../sftp/README.md) from another system if SSH and SFTP are enabled; otherwise external collection | Not yet tested |
| **VMware vCenter Server Appliance (VCSA)** | Go `linux/amd64` on a confirmed x86-64 Linux appliance | Python | Not yet tested |
| **Amazon Linux** | Go `linux/amd64` (x86-64) or `linux/arm64` (aarch64) | Python | Not yet tested |
| **Kubernetes: Linux nodes** | Go for Linux, matching the node architecture | Python where available | Not yet tested |
| **Kubernetes: container and image contents** | Go on exported, extracted or mounted files | Python in the collection environment | Not yet tested |

Notes:

- **Windows:** check first whether THOR or THOR Legacy can run. Go 1.10
  keeps XP/Vista-era support, but a published package is not a test of every
  edition. PowerShell needs the matching .NET runtime.
  [Batch](../scripts/batch/README.md) is a last resort: it needs WSH and a
  compatible curl 8.4+, so it is no dependency-free fallback for old Windows.
- **Linux:** select the actual compiler/kernel combination. Go 1.10's Linux
  floor is **2.6.23** plus architecture requirements, which does not cover
  every Linux 2.x system. Targets built only with stable Go have newer requirements.
- **Linux below the Go floor:** no current Go package is recommended.
  Distribution Bash, Python or wget may be too old for the scripts. Nextron
  reports historical RHEL 4 Thunderstorm deployments; they do not validate
  today's scripts. Test the exact environment against the
  [script requirements](#collector-files-and-runtime-requirements).
- **macOS:** prefer THOR for supported local scanning. Match the package
  compiler's macOS minimum and the actual CPU.
- **ESXi:** confirm the interpreter and execution policy. Earlier collector
  revisions were reportedly used successfully on ESXi; the revised collector is not yet
  validated there. A generic Linux Go binary or Bash collector is not an
  equivalent fallback. See the
  [ESXi quick start](../scripts/README.md#vmware-esxi-use-the-python-collector).
- **vCenter:** treat it separately from ESXi. Broadcom documents Photon OS and
  Bash/Python maintenance access on vCenter; that is no collector validation.
  Verify permitted execution and the actual OS/architecture.
- **Amazon Linux:** match the instance architecture and OS release. AWS
  documents both architectures for Amazon Linux 2023; do not infer every
  version from that. Verify the binary and any fallback interpreter on the
  target.
- **Kubernetes nodes:** run on the host, or in a separately designed
  collection environment with access to the host paths. A `hostPath` mount
  exposes one path on one node, not the cluster. Check mount visibility and
  collector exclusions. There is no cluster-wide discovery or deployment.
- **Container and image contents:** pick the binary for the system running the
  collector, not for the image. The collector does not enumerate registries,
  unpack image layers or expose container files and volumes; extraction is
  separate work.

Sources: [Nextron: unsupported platforms](https://thor-manual.nextron-systems.com/en/latest/usage/requirements.html#unsupported) ·
[Broadcom: Python on ESXi](https://knowledge.broadcom.com/external/article/373898) ·
[Broadcom: Photon OS on vCenter](https://knowledge.broadcom.com/external/article/301489/faq-support-for-photon-os-on-vcenter-ser.html) ·
[Broadcom: vCenter Bash/Python access](https://knowledge.broadcom.com/external/article/316581/resetting-the-vmware-update-manager-data.html) ·
[AWS: Amazon Linux 2023 architectures](https://docs.aws.amazon.com/linux/al2023/ug/performance-optimizations.html) ·
[Kubernetes: hostPath](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath) ·
[Kubernetes: volumes](https://kubernetes.io/docs/concepts/storage/volumes/)

### Edge Appliances and NAS

| Product or scope | Preferred | Alternative | Status |
| --- | --- | --- | --- |
| **Cisco ASA** | External collection with Cisco's documented procedure, then Go on the workstation | Python on the workstation | Not yet tested |
| **Cisco Nexus / NX-OS** | Python in an approved native on-box Python environment | Linux Go matching the architecture, in an approved Linux execution environment | Not yet tested |
| **Fortinet FortiGate / FortiOS** | [Export evidence and scan it with THOR Lab](../integration-guides/fortinet/fortigate-export-thor-lab.md), or upload approved exports from the workstation | FortiGate VM: scan a copy of its disks for more file coverage | Not yet tested |
| **Palo Alto Networks PAN-OS / GlobalProtect** | Vendor-guided external collection, then a workstation collector | Vendor-assisted acquisition for more file coverage | Not yet tested |
| **Citrix NetScaler, FreeBSD 8.4 amd64** | Legacy Go collector built with **Go 1.9.7** ([package](../go/README.md#dedicated-netscaler-package-and-downloads)) | [Bash with the NetScaler preset](../emerging-threats/citrix-netscaler/README.md#option-2-existing-bash-collector); or [SFTP collector](../sftp/README.md), or copy to a workstation | **VM-tested** (FreeBSD 8.4, 14.3); firmware not yet tested |
| **Citrix NetScaler, other versions** | [Bash with the NetScaler preset](../emerging-threats/citrix-netscaler/README.md#option-2-existing-bash-collector) | Go for the actual OS/CPU; or [SFTP collector](../sftp/README.md), or copy to a workstation | Not yet tested |
| **F5 BIG-IP LTM and GTM/DNS** | Bash | Linux Go with verified CPU architecture and kernel | Not yet tested |
| **Check Point Gaia gateways** | Bash in an authorized Expert shell | Linux Go after OS/CPU checks | Not yet tested |
| **Sophos Firewall / older XG** | POSIX sh/ash in the authorized Advanced Shell | Bash or Linux Go if their requirements are met | Not yet tested |
| **Ivanti Connect Secure / Policy Secure** | Vendor-documented external snapshot, then a workstation collector | Vendor-assisted acquisition | Not yet tested |
| **SonicWall SMA** | Vendor-guided snapshot or log collection, then a workstation collector | sh/ash or Bash only on a confirmed, authorized SMA1000 shell with all dependencies | Not yet tested |
| **Synology DSM NAS / SRM routers** | POSIX sh/ash after verifying tools and transport | Linux Go; Bash only if its requirements are met | Not yet tested |
| **QNAP QTS / QuTS hero NAS** | POSIX sh/ash after verifying tools and transport | Linux Go; Bash only if its requirements are met | Not yet tested |
| **pfSense / OPNsense, x86-64** | POSIX sh after testing the actual FreeBSD shell and utilities | `freebsd/amd64` after checking its compiler against the installed FreeBSD release | Not yet tested |
| **OpenWrt and other authorized embedded Linux** | POSIX sh/ash | Linux Go for x86, ARM or MIPS after kernel/CPU/ABI checks | Not yet tested |

Notes:

- **Cisco ASA:** no collector is recommended to run on the ASA itself. The Python collector
  uploads local files; it does not acquire them from the ASA.
- **Cisco NX-OS:** confirm model, NX-OS release, interpreter version and
  standard-library modules; Cisco's guide includes older Python 2.7 examples.
  Guest Shell is a separate container with version-dependent access: running
  there does not give access to all host files.
- **FortiGate:** FortiOS gives administrators a CLI, not a shell. Its Linux
  base does not make a Linux Go binary usable. GUI and CLI provide
  configuration, logs and diagnostics; scanning a system binary needs its file
  contents. For physical appliances, Fortinet reviews IoC outputs but does not
  provide forensic images.
- **PAN-OS:** Palo Alto Networks recommends a Tech Support File for analysis.
  It does not contain every host file, and a management CLI is no proof of
  arbitrary script execution.
- **NetScaler:** check the
  [firmware, OS and CPU](../go/README.md#choose-a-collector-for-your-netscaler)
  and follow the
  [NetScaler integration guide](../integration-guides/citrix/netscaler-collection-and-scanning.md).
  NetScaler firmware and FreeBSD version numbers differ. FreeBSD 8.4 is the
  legacy build target; 14.3 is a VM test, not a firmware cutoff.
- **NetScaler Bash preset and fallbacks:** the preset needs Bash
  3.2+, curl or GNU wget, and Unix utilities. Without local execution, pull the
  files with the SFTP collector where SFTP is enabled, or copy them to a
  workstation and upload them there.
- **F5 BIG-IP:** needs Bash 3.2+, curl or suitable GNU wget and the utilities
  in the [Bash guide](../scripts/bash/README.md). Appliance Mode can prevent
  shell access; then use an approved export. This covers the BIG-IP instance,
  not every underlying F5OS host or tenant.
- **Check Point:** Expert mode differs from restricted Clish. Check Bash 3.2+,
  transport and utilities. Vendor shell access does not certify the collector.
  Gaia Embedded / Quantum Spark need separate checks.
- **Sophos:** verify shell, utilities, transport and writable temporary space.
  Not every model has Bash or the same CPU.
- **Ivanti:** use the Integrity Checker Tool snapshot procedure for the exact
  firmware; this page knows no general on-device script route. An ICT result is
  separate from Thunderstorm file analysis.
- **SonicWall:** SMA1000 shell access (documented for 12.4.3) depends on
  version and configuration. It does not apply to SMA100 or SonicOS firewalls.
- **Synology:** match x86, x86-64 or the exact ARM generation and ABI; "ARM"
  alone is not enough. Scope the appliance and mounted volumes explicitly.
- **QNAP:** confirm the model's CPU, kernel and mounted paths. This row does
  not cover QES. The bundled shell may lack the upload dependencies.
- **pfSense / OPNsense:** modern FreeBSD needs a compatible runtime; do not use
  the NetScaler FreeBSD 8.4 package. ARM Netgate models need separate CPU and
  firmware checks.
- **OpenWrt:** uses BusyBox ash. The collector needs its
  [full utility and transport set](../scripts/ash/README.md#requirements-and-transport-selection):
  curl, suitable GNU wget, or nc plus timeout (HTTP only). **BusyBox wget alone
  is refused.** Check MIPS endianness and FPU, and the ARM generation; a
  successful cross-compile proves nothing.

Sources: [Cisco ASA forensic guide](https://sec.cloudapps.cisco.com/security/center/resources/forensic_guides/asa_forensic_investigation.html) ·
[Cisco NX-OS Python guide](https://developer.cisco.com/docs/nx-os/cisco-nexus-9000-series-python-sdk-user-guide-and-api-reference/) ·
[Cisco Guest Shell](https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/101x/programmability/cisco-nexus-9000-series-nx-os-programmability-guide-release-101x/m-n9k-guest-shell-101x.html) ·
[PAN-OS advisory CVE-2024-3400](https://security.paloaltonetworks.com/CVE-2024-3400) ·
[F5: scripts on BIG-IP](https://techdocs.f5.com/en-us/bigiq-8-4-0/managing-big-ip-devices-from-big-iq/script-management/create-a-script-to-run-on-devices.html) ·
[F5: Appliance Mode](https://www.f5.com/content/dam/f5/corp/global/pdf/white-papers/big-ip-system-security-wp.pdf) ·
[Check Point Expert mode](https://sc1.checkpoint.com/documents/R82/WebAdminGuides/EN/CP_R82_Gaia_AdminGuide/Content/Topics-GAG/Gaia-Clish-Expert-Mode.htm) ·
[Sophos Advanced Shell](https://docs.sophos.com/nsg/sophos-firewall/21.5/Help/en-us/webhelp/onlinehelp/CommandLineHelp/ConsoleAccess/PuttyAccess/index.html) ·
[Ivanti Integrity Checker Tool](https://www.ivanti.com/blog/enhanced-external-integrity-checking-tool-to-provide-additional-visibility-and-protection-for-customers-against-evolving-threat-actor-techniques-in-relation-to-previously-disclosed-vulnerabilities) ·
[SonicWall SMA1000 shell access](https://www.sonicwall.com/support/technical-documentation/docs/sma_1000-12-4-admin_guide/Content/supportability_enhancements/shell-access.htm) ·
[SonicWall SMA1000 snapshot](https://www.sonicwall.com/it-it/support/knowledge-base/logs-on-sma1000-and-its-importance-for-troubleshooting/kA1VN0000000MNC0A2) ·
[Synology SSH](https://kb.synology.com/en-us/DSM/tutorial/How_to_login_to_DSM_with_root_permission_via_SSH_Telnet) ·
[Synology CPU families](https://help.synology.com/developer-guide/appendix/platarchs.html) ·
[QNAP SSH](https://www.qnap.com/en/how-to/faq/article/how-do-i-access-my-qnap-nas-using-ssh) ·
[pfSense shell](https://docs.netgate.com/pfsense/en/latest/diagnostics/command-prompt.html) ·
[OPNsense SSH](https://docs.opnsense.org/manual/settingsmenu.html#secure-shell) ·
[OpenWrt shell scripts](https://openwrt.org/docs/guide-developer/write-shell-script)

### Specialist Infrastructure and Unix Platforms

| Product or scope | Preferred | Alternative | Status |
| --- | --- | --- | --- |
| **Nutanix AHV, x86-64 host** | Go `linux/amd64`, **only with a Nutanix-approved procedure** | Python under the same approval; otherwise external collection, or the [SFTP collector](../sftp/README.md) if SFTP read access is approved | Not yet tested |
| **Nutanix AOS / Controller VM (CVM)** | Go `linux/amd64`, **only with a Nutanix-approved procedure** and a confirmed x86-64 Linux CVM | As for AHV | Not yet tested |
| **FreeBSD** servers and other permitted FreeBSD environments | Go `freebsd/amd64` or `freebsd/386`; other published CPUs after checking their compiler | sh/ash, Bash or Python if the runtime and tools fit | Not yet tested |
| **OpenBSD** | Go `openbsd/amd64` or `openbsd/386`; other published CPUs after checking the compiler/OS pair | Python, or a verified shell/Bash environment with the required tools | Not yet tested |
| **NetBSD** | Go `netbsd/amd64` or `netbsd/386` with the matching OS/runtime | Python or a verified shell environment | Not yet tested |
| **Solaris / illumos, x86-64** | Go `solaris/amd64` or `illumos/amd64`, matching OS and compiler requirements | Perl with all required modules, or another verified script runtime | Not yet tested |
| **Solaris, SPARC** | Perl if interpreter and modules fit; otherwise external collection | Python 2.7/3.4+ if available; otherwise the [SFTP collector](../sftp/README.md) from another system | Not yet tested |
| **IBM AIX / POWER** | Go `aix/ppc64`, only for a compatible AIX/POWER generation | Perl or Python; otherwise the [SFTP collector](../sftp/README.md) or THOR over SSHFS from another system, or external collection | Not yet tested |

Notes:

- **Nutanix:** see the [restrictions below](#nutanix-execution-restrictions).
  Collect AHV host files only; CVMs and guest VMs are separate targets, and
  AHV access does not cover CVM files. Do not install runtime packages.
- **FreeBSD:** the normal Go 1.10 build needs **FreeBSD 10.3+** and is
  distinct from the FreeBSD 8.4 NetScaler build. Test old runtimes against
  newer kernels and ASLR, not only against minimum versions.
- **OpenBSD:** Go 1.10 targets OpenBSD 6.0; later releases are not covered by
  that. `ksh` alone does not show that the ash profile and its utilities work.
- **NetBSD:** Go 1.10 needs NetBSD 8 for x86. Go 1.10's notes flagged its ARM
  port as broken, and the published Go 1.10.8 ARM asset has no native
  acceptance test. It is published, not recommended.
- **Solaris x86-64:** an amd64 package does not run on SPARC. Stock Solaris
  utilities are not necessarily GNU/BSD-compatible; verify the shell profiles.
- **Solaris SPARC:** there is no Go SPARC package. Nextron reports historical
  SPARC Solaris collection deployments; they do not certify the revised
  scripts. Verify interpreter, modules and utilities first.
- **AIX:** do not use Linux PowerPC packages. Check the package's
  [OS/CPU floor](#compatibility-boundaries). On POWER7 or older, use a script
  if its runtime requirements are met; otherwise read the files over SFTP from
  another system or collect externally. See the
  [AIX on POWER7 SSHFS guide](../integration-guides/aix/aix-power7-sshfs-scanning.md).
  THOR itself runs on supported AIX systems.

Sources: [Nutanix AHV/CVM architecture](https://www.nutanix.com/tech-center/blog/understanding-cpu-resource-management-in-nutanix-ahv) ·
[Go 1.10 port notes](https://go.dev/doc/go1.10#ports) ·
[Nextron: unsupported platforms](https://thor-manual.nextron-systems.com/en/latest/usage/requirements.html#unsupported)

### Nutanix execution restrictions

> [!WARNING]
> A Nutanix employee advisory (2020) discourages third-party software on AHV
> hosts and CVMs, and the current support policy describes possible support
> limitations. Confirm the permitted collection procedure with Nutanix first.
> Without that confirmation, use approved exports and upload them from a
> separate system.

- An existing Linux shell does not grant permission to run a collector.
- A standalone binary that needs no package installation does not remove
  the restriction.
- The [SFTP collector](../sftp/README.md) runs nothing on the host, but the
  SSH access it needs is subject to the same approval.

Sources: [Nutanix community advisory (2020)](https://next.nutanix.com/installation-configuration-23/antivirus-on-nutanix-ahv-hosts-and-on-cvms-37041) ·
[Nutanix third-party support policy](https://www.nutanix.com/en_gb/support-services/support-policies-and-faqs?show=accordion-0)

## When Only SSH/SFTP Is Available

Use this when neither THOR nor a collector can run, for example because no
compatible binary or interpreter exists, the vendor does not permit
third-party software, or the account is limited to SFTP. If the SSH server
offers the SFTP subsystem, two routes read its files from another system:

| Route | Use it for | Read from the source |
| --- | --- | --- |
| [SFTP collector](../sftp/README.md) (prototype) | Selective or recurring collection to Thunderstorm, also from one host for many sources | The directory listing, header bytes where a header filter is set, and the selected files |
| [THOR over SSHFS](SCANNING_APPROACHES.md#remote-filesystem-scans-with-sshfs) | A complete assessment of a scope, with a **Forensic Lab License** | Every file THOR checks; a lab scan checks every file in scope up to its size limit |

- The SFTP collector runs on the Thunderstorm host or on any system that
  reaches both the source and Thunderstorm. The source needs no route to
  Thunderstorm.
- It is a prototype and **Not yet tested** on the products above.
- Its age filter can use only the modification time, and SFTP does not report
  filesystem types. See its
  [comparison with the other collectors](../sftp/README.md#how-it-differs-from-the-other-collectors)
  and its [limits](../sftp/README.md#limits).
- Without an SFTP subsystem, use
  [external collection](#external-collection-and-file-visibility).

## Direct THOR Scanning and ARM64

Nextron has announced **Windows ARM64 and Linux ARM64** support for the
upcoming **THOR 11**. Once the released THOR package supports the target OS
and local scanning is permitted, a collector is no longer needed just to work
around ARM64.

Collectors stay useful for:

- 32-bit ARM, legacy Linux kernels, old Windows versions and appliance
  firmware, which the announcement does not cover
- central file-analysis workflows

Check the requirements of the actual THOR release before replacing a collector
workflow.

Sources: [Management Center 4.1.1 announcement](https://management-center-manual.nextron-systems.com/en/latest/changelog/log1.html#management-center-4-1-1) ·
[THOR requirements](https://thor-manual.nextron-systems.com/en/latest/usage/requirements.html)

## External Collection and File Visibility

External collection means exporting or copying approved files with the
product's documented mechanisms, then running a collector on the receiving
system against that input directory.

- It is a workflow: the Go and script collectors have no built-in SSH or API
  acquisition mode.
- Where the source offers SFTP, the [SFTP collector](../sftp/README.md) reads
  the files in place and sends their original paths and the source name.
- Preserve the original files and source identity separately. Verify how the
  backend shows exported filenames and source identifiers.

A collector uploads only files that are visible and readable where it runs and
that pass its filters. For the SFTP collector, that is what the SSH account can
read over SFTP.

- An AHV host is not its CVM or its guest VMs.
- An ESXi host is not vCenter.
- A container's filesystem is not automatically its node's filesystem.
- Review size, age, extension and filesystem exclusions for the intended
  inputs, especially large exports or core files.
- Thunderstorm is not confirmed to analyse every possible export format.

## Collector Files and Runtime Requirements

Released files and current source can differ; see the
[main download guidance](../README.md#download-a-collector). Scripts have their
own settings and do not read the Go YAML configuration.

| Collector | Required execution environment |
| --- | --- |
| [Go](../go/README.md) | Matching OS, CPU instruction set/ABI and compiler runtime requirements; no installed Go runtime. See the [binary targets](#published-go-binary-targets). |
| [POSIX sh / ash](../scripts/ash/README.md) | Compatible shell, documented Unix utilities, temporary storage, and curl/GNU wget or the restricted nc + timeout HTTP transport. POSIX syntax does not certify every old shell or toolset. |
| [Bash](../scripts/bash/README.md) | Bash 3.2+, GNU/BSD utilities, and curl or GNU wget with `--no-config`; not BusyBox wget. |
| [Python](../scripts/python/README.md) | Python 3.4+, or the separate Python 2.7 script, with the standard library. Verified HTTPS on Python 2 needs **2.7.9+** and usable SSL. Python 2.3/2.4 on some old distributions is not enough. |
| [Perl](../scripts/perl/README.md) | Perl 5.8.1 syntax plus LWP 6+, JSON::PP and the documented modules; additional libraries for HTTPS. An old system Perl alone is not enough. |
| [PowerShell](../scripts/powershell/README.md) | PowerShell 3+, or the separate PS2 file, with the required .NET facilities. Validate the real Windows/CLR combination. |
| [Batch](../scripts/batch/README.md) | Windows cmd, enabled WSH/JScript, FileSystemObject, ADODB.Stream, and a trusted, OS-compatible curl 8.4+. |
| [SFTP](../sftp/README.md) (prototype) | Runs on another system: Linux amd64 and arm64 packages in releases after v1.1.0, or built from source with the Go version in its `go.mod`. Reads the Go YAML configuration. The source needs an SSH server with the SFTP subsystem, an account that can read the files in scope, and inbound SSH from the collector host. |

## Published Go Binary Targets

The [v1.0.1 release](https://github.com/NextronSystems/thunderstorm-collector/releases/tag/v1.0.1)
contains **44 Go binary archives**, each with its binary and `config.yml`.

- These are published architectures, not tested appliance combinations.
- Match the OS as well as the CPU: a Linux `amd64` executable does not run on
  FreeBSD `amd64`.

| Operating system / runtime | Published architectures |
| --- | --- |
| Linux | `386`, `amd64`, `arm`, `arm64`, `mips`, `mipsle`, `mips64`, `mips64le`, `ppc64`, `ppc64le`, `s390x`, `riscv64`, `loong64` |
| Windows | `386`, `amd64`, `arm64` |
| macOS (`darwin`) | `amd64`, `arm64` |
| FreeBSD | `386`, `amd64`, `arm`, `arm64` |
| OpenBSD | `386`, `amd64`, `arm`, `arm64`, `ppc64`, `riscv64` |
| NetBSD | `386`, `amd64`, `arm`, `arm64` |
| DragonFly BSD | `amd64` |
| Solaris | `amd64` |
| illumos | `amd64` |
| AIX | `ppc64` |
| Plan 9 | `386`, `amd64`, `arm` |
| JavaScript / WebAssembly | `wasm` |
| WASI Preview 1 (`wasip1`) | `wasm` |
| Native Client (`nacl`) | `386`, `amd64p32`, `arm` |

- **NetScaler:** the dedicated **`amd64-freebsd8-netscaler`** package (Go
  1.9.7) is in the
  [v1.1.0 release](https://github.com/NextronSystems/thunderstorm-collector/releases/tag/v1.1.0),
  not in v1.0.1. See [download availability](../README.md#download-a-collector)
  and the [NetScaler test record](../go/README.md#citrix-netscaler-and-freebsd-84).
- **JavaScript, WASI and Native Client** packages need a host runtime that
  exposes the required files and networking. These and the Plan 9 packages
  have no recorded end-to-end collection test and no ordinary appliance
  deployment route.

### Compatibility Boundaries

The [release workflow](../.github/workflows/release.yml) builds regular
targets with **Go 1.10.8** where that compiler supports them, and additional
targets with stable Go. The NetScaler build is separate. This is the current
build selection, not the compiler of every historical archive: check the
selected package's compiler against the
[Go requirements](https://go.dev/wiki/MinimumRequirements).

Go 1.10 operating-system floors:

| OS | Go 1.10 floor |
| --- | --- |
| Linux | **2.6.23**, plus architecture requirements |
| Windows | XP and Vista still supported; the last Go release to do so |
| macOS | OS X 10.8 and 10.9 still supported; the last Go release to do so |
| FreeBSD | **10.3** |
| NetBSD | **8** for x86 |
| OpenBSD | **6.0** |

- **Floors:** they do not apply to stable-Go packages and do not guarantee
  every newer OS.
- **ARM:** `arm64` is AArch64; `arm` is a separate 32-bit target. The Go
  1.10.8 cross-build from amd64 defaults to `GOARM=5` for the Linux/BSD
  targets. Check kernel, CPU and ABI too: the flag alone does not prove that a
  Linux 2.6 kernel works.
- **MIPS:** `mips` and `mips64` are big-endian, the `le` variants
  little-endian. The workflow does not set `GOMIPS`, so Go 1.10's 32-bit MIPS
  builds are hard-float. A matching filename is not enough for a router
  without the required floating-point hardware.
- **PowerPC:** `ppc64` is big-endian, `ppc64le` little-endian. Go 1.9+
  PowerPC ports need POWER8.
- **Solaris and AIX:** the Solaris port baseline is Solaris 11 / SunOS 5.11 on
  amd64, not SPARC. The AIX port started with AIX 7.2+ on POWER8. Validate the
  exact release and processor against the compiler.

The binaries need no installed Go runtime, but they depend on compatible
system calls, CPU features and access to the intended files. Below a binary's
runtime floor, use a script only if its interpreter, utilities and HTTP
transport meet the [requirements](#collector-files-and-runtime-requirements).

Sources: [Go 1.10 install requirements](https://github.com/golang/go/blob/go1.10.8/doc/install.html) ·
[Go 1.10 port notes](https://go.dev/doc/go1.10#ports) ·
[Go 1.10.8 GOARM default](https://github.com/golang/go/blob/go1.10.8/src/cmd/dist/util.go) ·
[Go on Solaris](https://go.dev/wiki/Solaris) ·
[Go 1.12 AIX port](https://go.dev/doc/go1.12#aix)

## Why Include These Edge Platforms?

They combine usable execution environments with incident-response relevance.
Vendor and first-hand reports document:

- [Fortinet persistent access](https://www.fortinet.com/uk/blog/psirt-blogs/analysis-of-threat-actor-activity)
- [PAN-OS exploitation](https://security.paloaltonetworks.com/CVE-2024-3400)
- [Sophos firewall campaigns, including older appliances](https://www.sophos.com/en-us/blog/pacific-rim-timeline)
- [SonicWall SMA100 exploitation](https://cloud.google.com/blog/topics/threat-intelligence/sonicwall-secure-mobile-access-exploitation-overstep-backdoor)
- [QNAP DEADBOLT attacks](https://www.qnap.com/en-us/security-advisory/qsa-22-02)
- [Synology SynoLocker](https://www.synology.com/en-af/security/advisory/SynoLocker) (historical, not a current campaign)

These show relevance to investigations, not collector compatibility or market
share. OpenWrt and pfSense/OPNsense are included as accessible edge platforms; this
page does not call them frequent victims.

## Test Evidence

| Status | Meaning |
| --- | --- |
| **Tested** | Run against a real Thunderstorm service on that platform |
| **VM-tested** | Run in a virtual machine with that OS, not on the product itself |
| **Automated** | Covered by CI or the test harness only |
| **Not yet tested** | No recorded result |

Records:

- [Script acceptance report](SCRIPT_COLLECTOR_ACCEPTANCE_2026-10-08.md):
  exact revisions, runtime versions, hashes and open checks for the scripts'
  real-THOR runs.
- [NetScaler/FreeBSD record](../go/README.md#compatibility-evidence-as-of-2026-10-08):
  the tested legacy Go artifact and its VM environments.
- [Collector testing overview](COLLECTOR_TESTING_OVERVIEW.md): what CI and the
  test harness cover.

To change a row's status, link a record that names:

- product/firmware, OS and architecture
- collector revision or asset hash, and the runtime
- execution context and visible paths
- HTTP or HTTPS mode
- dry-run outcome, and server-side receipt and results

Runtime availability, a successful start and a successful end-to-end
collection are different levels of evidence.
