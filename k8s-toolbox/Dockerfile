FROM debian:bookworm-slim

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ARG TARGETARCH
ARG YQ_VERSION
ARG KUBECTL_VERSION
ARG HELM_VERSION
ARG KUSTOMIZE_VERSION
ARG GCLOUD_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/google-cloud-sdk/bin:${PATH}"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    curl \
    dnsutils \
    git \
    iproute2 \
    jq \
    less \
    openssl \
    python3 \
    procps \
    tar \
    unzip \
  && rm -rf /var/lib/apt/lists/*

# ---- yq (mikefarah) ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  yq_arch="amd64" ;; \
      arm64)  yq_arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}" -o /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq \
  && yq --version | grep -F "${YQ_VERSION#v}"

# ---- kubectl ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  k8s_arch="amd64" ;; \
      arm64)  k8s_arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${k8s_arch}/kubectl" -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl \
  && kubectl version --client=true --output=yaml | grep -F "gitVersion: ${KUBECTL_VERSION}"

# ---- helm ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  helm_arch="amd64" ;; \
      arm64)  helm_arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${helm_arch}.tar.gz" -o /tmp/helm.tgz \
  && tar -xzf /tmp/helm.tgz -C /tmp \
  && install -m 0755 "/tmp/linux-${helm_arch}/helm" /usr/local/bin/helm \
  && rm -rf /tmp/helm.tgz "/tmp/linux-${helm_arch}" \
  && helm version --short | grep -F "${HELM_VERSION}"

# ---- kustomize ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  kus_arch="amd64" ;; \
      arm64)  kus_arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${kus_arch}.tar.gz" -o /tmp/kustomize.tgz \
  && tar -xzf /tmp/kustomize.tgz -C /usr/local/bin \
  && chmod +x /usr/local/bin/kustomize \
  && rm -rf /tmp/kustomize.tgz \
  && kustomize version | grep -F "${KUSTOMIZE_VERSION}"

# ---- Google Cloud SDK + GKE auth plugin (versioned tarball, not curl|bash) ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  gcloud_arch="x86_64" ;; \
      arm64)  gcloud_arch="arm" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VERSION}-linux-${gcloud_arch}.tar.gz" -o /tmp/gcloud.tgz \
  && tar -xzf /tmp/gcloud.tgz -C / \
  && rm -f /tmp/gcloud.tgz \
  && /google-cloud-sdk/install.sh --quiet --usage-reporting=false --path-update=false --command-completion=false \
  && gcloud --version | head -n 5 \
  && gcloud -q components install gke-gcloud-auth-plugin \
  && gcloud --version | grep -F "${GCLOUD_VERSION}"

RUN groupadd --gid 1000 toolbox \
  && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/toolbox toolbox

WORKDIR /work
USER toolbox

ENTRYPOINT ["/bin/bash"]
