#!/bin/bash

set -euo pipefail

pkg_url="https://github.com/paawankohli/perftest/raw/refs/heads/main/WebsocketServerClient_v1.2.1.tar.gz"
pkg_sha256=
go_version="1.22.5"

target_url=
max_connections=5000
max_new_cps=50
pause_between_messages=20
message_size="100"
duration=43200

INSTALL_DIR=/opt/websocket
LOG_FILE=/var/log/ws-client.log
SETUP_LOG=/var/log/ws-setup.log
BIN=/usr/local/bin/ws-client

mkdir -p "$(dirname "$SETUP_LOG")"
exec > >(tee -a "$SETUP_LOG") 2>&1
echo "=== ws_client_cse.sh starting $(date -u +%FT%TZ) ==="

while [ "$#" -gt 0 ]; do
    case $1 in
        --pkg-url)                pkg_url="$2";                shift 2 ;;
        --sha256)                 pkg_sha256="$2";             shift 2 ;;
        --go-version)             go_version="$2";             shift 2 ;;
        --target-url)             target_url="$2";             shift 2 ;;
        --max-connections)        max_connections="$2";        shift 2 ;;
        --max-new-cps)            max_new_cps="$2";            shift 2 ;;
        --pause-between-messages) pause_between_messages="$2"; shift 2 ;;
        --message-sizes)          message_size="$2";           shift 2 ;;
        --duration)               duration="$2";               shift 2 ;;
        *) echo "[Error] Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$pkg_url" ] || [ -z "$target_url" ]; then
    echo "[Error] --pkg-url and --target-url are both required."
    echo "        e.g. --target-url ws://10.0.1.99:80/   (or wss://<appgw-ip>:443/)"
    exit 1
fi

# Refuse plaintext transports: the tarball is executed as root after extraction.
case "$pkg_url" in
    https://*) ;;
    *) echo "[Error] --pkg-url must be an https:// URL."; exit 1 ;;
esac

case "$target_url" in
    ws://*|wss://*) ;;
    *) echo "[Error] --target-url must start with ws:// or wss://."; exit 1 ;;
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

SRC="$INSTALL_DIR/WebsocketTesting/client"
if [ ! -f "$SRC/client.go" ]; then
    echo "[Error] client.go not found at $SRC — unexpected package layout."
    exit 1
fi

# ============================================================================
# 4. Build a real binary (systemd supervises the client, not a `go run` child)
# ============================================================================
cd "$SRC"
go mod download
go build -o "$BIN" client.go
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
# Knobs live in an EnvironmentFile so the load can be retuned with an edit +
# `systemctl restart ws-client`, without re-running the extension.
cat << EOF > /etc/default/ws-client
WS_TARGET_URL=${target_url}
WS_MAX_CONNECTIONS=${max_connections}
WS_MAX_NEW_CPS=${max_new_cps}
WS_PAUSE_BETWEEN_MESSAGES=${pause_between_messages}
WS_MESSAGE_SIZES=${message_size}
WS_DURATION=${duration}
EOF

cat << EOF > /etc/systemd/system/ws-client.service
[Unit]
Description=WebSocket load client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ws-client
ExecStart=${BIN} -remoteUrl=\${WS_TARGET_URL} -maxConnections=\${WS_MAX_CONNECTIONS} -maxNewConnectionsPerSecond=\${WS_MAX_NEW_CPS} -pauseBetweenMessages=\${WS_PAUSE_BETWEEN_MESSAGES} -messageSizes=\${WS_MESSAGE_SIZES} -duration=\${WS_DURATION}
LimitNOFILE=1048576
Restart=always
RestartSec=5
User=root
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /etc/logrotate.d/ws-client
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
systemctl enable ws-client.service
systemctl restart ws-client.service

sleep 3
systemctl is-active --quiet ws-client.service || {
    echo "[Error] ws-client.service failed to start:"
    journalctl -u ws-client.service --no-pager -n 50 || true
    exit 1
}

echo "=== ws_client_cse.sh completed. Driving ${target_url} ==="
