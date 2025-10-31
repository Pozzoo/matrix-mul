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

# build a hostfile: include localhost and resolve 'worker' DNS which returns one record per scaled container
build_hostfile() {
  hf=/tmp/hostfile
  : > "$hf"
  # local host first (frontend)
  echo "localhost slots=1" >> "$hf"

  # find worker IPs via getent (returns multiple results when service scaled)
  if getent ahosts worker >/dev/null 2>&1; then
    getent ahosts worker | awk '{print $1}' | uniq | while read -r ip; do
      if [ -n "$ip" ]; then
        echo "${ip} slots=1" >> "$hf"
      fi
    done
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
  echo "[entry] launching mpiexec -f $HF -np ${NUM_PROCS} ${APP_BIN} --mode mpi --data ${DATA_DIR}"
  mpiexec -f "$HF" -np "${NUM_PROCS}" "$APP_BIN" --mode mpi --data "${DATA_DIR}"
  echo "[entry] mpiexec finished"
  sleep 1
  exit 0
fi

# workers or non-frontend in MPI mode: keep sshd running so frontend's mpiexec can ssh here
echo "[entry] worker container: sshd running; awaiting mpiexec from frontend"
tail -f /dev/null
