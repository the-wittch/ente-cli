FROM golang:alpine AS builder   
RUN apk add --no-cache git
WORKDIR /build
RUN git clone --depth=1 https://github.com/ente-io/ente.git
RUN cd ente/cli && CGO_ENABLED=0 go build -o bin/ente main.go

FROM alpine:3.21
RUN apk add --no-cache bash \
    && addgroup -g 1000 enteuser \
    && adduser -D -u 1000 -G enteuser enteuser \
    && mkdir -p /cli-data /data /var/log \
    && touch /etc/crontabs/enteuser \
    && chown enteuser:enteuser /etc/crontabs/enteuser
COPY --from=builder /build/ente/cli/bin/ente /usr/local/bin/ente-cli
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER enteuser
VOLUME /cli-data /data
CMD ["/entrypoint.sh"]   
