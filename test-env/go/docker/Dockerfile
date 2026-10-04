# syntax=docker/dockerfile:1.7
FROM golang:1.27-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195

ARG GOLANGCI_LINT_VERSION=v2.14.0
ARG TARGETARCH
ARG HADOLINT_VERSION=2.12.0

ENV CGO_ENABLED=0 \
    GOFLAGS=-buildvcs=false \
    GOMODCACHE=/go/pkg/mod \
    GOCACHE=/root/.cache/go-build

RUN apt-get update && apt-get install -y --no-install-recommends \
      git make ca-certificates curl shellcheck yamllint \
    && rm -rf /var/lib/apt/lists/*

# golangci-lint from its pinned release, checked against the published digest.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64|arm64) lint_arch="${TARGETARCH:-amd64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    lint_version="${GOLANGCI_LINT_VERSION#v}"; \
    archive="golangci-lint-${lint_version}-linux-${lint_arch}.tar.gz"; \
    release="https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}"; \
    curl -fsSL -o "/tmp/${archive}" "${release}/${archive}"; \
    curl -fsSL -o /tmp/golangci-checksums.txt \
      "${release}/golangci-lint-${lint_version}-checksums.txt"; \
    expected="$(awk -v file="${archive}" '$2 == file { print $1 }' /tmp/golangci-checksums.txt)"; \
    test -n "${expected}"; \
    printf '%s  %s\n' "${expected}" "/tmp/${archive}" > /tmp/golangci-verify.txt; \
    sha256sum -c /tmp/golangci-verify.txt; \
    tar -xzf "/tmp/${archive}" -C /usr/local/bin --strip-components=1 \
      "golangci-lint-${lint_version}-linux-${lint_arch}/golangci-lint"; \
    rm "/tmp/${archive}" /tmp/golangci-checksums.txt /tmp/golangci-verify.txt

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
