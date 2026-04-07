# syntax=docker/dockerfile:1.7
#
# System Control Centre — frontend
# linux/amd64 only. Build and run as a standalone service.
#
# All VITE_* vars are baked into the JS bundle at build time. Build a
# separate image per environment with the right --build-arg values.
#
# Build:
#   docker build --platform=linux/amd64 \
#     --build-arg VITE_API_BASE_URL=https://api.example.com \
#     --build-arg VITE_AUTH_API_BASE_URL=https://api.example.com \
#     --build-arg VITE_DEFAULT_ENV=PROD \
#     --build-arg VITE_AVAILABLE_ENVS=UAT,PROD,INTEG_CLUSTER \
#     -t scc-frontend:prod .
#
# Run:
#   docker run --platform=linux/amd64 -p 8080:80 scc-frontend:prod

# ── Build stage ────────────────────────────────────────────────────
FROM --platform=linux/amd64 node:22-bookworm-slim AS builder
WORKDIR /app

COPY package*.json ./
RUN npm ci --include=optional

COPY . .

# Build-time configuration. Defaults match local dev so an unconfigured
# `docker build` still produces a runnable image.
ARG VITE_API_BASE_URL=http://localhost:8012
ARG VITE_AUTH_API_BASE_URL=
ARG VITE_DEFAULT_ENV=UAT
ARG VITE_AVAILABLE_ENVS=UAT,PROD,INTEG_CLUSTER
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL \
    VITE_AUTH_API_BASE_URL=$VITE_AUTH_API_BASE_URL \
    VITE_DEFAULT_ENV=$VITE_DEFAULT_ENV \
    VITE_AVAILABLE_ENVS=$VITE_AVAILABLE_ENVS

RUN npm run build

# ── Runtime stage ──────────────────────────────────────────────────
FROM --platform=linux/amd64 nginx:1.27-alpine AS runtime

COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost/healthz || exit 1
