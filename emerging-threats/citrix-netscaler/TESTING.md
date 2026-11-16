# NetScaler Assessment Profile: Validation Record

Recorded checks of the [NetScaler assessment profile](README.md). None of them
ran on an actual NetScaler, against a real THOR server or over HTTPS.

| Date | Collector | Environment | Result |
|---|---|---|---|
| 2026-10-09 | Go profile | Source `d0b05d6b37b9dd26363c6bed6463c0ea2b36c488`, Go 1.26.0, macOS arm64 | Preview and loopback upload, synthetic files |
| 2026-10-09 | Bash preset | PR #44 revision `d645a00`, Bash 3.2, macOS | Dry run, synthetic files |
| 2026-10-11 | Go profile and Bash preset | [Source `35a8509`](https://github.com/NextronSystems/thunderstorm-collector/tree/35a8509d943778e6e3b2b341125ed6b9c94ea945), Go 1.21.0, Bash 3.2.57, macOS arm64 | Previews and loopback uploads, synthetic files |

Still required: an actual NetScaler preview and a controlled upload with the
intended server, for both options.

## Go Profile, 2026-10-09

- Remapped synthetic roots selected 28 small fixtures and an exactly 64 MiB
  file in preview, with no HTTP requests.
- Larger files and special or symlink entries were skipped.
- A local HTTP receiver verified all 28 small uploads byte for byte.
- Not a real THOR or TLS test.

## Bash Preset, 2026-10-09

The exact Bash header assignments from the guide were applied to PR #44
revision `d645a00` and checked with Bash 3.2 on macOS.

- With only the roots remapped, a synthetic dry run selected 11 eligible files,
  skipped one oversized file, and reported zero failures or scan errors.
- Covered: old timestamps, hidden and unexpected file types, deep paths, a
  cloud-named directory, and a root symlink. The configuration directory was
  collected once.
- Not covered: an actual appliance or a live Bash upload.

## Go Profile and Bash Preset, 2026-10-11

The local Go verification binary used the macOS external linker and an ad-hoc
signature. The supplied YAML and the Bash header settings were exercised with
synthetic roots.

- Previews made no HTTP requests.
- Explicit live overrides uploaded 14 Go fixtures and 13 Bash fixtures to a
  loopback HTTP receiver. Every payload's SHA-256 matched its source file.
- The one-file difference was Bash's retained `Library/CloudStorage`
  exclusion.
- Covered: old timestamps, hidden and extensionless files, unusual suffixes,
  binary bytes, a cloud-named directory, and configuration-root symlink
  handling.
- Exactly 64 MiB was included; 64 MiB plus one byte, internal symlinks and a
  FIFO were excluded.
- CLI root overrides selected only the replacement directory in both
  collectors.
- Not covered: an actual NetScaler, real THOR, HTTPS, or the Go 1.9.7 runtime.

## Legacy Go Binary

The legacy Go binary has separate
[reported FreeBSD 8.4 and 14.3 VM tests](https://github.com/NextronSystems/thunderstorm-collector/pull/51#issuecomment-6056935463).
They predate this profile and do not validate its appliance coverage. The
FreeBSD 14.3 test needed ASLR disabled for that invocation; the 8.4 test did
not.
