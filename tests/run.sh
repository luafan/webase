#!/usr/bin/env bash
# Integration test runner for webase
# Builds Docker image, starts container, runs tests, cleans up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="webase-test"
CONTAINER_NAME="webase-test-$$"
CONTAINER_PORT=2201
PURGE_TOKEN="test_secret_token"
HOST_PORT=""
MAX_WAIT=30

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    if docker ps -q -f "name=$CONTAINER_NAME" | grep -q .; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "  Container removed."
}

trap cleanup EXIT

DOCKERFILE_PATH="$PROJECT_DIR/${1:-Dockerfile}"
docker build --network=host -f "$DOCKERFILE_PATH" -t "$IMAGE_NAME" "$PROJECT_DIR"
echo "  Image built: $IMAGE_NAME"

echo ""
echo "=== Starting Container ==="
docker run -d \
    --name "$CONTAINER_NAME" \
    -p "0:$CONTAINER_PORT" \
    -e "PURGE_TOKEN=$PURGE_TOKEN" \
    -v "$SCRIPT_DIR/fixtures/handle:/root/handle:ro" \
    -v "$SCRIPT_DIR/fixtures/service:/root/service:ro" \
    "$IMAGE_NAME" >/dev/null

HOST_PORT=$(docker port "$CONTAINER_NAME" "$CONTAINER_PORT" | head -1 | cut -d: -f2)
BASE_URL="http://127.0.0.1:$HOST_PORT"
echo "  Container: $CONTAINER_NAME"
echo "  Listening: $BASE_URL"

echo ""
echo "=== Waiting for Server ==="
elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    if curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/" 2>/dev/null | grep -qE "^[2345]"; then
        echo "  Server ready after ${elapsed}s"
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ $elapsed -ge $MAX_WAIT ]; then
    echo "  ERROR: Server did not start within ${MAX_WAIT}s"
    echo "  Container logs:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -20
    exit 1
fi

echo ""

# Run tests
TOTAL_PASSED=0
TOTAL_FAILED=0

run_suite() {
    local script="$1"
    local name="$2"
    echo ""
    set +e
    BASE_URL="$BASE_URL" PURGE_TOKEN="$PURGE_TOKEN" CONTAINER_NAME="$CONTAINER_NAME" bash "$script"
    local failures=$?
    set -e

    if [ $failures -eq 0 ]; then
        echo "  [$name] All tests passed."
    else
        echo "  [$name] $failures test(s) failed."
        TOTAL_FAILED=$((TOTAL_FAILED + failures))
    fi
}

run_suite "$SCRIPT_DIR/test_functional.sh" "Functional"
run_suite "$SCRIPT_DIR/test_security.sh" "Security"
run_suite "$SCRIPT_DIR/test_websocket.sh" "WebSocket"

echo ""
echo "==============================="
echo "  FINAL RESULT"
echo "==============================="

if [ $TOTAL_FAILED -eq 0 ]; then
    echo "  ALL TESTS PASSED"
    exit 0
else
    echo "  $TOTAL_FAILED test(s) FAILED"
    echo ""
    echo "  Container logs (last 30 lines):"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -30
    exit 1
fi
