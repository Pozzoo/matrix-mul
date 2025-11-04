#!/usr/bin/env bash
set -euo pipefail

# minimal sshd startup and optional mpiexec invocation on frontend
SSH_DIR=/root/.ssh
SSHD=/usr/sbin/sshd
APP_BIN=/app/matrix-mul

# Ensure SSH keys exist (generate only if missing)
mkdir -p "$SSH_DIR"
if [ ! -f "$SSH_DIR/id_rsa" ]; then
  ssh-keygen -t rsa -N "" -f "$SSH_DIR/id_rsa" >/dev/null 2>&1 || true
  cat "$SSH_DIR/id_rsa.pub" >> "$SSH_DIR/authorized_keys"
  chmod 600 "$SSH_DIR/authorized_keys"
fi

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
  setsid sh -c "while :; do socat -u - UDP4-RECVFROM:${port},reuseaddr,broadcast,INTERFACE=${iface} - 2>/dev/null >>'${tmpfile}'; done" &
  listener_pid=$!

  # Give listener a moment to bind
  sleep 0.2

  echo "[discovery] broadcasting discovery packet on 192.168.0.255:$port" >&2
  # send our own IP so workers can reply
  socat -T1 -u - UDP4-DATAGRAM:192.168.0.255:"${port}",broadcast,INTERFACE="${iface}" <<< "DISCOVER_MATRIX_WORKER ${frontend_ip}" >/dev/null 2>&1 || true

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
  workers=$(awk -v self="$frontend_ip" '/^DISCOVER_MATRIX_WORKER / && $2 != self {print $2}' "$tmpfile" | sort -u)

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
  echo "[entry] frontend: waiting ${SLEEP_BEFORE_MPIRUN}s for workers to register"
  sleep "$SLEEP_BEFORE_MPIRUN"

  HF="$(build_hostfile)"
  echo "[entry] hostfile:"
  cat "$HF"
  NUM_HOSTS=$(wc -l < "$HF")

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
