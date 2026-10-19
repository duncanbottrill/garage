ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.21
ARG BUILD_ARCH=aarch64

# --- tesla-http-proxy from vehicle-command ---
# `go install .../tesla-http-proxy@v0.4.1` fails: the module's go.mod at this
# tag carries `replace` directives, which `go install` of a non-main module
# refuses ("must not contain directives that would cause it to be interpreted
# differently than if it were the main module"). Clone the tag as the main
# module and `go build` instead.
FROM golang:1.23-alpine AS proxy
RUN apk add --no-cache git
RUN git clone --depth 1 --branch v0.4.1 https://github.com/teslamotors/vehicle-command /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -o /out/tesla-http-proxy ./cmd/tesla-http-proxy

# --- fleet-telemetry binary (official multi-arch image) ---
# distroless image; the binary is at the filesystem root, not /usr/bin.
FROM tesla/fleet-telemetry:v0.9.5 AS telemetry

# --- ingest bundle ---
FROM node:22-alpine AS ingest
WORKDIR /src
COPY addon/garage-bridge/ingest/package.json addon/garage-bridge/ingest/package-lock.json* ./
RUN npm install --no-audit --no-fund
COPY addon/garage-bridge/ingest/ ./
COPY packages/core/ /core/
ENV CORE_PATH=/core/src/index.ts
RUN npm run build

# --- runtime ---
FROM ${BUILD_FROM}
# tailscale is in Alpine's community repo; the HA base image already enables
# both main and community in /etc/apk/repositories, so no edit is needed here.
RUN apk add --no-cache nodejs tailscale ca-certificates jq openssl
COPY --from=proxy /out/tesla-http-proxy /usr/bin/tesla-http-proxy
COPY --from=telemetry /fleet-telemetry /usr/bin/fleet-telemetry
COPY --from=ingest /src/dist /app/ingest/dist
COPY addon/garage-bridge/rootfs/ /
RUN chmod a+x /etc/s6-overlay/s6-rc.d/*/run /etc/s6-overlay/s6-rc.d/*/finish /usr/bin/garage-* 2>/dev/null || true
LABEL io.hass.version="0.1.0" io.hass.type="addon" io.hass.arch="aarch64|amd64"
