#!/bin/bash

set -euo pipefail

pkg_url="https://github.com/paawankohli/perftest/raw/refs/heads/main/WebsocketServerClient_v1.2.1.tar.gz"
pkg_sha256=
go_version="1.22.5"

INSTALL_DIR=/opt/websocket
LOG_FILE=/var/log/ws-backend.log
SETUP_LOG=/var/log/ws-setup.log
BIN=/usr/local/bin/ws-backend

mkdir -p "$(dirname "$SETUP_LOG")"
exec > >(tee -a "$SETUP_LOG") 2>&1
echo "=== ws_backend_cse.sh starting $(date -u +%FT%TZ) ==="

while [ "$#" -gt 0 ]; do
    case $1 in
        --pkg-url)    pkg_url="$2";    shift 2 ;;
        --sha256)     pkg_sha256="$2"; shift 2 ;;
        --go-version) go_version="$2"; shift 2 ;;
        *) echo "[Error] Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$pkg_url" ]; then
    echo "[Error] --pkg-url is required."
    exit 1
fi

# Refuse plaintext transports: the tarball is executed as root after extraction.
case "$pkg_url" in
    https://*) ;;
    *) echo "[Error] --pkg-url must be an https:// URL."; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# 1. Base packages
# ============================================================================
apt-get update -y
apt-get install -y curl ca-certificates tar

# ============================================================================
# 2. Go toolchain (official tarball — distro packages are often older than the
#    go 1.18 directive in the module, and the PPA is an extra failure point)
# ============================================================================
if [ ! -x /usr/local/go/bin/go ] || ! /usr/local/go/bin/go version | grep -q "go${go_version}"; then
    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64|arm64) ;;
        *) echo "[Error] Unsupported architecture: $arch"; exit 1 ;;
    esac
    curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 5 \
        -o /tmp/go.tar.gz "https://go.dev/dl/go${go_version}.linux-${arch}.tar.gz"
    rm -rf /usr/local/go
    tar -xzf /tmp/go.tar.gz -C /usr/local
    rm -f /tmp/go.tar.gz
fi
export PATH=/usr/local/go/bin:$PATH
export HOME=/root GOPATH=/root/go GOCACHE=/root/.cache/go-build
go version

# ============================================================================
# 3. Fetch + verify + extract the WebsocketServerClient package
# ============================================================================
curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 5 \
    -o /tmp/WebsocketServerClient.tar.gz "$pkg_url"

if [ ! -s /tmp/WebsocketServerClient.tar.gz ]; then
    echo "[Error] Downloaded package is empty: $pkg_url"
    exit 1
fi

if [ -n "$pkg_sha256" ]; then
    echo "${pkg_sha256}  /tmp/WebsocketServerClient.tar.gz" | sha256sum -c -
else
    echo "[Warn] No --sha256 supplied; the package is used without integrity verification."
fi

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf /tmp/WebsocketServerClient.tar.gz -C "$INSTALL_DIR"
rm -f /tmp/WebsocketServerClient.tar.gz

SRC="$INSTALL_DIR/WebsocketTesting/backendServer"
if [ ! -f "$SRC/server.go" ]; then
    echo "[Error] server.go not found at $SRC — unexpected package layout."
    exit 1
fi

# ============================================================================
# 4. Build a real binary (systemd supervises the server, not a `go run` child)
# ============================================================================
cd "$SRC"
go mod download
go build -o "$BIN" server.go
chmod +x "$BIN"

# ============================================================================
# 5. Kernel tuning for connection-heavy traffic (mirrors the LRT fleet)
# ============================================================================
cat << 'EOF' > /etc/sysctl.d/99-ws-perf.conf
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_tw_buckets = 16000
net.core.wmem_max = 33554432
net.core.rmem_max = 33554432
net.core.rmem_default = 20971520
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_max_orphans = 400000
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_max_syn_backlog = 32768
net.core.somaxconn = 32768
EOF
sysctl --system || true
# nf_conntrack is a module: only settable once loaded, and absent on some SKUs.
sysctl -w net.nf_conntrack_max=256000 2>/dev/null || true

# ============================================================================
# 6. systemd service
# ============================================================================
cat << EOF > /etc/systemd/system/ws-backend.service
[Unit]
Description=WebSocket echo server (backend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN}
LimitNOFILE=1048576
Restart=always
RestartSec=5
User=root
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /etc/logrotate.d/ws-backend
${LOG_FILE} {
    size 50M
    rotate 3
    copytruncate
    missingok
    notifempty
    compress
}
EOF

systemctl daemon-reload
systemctl enable ws-backend.service
systemctl restart ws-backend.service

sleep 3
systemctl is-active --quiet ws-backend.service || {
    echo "[Error] ws-backend.service failed to start:"
    journalctl -u ws-backend.service --no-pager -n 50 || true
    exit 1
}

echo "=== ws_backend_cse.sh completed. Listening on :8080 ==="
