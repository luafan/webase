FROM luafan/luafan-alpine

ENV MARIA_DATABASE_NAME test
ENV MARIA_USERNAME test
ENV MARIA_PASSWORD test
ENV MARIA_CHARSET utf8

ENV SERVICE_HOST 0.0.0.0
ENV SERVICE_PORT 2201

ENV WEBROOT /root/web

COPY config /root/config
COPY handle /root/handle
COPY service /root/service
COPY web /root/web

COPY *.lua /root/
COPY cert.pem /root/
COPY mime.types /root/

VOLUME ["/root/config.d"]

WORKDIR /root/

CMD luajit core.lua
