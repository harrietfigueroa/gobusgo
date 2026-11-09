# Builds the image that runs the application as a release, on a developer's
# machine and in production.
#
# The versions match .tool-versions. The run stage uses the Debian release
# the build stage is based on, because a release bundles the Erlang runtime
# and links against the build stage's system libraries. Each base image is
# pinned by the digest of its tag's multi-platform index as well, because a
# tag can be moved; the digest changes together with the versions.
# https://mix.hexdocs.pm/Mix.Tasks.Release.html#module-requirements — checked 2026-10-02
# https://docs.docker.com/build/building/best-practices/ — checked 2026-10-14
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20260918-slim
ARG BUILD_IMAGE_DIGEST=sha256:27dc95204c20b774f5c73f050d13ce7735d251a2e349c3ddcd2c3acf6ea873c1
ARG RUN_IMAGE_DIGEST=sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}@${BUILD_IMAGE_DIGEST} AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Dependencies are fetched and compiled before the sources are copied, so a
# source change reuses these layers.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/config.exs
RUN mix deps.compile

# Downloads the esbuild and Tailwind binaries at the versions config.exs pins.
RUN mix assets.tools

COPY assets assets
COPY lib lib
# The web app manifest and its icons are checked in where the endpoint
# serves them; the rest of priv/static is built here.
COPY priv/static/manifest.webmanifest priv/static/manifest.webmanifest
COPY priv/static/icons priv/static/icons
RUN mix compile

# Downloads the vendored front-end packages that assets/vendor.lock.json pins
# and checks them against its hashes. The task is part of the application, so
# it runs once the application is compiled.
RUN mix gobusgo.vendor.fetch
RUN mix assets.deploy

COPY config/runtime.exs config/runtime.exs
RUN mix release

FROM debian:${DEBIAN_VERSION}@${RUN_IMAGE_DIGEST} AS run

LABEL org.opencontainers.image.licenses="MIT"

# The Erlang runtime links against these libraries, curl is the health
# check's client, and tippecanoe builds the route and stop tile archive. The
# runtime opens libsctp when it starts and logs a warning on every start,
# `rpc`, and `remote` when the library is absent. tippecanoe is pinned to the
# version the Debian release ships, 2.53.0, whose arm64 build carries a
# rebuild suffix (`+b1`) that the pattern admits.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends \
    ca-certificates \
    curl \
    libncurses6 \
    libsctp1 \
    libstdc++6 \
    openssl \
    tippecanoe=2.53.0-1* \
  && rm -rf /var/lib/apt/lists/*

# Fixed identifiers keep file ownership the same across image builds, so a
# volume written by one build is writable by the next. `--no-log-init` keeps
# useradd from writing a lastlog entry, a sparse file sized by the user
# identifier.
ARG USER_ID=10001
RUN groupadd --gid ${USER_ID} gobusgo \
  && useradd --uid ${USER_ID} --gid ${USER_ID} --no-log-init --no-create-home \
    --home-dir /app --shell /usr/sbin/nologin gobusgo \
  && mkdir /app /data \
  && chown gobusgo:gobusgo /app /data

# The data directory is the image's one mutable path.
VOLUME /data

# The listener binds every interface because a published port reaches the
# container on its network interface, never on its loopback.
ENV LANG=C.UTF-8 \
  GOBUSGO_DATA_DIR=/data \
  GOBUSGO_HTTP_HOST=0.0.0.0 \
  GOBUSGO_HTTP_PORT=4000

WORKDIR /app
USER gobusgo
COPY --from=build --chown=gobusgo:gobusgo /app/_build/prod/rel/gobusgo ./

# The full commit the image is built from, which /health and the pages name.
# A build without it, such as a local one, names no commit. It is declared
# after the release is copied, so a new commit rebuilds no earlier layer.
ARG GOBUSGO_REVISION=""
ENV GOBUSGO_REVISION=${GOBUSGO_REVISION}

EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --start-interval=1s --retries=3 \
  CMD curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${GOBUSGO_HTTP_PORT}/health" || exit 1

CMD ["/app/bin/gobusgo", "start"]
