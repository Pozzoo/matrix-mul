#!/usr/bin/env bash
set -euo pipefail

# minimal sshd startup and optional mpiexec invocation on frontend
SSH_DIR=/root/.ssh
SSHD=/usr/sbin/sshd
APP_BIN=/app/matrix-mul

# SSH keys are already in the image, just ensure proper permissions
chmod 700 "$SSH_DIR" 2>/dev/null || true
chmod 600 "$SSH_DIR/id_rsa" 2>/dev/null || true
chmod 644 "$SSH_DIR/id_rsa.pub" 2>/dev/null || true
chmod 600 "$SSH_DIR/authorized_keys" 2>/dev/null || true

# start sshd
mkdir -p /run/sshd
if ! grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
  echo 'UseDNS no' >> /etc/ssh/sshd_config
fi
$SSHD

# env defaults
MODE=${MODE:-mpi}         # linear | mt | mpi
DATA_DIR=${DATA_DIR:-/data}
NUM_PROCS=${NUM_PROCS:-3}
SLEEP_BEFORE_MPIRUN=${SLEEP_BEFORE_MPIRUN:-1}

# discover workers via UDP broadcast
discover_workers() {
  local port=${DISCOVERY_PORT:-4000}
  local wait_secs=${DISCOVERY_TIMEOUT:-10}   # change default wait time here
  local tmpfile
  tmpfile=$(mktemp)

  local frontend_ip iface
  frontend_ip=$(hostname -I | awk '{print $1}')
  iface=$(ip route | awk '/default/ {print $5; exit}')

  echo "[discovery] frontend IP: $frontend_ip" >&2
  echo "[discovery] using interface: $iface" >&2
  echo "[discovery] starting listener on UDP port $port for ${wait_secs}s..." >&2

  # Start socat in its own session so we can always kill it reliably later.
  # We append replies to tmpfile (one datagram per line).
  setsid sh -c "while :; do socat UDP4-RECVFROM:${port},reuseaddr,broadcast - | tee -a '${tmpfile}' >/dev/null; done" &
  listener_pid=$!

  # Give listener a moment to bind
  sleep 0.2

  echo "[discovery] broadcasting discovery packet on 192.168.0.255:$port" >&2
  # send our own IP so workers can reply
  echo "DISCOVER_MATRIX_WORKER ${frontend_ip}" | socat -T1 - UDP4-DATAGRAM:192.168.0.255:"${port}",broadcast,INTERFACE="${iface}" >/dev/null 2>&1 || true

  # Wait explicitly the desired amount of time for replies to arrive
  sleep "${wait_secs}"

  # Cleanly kill the listener session (kill the whole process group)
  if kill -0 "$listener_pid" 2>/dev/null; then
    # negative PID kills process group started by setsid
    pgid=$(ps -o pgid= -p "$listener_pid" | tr -d ' ')
    if [ -n "$pgid" ]; then
      kill -TERM -"${pgid}" 2>/dev/null || true
    else
      kill -TERM "$listener_pid" 2>/dev/null || true
    fi
  fi

  # Wait for listener to exit
  wait "$listener_pid" 2>/dev/null || true

  echo "[discovery] checking replies..." >&2

  # Filter out self-echo, print workers if present
  workers=$(awk -v self="$frontend_ip" '/WORKER / && $2 != self {print $2}' "$tmpfile" | sort -u)

  if [ -n "$workers" ]; then
    echo "[discovery] received replies:" >&2
    echo "$workers" >&2
    printf '%s\n' "$workers"
  else
    echo "[discovery] no replies received" >&2
  fi

  rm -f "$tmpfile" 2>/dev/null || true
}

# build a hostfile
build_hostfile() {
  hf=/tmp/hostfile
  : > "$hf"

  frontend_ip=$(hostname -I | awk '{print $1}')
  echo "$frontend_ip" >> "$hf"

  if [ "${DISCOVERY:-0}" = "1" ]; then
    discover_workers | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$hf"
  elif getent ahosts worker >/dev/null 2>&1; then
    getent ahosts worker | awk '{print $1}' | uniq >> "$hf"
  fi

  echo "$hf"
}

# ---- Execution modes ----
if [ "$MODE" = "linear" ]; then
  echo "[entry] running linear mode"
  "$APP_BIN" --mode linear --data "$DATA_DIR"
  exit 0
fi

if [ "$MODE" = "mt" ]; then
  echo "[entry] running multithreaded mode"
  "$APP_BIN" --mode mt --data "$DATA_DIR"
  exit 0
fi

if [ "$MODE" = "frontend" ]; then
  HF="$(build_hostfile)"
  echo "[entry] hostfile:"
  cat "$HF"
  NUM_HOSTS=$(wc -l < "$HF")

  frontend_ip=$(hostname -I | awk '{print $1}')

  echo "[entry] testing SSH connectivity to all workers..."
  all_workers_ok=true
  while read -r worker_ip; do
    if [ "$worker_ip" != "$frontend_ip" ]; then
      echo "[entry] waiting for SSH on $worker_ip..."
      
      # Wait for SSH to be available on worker (max 30 seconds)
      ssh_ready=false
      for i in {1..30}; do
        if nc -z -w1 "$worker_ip" 22 2>/dev/null; then
          ssh_ready=true
          break
        fi
        echo "[entry]   attempt $i/30..."
        sleep 1
      done
      
      if [ "$ssh_ready" = false ]; then
        echo "[error] SSH not available on $worker_ip after 30 seconds"
        all_workers_ok=false
        continue
      fi
      
      # Test SSH connectivity (should work now with shared keys)
      if ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "root@$worker_ip" "echo 'SSH OK'" >/dev/null 2>&1; then
        echo "[entry] ✓ SSH to $worker_ip: OK"
      else
        echo "[error] ✗ SSH to $worker_ip: FAILED"
        all_workers_ok=false
      fi
    fi
  done < "$HF"

  if [ "$all_workers_ok" = false ]; then
    echo "[error] Not all workers are accessible via SSH. MPI may fail."
    exit 1
  fi

  echo "[entry] launching mpiexec -f $HF -np $NUM_HOSTS ${APP_BIN} --mode mpi --data ${DATA_DIR}"
  mpiexec -f "$HF" -np "$NUM_HOSTS" "$APP_BIN" --mode mpi --data "${DATA_DIR}"

  echo "[entry] mpiexec finished"
  sleep 1
  exit 0
fi

# Worker containers
echo "[entry] worker container: sshd running; awaiting mpiexec from frontend"

if [ "${DISCOVERY:-0}" = "1" ]; then
  port=4000
  iface=eth0
  echo "[entry] worker: starting UDP discovery responder on ${iface}:${port}"

  responder_script=$(mktemp)
  cat > "$responder_script" <<'EOF'
#!/usr/bin/env bash
set +u  # disable unbound variable errors here
msg=$(cat)  # read entire datagram from stdin
if echo "$msg" | grep -q "^DISCOVER_MATRIX_WORKER"; then
  sender_ip=$(echo "$msg" | awk '{print $2}')
  my_ip=$(hostname -I | awk '{print $1}')
  echo "[entry] worker: replying to $sender_ip with my IP $my_ip" >&2
  echo "WORKER $my_ip" | socat -u - UDP4-DATAGRAM:"$sender_ip":4000,sourceport=4000,INTERFACE=eth0,reuseaddr
fi
EOF
  chmod +x "$responder_script"

  # Now start socat using the script
  socat -u UDP4-RECVFROM:"$port",reuseaddr,broadcast,INTERFACE="${iface}" SYSTEM:"$responder_script" &
fi


tail -f /dev/null
