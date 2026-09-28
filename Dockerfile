# syntax=docker/dockerfile:1

FROM golang:1.26.4-alpine3.23@sha256:18b460dd17542c2ba43299a633cf6ebfc1115101509531471d7cfce1019af083 AS builder

RUN apk add --no-cache git

# UPSTREAM_REF may be a cli-v* tag (preferred) or a commit SHA.
ARG UPSTREAM_REF=cli-v0.3.0
ARG VERSION=v0.3.0

WORKDIR /build
RUN git init ente \
    && cd ente \
    && git remote add origin https://github.com/ente-io/ente.git \
    && git sparse-checkout init --cone \
    && git sparse-checkout set cli \
    && if git fetch --depth=1 origin "refs/tags/${UPSTREAM_REF}:refs/tags/${UPSTREAM_REF}"; then \
         git checkout "refs/tags/${UPSTREAM_REF}"; \
       else \
         git fetch --depth=1 origin "${UPSTREAM_REF}" \
         && git checkout FETCH_HEAD; \
       fi

WORKDIR /build/ente/cli
ENV CGO_ENABLED=0
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download \
    && go build -trimpath \
        -ldflags "-s -w -X main.AppVersion=${VERSION}" \
        -o /ente-cli main.go

FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

RUN apk add --no-cache ca-certificates tzdata su-exec \
    && addgroup -g 1000 enteuser \
    && adduser -D -u 1000 -G enteuser enteuser \
    && mkdir -p /cli-data /data \
    && chown enteuser:enteuser /cli-data /data

COPY --from=builder /ente-cli /usr/local/bin/ente-cli
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV TZ=UTC

VOLUME /cli-data /data

# Entrypoint drops to enteuser for SCHEDULER=loop; cron mode stays root.
ENTRYPOINT ["/entrypoint.sh"]
