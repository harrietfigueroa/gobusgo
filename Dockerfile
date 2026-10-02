# Builds the image that runs the HTTP server for local development.
#
# The versions match .tool-versions. The run stage uses the Debian release
# the build stage is based on, because a release bundles the Erlang runtime
# and links against the build stage's system libraries.
# https://mix.hexdocs.pm/Mix.Tasks.Release.html#module-requirements — checked 2026-10-02
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20260918-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ENV MIX_ENV=prod
WORKDIR /app

# brod's crc32cer dependency builds a native library with CMake and a C and
# C++ compiler.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends \
    build-essential \
    cmake \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Dependencies are fetched and compiled before the sources are copied, so a
# source change reuses these layers.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/config.exs
RUN mix deps.compile

# Downloads the esbuild and Tailwind binaries at the versions config.exs pins.
RUN mix assets.setup

COPY assets assets
COPY lib lib
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/runtime.exs
RUN mix release

FROM debian:${DEBIAN_VERSION} AS run

# The Erlang runtime links against these libraries, and curl is the health
# check's client. The runtime opens libsctp when it starts and logs a warning
# on every start, `rpc`, and `remote` when the library is absent.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends \
    ca-certificates \
    curl \
    libncurses6 \
    libsctp1 \
    libstdc++6 \
    openssl \
  && rm -rf /var/lib/apt/lists/*

# A fixed identifier keeps file ownership the same across image builds, so a
# volume written by one build is writable by the next.
ARG USER_ID=10001
RUN useradd --uid ${USER_ID} --user-group --no-create-home --home-dir /app \
    --shell /usr/sbin/nologin gobusgo \
  && mkdir /app /data \
  && chown gobusgo:gobusgo /app /data

# The listener binds every interface because a published port reaches the
# container on its network interface, never on its loopback.
ENV LANG=C.UTF-8 \
  GOBUSGO_DATA_DIR=/data \
  GOBUSGO_HTTP_HOST=0.0.0.0 \
  GOBUSGO_HTTP_PORT=4000

WORKDIR /app
USER gobusgo
COPY --from=build --chown=gobusgo:gobusgo /app/_build/prod/rel/gobusgo ./

EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --start-interval=1s --retries=3 \
  CMD curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${GOBUSGO_HTTP_PORT}/health" || exit 1

CMD ["/app/bin/gobusgo", "start"]
