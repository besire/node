#!/bin/sh
# Builds build/remnanode-alpine-<arch>.tar.gz: the bundled node with its traced
# node_modules (musl prebuilds only) and deploy/alpine, for the CPU arch of the
# build host. Runs natively on Alpine, elsewhere inside a node:24-alpine container.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="${OUT_DIR:-$ROOT/build}"
BUILD_IMAGE="${BUILD_IMAGE:-node:24-alpine}"

if [ ! -f /etc/alpine-release ]; then
    mkdir -p "$OUT_DIR"
    exec docker run --rm \
        -v "$ROOT:/src:ro" \
        -v "$OUT_DIR:/out" \
        -e OUT_DIR=/out \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        "$BUILD_IMAGE" sh /src/scripts/package-alpine.sh
fi

case "$(uname -m)" in
    x86_64) ARCH=x64 ;;
    aarch64) ARCH=arm64 ;;
    *)
        echo "unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Copy the sources without host artifacts: node_modules from another OS/libc
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
echo "==> Building Remnawave Node $VERSION for linux-musl-$ARCH"

npm ci --no-audit --no-fund
NODE_ENV=production npm run build
npm run trace

echo "==> Pruning native binaries for other platforms"
find dist/node_modules -name '*.node' \( -name '*glibc*' -o -name 'node.abi*' \) -delete
find dist/node_modules -type d -name prebuilds | while read -r dir; do
    find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name "linux-$ARCH" -exec rm -rf {} +
done

echo "==> Checking that native modules load on musl"
for m in lmdb nftables-napi sockdestroy; do
    node -e "require(require.resolve('$m', { paths: [process.argv[1]] }))" "$PWD/dist" ||
        { echo "native module $m failed to load" >&2; exit 1; }
done

STAGE="$WORK/stage/remnanode"
mkdir -p "$STAGE"
cp -a dist "$STAGE/dist"
cp -a deploy/alpine "$STAGE/deploy"
echo "$VERSION" > "$STAGE/VERSION"

# These files run as root: never ship group/world-writable modes from the checkout.
chown -R 0:0 "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod go-w {} +
chmod 755 "$STAGE/deploy/remnanode-start" "$STAGE/deploy/remnanode-cli" \
    "$STAGE/deploy/remnanode.initd" "$STAGE/deploy/install.sh"

NAME="remnanode-alpine-$ARCH.tar.gz"
mkdir -p "$OUT_DIR"
tar -C "$WORK/stage" -czf "$OUT_DIR/$NAME" remnanode
(cd "$OUT_DIR" && sha256sum "$NAME" > "$NAME.sha256")
cp deploy/alpine/install.sh "$OUT_DIR/install.sh"

if [ -n "${HOST_UID:-}" ]; then
    chown "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT_DIR/$NAME" "$OUT_DIR/$NAME.sha256" "$OUT_DIR/install.sh"
fi

echo "==> $OUT_DIR/$NAME ($(du -h "$OUT_DIR/$NAME" | cut -f1))"
