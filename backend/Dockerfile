# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim AS build
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git gcc g++ make pkg-config \
      libpq-dev libssl-dev libzstd-dev zlib1g-dev libpcre3-dev \
      ca-certificates libffi-dev libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=1
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
ENV PATH="/root/.ghcup/bin:${PATH}"
RUN ghcup install ghc 9.6.7 --set && ghcup install cabal 3.10.3.0 --set

COPY cabal.project namma-ap.cabal ./
RUN mkdir -p app src test
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.ghc \
    cabal update && cabal build --only-dependencies -j4

COPY . .
RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.ghc \
    cabal build exe:namma-ap-exe -j4 && \
    cp "$(cabal list-bin exe:namma-ap-exe)" /usr/local/bin/namma-ap

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl libpq5 libpcre3 libssl3 zlib1g libzstd1 libgmp10 libffi8 libnuma1 \
    && ARCH="$(dpkg --print-architecture)" \
    && KARCH="$( [ "$ARCH" = "arm64" ] && echo arm64 || echo amd64 )" \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${KARCH}/kubectl" \
       -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/namma-ap /usr/local/bin/namma-ap
WORKDIR /srv/namma-ap
COPY .env.example .env

ENV APP_STATE=SERVER
EXPOSE 8012
ENTRYPOINT ["/usr/local/bin/namma-ap"]