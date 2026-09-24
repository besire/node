#!/bin/sh
# Builds build/remnanode-<libc>-<arch>.tar.gz: the bundled node with its traced
# node_modules (native prebuilds for one libc/arch only) and deploy/linux.
#
#   sh scripts/package.sh musl    # Alpine
#   sh scripts/package.sh glibc   # Debian, Ubuntu, RHEL, ...
#
# Runs natively on a matching Linux host with Node.js 24 + npm (Alpine for musl),
# elsewhere inside node:24-alpine / node:24-bookworm-slim. The arch follows the host.
set -eu

LIBC="${1:-musl}"
case "$LIBC" in
    musl) DEFAULT_IMAGE=node:24-alpine ;;
    glibc) DEFAULT_IMAGE=node:24-bookworm-slim ;;
    *)
        echo "usage: $0 [musl|glibc]" >&2
        exit 2
        ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="${OUT_DIR:-$ROOT/build}"
BUILD_IMAGE="${BUILD_IMAGE:-$DEFAULT_IMAGE}"

native_build_possible() {
    [ "$(uname -s)" = Linux ] || return 1
    if [ -f /etc/alpine-release ]; then [ "$LIBC" = musl ] || return 1; else [ "$LIBC" = glibc ] || return 1; fi
    command -v npm >/dev/null 2>&1 || return 1
    [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 24 ]
}

if ! native_build_possible; then
    if [ -n "${IN_BUILD_CONTAINER:-}" ]; then
        echo "$BUILD_IMAGE has no Node.js 24 + npm" >&2
        exit 1
    fi
    mkdir -p "$OUT_DIR"
    exec docker run --rm \
        -v "$ROOT:/src:ro" \
        -v "$OUT_DIR:/out" \
        -e OUT_DIR=/out \
        -e IN_BUILD_CONTAINER=1 \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        "$BUILD_IMAGE" sh /src/scripts/package.sh "$LIBC"
fi

case "$(uname -m)" in
    x86_64) ARCH=x64 ;;
    aarch64) ARCH=arm64 ;;
    *)
        echo "unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

if [ "$LIBC" = musl ]; then OTHER_LIBC=glibc; else OTHER_LIBC=musl; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Copy the sources without host artifacts: node_modules from another OS
# would carry the wrong native binaries.
mkdir -p "$WORK/src"
for f in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
        node_modules | dist | build | .git | .claude) continue ;;
    esac
    cp -a "$f" "$WORK/src/"
done

cd "$WORK/src"

VERSION=$(node -p "require('./package.json').version")
echo "==> Building Remnawave Node $VERSION for linux-$ARCH-$LIBC"

npm ci --no-audit --no-fund
# Bundle the JS dependencies (smaller on disk and in V8's heap); only native
# addons stay in node_modules. The Docker build keeps the default externals.
RWNODE_BUNDLE=1 NODE_ENV=production npm run build
npm run trace

size_of() { du -sk "$1" | cut -f1; }
BEFORE=$(size_of dist/node_modules)

echo "==> Pruning native binaries for other platforms"
find dist/node_modules -name '*.node' \( -name "*$OTHER_LIBC*" -o -name 'node.abi*' \) -exec rm -f {} +
find dist/node_modules -type d -name prebuilds | while read -r dir; do
    find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name "linux-$ARCH" -exec rm -rf {} +
done

echo "==> Pruning files not needed at runtime (license files are kept)"
find dist/node_modules -type f \( \
    -name '*.d.ts' -o -name '*.d.cts' -o -name '*.d.mts' -o -name '*.map' \
    -o -name '*.md' -o -name '*.markdown' -o -name '*.gyp' -o -name '*.gypi' \
    -o -name '.npmignore' -o -name '.eslintrc*' -o -name '.prettierrc*' -o -name 'tsconfig*.json' \
    \) ! -iname 'license*' ! -iname 'notice*' -exec rm -f {} +
# C/C++ sources of the native addons, only used to compile them
for d in lmdb/src lmdb/dependencies nftables-napi/src sockdestroy/src msgpackr-extract/src; do
    rm -rf "dist/node_modules/$d"
done

echo "    node_modules: $((BEFORE / 1024)) MB -> $(($(size_of dist/node_modules) / 1024)) MB"

echo "==> Checking that native modules load"
for m in lmdb nftables-napi sockdestroy; do
    node -e "require(require.resolve('$m', { paths: [process.argv[1]] }))" "$PWD/dist" ||
        {
            echo "native module $m failed to load" >&2
            exit 1
        }
done

STAGE="$WORK/stage/remnanode"
mkdir -p "$STAGE"
cp -a dist "$STAGE/dist"
cp -a deploy/linux "$STAGE/deploy"
echo "$VERSION" > "$STAGE/VERSION"
echo "$LIBC" > "$STAGE/LIBC"

# These files run as root: never ship group/world-writable modes from the checkout.
chown -R 0:0 "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod go-w {} +
for f in remnanode-start remnanode-cli remnanode.initd rwnode; do
    chmod 755 "$STAGE/deploy/$f"
done

NAME="remnanode-$LIBC-$ARCH.tar.gz"
mkdir -p "$OUT_DIR"
tar -C "$WORK/stage" -czf "$OUT_DIR/$NAME" remnanode
(cd "$OUT_DIR" && sha256sum "$NAME" > "$NAME.sha256")
OUTPUTS="$NAME $NAME.sha256"

# Installers from 3.4.1-alpine.1 download remnanode-alpine-<arch>.tar.gz on update.
if [ "$LIBC" = musl ]; then
    LEGACY="remnanode-alpine-$ARCH.tar.gz"
    cp "$OUT_DIR/$NAME" "$OUT_DIR/$LEGACY"
    (cd "$OUT_DIR" && sha256sum "$LEGACY" > "$LEGACY.sha256")
    OUTPUTS="$OUTPUTS $LEGACY $LEGACY.sha256"
fi

cp deploy/linux/rwnode "$OUT_DIR/install.sh"
OUTPUTS="$OUTPUTS install.sh"

if [ -n "${HOST_UID:-}" ]; then
    for f in $OUTPUTS; do chown "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT_DIR/$f"; done
fi

echo "==> $OUT_DIR/$NAME ($(du -h "$OUT_DIR/$NAME" | cut -f1), $(($(size_of "$STAGE") / 1024)) MB unpacked)"
