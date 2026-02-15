#!/bin/bash
# start_and_download.sh
# Starts IQFeed Docker container, waits for it to be ready, then downloads data.
# Usage: ./start_and_download.sh
#
# Credentials: Copy .env.example to .env and set IQFEED_LOGIN and IQFEED_PASSWORD

set -e

# Load .env if present
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

CONTAINER_NAME="iqfeed-modern"
IMAGE="my-iqfeed:latest"
LOGIN="${IQFEED_LOGIN:?Set IQFEED_LOGIN in .env or export IQFEED_LOGIN}"
PASSWORD="${IQFEED_PASSWORD:?Set IQFEED_PASSWORD in .env or export IQFEED_PASSWORD}"
PRODUCT_ID="${IQFEED_PRODUCT_ID:?Set IQFEED_PRODUCT_ID in .env or export IQFEED_PRODUCT_ID}"

# Check if qdownload is in PATH
if ! command -v qdownload &>/dev/null; then
  export PATH="$PATH:$HOME/go/bin"
  if ! command -v qdownload &>/dev/null; then
    echo "ERROR: qdownload not found. Install it with: go install github.com/nhedlund/qdownload@latest"
    exit 1
  fi
fi

# Stop and remove existing container if running
echo "=== Cleaning up old container ==="
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Start fresh container
echo "=== Starting IQFeed container ==="
docker run -d --name "$CONTAINER_NAME" --platform=linux/amd64 \
  -e LOGIN="$LOGIN" \
  -e PASSWORD="$PASSWORD" \
  -e PRODUCT_ID="$PRODUCT_ID" \
  -p 5900:5900 \
  -p 5009:5010 \
  -p 9100:9101 \
  -p 9300:9301 \
  "$IMAGE"

# Wait for IQFeed to be ready
echo "=== Waiting for IQFeed to start ==="
MAX_WAIT=120
WAITED=0
while ! python3 -c "
import socket
s = socket.socket()
s.settimeout(2)
s.connect(('127.0.0.1', 9100))
s.close()
" 2>/dev/null; do
  sleep 5
  WAITED=$((WAITED + 5))
  echo "  Waiting... ($WAITED/${MAX_WAIT}s)"
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "ERROR: IQFeed not ready after ${MAX_WAIT}s"
    echo "Check VNC at localhost:5900 to see what's happening"
    echo "Container logs:"
    docker logs "$CONTAINER_NAME" --tail 20
    exit 1
  fi
done
echo "=== IQFeed is READY! ==="

# Give it a couple more seconds to fully stabilize
sleep 3

# ============================================
# DOWNLOAD DATA HERE - Edit these commands!
# ============================================
echo "=== Downloading data ==="

# EOD (daily) bars
qdownload -s 20251201 -e 20251210 -o data/eod eod SPY,AAPL,MSFT,GOOG,AMZN

# Minute bars (uncomment if needed)
# qdownload -s 20251201 -e 20251210 -o data/minute minute SPY

# Tick data (uncomment if needed)
# qdownload -s 20251204 -e 20251204 -o data/tick -z America/New_York tick SPY

echo ""
echo "=== Download complete! ==="
echo "Data saved to ./data/ directory"
echo ""
echo "Container is still running. You can run more downloads with:"
echo "  qdownload -s YYYYMMDD -e YYYYMMDD -o data/eod eod SYMBOL1,SYMBOL2"
echo ""
echo "To stop the container when done:"
echo "  docker stop $CONTAINER_NAME && docker rm $CONTAINER_NAME"
