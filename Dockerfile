# ---- builder: compile gcm.so (AES-GCM with AAD) ----
# Links only against libcrypto (already in base image); needs gcc + libssl-dev.
FROM luafan/luafan-ubuntu AS gcm-builder

COPY gcm/ /tmp/gcm/
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        gcc libssl-dev wget ca-certificates >/dev/null 2>&1 \
    && sh /tmp/gcm/build.sh /gcm-out \
    && rm -rf /tmp/gcm /var/lib/apt/lists/*

# ---- builder: compile curlimp.so (not committed; built in-image) ----
# Start from the luafan base image so fan.so, libevent runtime and Lua 5.3
# are already there — we only need to install gcc + libevent-dev + wget for
# the build. The builder stage is discarded; only /out/* is copied below.
FROM luafan/luafan-ubuntu AS curlimp-builder

ARG TARGETARCH
COPY curl-impersonate/ /tmp/curl-impersonate/
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        gcc libevent-dev wget ca-certificates >/dev/null 2>&1 \
    && sh /tmp/curl-impersonate/build.sh "$TARGETARCH" /out \
    && rm -rf /tmp/curl-impersonate /var/lib/apt/lists/*

# ---- final webase image ----
FROM luafan/luafan-ubuntu

ENV MARIA_DATABASE_NAME=test

ENV SERVICE_HOST=0.0.0.0
ENV SERVICE_PORT=2201

# Worker threads. 0 = single-threaded event loop (safe with any Lua build).
# Multi-worker (>0) REQUIRES a Lua built with the global lua_lock hook
# (LUA_USER_H=fan_lua_lock.h); otherwise concurrent worker threads race on the
# shared lua_State. Keep 0 until the base image ships the locked Lua.
ENV SERVICE_WORKERS=0

ENV HTTP_USING_CORE=true
ENV HTTPD_USING_CORE=true

ENV WEBROOT=/root/web

RUN wget https://curl.haxx.se/ca/cacert.pem -O cert.pem

# curl-impersonate (curlimp Lua module + libcurl-impersonate).
# build.sh lays /out/ out as {lib/, lib/lua/5.3/}; a single directory COPY
# preserves the two soname symlinks (individual file COPYs would each
# dereference libcurl-impersonate.so and duplicate the 30MB blob).
ARG TARGETPLATFORM
COPY --from=curlimp-builder /out/ /usr/local/

# gcm.so (AES-GCM with AAD — links libcrypto only, no fan.so).
COPY --from=gcm-builder /gcm-out/lib/lua/5.3/gcm.so /usr/local/lib/lua/5.3/

COPY config.d /root/config.d
COPY web /root/web

COPY *.lua /root/
COPY mime.types /root/

VOLUME ["/root/config.d"]

WORKDIR /root/

ENTRYPOINT ["lua", "core.lua"]
