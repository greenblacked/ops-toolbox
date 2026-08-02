FROM debian:bookworm-slim

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ARG TARGETARCH

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
  && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" -o /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq \
  && yq --version

# ---- kubectl ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  k8s_arch="amd64" ;; \
      arm64)  k8s_arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
  && curl -fsSL "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${k8s_arch}/kubectl" -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl \
  && kubectl version --client=true --output=yaml | head -n 20

# ---- helm ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  helm_arch="amd64" ;; \
      arm64)  helm_arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && helm_version="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)" \
  && curl -fsSL "https://get.helm.sh/helm-${helm_version}-linux-${helm_arch}.tar.gz" -o /tmp/helm.tgz \
  && tar -xzf /tmp/helm.tgz -C /tmp \
  && install -m 0755 "/tmp/linux-${helm_arch}/helm" /usr/local/bin/helm \
  && rm -rf /tmp/helm.tgz "/tmp/linux-${helm_arch}" \
  && helm version

# ---- kustomize ----
RUN case "${TARGETARCH:-amd64}" in \
      amd64)  kus_arch="amd64" ;; \
      arm64)  kus_arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && kus_version="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest | jq -r .tag_name | sed 's|^kustomize/||')" \
  && curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${kus_version}/kustomize_${kus_version}_linux_${kus_arch}.tar.gz" -o /tmp/kustomize.tgz \
  && tar -xzf /tmp/kustomize.tgz -C /usr/local/bin \
  && chmod +x /usr/local/bin/kustomize \
  && rm -rf /tmp/kustomize.tgz \
  && kustomize version

# ---- Google Cloud SDK + GKE auth plugin ----
RUN curl -fsSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/ \
  && gcloud --version | head -n 20 \
  && gcloud -q components install gke-gcloud-auth-plugin

RUN groupadd --gid 1000 toolbox \
  && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/toolbox toolbox

WORKDIR /work
USER toolbox

ENTRYPOINT ["/bin/bash"]
