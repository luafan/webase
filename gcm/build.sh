#!/bin/sh
# build.sh - compile gcm.so (Lua binding for AES-GCM with AAD) in Docker build stage.
#
# Designed to run inside a luafan base image (luafan/luafan-ubuntu or
# luafan/luafan-alpine) so OpenSSL runtime is already present. Only needs
# gcc + libssl-dev (or openssl-dev on Alpine) + Lua headers for the build.
#
# Unlike curlimp, this module links ONLY against libcrypto (OpenSSL) — no
# fan.so, no libevent, no external downloads. It is pure computation.
#
# Output layout:
#   lib/lua/5.3/gcm.so         (Lua module, NEEDED: libcrypto.so)
#
# Usage:
#   sh build.sh <TARGETARCH|amd64|arm64> <outdir>
#   e.g. sh build.sh amd64 /out
#
set -e

ARCH_ARG="$1"
OUT="$2"
[ -z "$OUT" ] && OUT=/out

# ---- arch: buildx TARGETARCH (amd64/arm64), fallback to uname -m ----
if [ -z "$ARCH_ARG" ]; then
  case "$(uname -m)" in
    x86_64)  ARCH_ARG=amd64 ;;
    aarch64) ARCH_ARG=arm64 ;;
    *) echo "cannot detect arch" >&2; exit 1 ;;
  esac
fi
case "$ARCH_ARG" in
  amd64) ARCH="x86_64"  ;;
  arm64) ARCH="aarch64" ;;
  *) echo "unsupported arch: $ARCH_ARG" >&2; exit 1 ;;
esac

# ---- libc: ubuntu -> gnu, alpine -> musl ----
if grep -qi alpine /etc/os-release 2>/dev/null; then
  LIBC="musl"
else
  LIBC="gnu"
fi
echo ">> gcm build: arch=$ARCH libc=$LIBC"

# ---- 1. Lua 5.3 headers (platform independent, from source) ----
if [ ! -f /tmp/lua-5.3.6/src/lua.h ]; then
  echo ">> downloading lua-5.3.6 headers"
  wget -q https://www.lua.org/ftp/lua-5.3.6.tar.gz -O /tmp/lua.tar.gz
  tar xzf /tmp/lua.tar.gz -C /tmp
fi
LUAINC="/tmp/lua-5.3.6/src"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT/lib/lua/5.3"

# ---- 2. compile gcm.so ----
# Links against libcrypto only (no fan.so, no libevent).
# rpath pinned to /usr/local/lib and /usr/local/lib/lua/5.3 so the module
# always finds libcrypto at runtime.
gcc -shared -fPIC -O2 \
    -I"$LUAINC" \
    -o "$OUT/lib/lua/5.3/gcm.so" "$SRC_DIR/luagcm.c" \
    -lcrypto \
    -Wl,-rpath,/usr/local/lib:/usr/local/lib/lua/5.3

rm -rf /tmp/lua.tar.gz
echo ">> built:"
ls -la "$OUT/lib/lua/5.3/gcm.so"
