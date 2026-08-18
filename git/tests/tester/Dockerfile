# Linux container for static checks and portable behavior tests on Git scripts.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    python3 \
    shellcheck \
    zsh \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV REPO_ROOT=/repo
WORKDIR /repo
