#!/usr/bin/env bash
# WebSocket integration tests for webase
# Runs a Lua test client inside the running container

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:2201}"
CONTAINER_NAME="${CONTAINER_NAME:-}"

FAILURES=0

echo "=== WebSocket Tests ==="

# Find the container name from the environment or by convention
if [ -z "$CONTAINER_NAME" ]; then
    # Try to detect container from BASE_URL port
    PORT=$(echo "$BASE_URL" | grep -oP ':\K[0-9]+$')
    if [ -n "$PORT" ]; then
        CONTAINER_NAME=$(docker ps --format '{{.Names}}' --filter "publish=$PORT" | head -1)
    fi
fi

if [ -z "$CONTAINER_NAME" ]; then
    echo "  SKIP: Cannot determine container name for WebSocket test"
    exit 0
fi

# Copy test script into container and run it
docker cp "$(dirname "$0")/fixtures/test_websocket.lua" "$CONTAINER_NAME:/root/test_websocket.lua"

# Run test; fan.loop may not exit cleanly after os.exit, use timeout
OUTPUT=$(docker exec "$CONTAINER_NAME" lua /root/test_websocket.lua 2>&1)
RC=$?
echo "$OUTPUT"

# Extract pass/fail from output
if echo "$OUTPUT" | grep -q "0 failed"; then
    exit 0
else
    exit 1
fi
