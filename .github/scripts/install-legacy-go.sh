#!/usr/bin/env bash
set -euo pipefail
# Official archive and checksum from https://go.dev/dl/?mode=json&include=all.
archive=go1.9.7.linux-amd64.tar.gz
checksum=88573008f4f6233b81f81d8ccf92234b4f67238df0f0ab173d75a302a1f3d6ee
: "${LEGACY_TOOLCHAIN_DIR:?Set a dedicated toolchain directory}"
mkdir -p "$LEGACY_TOOLCHAIN_DIR"
curl --fail --location --retry 3 "https://go.dev/dl/$archive" -o "$LEGACY_TOOLCHAIN_DIR/$archive"
printf '%s  %s\n' "$checksum" "$LEGACY_TOOLCHAIN_DIR/$archive" | sha256sum --check --strict
# Refuse to reuse an existing installation rather than blending toolchains.
test ! -e "$LEGACY_TOOLCHAIN_DIR/go"
tar -xzf "$LEGACY_TOOLCHAIN_DIR/$archive" -C "$LEGACY_TOOLCHAIN_DIR"
"$LEGACY_TOOLCHAIN_DIR/go/bin/go" version
