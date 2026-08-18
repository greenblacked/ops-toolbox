# syntax=docker/dockerfile:1.7
# Test Kitchen runner: Ruby toolchain + Docker CLI (uses host engine via socket).
FROM ruby:3.3-bookworm-slim

# TARGETARCH is set automatically by BuildKit (amd64 | arm64).
ARG TARGETARCH
ARG DOCKER_CLI_VERSION=27.3.1
ARG HADOLINT_VERSION=2.12.0

ENV BUNDLE_SILENCE_ROOT_WARNING=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git libffi-dev yamllint shellcheck \
    && rm -rf /var/lib/apt/lists/*

# hadolint (Dockerfile linter) — single static binary.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) harch=x86_64 ;; \
      arm64) harch=arm64  ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/hadolint \
      "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${harch}"; \
    chmod +x /usr/local/bin/hadolint

# Map BuildKit TARGETARCH → Docker static bundle arch.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) darch=x86_64 ;; \
      arm64) darch=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${darch}/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar xz -C /tmp docker/docker; \
    mv /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker

WORKDIR /chef

COPY Gemfile ./
RUN bundle install

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["kitchen", "list"]
