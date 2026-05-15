FROM luafan/luafan-ubuntu

ENV MARIA_DATABASE_NAME=test

ENV SERVICE_HOST=0.0.0.0
ENV SERVICE_PORT=2201

ENV HTTP_USING_CORE=true
ENV HTTPD_USING_CORE=true

ENV WEBROOT=/root/web

RUN wget https://curl.haxx.se/ca/cacert.pem -O cert.pem

COPY config /root/config
COPY web /root/web

COPY *.lua /root/
COPY mime.types /root/

VOLUME ["/root/config.d"]

WORKDIR /root/

ENTRYPOINT ["lua", "core.lua"]
