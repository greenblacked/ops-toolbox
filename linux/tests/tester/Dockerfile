# One Dockerfile, three base images. The linux/ scripts are the only ones in
# this repository whose target OS *is* the container, so unlike the macOS suite
# these tests run the scripts for real rather than only parsing them.
#
# Tags are pinned. Arch is a rolling release and Fedora moves fast; an unpinned
# base would turn an upstream change into a red build on an unrelated pull
# request, and this repository pins the CHR image, ruff and PSScriptAnalyzer for
# the same reason.
ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

# Each distro needs its own bootstrap, and the point is to install as little as
# possible: the scripts must work on a machine that has nothing, so anything
# installed here is something the tests can no longer prove. Arch's downloader
# cannot install its seccomp filter under amd64 emulation on Apple Silicon, so
# only that sandbox layer is disabled; its filesystem sandbox remains active.
RUN if command -v apt-get >/dev/null 2>&1; then \
      apt-get update && apt-get install --yes --no-install-recommends \
        bash ca-certificates diffutils git procps python3 python3-yaml && rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf >/dev/null 2>&1; then \
      dnf install -y bash ca-certificates diffutils git procps-ng python3 python3-pyyaml && dnf clean all; \
    elif command -v pacman >/dev/null 2>&1; then \
      pacman -Sy --disable-sandbox-syscalls --noconfirm \
        bash ca-certificates diffutils git procps-ng python python-yaml && \
        pacman -Scc --noconfirm; \
    fi

ENV REPO_ROOT=/repo
WORKDIR /repo
