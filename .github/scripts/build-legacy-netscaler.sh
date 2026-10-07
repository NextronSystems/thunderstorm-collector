#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
: "${LEGACY_GO:?Set LEGACY_GO to the verified Go 1.9.7 executable}"
compiler=$("$LEGACY_GO" version)
test "$compiler" = 'go version go1.9.7 linux/amd64' || {
    echo "Expected exactly Go 1.9.7 on Linux/amd64, got: $compiler" >&2; exit 1;
}
test -d "$repo/go/vendor" || { echo 'Prepare pinned vendored dependencies first' >&2; exit 1; }
version=${VERSION:-$(git -C "$repo" describe --tags --always)}
version=${version#refs/tags/}
case "$version" in v[0-9]*) version=${version#v} ;; esac
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid package version' >&2; exit 1; }
commit=$(git -C "$repo" rev-parse HEAD)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GOPATH="$work/gopath"
export GOROOT
GOROOT=$(cd "$(dirname "$LEGACY_GO")/.." && pwd)
export CGO_ENABLED=0
# Go 1.9 predates modules. All imports come from this GOPATH/vendor layout.
import_path=github.com/NextronSystems/thunderstorm-collector/go
mkdir -p "$GOPATH/src/$(dirname "$import_path")"
ln -s "$repo/go" "$GOPATH/src/$import_path"
echo "$compiler"
echo "Source commit: $commit; target: freebsd/amd64; CGO_ENABLED=0"
cd "$repo/go"
# Host tests exercise the same source/dependencies with the old runtime.
GOOS=linux GOARCH=amd64 "$LEGACY_GO" test -v "$import_path"
GOOS=linux GOARCH=amd64 "$LEGACY_GO" build -o "$work/linux-collector" "$import_path"
python3 "$repo/.github/scripts/test-legacy-runtime.py" "$work/linux-collector" "$repo/go/config.yml"
name="thunderstorm-collector-$version-amd64-freebsd8-netscaler"
mkdir -p "$work/$name" "$repo/go/dist"
GOOS=freebsd GOARCH=amd64 "$LEGACY_GO" build -ldflags '-w -s' \
    -o "$work/$name/amd64-freebsd8-netscaler-thunderstorm-collector" "$import_path"
chmod 755 "$work/$name/amd64-freebsd8-netscaler-thunderstorm-collector"
cp "$repo/go/config.yml" "$work/$name/config.yml"
cp "$repo/go/legacy/COMPATIBILITY.txt" "$work/$name/COMPATIBILITY.txt"
# Record the exact dependency input, including the generated vendored sources.
(cd vendor && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$work/vendor-checksums"
vendor_hash=$(sha256sum "$work/vendor-checksums" | cut -d' ' -f1)
input_hash=$(sha256sum go.mod go.sum)
dirty=false
if test -n "$(git -C "$repo" status --porcelain --untracked-files=normal)"; then dirty=true; fi
cat > "$work/$name/BUILD-INFO.txt" <<EOF
$compiler
source_commit=$commit
source_dirty=$dirty
version=$version
GOOS=freebsd
GOARCH=amd64
CGO_ENABLED=0
build_flags=-ldflags '-w -s'
toolchain_archive=go1.9.7.linux-amd64.tar.gz
toolchain_sha256=88573008f4f6233b81f81d8ccf92234b4f67238df0f0ab173d75a302a1f3d6ee
vendored_file_manifest_sha256=$vendor_hash
$input_hash
validation=Go 1.9.7 Linux/amd64 host tests and HTTP integration; FreeBSD ELF/package checks
FreeBSD_8.4_runtime=pending
NetScaler_appliance_firmware=pending
EOF
tar -czf "$repo/go/dist/$name.tar.gz" -C "$work" "$name"
(cd "$repo/go/dist" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
python3 "$repo/.github/scripts/verify-legacy-package.py" "$repo/go/dist/$name.tar.gz" "$repo/go/config.yml"
echo "Created go/dist/$name.tar.gz"
