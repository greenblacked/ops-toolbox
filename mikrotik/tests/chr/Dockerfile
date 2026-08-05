# MikroTik Cloud Hosted Router (CHR), version supplied by the test harness.
# Build downloads the official VDI from MikroTik and converts it to qcow2 for QEMU.
# Build through mikrotik/tests/run.sh, which supplies the pinned version.
# RouterOS is proprietary; use per MikroTik CHR license terms.
FROM alpine:3.21.3

ARG ROUTEROS_VERSION
ARG ROUTEROS_SHA256

RUN test -n "$ROUTEROS_VERSION"

EXPOSE 22 23 80 443 8728 8729 8291 5900

WORKDIR /routeros

# netcat-openbsd is used by the compose healthcheck (-z requires this, busybox-nc has no -z).
RUN apk add --no-cache bash netcat-openbsd qemu-img qemu-system-x86_64 unzip wget

ENV ROUTEROS_VERSION="${ROUTEROS_VERSION}"
ENV ROUTEROS_IMAGE="chr-${ROUTEROS_VERSION}.qcow2"

# Try the stable mirror first, fall back to the CDN (used for rc/beta builds).
RUN set -eux; \
    for url in \
      "https://download.mikrotik.com/routeros/${ROUTEROS_VERSION}/chr-${ROUTEROS_VERSION}.vdi.zip" \
      "https://cdn.mikrotik.com/routeros/${ROUTEROS_VERSION}/chr-${ROUTEROS_VERSION}.vdi.zip" ; do \
      if wget -q --tries=3 --timeout=30 "$url" -O "chr-${ROUTEROS_VERSION}.vdi.zip"; then \
        break; \
      fi; \
      rm -f "chr-${ROUTEROS_VERSION}.vdi.zip"; \
    done; \
    test -s "chr-${ROUTEROS_VERSION}.vdi.zip"; \
    if [ -n "$ROUTEROS_SHA256" ]; then \
      echo "${ROUTEROS_SHA256}  chr-${ROUTEROS_VERSION}.vdi.zip" | sha256sum -c -; \
    else \
      echo "WARNING: ROUTEROS_SHA256 is not recorded, so this image is unverified."; \
      echo "WARNING: it boots as a kernel with the repository mounted."; \
      echo "WARNING: record it with: mikrotik/tests/routeros_version.py record-hash"; \
    fi

RUN unzip -q "chr-${ROUTEROS_VERSION}.vdi.zip" \
    && rm -f "chr-${ROUTEROS_VERSION}.vdi.zip" \
    && qemu-img convert -f vdi -O qcow2 \
        "chr-${ROUTEROS_VERSION}.vdi" \
        "chr-${ROUTEROS_VERSION}.qcow2" \
    && rm -f "chr-${ROUTEROS_VERSION}.vdi"

COPY entrypoint.sh /routeros/entrypoint.sh
RUN chmod +x /routeros/entrypoint.sh

# Image-level healthcheck so `docker run` users (no compose) also benefit.
HEALTHCHECK --interval=5s --timeout=3s --start-period=30s --retries=240 \
  CMD nc -z -w 1 127.0.0.1 8728 || exit 1

ENTRYPOINT ["/routeros/entrypoint.sh"]
