FROM golang:1.22-alpine AS builder
RUN apk add --no-cache git
WORKDIR /build
RUN git clone --depth=1 --filter=blob:none --sparse https://github.com/ente-io/ente.git \
    && cd ente \
    && git sparse-checkout set cli \
    && cd cli \
    && go build -o bin/ente main.go

FROM alpine:3.19
RUN apk add --no-cache bash \
    && addgroup -g 1000 enteuser \
    && adduser -D -u 1000 -G enteuser enteuser \
    && mkdir -p /cli-data /data /var/log
COPY --from=builder /build/ente/cli/bin/ente /usr/local/bin/ente-cli
USER enteuser
VOLUME /cli-data /data
CMD ["crond", "-f", "-l", "8"]   
