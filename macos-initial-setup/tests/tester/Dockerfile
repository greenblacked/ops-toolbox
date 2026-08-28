# Linux container for static checks and portable CLI checks on the macOS setup
# scripts, plus the per-step and unprivileged stay_fresh suites.
# (Behavior that genuinely requires macOS APIs is faked, not executed.)
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    shellcheck \
    zsh \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# A non-root user for tests/test_stay_fresh_unprivileged.sh. Running as root
# makes every EACCES branch unreachable, so those assertions need a uid that the
# filesystem is willing to refuse.
RUN useradd -m -u 1000 -s /bin/bash tester

# Two directories the unprivileged suite points TMPDIR at. They are root-owned
# on purpose and must stay that way:
#   /rootonly   mode 700 — `mkdir -p` beneath it fails (nothing can be created)
#   /rootlocked mode 755 — it exists and is traversable, so `mkdir -p` succeeds
#                          and the lock's own mkdir is what gets EACCES
RUN mkdir -p /rootonly /rootlocked \
    && chmod 700 /rootonly \
    && chmod 755 /rootlocked

ENV REPO_ROOT=/repo
WORKDIR /repo
