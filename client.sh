#!/bin/bash
set -euo pipefail

wget https://github.com/tsenart/vegeta/releases/download/v12.8.4/vegeta_12.8.4_linux_amd64.tar.gz
tar xfz ./vegeta_12.8.4_linux_amd64.tar.gz
sudo mv vegeta /usr/bin/vegeta

# ulimit alone dies with this script, so raise the limit for later interactive/SSH sessions too.
cat > /etc/security/limits.d/99-perftest.conf <<'EOF'
*     soft nofile 64000
*     hard nofile 64000
root  soft nofile 64000
root  hard nofile 64000
EOF

ulimit -n 64000
sysctl -w net.core.wmem_max=33554432
sysctl -w net.core.rmem_max=33554432
sysctl -w net.ipv4.tcp_max_syn_backlog="16384"
sysctl -w net.ipv4.tcp_synack_retries="1"
sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_max_orphans="400000"
# Only present once the conntrack module is loaded.
modprobe nf_conntrack || true
sysctl -w net.nf_conntrack_max="131000" || true