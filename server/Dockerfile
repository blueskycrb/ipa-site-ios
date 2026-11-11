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


# ---- 编译支持 Apple 新认证流程的 Linux ipatool 和本机设备证明组件 ----
FROM golang:1.26.5-bookworm AS ipatool-build

# 临时使用尚未合入上游的 Linux 修复，固定提交，避免构建时跟随分支变化。
# https://github.com/trikesh32/ipatool/pull/1
ARG IPATOOL_COMMIT=175c3e92a58a38fe538f4d94e785de4e575c6972
WORKDIR /src
RUN curl -fsSL "https://codeload.github.com/trikesh32/ipatool/tar.gz/${IPATOOL_COMMIT}" \
    | tar -xz --strip-components=1 -C /src
RUN go mod download && go generate ./... \
    && go test -timeout 20m ./... \
    && go vet ./... \
    && go build -buildvcs=false -trimpath -ldflags "-X github.com/majd/ipatool/v2/cmd.version=native-store-${IPATOOL_COMMIT}" -o /out/ipatool .
RUN cd tools/store-proof && go mod download && go test ./... \
    && go build -buildvcs=false -trimpath -o /out/ipatool-store-proof .

# ---- 运行环境 ----
FROM python:3.12-slim

# openssl 用来读取 p12 证书信息。Apple 的设备证明库在服务器首次启动时下载并校验，
# 不把个人设备身份或 Apple 的二进制库打进镜像。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates openssl; \
    rm -rf /var/lib/apt/lists/*

# 解密脚本要用 cryptography（只在解密子进程里用，网站本身仍只用标准库）。
# PyPI 慢时构建加 --build-arg PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN pip install --no-cache-dir -i "$PIP_INDEX_URL" "cryptography>=41"

COPY --from=zsign-build /usr/local/bin/zsign /usr/local/bin/zsign
COPY --from=zsign-build /fairplay /app/fairplay
COPY --from=ipatool-build /out/ipatool /out/ipatool-store-proof /usr/local/bin/
COPY --from=ipatool-build /src/LICENSE /usr/share/licenses/ipatool/LICENSE
# LGPL helper 的对应源码、许可证、来源说明随镜像提供。
COPY --from=ipatool-build /src/tools/store-proof /usr/share/ipatool/store-proof-source/

# /data 保存 ipatool 的登录状态（$HOME/.ipatool）、钥匙串口令、证书和下载的 IPA
RUN useradd --create-home --home-dir /data --uid 1000 app

WORKDIR /app
COPY server.py fairplay_fast.py store_proof.py parallel_install.py download_control.py ./
COPY static ./static

ENV HOME=/data \
    IPA_HOST=0.0.0.0 \
    IPA_PORT=8686 \
    IPA_DOWNLOAD_DIR=/data/downloads \
    IPA_PASSPHRASE_FILE=/data/.keychain-passphrase \
    PYTHONUNBUFFERED=1 \
    IPATOOL_STORE_PROOF_HELPER=/usr/local/bin/ipatool-store-proof \
    IPATOOL_STORE_PROOF_DIR=/data/.config/ipatool/store-proof

USER app
VOLUME /data
EXPOSE 8686
CMD ["python", "server.py"]
