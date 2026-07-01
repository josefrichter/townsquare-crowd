# Multi-stage build for a self-contained OTP release.
#
# Unlike TownSquare, this app serves no static assets and has no public/ dir to
# carry into the runtime image — it's a WS client plus one tiny status page.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250520-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, for layer caching.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/
RUN mix deps.compile

# App sources.
COPY lib lib
RUN mix compile

# Runtime config is read on boot, not at build time.
COPY config/runtime.exs config/

RUN mix release

# --- runtime image --------------------------------------------------------
FROM ${RUNNER_IMAGE}

# ripgrep backs TownCrowd.Knowledge's search_repo tool (falls back to grep if
# CROWD_REPO is unset or rg is absent, but it's cheap to include).
RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates ripgrep \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/town_crowd ./

USER nobody

# PORT and the rest of config/runtime.exs's env vars are read at boot.
ENV PORT=8080
EXPOSE 8080

# Distributed Erlang needs a routable, unique node name to cluster the two Fly
# machines (see config/runtime.exs's libcluster topology): long names, and one
# node per machine's private 6PN address (FLY_PRIVATE_IP, injected by Fly).
# FLY_PRIVATE_IP is IPv6, but the BEAM's distribution protocol defaults to IPv4
# (inet_tcp) — without -proto_dist inet6_tcp it resolves the node name but never
# actually connects (silently retries forever).
# `exec` keeps this process as PID 1 so Fly's SIGTERM still reaches the BEAM.
ENV RELEASE_DISTRIBUTION=name
ENV ERL_AFLAGS="-proto_dist inet6_tcp"
CMD ["sh", "-c", "RELEASE_NODE=town_crowd@${FLY_PRIVATE_IP:-127.0.0.1} exec /app/bin/town_crowd start"]
