# syntax=docker/dockerfile:1

FROM golang:1.27.2-alpine3.23@sha256:9e45f0eb4a63ed37ad6e604950407558b7c738e34e015ae77a5d4ad369cde079 AS builder

RUN apk add --no-cache git

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

FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8 AS runtime

ARG VERSION=v0.3.0
LABEL org.opencontainers.image.title="ente-cli" \
      org.opencontainers.image.description="Ente CLI with scheduled exports" \
      org.opencontainers.image.source="https://github.com/the-wittch/ente-cli" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

RUN apk add --no-cache ca-certificates tzdata su-exec curl \
    && addgroup -g 1000 enteuser \
    && adduser -D -u 1000 -G enteuser enteuser \
    && mkdir -p /cli-data /data \
    && chown enteuser:enteuser /cli-data /data

COPY --from=builder /ente-cli /usr/local/bin/ente-cli
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

ENV TZ=UTC \
    ENTE_CLI_CONFIG_DIR=/cli-data

VOLUME /cli-data /data

ENTRYPOINT ["/entrypoint.sh"]
