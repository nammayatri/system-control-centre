# syntax=docker/dockerfile:1.7
#
# System Control Centre — frontend
# linux/amd64 only. Build and run as a standalone service.
#
# VITE_* vars are baked into the JS bundle at build time. Only the API URL
# is build-time; the deployment environment label (UAT/PROD/etc.) is served
# by the backend via /auth/me at runtime, so one image can serve any env.
#
# Build:
#   docker build --platform=linux/amd64 \
#     --build-arg VITE_API_BASE_URL=https://api.example.com \
#     --build-arg VITE_AUTH_API_BASE_URL=https://api.example.com \
#     -t scc-frontend:latest .
#
# Run:
#   docker run --platform=linux/amd64 -p 8080:80 scc-frontend:latest

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
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL \
    VITE_AUTH_API_BASE_URL=$VITE_AUTH_API_BASE_URL

RUN npm run build

# ── Runtime stage ──────────────────────────────────────────────────
FROM --platform=linux/amd64 nginx:1.27-alpine AS runtime

COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost/healthz || exit 1
