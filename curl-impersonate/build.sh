#!/bin/sh
# build.sh - compile curlimp.so (Lua binding for curl-impersonate) in Docker build stage.
#
# Designed to run inside a luafan base image (luafan/luafan-ubuntu or
# luafan/luafan-alpine) so fan.so, libevent runtime, and Lua 5.3 are already
# present. Only gcc/libevent-dev/wget need to be installed for the build.
#
# Downloads the matching prebuilt libcurl-impersonate from
# lexiforest/curl-impersonate releases (arch x libc), plus the Lua 5.3
# headers from lua.org, then compiles curlimp.so against it.
#
# curlimp.so is the coroutine-friendly (curl_multi + libevent) binding; it
# links against fan.so (event_mgr_base / utlua_mainthread / FAN_RESUME) and
# libevent, and yields the calling Lua thread while a request is in flight.
#
# The output dir gets:
#   curlimp.so                    (Lua module,
#                                  NEEDED: libcurl-impersonate.so.4, fan.so,
#                                          libevent-2.1.so.7)
#   libcurl-impersonate.so.4.8.0  (prebuilt lib)
#   libcurl-impersonate.so.4 ->   (soname symlink)
#   libcurl-impersonate.so  ->    (generic symlink)
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
echo ">> curlimp build: arch=$ARCH libc=$LIBC"

# ---- 1. prebuilt libcurl-impersonate (has include/curl/curl.h) ----
VERSION="v2.0.0"
BASE="https://github.com/lexiforest/curl-impersonate/releases/download/${VERSION}"
PKG="libcurl-impersonate-${VERSION}.${ARCH}-linux-${LIBC}.tar.gz"

echo ">> downloading ${PKG}"
wget -q "${BASE}/${PKG}" -O /tmp/ci.tar.gz
mkdir -p /tmp/ci
tar xzf /tmp/ci.tar.gz -C /tmp/ci

# ---- 2. Lua 5.3 headers (platform independent, from source) ----
if [ ! -f /tmp/lua-5.3.6/src/lua.h ]; then
  echo ">> downloading lua-5.3.6 headers"
  wget -q https://www.lua.org/ftp/lua-5.3.6.tar.gz -O /tmp/lua.tar.gz
  tar xzf /tmp/lua.tar.gz -C /tmp
fi
LUAINC="/tmp/lua-5.3.6/src"

# ---- 3. compile curlimp.so ----
# Link against:
#   libcurl-impersonate.so.4.8.0 (own SONAME, independent from system libcurl)
#   fan.so                        (event_mgr_base / utlua_mainthread / FAN_RESUME)
#   libevent                      (curl_multi socket/timer plumbing)
# rpath pinned to /usr/local/lib and /usr/local/lib/lua/5.3 so the module
# never picks up another libcurl and always finds fan.so at runtime.
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
FAN_SO_DIR="/usr/local/lib/lua/5.3"
if [ ! -f "$FAN_SO_DIR/fan.so" ]; then
  echo "!! fan.so not found at $FAN_SO_DIR — must build inside a luafan base image" >&2
  exit 1
fi
mkdir -p "$OUT"
gcc -shared -fPIC -O2 \
    -I"$LUAINC" -I/tmp/ci/include \
    -o "$OUT/curlimp.so" "$SRC_DIR/luacurlimp.c" \
    -L/tmp/ci -l:libcurl-impersonate.so.4.8.0 \
    -L"$FAN_SO_DIR" -l:fan.so \
    -levent \
    -Wl,-rpath,/usr/local/lib:/usr/local/lib/lua/5.3

# ---- 4. install prebuilt lib + soname links into out dir ----
cp -f /tmp/ci/libcurl-impersonate.so.4.8.0 "$OUT/"
ln -sf libcurl-impersonate.so.4.8.0 "$OUT/libcurl-impersonate.so.4"
ln -sf libcurl-impersonate.so.4.8.0 "$OUT/libcurl-impersonate.so"

rm -rf /tmp/ci /tmp/ci.tar.gz /tmp/lua.tar.gz
echo ">> built:"
ls -la "$OUT"