# ---- 第一阶段：编译 zsign（用 p12 证书给 IPA 重新签名）----
FROM python:3.12-slim AS zsign-build

ARG ZSIGN_COMMIT=614caa8d1ca949e260e5746144aa52d27a4b08d6

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl g++ make pkg-config libssl-dev; \
    curl -fsSL "https://github.com/zhlynn/zsign/archive/${ZSIGN_COMMIT}.tar.gz" | tar -xz -C /tmp; \
    cd "/tmp/zsign-${ZSIGN_COMMIT}/build/linux"; \
    make VERSION="git-${ZSIGN_COMMIT}" -j"$(nproc)"; \
    install -m 0755 ../../bin/zsign /usr/local/bin/zsign; \
    zsign -v || true


# ---- 第二阶段：运行环境 ----
FROM python:3.12-slim

ARG IPATOOL_VERSION=2.7.0
ARG TARGETARCH

# 从 GitHub 官方 releases 下载 Linux 版 ipatool，并校验 SHA-256；openssl 用来读取 p12 证书信息
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl openssl; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=amd64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "不支持的架构: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    url="https://github.com/majd/ipatool/releases/download/v${IPATOOL_VERSION}/ipatool-${IPATOOL_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSL -o /tmp/ipatool.tar.gz "$url"; \
    echo "$(curl -fsSL "$url.sha256sum" | cut -d' ' -f1)  /tmp/ipatool.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/ipatool.tar.gz -C /tmp; \
    install -m 0755 "/tmp/bin/ipatool-${IPATOOL_VERSION}-linux-${arch}" /usr/local/bin/ipatool; \
    rm -rf /tmp/ipatool.tar.gz /tmp/bin; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    ipatool --version

COPY --from=zsign-build /usr/local/bin/zsign /usr/local/bin/zsign

# /data 保存 ipatool 的登录状态（$HOME/.ipatool）、钥匙串口令、证书和下载的 IPA
RUN useradd --create-home --home-dir /data --uid 1000 app

WORKDIR /app
COPY server.py ./
COPY static ./static

ENV HOME=/data \
    IPA_HOST=0.0.0.0 \
    IPA_PORT=8686 \
    IPA_DOWNLOAD_DIR=/data/downloads \
    IPA_PASSPHRASE_FILE=/data/.keychain-passphrase \
    PYTHONUNBUFFERED=1

USER app
VOLUME /data
EXPOSE 8686
CMD ["python", "server.py"]
