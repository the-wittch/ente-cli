# syntax=docker/dockerfile:1

FROM golang:1.26.4-alpine3.23 AS builder

RUN apk add --no-cache git

ARG UPSTREAM_SHA=main
ARG VERSION

WORKDIR /build
RUN git init ente \
    && cd ente \
    && git remote add origin https://github.com/ente-io/ente.git \
    && git sparse-checkout init --cone \
    && git sparse-checkout set cli \
    && git fetch --depth=1 origin "${UPSTREAM_SHA}" \
    && git checkout FETCH_HEAD

WORKDIR /build/ente/cli
ENV CGO_ENABLED=0
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download \
    && go build -trimpath \
        -ldflags "-s -w -X main.AppVersion=${VERSION:-${UPSTREAM_SHA}}" \
        -o /ente-cli main.go

FROM alpine:3.22

RUN mkdir -p /cli-data /data

COPY --from=builder /ente-cli /usr/local/bin/ente-cli
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /cli-data /data

# Root is required for BusyBox crond (SCHEDULER=cron). Loop mode could run
# as non-root, but a single image identity keeps both schedulers simple.
ENTRYPOINT ["/entrypoint.sh"]
