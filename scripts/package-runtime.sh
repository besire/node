#!/bin/sh
# Repackages the official Node.js build that rwnode installs on hosts without
# a Node.js 24 package: only bin/node (stripped, about 17 MB smaller) and LICENSE.
#
#   sh scripts/package-runtime.sh glibc x64|arm64
#   sh scripts/package-runtime.sh musl x64        (Alpine older than 3.23)
#
# Output: build/node-runtime-<version>-<libc>-<arch>.tar.{xz,gz} + .sha256
# The version comes from NODE_VERSION in deploy/linux/rwnode. Needs curl, xz, strip.
set -eu

LIBC="${1:?usage: $0 glibc|musl x64|arm64}"
ARCH="${2:?usage: $0 glibc|musl x64|arm64}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="${OUT_DIR:-$ROOT/build}"
MIRROR="${NODE_MIRROR:-https://nodejs.org/dist}"
NODE_VERSION=$(sed -n 's/^NODE_VERSION="\(v[0-9.]*\)"$/\1/p' "$ROOT/deploy/linux/rwnode")
[ -n "$NODE_VERSION" ] || {
    echo "NODE_VERSION not found in deploy/linux/rwnode" >&2
    exit 1
}

case "$LIBC-$ARCH" in
    glibc-x64 | glibc-arm64) VARIANT="linux-$ARCH" ;;
    musl-x64) VARIANT="linux-x64-musl" ;;
    *)
        echo "no official Node.js build for $LIBC-$ARCH" >&2
        exit 1
        ;;
esac

STRIP="${STRIP:-strip}"
if [ "$ARCH" = arm64 ] && [ "$(uname -m)" != aarch64 ]; then STRIP="${STRIP_ARM64:-aarch64-linux-gnu-strip}"; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

SRC="node-$NODE_VERSION-$VARIANT"
echo "==> $SRC"
curl -fsSLO "$MIRROR/$NODE_VERSION/$SRC.tar.xz"
curl -fsSL "$MIRROR/$NODE_VERSION/SHASUMS256.txt" | grep " $SRC.tar.xz\$" | sha256sum -c -

xz -dc "$SRC.tar.xz" | tar -xf - "$SRC/bin/node" "$SRC/LICENSE"
mkdir -p stage/node/bin
mv "$SRC/LICENSE" stage/node/LICENSE
mv "$SRC/bin/node" stage/node/bin/node
BEFORE=$(du -k stage/node/bin/node | cut -f1)
"$STRIP" stage/node/bin/node
echo "    bin/node: $((BEFORE / 1024)) MB -> $(($(du -k stage/node/bin/node | cut -f1) / 1024)) MB"

chmod 755 stage/node stage/node/bin stage/node/bin/node
chmod 644 stage/node/LICENSE

# Record root ownership even when built as a regular user (CI runners).
NAME="node-runtime-$NODE_VERSION-$LIBC-$ARCH"
mkdir -p "$OUT_DIR"
tar --owner=0 --group=0 --numeric-owner -C stage -cf - node | xz -T0 -9 > "$OUT_DIR/$NAME.tar.xz"
tar --owner=0 --group=0 --numeric-owner -C stage -czf "$OUT_DIR/$NAME.tar.gz" node
(
    cd "$OUT_DIR"
    sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256"
    sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
    ls -la "$NAME".tar.*
)
