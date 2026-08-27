#!/usr/bin/env bash
# Alpine release smoke: exercise the full webase suite against Dockerfile.alpine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/run.sh" Dockerfile.alpine
