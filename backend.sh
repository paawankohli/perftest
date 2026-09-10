#!/bin/bash
set -euo pipefail

sudo rm -f /var/lib/dpkg/lock-frontend
apt-get update -y && apt-get install -y nginx
echo $(hostname) | sudo tee /var/www/html/index.html
 
 
dd if=/dev/urandom of=/var/www/html/1kb.html bs=1024 count=1
dd if=/dev/urandom of=/var/www/html/10kb.html bs=10240 count=1
dd if=/dev/urandom of=/var/www/html/100kb.html bs=102400 count=1
dd if=/dev/urandom of=/var/www/html/1mb.html bs=1024000 count=1
dd if=/dev/urandom of=/var/www/html/10mb.html bs=10240000 count=1


# Compression would shrink the payloads on the wire and invalidate size comparisons.
sed -i 's/^\([[:space:]]*\)gzip on;/\1gzip off;/' /etc/nginx/nginx.conf
sed -i 's/^\([[:space:]]*\)worker_connections .*/\1worker_connections 16384;/' /etc/nginx/nginx.conf
grep -q '^worker_rlimit_nofile' /etc/nginx/nginx.conf || sed -i '/^worker_processes/a worker_rlimit_nofile 64000;' /etc/nginx/nginx.conf

mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/nofile.conf <<'EOF'
[Service]
LimitNOFILE=64000
EOF

cat > /etc/security/limits.d/99-perftest.conf <<'EOF'
*     soft nofile 64000
*     hard nofile 64000
root  soft nofile 64000
root  hard nofile 64000
EOF

systemctl daemon-reload
nginx -t && systemctl restart nginx

ulimit -n 64000
sysctl -w net.core.wmem_max=33554432
sysctl -w net.core.rmem_max=33554432
sysctl -w net.ipv4.tcp_max_syn_backlog="65535"
sysctl -w net.ipv4.tcp_synack_retries="1"
sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_max_orphans="400000"
# Only present once the conntrack module is loaded.
modprobe nf_conntrack || true
sysctl -w net.nf_conntrack_max="131000" || true
sysctl -w net.core.somaxconn="65536"
