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
# minimal sshd config adjustments for dev: permit root login via key
mkdir -p /run/sshd
if ! grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
  echo 'UseDNS no' >> /etc/ssh/sshd_config
fi
$SSHD

# env defaults
MODE=${MODE:-mpi}         # linear | mt | mpi (frontend spawns mpiexec)
DATA_DIR=${DATA_DIR:-/data}
NUM_PROCS=${NUM_PROCS:-3}
THREADS=${THREADS:-4}
N=${N:-200}
SLEEP_BEFORE_MPIRUN=${SLEEP_BEFORE_MPIRUN:-1}

hostname="$(hostname)"

# discover workers via UDP broadcast
discover_workers() {
  local port=${DISCOVERY_PORT:-4000}
  local tmpfile
  tmpfile=$(mktemp)
  local frontend_ip

  frontend_ip=$(hostname -I | awk '{print $1}')
  echo "[discovery] frontend IP: $frontend_ip" >&2

  # Start listening BEFORE sending (in background)
  echo "[discovery] starting listener on UDP port $port..." >&2
  (
    # Listen for up to 3 seconds and write to tmpfile
    timeout 3 sh -c "nc -u -l -p $port >'$tmpfile' 2>/dev/null"
  ) &

  sleep 0.3

  # Broadcast discovery packet
  echo "[discovery] broadcasting discovery packet on 192.168.0.255:$port" >&2
  echo "DISCOVER_MATRIX_WORKER $frontend_ip" | nc -u -w1 -b 192.168.0.255 "$port" >/dev/null 2>&1 || true

  # Wait for listener to finish
  wait || true

  echo "[discovery] received replies:" >&2
  if [ -s "$tmpfile" ]; then
    cat "$tmpfile" >&2
    awk '/^WORKER / {print $2}' "$tmpfile" | sort -u
  else
    echo "[discovery] no replies received" >&2
  fi
}

# build a hostfile: include localhost and resolve 'worker' DNS or discovery
build_hostfile() {
  hf=/tmp/hostfile
  : > "$hf"

  # Get frontend’s own reachable IP
  frontend_ip=$(hostname -I | awk '{print $1}')
  echo "$frontend_ip" >> "$hf"

  if [ "${DISCOVERY:-0}" = "1" ]; then
      # Only append valid IPs (suppress debug output)
      (discover_workers) 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$hf"
  elif getent ahosts worker >/dev/null 2>&1; then
    getent ahosts worker | awk '{print $1}' | uniq >> "$hf"
  fi

  echo "$hf"
}


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

# MPI mode: only frontend launches mpiexec; workers keep sshd alive for mpiexec to ssh into
if [ "$hostname" = "frontend" ] && [ "$MODE" = "mpi" ]; then
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

# workers or non-frontend in MPI mode: keep sshd running so frontend's mpiexec can ssh here
echo "[entry] worker container: sshd running; awaiting mpiexec from frontend"

# worker: reply to UDP discovery packets if DISCOVERY=1
if [ "${DISCOVERY:-0}" = "1" ]; then
  port=${DISCOVERY_PORT:-4000}
  echo "[entry] worker: starting UDP discovery responder on port $port"

  while true; do
    # Receive one message, capture sender IP
    msg_and_ip=$(timeout 3 nc -u -l -p "$port" -v 2>&1 || true)
    sender_ip=$(echo "$msg_and_ip" | grep "Connection from" | awk '{print $3}' | cut -d'.' -f1-4)

    if echo "$msg_and_ip" | grep -q "DISCOVER_MATRIX_WORKER"; then
      ip=$(hostname -I | awk '{print $1}')
      echo "[entry] worker: replying to $sender_ip with my IP $ip"
      echo "WORKER $ip" | nc -u -w1 "$sender_ip" "$port"
    fi
  done &
fi

tail -f /dev/null
