FROM python:3.12-slim

ARG IPATOOL_VERSION=2.7.0
ARG TARGETARCH

# 从 GitHub 官方 releases 下载 Linux 版 ipatool，并校验 SHA-256
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
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

# /data 保存 ipatool 的登录状态（$HOME/.ipatool）、钥匙串口令和下载的 IPA
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
