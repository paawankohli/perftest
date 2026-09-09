sudo tee /usr/local/bin/appgw-softirq-probe.sh >/dev/null <<'EOF'
#!/bin/bash
# Samples /proc/stat, /proc/softirqs, /proc/net/softnet_stat and appends one JSON
# record per core per interval to the bootstrap log (fluent-bit -> ApplicationGatewayBootstrap).
set -u

LOG=${LOG:-/var/log/appgwbootstrap/bootstrap.log}
INTERVAL=${INTERVAL:-1}
DURATION=${DURATION:-1800}
COMPONENT=ProcStatProbe
ACTIVITY=SoftirqProbe
MYPID=$$
echo $MYPID > /run/appgw-softirq-probe.pid

declare -A P
first=1
end=$(( SECONDS + DURATION ))

pct() { printf '%d.%02d' $(( $1 * 100 / $2 )) $(( ( $1 * 10000 / $2 ) % 100 )); }

emit() {
  local now
  printf -v now '%(%Y-%m-%dT%H:%M:%S)T' -1
  printf '{"TimeStamp":"%s.0000000Z","GatewayName":"","GatewayVersion":"","ComponentName":"%s","ActivityId":"","OperationId":"","ActivityName":"%s","Tid":0,"Pid":%d,"Level":"INFO","Msg":"%s"}\n' \
    "$now" "$COMPONENT" "$ACTIVITY" "$MYPID" "$1" >> "$LOG"
}

while (( SECONDS < end )); do
  unset C; declare -A C

  while read -r n u ni sy id io hi si st _; do
    [[ $n == cpu[0-9]* ]] || continue
    C[$n.user]=$u;  C[$n.nice]=$ni; C[$n.sys]=$sy;   C[$n.idle]=$id
    C[$n.iow]=$io;  C[$n.irq]=$hi;  C[$n.sirq]=$si;  C[$n.steal]=${st:-0}
  done < /proc/stat

  while read -r tag rest; do
    case $tag in
      NET_RX:) k=netrx ;;
      NET_TX:) k=nettx ;;
      *) continue ;;
    esac
    i=0; for v in $rest; do C[cpu$i.$k]=$v; i=$(( i + 1 )); done
  done < /proc/softirqs

  i=0
  while read -r pr dr sq _; do
    C[cpu$i.proc]=$(( 16#$pr )); C[cpu$i.drop]=$(( 16#$dr )); C[cpu$i.sqz]=$(( 16#$sq ))
    i=$(( i + 1 ))
  done < /proc/net/softnet_stat

  if (( first )); then
    first=0
  else
    c=0
    while [[ -n ${C[cpu$c.user]:-} ]]; do
      k=cpu$c
      du=$(( C[$k.user] - P[$k.user] )); dn=$(( C[$k.nice] - P[$k.nice] ))
      ds=$(( C[$k.sys]  - P[$k.sys]  )); di=$(( C[$k.idle] - P[$k.idle] ))
      dw=$(( C[$k.iow]  - P[$k.iow]  )); dq=$(( C[$k.irq]  - P[$k.irq]  ))
      dx=$(( C[$k.sirq] - P[$k.sirq] )); dt=$(( C[$k.steal]- P[$k.steal]))
      tot=$(( du + dn + ds + di + dw + dq + dx + dt ))
      if (( tot > 0 )); then
        emit "PROBE core=$k ticks=$tot usr=$(pct $du $tot) sys=$(pct $ds $tot) irq=$(pct $dq $tot) sirq=$(pct $dx $tot) iowait=$(pct $dw $tot) steal=$(pct $dt $tot) idle=$(pct $di $tot) netrx=$(( C[$k.netrx] - P[$k.netrx] )) nettx=$(( C[$k.nettx] - P[$k.nettx] )) softnet_proc=$(( C[$k.proc] - P[$k.proc] )) softnet_drop=$(( C[$k.drop] - P[$k.drop] )) softnet_squeeze=$(( C[$k.sqz] - P[$k.sqz] ))"
      fi
      c=$(( c + 1 ))
    done
  fi

  for key in "${!C[@]}"; do P[$key]=${C[$key]}; done
  sleep "$INTERVAL"
done
EOF
sudo chmod +x /usr/local/bin/appgw-softirq-probe.sh
