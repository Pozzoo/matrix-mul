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

  echo "[discovery] broadcasting on UDP port $port..." >&2
  (echo "DISCOVER_MATRIX_WORKER" | nc -w1 -b 255.255.255.255 "$port" >/dev/null 2>&1) &

  timeout 2 nc -lu -p "$port" > "$tmpfile" 2>/dev/null || true

  echo "[discovery] received replies:" >&2
  cat "$tmpfile" >&2
  awk '/^WORKER / {print $2}' "$tmpfile" | sort -u
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
      discover_workers 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$hf"
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
  (
    while true; do
      msg=$(nc -lu -p "$port" -w1 2>/dev/null || true)
      if [ "$msg" = "DISCOVER_MATRIX_WORKER" ]; then
        ip=$(hostname -I | awk '{print $1}')
        # send back to broadcast address (so frontend receives)
        echo "WORKER $ip" | nc -w1 -u 255.255.255.255 "$port" >/dev/null 2>&1
        echo "found frontend"
      fi
    done
  ) &
fi

tail -f /dev/null
