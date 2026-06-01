# syntax=docker/dockerfile:1.7
#
# System Control Centre — backend
# linux/amd64 only. Build and run as a standalone service.
#
# Build:
#   docker build --platform=linux/amd64 -t scc-backend .
#
# Run:
#   docker run --platform=linux/amd64 -p 8012:8012 \
#     -e SC_DATABASE_URL=postgres://user:pass@host:5432/system_control \
#     -e SLACK_BOT_TOKEN=xoxb-... \
#     scc-backend
#
# GHC version is pinned to match the nix-flake dev toolchain (ghc 9.2.7).

# ── Build stage ────────────────────────────────────────────────────
FROM --platform=linux/amd64 debian:bookworm-slim AS build
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git gcc g++ make pkg-config xz-utils \
      libpq-dev libssl-dev libzstd-dev zlib1g-dev libpcre3-dev \
      ca-certificates libffi-dev libgmp-dev libnuma-dev \
    && rm -rf /var/lib/apt/lists/*

ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
    BOOTSTRAP_HASKELL_GHC_VERSION=9.2.7 \
    BOOTSTRAP_HASKELL_CABAL_VERSION=3.10.3.0 \
    BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
ENV PATH="/root/.ghcup/bin:${PATH}"

# Cache deps separately so source changes don't bust the dependency layer
COPY cabal.project scc.cabal ./
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.ghc \
    cabal update && cabal build --only-dependencies -j4

# Build the app
COPY . .
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.ghc \
    cabal build exe:scc -j4 && \
    cp "$(cabal list-bin exe:scc)" /usr/local/bin/scc && \
    strip /usr/local/bin/scc || true

# ── Runtime stage ──────────────────────────────────────────────────
FROM --platform=linux/amd64 debian:bookworm-slim AS runtime

# Runtime libs + tools:
#   - kubectl (release operations)
#   - jq (JSON processing in clone/patch k8s deployment commands)
#   - dhall-to-json (loadLoggerConfigFromDhall calls this as a subprocess)
#   - tini (proper PID 1 + signal handling)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tini bzip2 jq \
      libpq5 libpcre3 libssl3 zlib1g libzstd1 libgmp10 libffi8 libnuma1 \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
       -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://github.com/dhall-lang/dhall-haskell/releases/download/1.42.2/dhall-json-1.7.12-x86_64-linux.tar.bz2" \
       -o /tmp/dhall-json.tar.bz2 \
    && tar -xjf /tmp/dhall-json.tar.bz2 -C /usr/local \
    && rm /tmp/dhall-json.tar.bz2 \
    && /usr/local/bin/dhall-to-json --version \
    && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN groupadd --system --gid 1001 scc && \
    useradd --system --uid 1001 --gid scc --home /srv/scc --shell /bin/sh scc

WORKDIR /srv/scc

# Binary
COPY --from=build /usr/local/bin/scc /usr/local/bin/scc

# Schema + migrations bundled in image so a fresh DB can be initialised
# from inside the container (e.g. an init container or a one-shot job).
COPY --from=build /app/dev/sql-seed     /srv/scc/dev/sql-seed
COPY --from=build /app/dev/migrations   /srv/scc/dev/migrations

# NOTE: dhall-configs/ is intentionally NOT baked into the image (matches
# NammaYatri's pattern). The container is environment-agnostic — production
# mounts the dhall file at runtime via a k8s Secret/ConfigMap volume and
# points the binary at it with SC_CONFIG_PATH:
#
#   volumes:
#     - name: scc-dhall
#       secret: { secretName: scc-dhall }
#   volumeMounts:
#     - name: scc-dhall
#       mountPath: /etc/scc/system-control.dhall
#       subPath: system-control.dhall
#       readOnly: true
#   env:
#     - name: SC_CONFIG_PATH
#       value: /etc/scc/system-control.dhall
#
# See README.md → Production deployment for the full pattern.

# Entrypoint: decodes DHALL_CONFIGS (base64) when set, then execs the binary.
# See scripts/scc-entrypoint.sh for the resolution logic.
COPY --from=build /app/scripts/scc-entrypoint.sh /usr/local/bin/scc-entrypoint.sh
RUN chmod +x /usr/local/bin/scc-entrypoint.sh

RUN chown -R scc:scc /srv/scc

USER scc

ENV APP_STATE=SERVER \
    PORT=8012 \
    SC_KUBECTL_BIN=kubectl

EXPOSE 8012

# TCP-level health check: any HTTP response (even a 404) proves the server
# is listening. Replace with a /health endpoint when the backend grows one.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl --max-time 3 --silent --output /dev/null "http://localhost:${PORT}/" || exit 1

# tini as PID 1 so signals + zombie reaping work correctly.
# scc-entrypoint.sh decodes DHALL_CONFIGS if set, then execs scc.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/scc-entrypoint.sh"]
