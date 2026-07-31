# Linux container for static checks and portable CLI checks on the macOS setup scripts.
# (Full install/refresh behavior is macOS-only and is not executed here.)
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    shellcheck \
    zsh \
    python3 \
    && rm -rf /var/lib/apt/lists/*

ENV REPO_ROOT=/repo
WORKDIR /repo
