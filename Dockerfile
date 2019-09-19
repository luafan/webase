FROM luafan/luafan-alpine

ENV MARIA_DATABASE_NAME test

ENV SERVICE_HOST 0.0.0.0
ENV SERVICE_PORT 2201

ENV HTTP_USING_CORE true
ENV HTTPD_USING_CORE true

ENV WEBROOT /root/web

COPY config /root/config
COPY handle /root/handle
COPY service /root/service
COPY web /root/web

COPY *.lua /root/
COPY mime.types /root/

RUN curl https://curl.haxx.se/ca/cacert.pem -o cert.pem

VOLUME ["/root/config.d"]

WORKDIR /root/

ENTRYPOINT ["luajit", "core.lua"]
