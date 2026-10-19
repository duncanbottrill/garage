ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base-debian:bookworm
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
COPY garage-bridge/ingest/package.json garage-bridge/ingest/package-lock.json* ./
RUN npm install --no-audit --no-fund
COPY garage-bridge/ingest/ ./
# Nested under /src (not a /core sibling): @garage/core's own runtime deps
# (@noble/ciphers, imported by crypto.ts via bare subpath specifiers like
# "@noble/ciphers/chacha") resolve by walking up from the importing file,
# so core needs to sit somewhere under the directory tree that has
# node_modules — here, /src/node_modules, installed above.
COPY packages/core/ /src/core/
ENV CORE_PATH=/src/core/src/index.ts
RUN npm run build

# --- runtime ---
# Debian bookworm, not Alpine: the official fleet-telemetry binary is
# glibc-linked (see Task 1 finding 4 — it fails under musl+gcompat with
# "symbol not found: pthread_cond_clockwait"). We will run the real
# telemetry service in a later task, so the runtime needs glibc.
FROM ${BUILD_FROM}
ARG BUILD_ARCH=aarch64
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq openssl \
    && rm -rf /var/lib/apt/lists/*

# Tailscale from its official apt repo for Debian bookworm. `tailscale`
# pulls in `tailscaled` as well. The keyring is fetched pre-dearmored
# (`.noarmor.gpg`), so no `gnupg` package is needed at all. Pinned to the
# version the last build resolved and held so a later `apt-get upgrade`
# inside this image can't silently drift it.
RUN mkdir -p /usr/share/keyrings \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y --no-install-recommends tailscale=1.104.1 \
    && apt-mark hold tailscale \
    && rm -rf /var/lib/apt/lists/*

# Node 22 runtime: the ingest bundle is a self-contained esbuild output with
# no runtime node_modules, so only the `node` binary is needed, not a full
# Node image or apt's (older) nodejs package. Pinned by digest (manifest
# list, resolves to the right platform) for reproducibility.
COPY --from=node:22-bookworm-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 /usr/local/bin/node /usr/local/bin/node

COPY --from=proxy /out/tesla-http-proxy /usr/bin/tesla-http-proxy
COPY --from=telemetry /fleet-telemetry /usr/bin/fleet-telemetry
COPY --from=ingest /src/dist /app/ingest/dist

# ISRG Root X1, used by Task 2's cert script.
RUN mkdir -p /usr/share/garage \
    && curl -fsSL https://letsencrypt.org/certs/isrgrootx1.pem -o /usr/share/garage/isrgrootx1.pem

COPY garage-bridge/rootfs/ /
RUN chmod a+x /etc/s6-overlay/s6-rc.d/*/run /etc/s6-overlay/s6-rc.d/*/finish /usr/bin/garage-* 2>/dev/null || true
LABEL io.hass.version="0.2.0" io.hass.type="addon" io.hass.arch="${BUILD_ARCH}"
