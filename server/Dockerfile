# ---- 第一阶段：编译 zsign（用 p12 证书给 IPA 重新签名），取 fairplay-decrypt 解密脚本 ----
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

# fairplay-decrypt 的解密脚本（用账号凭证离线解密 App Store 原版 IPA）。
# 这个项目没有声明开源许可，所以不放进本仓库，构建时按固定提交从 GitHub 下载。
ARG FAIRPLAY_COMMIT=7f80db2ef37634073fab06b3aad1aa0cf24561a1

RUN set -eux; \
    curl -fsSL "https://github.com/EthanArbuckle/fairplay-decrypt/archive/${FAIRPLAY_COMMIT}.tar.gz" | tar -xz -C /tmp; \
    mkdir -p /fairplay; \
    cp "/tmp/fairplay-decrypt-${FAIRPLAY_COMMIT}/decrypt.py" "/tmp/fairplay-decrypt-${FAIRPLAY_COMMIT}/core.py" /fairplay/


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

# 解密脚本要用 cryptography（只在解密子进程里用，网站本身仍只用标准库）。
# PyPI 慢时构建加 --build-arg PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN pip install --no-cache-dir -i "$PIP_INDEX_URL" "cryptography>=41"

COPY --from=zsign-build /usr/local/bin/zsign /usr/local/bin/zsign
COPY --from=zsign-build /fairplay /app/fairplay

# /data 保存 ipatool 的登录状态（$HOME/.ipatool）、钥匙串口令、证书和下载的 IPA
RUN useradd --create-home --home-dir /data --uid 1000 app

WORKDIR /app
COPY server.py fairplay_fast.py ./
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
