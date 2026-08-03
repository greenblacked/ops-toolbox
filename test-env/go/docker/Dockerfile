# syntax=docker/dockerfile:1.7
FROM golang:1.23-bookworm

ARG GOLANGCI_LINT_VERSION=v1.61.0
ARG TARGETARCH
ARG HADOLINT_VERSION=2.12.0

ENV CGO_ENABLED=0 \
    GOFLAGS=-buildvcs=false \
    GOMODCACHE=/go/pkg/mod \
    GOCACHE=/root/.cache/go-build

RUN apt-get update && apt-get install -y --no-install-recommends \
      git make ca-certificates curl shellcheck yamllint \
    && rm -rf /var/lib/apt/lists/*

# golangci-lint via official installer (pinned).
RUN curl -fsSL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh \
    | sh -s -- -b /usr/local/bin ${GOLANGCI_LINT_VERSION}

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

# Extra dev tools (govulncheck for vulnerability scanning, goimports for formatting).
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go install golang.org/x/vuln/cmd/govulncheck@latest && \
    go install golang.org/x/tools/cmd/goimports@latest

WORKDIR /go/src/app

# Warm module cache for the project.
COPY go.mod go.su[m] ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Source is bind-mounted at runtime via compose; CMD is overridden by the dev
# service (sleep infinity) but is useful for one-shot `docker compose run`.
CMD ["go", "test", "./..."]
