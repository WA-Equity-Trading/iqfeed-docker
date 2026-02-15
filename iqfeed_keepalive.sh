#!/bin/bash
# IQFeed Keepalive Script
# Sends periodic requests to IQFeed to prevent idle timeout disconnection.
# Runs as a supervisor process alongside the main IQFeed client.

ADMIN_PORT=9300
LOOKUP_PORT=9100
PING_INTERVAL=15  # seconds between keepalive pings

echo "[keepalive] Starting IQFeed keepalive daemon (ping every ${PING_INTERVAL}s)"

# Wait for IQFeed to be ready before starting keepalive
echo "[keepalive] Waiting for IQFeed to start on port $ADMIN_PORT..."
MAX_WAIT=120
WAITED=0
while ! python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', $ADMIN_PORT)); s.close()" 2>/dev/null; do
  sleep 5
  WAITED=$((WAITED + 5))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[keepalive] IQFeed not responding after ${MAX_WAIT}s. Will keep trying..."
    WAITED=0
  fi
done
echo "[keepalive] IQFeed is responding on port $ADMIN_PORT!"

# Main keepalive loop
while true; do
  # Send a stats request to the admin port (lightweight keepalive)
  python3 -c "
import socket, time
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(('127.0.0.1', $ADMIN_PORT))
    s.sendall(b'S,STATS\r\n')
    data = s.recv(4096)
    status = data.decode('utf-8', errors='ignore').strip()[:80]
    print(f'[keepalive] Admin ping OK: {status}')
    s.close()
except Exception as e:
    print(f'[keepalive] Admin ping failed: {e}')
" 2>&1

  # Also ping the lookup port to keep that connection alive
  python3 -c "
import socket
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(('127.0.0.1', $LOOKUP_PORT))
    # Send a simple symbol lookup to keep lookup port active
    s.sendall(b'SBF,SPY,1,,,,\r\n')
    data = s.recv(4096)
    print(f'[keepalive] Lookup ping OK')
    s.close()
except Exception as e:
    print(f'[keepalive] Lookup ping failed: {e}')
" 2>&1

  sleep $PING_INTERVAL
done
