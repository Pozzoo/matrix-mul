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

# Configure sshd properly
mkdir -p /run/sshd

SSH_PORT=2222

# Modify sshd_config to ensure correct settings
if ! grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config 2>/dev/null; then
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
fi
if ! grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config 2>/dev/null; then
  echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
fi
if ! grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config 2>/dev/null; then
  echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
fi
if ! grep -q '^AuthorizedKeysFile' /etc/ssh/sshd_config 2>/dev/null; then
  echo 'AuthorizedKeysFile /root/.ssh/authorized_keys' >> /etc/ssh/sshd_config
fi
if ! grep -q '^UseDNS no' /etc/ssh/sshd_config 2>/dev/null; then
  echo 'UseDNS no' >> /etc/ssh/sshd_config
fi

# Set the port
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config

# Ensure /run/sshd exists
mkdir -p /run/sshd
chmod 755 /run/sshd

# Start sshd in background
$SSHD -D -e &
SSHD_PID=$!

# Give it a moment
sleep 1

# Check if sshd is alive
if ! kill -0 $SSHD_PID 2>/dev/null; then
    echo "[error] sshd process died immediately after starting!"
    echo "[error] Checking port status..." >&2
    netstat -tuln | grep ':2222' || echo "No SSH ports listening"
    exit 1
fi

echo "[entry] sshd started successfully on port $SSH_PORT (PID: $SSHD_PID)"

# env defaults
MODE=${MODE:-mpi}         # linear | mt | mpi
DATA_DIR=${DATA_DIR:-/data}
NUM_PROCS=${NUM_PROCS:-3}
SLEEP_BEFORE_MPIRUN=${SLEEP_BEFORE_MPIRUN:-1}

# discover workers via UDP broadcast
discover_workers() {
  local port=${DISCOVERY_PORT:-4000}
  local wait_secs=${DISCOVERY_TIMEOUT:-10}
  local tmpfile
  tmpfile=$(mktemp)

  local frontend_ip iface
  frontend_ip=$(hostname -I | awk '{print $1}')
  iface=$(ip route | awk '/default/ {print $5; exit}')

  echo "[discovery] frontend IP: $frontend_ip" >&2
  echo "[discovery] using interface: $iface" >&2
  echo "[discovery] starting listener on UDP port $port for ${wait_secs}s..." >&2

  setsid sh -c "while :; do socat UDP4-RECVFROM:${port},reuseaddr,broadcast - | tee -a '${tmpfile}' >/dev/null; done" &
  listener_pid=$!

  sleep 0.2

  echo "[discovery] broadcasting discovery packet on 192.168.0.255:$port" >&2
  echo "DISCOVER_MATRIX_WORKER ${frontend_ip}" | socat -T1 - UDP4-DATAGRAM:192.168.0.255:"${port}",broadcast,INTERFACE="${iface}" >/dev/null 2>&1 || true

  sleep "${wait_secs}"

  if kill -0 "$listener_pid" 2>/dev/null; then
    pgid=$(ps -o pgid= -p "$listener_pid" | tr -d ' ')
    if [ -n "$pgid" ]; then
      kill -TERM -"${pgid}" 2>/dev/null || true
    else
      kill -TERM "$listener_pid" 2>/dev/null || true
    fi
  fi

  wait "$listener_pid" 2>/dev/null || true

  echo "[discovery] checking replies..." >&2

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
      echo "[entry] checking SSH connectivity to $worker_ip..."
      
      ssh_port=2222
      
      # Wait for SSH to be available on worker (max 30 seconds)
      ssh_ready=false
      for i in {1..30}; do
        if nc -z -w1 "$worker_ip" "$ssh_port" 2>/dev/null; then
          ssh_ready=true
          echo "[entry]   SSH port $ssh_port is open on $worker_ip"
          break
        fi
        echo "[entry]   waiting for SSH on $worker_ip:$ssh_port (attempt $i/30)..."
        sleep 1
      done
      
      if [ "$ssh_ready" = false ]; then
        echo "[error] SSH port not available on $worker_ip after 30 seconds"
        all_workers_ok=false
        continue
      fi
      
      # Test SSH authentication (should work now with shared keys)
      echo "[entry] testing SSH authentication to $worker_ip:$ssh_port..."
      if ssh -n -p "$ssh_port" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "root@$worker_ip" "echo 'SSH OK'" >/dev/null 2>&1; then
        echo "[entry] ✓ SSH to $worker_ip:$ssh_port: OK"
      else
        echo "[error] ✗ SSH to $worker_ip:$ssh_port: FAILED"
        all_workers_ok=false
      fi
    fi
  done < "$HF"

  if [ "$all_workers_ok" = false ]; then
    echo "[error] Not all workers are accessible via SSH. MPI may fail."
    exit 1
  fi

  echo "[entry] all workers are accessible via SSH ✓"
  echo "[entry] launching mpiexec -f $HF -np $NUM_HOSTS ${APP_BIN} --mode mpi --data ${DATA_DIR}"
  mpiexec -f /tmp/hostfile -np "$NUM_HOSTS" /app/matrix-mul --mode mpi --data /data


  echo "[entry] mpiexec finished"
  sleep 1
  exit 0
fi

# Worker containers
echo "[entry] worker container: sshd running on port $SSH_PORT; awaiting mpiexec from frontend"

if [ "${DISCOVERY:-0}" = "1" ]; then
  port=4000
  iface=eth0
  echo "[entry] worker: starting UDP discovery responder on ${iface}:${port}"

  responder_script=$(mktemp)
  cat > "$responder_script" <<'EOF'
#!/usr/bin/env bash
set +u
msg=$(cat)
if echo "$msg" | grep -q "^DISCOVER_MATRIX_WORKER"; then
  sender_ip=$(echo "$msg" | awk '{print $2}')
  my_ip=$(hostname -I | awk '{print $1}')
  echo "[entry] worker: replying to $sender_ip with my IP $my_ip" >&2
  echo "WORKER $my_ip" | socat -u - UDP4-DATAGRAM:"$sender_ip":4000,sourceport=4000,INTERFACE=eth0,reuseaddr
fi
EOF
  chmod +x "$responder_script"

  socat -u UDP4-RECVFROM:"$port",reuseaddr,broadcast,INTERFACE="${iface}" SYSTEM:"$responder_script" &
fi

tail -f /dev/null
