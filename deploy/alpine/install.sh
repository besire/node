#!/bin/sh
# Remnawave Node installer for Alpine Linux 3.23+ (LXC containers, VMs), no Docker.
#
#   curl -fsSL https://github.com/besire/node/releases/latest/download/install.sh \
#       | sh -s -- --secret-key '<SECRET_KEY from the panel>'
#
# Run with --help for all commands and options.
set -eu

REPO="${REMNANODE_REPO:-besire/node}"
RELEASE="${REMNANODE_RELEASE:-latest}"
XRAY_VERSION="${XRAY_VERSION:-v26.7.28}"
XRAY_REPO="${XRAY_REPO:-XTLS}"
GEOCHECK_VERSION="${GEOCHECK_VERSION:-0.3.0}"
ASN_URL="${ASN_URL:-https://github.com/remnawave/asn-index/releases/latest/download/asn-prefixes.lmdb.zst}"

APP_DIR=/opt/remnanode
CONF_DIR=/etc/remnanode
CONF_FILE=$CONF_DIR/remnanode.env
STATE_DIR=/var/lib/remnanode
LOG_DIR=/var/log/remnanode
INITD=/etc/init.d/remnanode
BIN_DIR=/usr/local/bin
XRAY_ASSETS=/usr/local/share/xray
ASN_DIR=/usr/local/share/asn

ACTION=install
SECRET_KEY_ARG=""
NODE_PORT_ARG=""
TARBALL=""
WITH_GEOCHECK=1
WITH_ASN=1
START=1
PURGE=0

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: install.sh [command] [options]

Commands:
  install            Install or reinstall Remnawave Node (default)
  update             Update node package, Xray and data files, keep config
                     (--port / --secret-key change the saved config)
  uninstall          Remove the service and the node package (add --purge for everything)
  status             Show service status and recent logs

Options:
  --secret-key KEY   SECRET_KEY from the panel (prompted if missing on first install)
  --port PORT        NODE_PORT the panel connects to (default: 2222)
  --tarball PATH|URL Use this node package instead of the GitHub release
  --release TAG      Release tag to download (default: latest)
  --repo OWNER/REPO  GitHub repository with the releases (default: $REPO)
  --xray-version V   Xray-core release (default: $XRAY_VERSION)
  --no-geocheck      Skip geocheck (panel "Geo check" feature)
  --no-asn           Skip the ASN database (ASN based plugin lists)
  --no-start         Install only, do not (re)start the service
  --purge            With uninstall: also remove config, Xray, data and logs
  -h, --help         Show this help
EOF
}

need_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        install | update | uninstall | status) ACTION=$1 ;;
        --secret-key)
            need_value "$@"
            SECRET_KEY_ARG=$2
            shift
            ;;
        --secret-key=*) SECRET_KEY_ARG=${1#*=} ;;
        --port)
            need_value "$@"
            NODE_PORT_ARG=$2
            shift
            ;;
        --port=*) NODE_PORT_ARG=${1#*=} ;;
        --tarball)
            need_value "$@"
            TARBALL=$2
            shift
            ;;
        --release)
            need_value "$@"
            RELEASE=$2
            shift
            ;;
        --repo)
            need_value "$@"
            REPO=$2
            shift
            ;;
        --xray-version)
            need_value "$@"
            XRAY_VERSION=$2
            shift
            ;;
        --no-geocheck) WITH_GEOCHECK=0 ;;
        --no-asn) WITH_ASN=0 ;;
        --no-start) START=0 ;;
        --purge) PURGE=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

TMP=""
cleanup() {
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fetch() {
    curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
}

openrc_booted() {
    [ -e /run/openrc/softlevel ]
}

service_running() {
    openrc_booted && rc-service remnanode status >/dev/null 2>&1
}

preflight() {
    [ "$(id -u)" = 0 ] || die "please run as root"
    [ -f /etc/alpine-release ] || die "this installer supports Alpine Linux only"

    ALPINE_VERSION=$(cut -d. -f1,2 /etc/alpine-release)
    major=${ALPINE_VERSION%%.*}
    minor=${ALPINE_VERSION#*.}
    minor=${minor%%[!0-9]*}
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 23 ]; }; then
        die "Alpine $ALPINE_VERSION is too old: Node.js 24 is required, it ships with Alpine 3.23+"
    fi

    case "$(uname -m)" in
        x86_64)
            ARCH=x64
            GO_ARCH=amd64
            XRAY_ZIP=Xray-linux-64.zip
            ;;
        aarch64)
            ARCH=arm64
            GO_ARCH=arm64
            XRAY_ZIP=Xray-linux-arm64-v8a.zip
            ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac

    TMP=$(mktemp -d)
}

install_packages() {
    log "Installing system packages"

    pkgs="nodejs ca-certificates curl unzip openrc logrotate"
    if [ "$WITH_ASN" = 1 ]; then pkgs="$pkgs zstd"; fi

    # shellcheck disable=SC2086
    apk add --no-cache --quiet $pkgs || die "apk add failed"

    node_major=$(node -p 'process.versions.node.split(".")[0]')
    [ "$node_major" -ge 24 ] || die "Node.js 24+ is required, found $(node -v)"
}

release_url() {
    if [ "$RELEASE" = latest ]; then
        echo "https://github.com/$REPO/releases/latest/download"
    else
        echo "https://github.com/$REPO/releases/download/$RELEASE"
    fi
}

install_app() {
    name="remnanode-alpine-$ARCH.tar.gz"
    pkg="$TMP/$name"

    case "$TARBALL" in
        "")
            log "Downloading $name from $REPO ($RELEASE)"
            fetch "$(release_url)/$name" "$pkg" || die "failed to download the node package"
            fetch "$(release_url)/$name.sha256" "$pkg.sha256" || die "failed to download $name.sha256"
            ;;
        http://* | https://*)
            log "Downloading $TARBALL"
            fetch "$TARBALL" "$pkg" || die "failed to download $TARBALL"
            fetch "$TARBALL.sha256" "$pkg.sha256" 2>/dev/null || rm -f "$pkg.sha256"
            ;;
        *)
            [ -f "$TARBALL" ] || die "package not found: $TARBALL"
            cp "$TARBALL" "$pkg"
            if [ -f "$TARBALL.sha256" ]; then cp "$TARBALL.sha256" "$pkg.sha256"; fi
            ;;
    esac

    if [ -f "$pkg.sha256" ]; then
        (cd "$TMP" && awk -v f="$name" '{ print $1 "  " f }' "$pkg.sha256" | sha256sum -c - >/dev/null) ||
            die "checksum mismatch for $name"
    else
        warn "no .sha256 next to the package, skipping checksum verification"
    fi

    mkdir -p "$TMP/pkg"
    tar -xzf "$pkg" -C "$TMP/pkg"
    [ -f "$TMP/pkg/remnanode/dist/main.js" ] || die "invalid package: dist/main.js is missing"

    if service_running; then
        log "Stopping the running service"
        rc-service remnanode stop >/dev/null || true
    fi

    rm -rf "$APP_DIR.new" "$APP_DIR.old"
    mv "$TMP/pkg/remnanode" "$APP_DIR.new"
    chown -R 0:0 "$APP_DIR.new"
    chmod -R go-w "$APP_DIR.new"
    chmod 755 "$APP_DIR.new/deploy/remnanode-start" "$APP_DIR.new/deploy/remnanode-cli"
    if [ -d "$APP_DIR" ]; then mv "$APP_DIR" "$APP_DIR.old"; fi
    mv "$APP_DIR.new" "$APP_DIR"
    rm -rf "$APP_DIR.old"

    log "Remnawave Node $(cat "$APP_DIR/VERSION") installed to $APP_DIR"
}

install_xray() {
    want=${XRAY_VERSION#v}

    if [ -x "$BIN_DIR/xray" ] && "$BIN_DIR/xray" version 2>/dev/null | head -n 1 | grep -q "^Xray $want "; then
        log "Xray $want is already installed"
    else
        log "Installing Xray $XRAY_VERSION"

        base="https://github.com/$XRAY_REPO/Xray-core/releases/download/$XRAY_VERSION"
        fetch "$base/$XRAY_ZIP" "$TMP/$XRAY_ZIP" || die "failed to download $XRAY_ZIP"
        fetch "$base/$XRAY_ZIP.dgst" "$TMP/xray.dgst" || die "failed to download $XRAY_ZIP.dgst"

        sum=$(awk '/^SHA2-256=/ { print $2 }' "$TMP/xray.dgst")
        [ -n "$sum" ] || die "no SHA2-256 in $XRAY_ZIP.dgst"
        echo "$sum  $TMP/$XRAY_ZIP" | sha256sum -c - >/dev/null || die "checksum mismatch for $XRAY_ZIP"

        mkdir -p "$TMP/xray" "$XRAY_ASSETS"
        unzip -qo "$TMP/$XRAY_ZIP" -d "$TMP/xray"

        # Rename over the old binary: writing into a running executable fails with ETXTBSY.
        install -m 755 "$TMP/xray/xray" "$BIN_DIR/xray.new"
        mv -f "$BIN_DIR/xray.new" "$BIN_DIR/xray"
        install -m 644 "$TMP/xray/geoip.dat" "$XRAY_ASSETS/geoip.dat"
        install -m 644 "$TMP/xray/geosite.dat" "$XRAY_ASSETS/geosite.dat"
    fi

    # rw-core is managed by node afterwards (custom core support), only create it once.
    if [ ! -e "$BIN_DIR/rw-core" ]; then ln -sf "$BIN_DIR/xray" "$BIN_DIR/rw-core"; fi
}

install_geocheck() {
    if [ "$WITH_GEOCHECK" != 1 ]; then return 0; fi

    if [ -x "$BIN_DIR/geocheck" ] && [ "$(cat "$STATE_DIR/geocheck.version" 2>/dev/null)" = "$GEOCHECK_VERSION" ]; then
        return 0
    fi

    log "Installing geocheck $GEOCHECK_VERSION"

    archive="geocheck_linux_$GO_ARCH.tar.gz"
    base="https://github.com/remnawave/geocheck/releases/download/v$GEOCHECK_VERSION"

    if ! fetch "$base/$archive" "$TMP/$archive" || ! fetch "$base/checksums.txt" "$TMP/checksums.txt"; then
        warn "failed to download geocheck, the geo check feature will be unavailable"
        return 0
    fi

    if ! (cd "$TMP" && grep "  $archive\$" checksums.txt | sha256sum -c - >/dev/null); then
        warn "checksum mismatch for $archive, skipping geocheck"
        return 0
    fi

    tar -xzf "$TMP/$archive" -C "$TMP" geocheck
    install -m 755 "$TMP/geocheck" "$BIN_DIR/geocheck.new"
    mv -f "$BIN_DIR/geocheck.new" "$BIN_DIR/geocheck"

    mkdir -p "$STATE_DIR"
    echo "$GEOCHECK_VERSION" > "$STATE_DIR/geocheck.version"
}

install_asn() {
    if [ "$WITH_ASN" != 1 ]; then return 0; fi
    if [ -f "$ASN_DIR/asn-prefixes.lmdb" ] && [ "$ACTION" != update ]; then return 0; fi

    log "Downloading the ASN database"

    if ! fetch "$ASN_URL" "$TMP/asn.lmdb.zst" || ! zstd -q -d "$TMP/asn.lmdb.zst" -o "$TMP/asn.lmdb"; then
        warn "failed to download the ASN database, ASN based lists will be unavailable"
        return 0
    fi

    mkdir -p "$ASN_DIR"
    install -m 644 "$TMP/asn.lmdb" "$ASN_DIR/asn-prefixes.lmdb.new"
    mv -f "$ASN_DIR/asn-prefixes.lmdb.new" "$ASN_DIR/asn-prefixes.lmdb"
}

# Accepts the key as shown by the panel, e.g. SECRET_KEY="eyJ..." or - SECRET_KEY=eyJ...
normalize_key() {
    printf '%s' "$1" | tr -d ' \t\r\n' |
        sed -e 's/^-*//' -e 's/^SECRET_KEY=//' -e "s/^[\"']//" -e "s/[\"']\$//"
}

validate_key() {
    node -e '
        const p = JSON.parse(Buffer.from(process.argv[1], "base64").toString("utf8"));
        for (const k of ["caCertPem", "jwtPublicKey", "nodeCertPem", "nodeKeyPem"]) {
            if (typeof p[k] !== "string") process.exit(1);
        }
    ' "$1" 2>/dev/null
}

read_conf() {
    sed -n "s/^$1=//p" "$CONF_FILE" 2>/dev/null | tail -n 1 | tr -d "\"'"
}

configure() {
    key=$(normalize_key "$SECRET_KEY_ARG")
    port=$NODE_PORT_ARG

    if [ -z "$key" ]; then key=$(read_conf SECRET_KEY); fi
    if [ -z "$port" ]; then port=$(read_conf NODE_PORT); fi
    if [ -z "$port" ]; then port=2222; fi

    if [ -z "$key" ]; then
        (: </dev/tty) 2>/dev/null || die "SECRET_KEY is required: pass --secret-key '<key from the panel>'"
        printf 'Paste SECRET_KEY from the panel: ' >/dev/tty
        read -r key </dev/tty
        key=$(normalize_key "$key")
    fi

    validate_key "$key" || die "SECRET_KEY is invalid, copy it again from the panel (Nodes -> node -> SECRET_KEY)"

    case "$port" in
        '' | *[!0-9]*) die "invalid port: $port" ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then die "invalid port: $port"; fi

    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"

    (
        umask 077
        if [ -f "$CONF_FILE" ]; then
            grep -vE '^(SECRET_KEY|NODE_PORT)=' "$CONF_FILE" > "$CONF_FILE.new" || true
        else
            cat > "$CONF_FILE.new" <<'EOF'
# Remnawave Node configuration. Apply changes with: rc-service remnanode restart
#
# Optional settings (defaults shown):
# SNI_VERIFICATION=false
# DISABLE_HASHED_SET_CHECK=false
# NFTABLES_LOGGING=true
# NFTABLES_ACCEPT_REPLY_TRAFFIC=false
EOF
        fi
        printf "NODE_PORT=%s\nSECRET_KEY='%s'\n" "$port" "$key" >> "$CONF_FILE.new"
        mv -f "$CONF_FILE.new" "$CONF_FILE"
    )

    NODE_PORT=$port
    log "Configuration saved to $CONF_FILE (NODE_PORT=$port)"
}

install_service() {
    install -m 755 "$APP_DIR/deploy/remnanode.initd" "$INITD"
    ln -sf "$APP_DIR/deploy/remnanode-cli" "$BIN_DIR/remnanode-cli"
    printf '#!/bin/sh\nexec tail -n +1 -f /var/log/xray/current\n' > "$BIN_DIR/xlogs"
    chmod 755 "$BIN_DIR/xlogs"

    mkdir -p "$LOG_DIR" /var/log/xray

    cat > /etc/logrotate.d/remnanode <<EOF
$LOG_DIR/*.log {
    size 10M
    rotate 3
    missingok
    notifempty
    compress
    copytruncate
}
EOF

    rc-update add remnanode default >/dev/null 2>&1 || warn "rc-update add remnanode failed"

    # logrotate runs from /etc/periodic/daily
    if [ -x /etc/init.d/crond ]; then
        rc-update add crond default >/dev/null 2>&1 || true
        if openrc_booted; then rc-service crond start >/dev/null 2>&1 || true; fi
    fi
}

start_service() {
    if [ "$START" != 1 ]; then
        log "Not starting the service (--no-start). Start it with: rc-service remnanode start"
        return 0
    fi

    if ! openrc_booted; then
        warn "OpenRC is not running on this system, start the node manually: $APP_DIR/deploy/remnanode-start"
        return 0
    fi

    log "Starting remnanode"
    rc-service remnanode restart >/dev/null || die "failed to start, see $LOG_DIR/node.log"

    sleep 3
    if ! rc-service remnanode status >/dev/null 2>&1; then
        tail -n 30 "$LOG_DIR/node.log" >&2 || true
        die "remnanode exited right after start, see $LOG_DIR/node.log"
    fi
}

check_limits() {
    # shellcheck disable=SC3045 # busybox ash supports ulimit -H
    hard=$(ulimit -Hn)
    if [ "$hard" != unlimited ] && [ "$hard" -lt 65536 ]; then
        warn "open files hard limit is $hard. For an LXC container raise it on the host:"
        warn "  add 'lxc.prlimit.nofile: 1048576' to /etc/pve/lxc/<id>.conf and restart the container"
    fi
}

print_summary() {
    cat <<EOF

  Remnawave Node is installed.

  Panel address   : <this host>:${NODE_PORT:-2222}
  Config          : $CONF_FILE
  Node log        : $LOG_DIR/node.log
  Xray log        : xlogs
  Service         : rc-service remnanode {status|restart|stop}
  CLI             : remnanode-cli
  Update          : sh install.sh update

EOF
}

do_install() {
    preflight
    install_packages
    configure
    install_app
    install_xray
    install_geocheck
    install_asn
    install_service
    check_limits
    start_service
    print_summary
}

do_update() {
    [ -d "$APP_DIR" ] || die "Remnawave Node is not installed, run: sh install.sh install"
    preflight
    install_packages
    if [ -n "$SECRET_KEY_ARG" ] || [ -n "$NODE_PORT_ARG" ]; then configure; fi
    install_app
    install_xray
    install_geocheck
    install_asn
    install_service
    start_service
    log "Updated to $(cat "$APP_DIR/VERSION")"
}

do_uninstall() {
    [ "$(id -u)" = 0 ] || die "please run as root"

    if service_running; then rc-service remnanode stop >/dev/null || true; fi
    rc-update del remnanode default >/dev/null 2>&1 || true

    rm -f "$INITD" "$BIN_DIR/remnanode-cli" "$BIN_DIR/xlogs" /etc/logrotate.d/remnanode
    rm -rf "$APP_DIR" "$APP_DIR.new" "$APP_DIR.old" /run/remnanode

    if [ "$PURGE" = 1 ]; then
        rm -rf "$CONF_DIR" "$STATE_DIR" "$LOG_DIR" /var/log/xray "$ASN_DIR" "$XRAY_ASSETS"
        rm -f "$BIN_DIR/xray" "$BIN_DIR/xray-custom" "$BIN_DIR/rw-core" "$BIN_DIR/.rw-core.json" "$BIN_DIR/geocheck"
        log "Remnawave Node, Xray, config and data removed"
    else
        log "Remnawave Node removed. Config ($CONF_FILE) and Xray were kept, use --purge to remove them"
    fi
}

do_status() {
    if openrc_booted; then rc-service remnanode status || true; fi
    if [ -f "$APP_DIR/VERSION" ]; then echo "version: $(cat "$APP_DIR/VERSION")"; fi
    if [ -f "$LOG_DIR/node.log" ]; then
        echo "--- $LOG_DIR/node.log"
        tail -n 20 "$LOG_DIR/node.log"
    fi
}

case "$ACTION" in
    install) do_install ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
    status) do_status ;;
esac
