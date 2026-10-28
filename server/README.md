# IPA 下载站（服务端）

基于 [ipatool](https://github.com/majd/ipatool) 的 App Store IPA 下载服务，用 Docker 部署在自己的服务器上，配一个网页和一个 iPhone 客户端（见仓库根目录）。网站本身只用 Python 标准库，镜像里自带 Linux 版 ipatool、zsign 和解密脚本。

**功能**

- 网页登录 Apple ID（支持双重认证、多个账号随时切换），搜索 App，下载最新版或任意历史版本
- 历史版本按版本号或日期查找（如 14.8.40、2026-09）
- 文件以「应用名_版本.ipa」命名，列表显示图标和版本；上传的、改版的、证书签名的 IPA 也会从 IPA 里取出图标显示
- 下载完自动上传到 Alist（可选），可浏览 Alist 目录、用网盘直链下载
- iPhone 一键安装：系统安装（itms-services，需要 HTTPS）或交给 TrollStore 安装
- 证书签名：上传自己的 p12 证书 + 描述文件，用 zsign 重签后安装（网页 `/sign`）
- 解密：用 [fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt) 和 Apple ID 凭证离线解密 App Store 原版 IPA，凭证按地区（US、CN…）管理，自动用下载账号对应的凭证
- 网络不稳时自动避开连不上的 Apple 节点（见[连不上 Apple 时](#连不上-apple-时)）
- 访问密码、IPv4 / IPv6、多任务并行下载

目录：[目录结构](#目录结构) · [完整安装步骤](#完整安装步骤) · [更新](#更新) · [备份与迁移](#备份与迁移) · [配置说明](#配置说明env) · [访问方式](#访问方式) · [安装 App](#在-iphone-上安装下载的-app) · [证书签名](#证书签名) · [解密](#解密-app-store-原版-ipa) · [连不上 Apple 时](#连不上-apple-时) · [常用操作](#常用操作) · [常见问题](#常见问题) · [不用 Docker 运行](#不用-docker-直接运行)

---

## 目录结构

### 仓库里的 `server/`（部署时用的就是这个目录）

| 文件 | 作用 | 部署时要不要改 |
|---|---|---|
| `server.py` | 网站程序：网页接口、下载队列、Alist 上传、安装链接、证书签名、解密、连 Apple 用的中转 | 不改 |
| `fairplay_fast.py` | 解密的入口：用多个 CPU 核运行 fairplay-decrypt 的 `decrypt.py`，结果和原来逐字节相同 | 不改 |
| `static/index.html` | 首页：搜索、下载任务、已下载文件、解密凭证 | 不改 |
| `static/sign.html` | 证书签名页（`/sign`） | 不改 |
| `static/app.css` | 网页样式 | 不改 |
| `Dockerfile` | 构建镜像：编译 zsign，下载 ipatool 和 fairplay-decrypt 的解密脚本（都是固定版本），安装 cryptography | 不改 |
| `docker-compose.yml` | 容器配置：端口、数据卷、MAC 地址、环境变量；另有可选的 Caddy（HTTPS） | 一般不改，配置都写在 `.env` |
| `.env.example` | 配置模板，每一项都有注释 | 复制成 `.env` 再改 |
| `Caddyfile` | 可选的 Caddy 自动 HTTPS 配置 | 用自带 Caddy 时才用到 |
| `.dockerignore` / `.gitignore` | 构建时、提交时忽略的文件（`.env`、数据、密钥等） | 不改 |
| `start.bat` | Windows 上不用 Docker 直接运行的启动脚本 | — |
| `README.md` | 本文档 | — |

### 部署后服务器上的目录

以部署在 `/opt/ipa-site` 为例（目录随意，下面的命令都在这个目录里运行）：

```
/opt/ipa-site/
├── server.py、static/、Dockerfile、docker-compose.yml …   仓库 server/ 里的文件
├── .env          你的配置（访问密码、MAC 地址等）。只在服务器上，不要提交、不要外传
└── data/         数据目录。只在 .env 里设置了 IPA_DATA=./data 时才有；
                  不设置时数据在 Docker 卷 <目录名>_ipa-data 里，内容一样
```

### 镜像里有什么

| 路径 | 内容 |
|---|---|
| `/app/server.py`、`/app/fairplay_fast.py`、`/app/static/` | 网站程序、解密入口和网页 |
| `/app/fairplay/decrypt.py`、`core.py` | fairplay-decrypt 的解密脚本（构建时从 GitHub 按固定提交下载） |
| `/usr/local/bin/ipatool` | Linux 版 ipatool（构建时从 GitHub releases 下载并校验 SHA-256） |
| `/usr/local/bin/zsign` | 证书签名工具（构建时编译） |
| `/data` | 数据目录，挂载到 Docker 卷或 `IPA_DATA` 指定的目录 |

### 数据目录（容器里的 `/data`）

```
/data/
├── .ipatool/                     第一个 Apple ID 的登录状态（加密的）
├── accounts/<id>/.ipatool/       之后添加的其他 Apple ID 的登录状态，每个账号一个目录
├── accounts.json                 账号列表和当前使用的账号
├── .keychain-passphrase          解密上面登录状态的口令（首次启动自动生成）
├── .link-secret                  安装链接的签名密钥（自动生成）
├── .version-cache.json           查过的历史版本号和发布日期
├── certs/<id>/                   签名证书：cert.p12、profile.mobileprovision、cert.json（含证书密码）
├── signed/<证书id>/*.ipa         证书签名后的 IPA（最多保留 20 个），signed/meta.json 是它们的信息
├── fairplay/<名称>.bin           解密用的 Apple ID 凭证，例如 US.bin、CN.bin
├── fairplay/links.json           凭证和 Apple ID 的对应关系
├── icons/<哈希>.png               从 IPA 里取出的 App 图标（上传的、改版的、证书签名的 App 用），自动生成
└── downloads/
    ├── *.ipa                     下载的、上传的、解密出来的 IPA
    ├── .meta.json                每个文件的应用名、版本、图标、下载用的 Apple ID、是否解密
    ├── .partial/                 下载中的临时文件（重启时清空）
    └── .decrypt/                 解密中的临时文件（重启时清空）
```

| 路径 | 能删吗 | 外传风险 |
|---|---|---|
| `.ipatool/`、`accounts/`、`.keychain-passphrase` | 删了要重新登录 Apple ID | **高**：两者合在一起就是你的 Apple ID 登录状态 |
| `certs/` | 删了要重新导入证书 | **高**：含证书和证书密码 |
| `fairplay/*.bin` | 删了要重新添加凭证 | **高**：能解密这个 Apple ID 下载的所有 App |
| `downloads/`、`signed/` | 可以，只是文件没了 | 低 |
| `.link-secret` | 可以，之前生成的安装链接会失效 | 中 |
| `icons/` | 可以，下次启动会重新生成 | 无 |
| `.version-cache.json`、`.partial/`、`.decrypt/` | 可以 | 无 |

---

## 完整安装步骤

### 第 0 步：准备

- 一台 Linux 服务器（x86_64 或 ARM64，NAS、软路由、VPS 都行），装好 Docker 和 Docker Compose 插件（`docker compose version` 能输出版本号）
- 构建镜像时要能访问 GitHub（下载 ipatool、zsign、解密脚本）和 PyPI（安装 cryptography）
- 下载、登录要能访问 Apple 的服务器；网络不稳也没关系，程序会自动换节点

### 第 1 步：获取代码

推荐用 git，以后更新只要 `git pull`：

```bash
git clone https://github.com/blueskycrb/ipa-site-ios.git /opt/ipa-site-ios
cd /opt/ipa-site-ios/server
```

没有 git 的话，在 GitHub 页面下载 zip，把里面的 `server/` 目录整个拷到服务器上（例如 `/opt/ipa-site`），再进入这个目录。

### 第 2 步：写配置

```bash
cp .env.example .env
vi .env
```

至少要填两项：

| 变量 | 填什么 |
|---|---|
| `IPA_PASSWORD` | 网站访问密码。生成随机密码：`openssl rand -base64 24` |
| `IPA_MAC_ADDRESS` | 容器的 MAC 地址，ipatool 用它当设备标识。生成：`printf '02:%02x:%02x:%02x:%02x:%02x\n' $(od -An -N5 -tu1 /dev/urandom)`，定下来就不要改 |

建议再设置：

- `IPA_COUNTRY`：Apple ID 的地区（cn、us…）
- `IPA_DATA=./data`：数据直接放在部署目录下，备份、迁移都方便。设置后先建好目录：

  ```bash
  mkdir -p data && chown 1000:1000 data
  ```

  数据目录所在的磁盘要支持硬链接（ext4、btrfs、xfs、NTFS 都行，exFAT / FAT32 不行，解密时会失败）。

其他配置（Alist、HTTPS、绑定地址）见[配置说明](#配置说明env)，以后再加也行。

### 第 3 步：构建并启动

```bash
docker compose up -d --build
docker compose logs -f ipa-site      # 看到「访问密码: 已设置」后按 Ctrl+C 退出
```

构建可能遇到的问题：

- **PyPI 很慢或报 `No matching distribution found for cryptography`**：换一个 PyPI 镜像构建，再启动：

  ```bash
  docker compose build --build-arg PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/ ipa-site
  docker compose up -d
  ```

- **报 `all predefined address pools have been fully subnetted`**：Docker 能分配的网段用完了（容器很多的机器上常见）。清理不用的网络 `docker network prune`，或者在 `docker-compose.yml` 的 `ipa-site` 下加一行 `network_mode: bridge` 改用 Docker 自带的网络（这时不能再用自带的 Caddy）。
- **报 `请在 .env 里设置 IPA_MAC_ADDRESS`**：第 2 步漏填了 MAC 地址。

### 第 4 步：登录网站和 Apple ID

1. 浏览器打开 `http://你的服务器IP:8686`，弹出登录框：用户名随便填，密码填 `IPA_PASSWORD`
2. 点右上角「登录 Apple ID」，输入 Apple ID 和密码。需要双重认证时，先留空验证码点登录，Apple 设备上弹出 6 位验证码后填进去再点登录
3. 要用多个 Apple ID（例如美区、国区各一个），在右上角的账号下拉框里「添加 Apple ID」。下载时用当前选中的账号

到这里就可以搜索、下载了。下面几步都是可选的。

### 第 5 步（可选）：解密凭证

想解密下载的原版 IPA（之后证书签名或 TrollStore 安装），每个 Apple ID 需要一个凭证：

1. 用 [fairplay-decrypt 的 credential-retrieval](https://github.com/EthanArbuckle/fairplay-decrypt/tree/main/credential-retrieval) 从越狱设备导出 `credential.bin`（需要一台 Mac 编译、一台登录了这个 Apple ID 的越狱设备，导出一次就能一直用）。按地区改名，例如 `US.bin`、`CN.bin`
2. 网页右上角「解密凭证」→ 选文件 →「添加」
3. 在凭证列表里给每个凭证选「对应 Apple ID」，例如 `US` 对应 `us@example.com`、`CN` 对应 `cn@example.com`

也可以在服务器上用命令导入（凭证文件在服务器上时）：

```bash
docker exec -i ipa-site sh -c 'mkdir -p /data/fairplay && cat > /data/fairplay/US.bin && chmod 600 /data/fairplay/US.bin' < /path/to/US.bin
```

详细说明见[解密 App Store 原版 IPA](#解密-app-store-原版-ipa)。

### 第 6 步（可选）：证书签名

网页右上角「证书签名」（`/sign`）→「上传证书」，选证书 zip 包（或 `.p12` + `.mobileprovision`）。见[证书签名](#证书签名)。

### 第 7 步（可选）：上传到 Alist

在 `.env` 里填 `ALIST_URL`、`ALIST_USERNAME`、`ALIST_PASSWORD`、`ALIST_DIR`，然后 `docker compose up -d`。`ALIST_URL` 不能写 `localhost`，要写服务器的局域网 IP。

### 第 8 步（可选）：HTTPS 和「系统安装」

iPhone「系统安装」要求网站有手机信任的 https 地址：用 Lucky / Nginx / Caddy 反向代理到 `http://127.0.0.1:8686` 并配好证书，然后在 `.env` 里设置 `IPA_PUBLIC_URL=https://你的域名:端口`，再 `docker compose up -d`。只用 TrollStore 安装的话不需要。见[访问方式](#访问方式)。

### 第 9 步：iPhone 客户端

安装方法见[仓库根目录的说明](../README.md#二iphone-客户端)。打开 App →「设置」填服务器地址（`http://你的服务器IP:8686` 或 https 地址）和网站访问密码 →「测试连接」。

---

## 更新

### 用 git 部署的

```bash
cd /opt/ipa-site-ios/server
git pull
docker compose up -d --build
```

### 直接拷文件部署的

只替换程序文件，**不要动 `.env`、`data/`**；`docker-compose.yml` 先对比，有变化再手动合并（里面有你的配置，比如 MAC 地址）：

```bash
cd /opt/ipa-site                                   # 你的部署目录
mkdir -p ../ipa-site-backup && cp -a server.py Dockerfile static ../ipa-site-backup/   # 先备份
rm -rf /tmp/ipa-site-ios && git clone --depth 1 https://github.com/blueskycrb/ipa-site-ios.git /tmp/ipa-site-ios
cd /tmp/ipa-site-ios/server && cp server.py fairplay_fast.py Dockerfile README.md .dockerignore .env.example /opt/ipa-site/ && cd /opt/ipa-site
cp -r /tmp/ipa-site-ios/server/static/. static/
diff /tmp/ipa-site-ios/server/docker-compose.yml docker-compose.yml   # 没输出就是一样的
docker compose up -d --build
```

想退回旧版：把备份目录里的文件拷回来，再 `docker compose up -d --build`。

### 从旧版本升级的注意事项

- 新版的 `docker-compose.yml` 从 `.env` 读 MAC 地址（`IPA_MAC_ADDRESS`）。如果换用新的 `docker-compose.yml`，把旧文件里 `mac_address:` 后面的值填到 `.env` 的 `IPA_MAC_ADDRESS`，Apple 仍认为是同一台设备，不用重新登录。

---

## 备份与迁移

要备份的只有 `.env` 和数据目录。

**数据在 `./data` 目录（`IPA_DATA=./data`）：**

```bash
cd /opt/ipa-site
docker compose stop
tar czf ipa-site-backup.tgz .env data
docker compose start
```

**数据在 Docker 卷里（没设置 `IPA_DATA`）：** 先用 `docker volume ls | grep ipa-data` 查卷名（一般是「部署目录名_ipa-data」），再：

```bash
docker compose stop
docker run --rm -v 卷名:/data -v "$PWD":/backup alpine tar czf /backup/ipa-data.tgz -C /data .
docker compose start
```

**迁移到新服务器：** 在新服务器上按[完整安装步骤](#完整安装步骤)放好代码，把 `.env` 和数据目录拷过去（用 `./data` 的话 `chown -R 1000:1000 data`），再 `docker compose up -d --build`。只要 `IPA_MAC_ADDRESS` 不变、`.keychain-passphrase` 和 `.ipatool/` 一起带过去，Apple ID 不用重新登录。

---

## 配置说明（.env）

完整模板见 [.env.example](.env.example)，每一项都有注释。改完 `.env` 后必须运行 `docker compose up -d` 重建容器才会生效（`docker compose restart` 不会重新读取 `.env`）。开关类配置只认 `1`（开）和 `0`（关），写错时日志里会出现「配置提示」。

### 网站访问

| 变量 | 默认 | 说明 |
|---|---|---|
| `IPA_PASSWORD` | 空 | 网站访问密码。浏览器弹窗登录，用户名随意。**开放到局域网 / 外网时必须设置**。含 `$` `#` 空格等字符时用单引号括起来 |
| `IPA_ALLOW_NO_PASSWORD` | `0` | 设为 `1` 才允许不设密码对外监听，只适合可信内网。不设密码又没打开它，网站拒绝启动 |

### 下载

| 变量 | 默认 | 说明 |
|---|---|---|
| `IPA_COUNTRY` | `cn` | 商店地区代码（cn / us / hk / jp …），和 Apple ID 地区一致。用于补全图标等信息、查询最新版本号 |
| `IPA_CONCURRENCY` | `3` | 同时下载的任务数 |

### Alist 上传（可选）

| 变量 | 默认 | 说明 |
|---|---|---|
| `ALIST_URL` | 空 | Alist 地址，留空不启用。容器里不能用 localhost，要填服务器局域网 IP，如 `http://192.168.1.10:5244` |
| `ALIST_USERNAME` / `ALIST_PASSWORD` | 空 | Alist 账号密码，需要对上传目录有写权限 |
| `ALIST_DIR` | `/` | 上传到 Alist 的哪个目录，如 `/阿里云盘/ipa` |
| `ALIST_AUTO_UPLOAD` | `0` | `1` = 下载完自动上传；`0` = 只在点「传到 Alist」时上传 |

### 直接安装（可选）

| 变量 | 默认 | 说明 |
|---|---|---|
| `IPA_PUBLIC_URL` | 空 | 手机能访问、证书可信的 https 地址，如 `https://ipa.example.com:8443`。「系统安装」必需；TrollStore 安装不需要 |

### 网络与存储

| 变量 | 默认 | 说明 |
|---|---|---|
| `IPA_MAC_ADDRESS` | 无（必填） | 容器的 MAC 地址，ipatool 用它生成设备标识。每个部署用自己的一个，定下来不要改，生成方法见上面第 2 步 |
| `IPA_BIND` / `IPA_BIND6` | `0.0.0.0` / `[::]` | 端口 8686 绑定的 IPv4 / IPv6 地址。只让本机反向代理访问时改成 `127.0.0.1` / `[::1]` |
| `IPA_DATA` | 空 | 数据存放位置。留空用 Docker 卷 `ipa-data`；填目录（如 `./data`）则存到该目录，需先 `chown 1000:1000` |
| `DOMAIN` | 空 | 只在用自带 Caddy（`--profile https`）时需要，见下文 |

### docker-compose.yml 里的其他设置

- `HTTPS_PROXY`：服务器访问 Apple 必须走代理时取消注释，例如 `http://192.168.1.2:7890`。设置后 Apple 的流量都交给这个代理（只有查版本号的服务器仍由内置中转处理）。网络只是不稳的话不用设置，内置中转会自己换节点。
- 构建参数（`docker compose build --build-arg 名称=值`）：`IPATOOL_VERSION`（ipatool 版本）、`FAIRPLAY_COMMIT`（解密脚本的提交号）、`PIP_INDEX_URL`（PyPI 镜像）。

---

## 访问方式

| 场景 | 做法 |
|---|---|
| 局域网 | 直接 `http://服务器IP:8686` |
| 外网（推荐） | Tailscale 等组网工具，不用开放公网端口 |
| 外网 IPv6 | 防火墙放行 8686，用 DDNS 域名访问；务必设置 `IPA_PASSWORD` |
| 外网 + HTTPS | Lucky / Nginx / Caddy 反向代理到 `http://127.0.0.1:8686` 并配证书；或用自带 Caddy：`.env` 填 `DOMAIN`、`IPA_BIND=127.0.0.1`、`IPA_BIND6=[::1]`，然后 `docker compose --profile https up -d --build` |

用 http 暴露到公网时，访问密码是明文传输的，长期在外网用建议加 HTTPS，并且只开放 HTTPS 的端口、不要把 8686 直接开放到公网。

**防猜密码**：输错密码的请求会排队一个一个处理，而且越错越慢（10 分钟内错 10 次以内每次等 1 秒，50 次以内 3 秒，再多 10 秒），不管同时发多少请求，每秒最多只能猜一次；密码正确的请求不受影响。日志里的「访问密码错误：IP（10 分钟内第 N 次）」可以看到有没有人在猜。没有按 IP 封禁，因为经反向代理或 IPv6 进来的请求，看到的来源地址可能都一样，按 IP 封会把自己也封掉。

---

## 在 iPhone 上安装下载的 App

在网页或 iPhone 客户端的文件列表里点「安装」：

- **系统安装**（默认）：iOS 官方的在线安装（itms-services）。需要设置 `IPA_PUBLIC_URL`（https），只对本站从 App Store 下载的 IPA 有效；装好后打开时可能需要手机登录同一个 Apple ID。
- **TrollStore 安装**：打开 `apple-magnifier://install?url=…` 交给 TrollStore 下载安装，任何 IPA 都行（包括 Alist 里的改版 IPA、解密后的 IPA）。

安装链接带签名、6 小时内有效，所以 iOS 安装器不用网站密码也能下载。文件在 Alist 里有副本时，优先用网盘直链，不占家里的上行带宽。

---

## 证书签名

网页首页右上角「证书签名」（`/sign`），或 iPhone 客户端「Alist」/「文件」页的「证书签名」按钮。

1. 在 `/sign` 页点「上传证书」，直接选证书 zip 压缩包（可以一次选多个），或者同时选 `.p12` 和 `.mobileprovision`：
   - 压缩包里写着密码的 txt（如「密码：1234」）会自动识别，识别不到再在密码框里填；
   - 一个压缩包里有多套证书也行，按「描述文件里是否包含这个证书」自动配对；
   - 证书名称默认用压缩包名 / 文件夹名，同一套证书重复导入会自动跳过；
   - 只支持 zip，rar / 7z 请先解压或重新打包成 zip。

   导入后页面会显示证书名称、有效期、支持的设备数，并检查证书是否在描述文件里（不在的话签出来装不上）。
2. 在左边选 Alist 或服务器上的 IPA，点「签名」：服务器先从网盘取回文件，再用 [zsign](https://github.com/zhlynn/zsign) 重签（镜像里已编译好）。
   自己电脑 / 手机上的 IPA：点「上传 IPA」传到服务器文件里再签名；iPhone 客户端可以在「文件」页右上角「导入 IPA」，或在微信、Safari 里「用其他应用打开 → IPA 下载」，然后点「证书签名」（上传、签名、安装一步完成）。
3. 签好后点「安装」（系统在线安装，需要 `IPA_PUBLIC_URL`），也可以交给 TrollStore 或直接下载。最近 20 个签好的文件会保留，可以随时重新安装（网页「已签名文件」，或 iPhone 客户端「文件」页）。

### 证书过期 / 掉签后换证书

在「已签名文件」里点「换证书重签」，直接用签好的文件换新证书重签（不用再从网盘取），签完再点「安装」：

- **新证书和原来的是同一个团队**（同一个开发者账号或同一家企业续期 / 新发的证书）：直接覆盖安装，**不用卸载，App 里的数据都在**。
- **不是同一个团队**（换了另一家的证书）：iOS 规定覆盖安装时 Team ID 必须相同，否则拒绝安装（提示「无法安装」）。只能先删除手机上的旧 App 再装，App 里的数据会丢；有账号云同步的 App 重新登录即可。页面会在重签前提示。
- 删除过期证书时，用它签好的文件会保留，方便之后换证书重签；换证书重签成功后，旧证书（已过期 / 已删除）签的那份会自动删掉。
- 手机装了 TrollStore 的话，用 TrollStore 安装的 App 不依赖证书，不会掉签。

注意：

- App Store 原版 IPA 是加密的，重签后打开会闪退；原版请用「系统安装」，或者先[解密](#解密-app-store-原版-ipa)再签名。证书签名适合改版 / 砸壳 / 解密后的 IPA。
- 个人 / 开发者证书需要描述文件里包含手机的 UDID；企业证书不需要，但可能被苹果吊销（掉签）。
- 证书和密码保存在数据目录的 `certs/` 里，只在你的服务器上。

---

## 解密 App Store 原版 IPA

本站下载的原版 IPA 主程序是 FairPlay 加密的。用 [fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt) 加上下载它的 Apple ID 的凭证，可以直接在服务器上离线解密，解密后的 IPA 能证书签名、交给 TrollStore 安装，或拿去分析。

1. **准备凭证**：凭证是 fairplay-decrypt 从越狱设备导出的 16 字节 `credential.bin`，每个 Apple ID 一个（导出方法见 fairplay-decrypt 的 credential-retrieval）。
2. **添加凭证**：网页右上角「解密凭证」，名称建议用 Apple ID 的地区（US、CN…），选 `credential.bin` 后点「添加」。文件名本身是 `US.bin` 这样时会自动填名称。iPhone 客户端在「设置 → 解密凭证」里也能添加。
3. **对应 Apple ID**：在凭证列表里给每个凭证选「对应 Apple ID」（网站里登录过的账号），例如 US 对应美区账号、CN 对应国区账号。一个 Apple ID 只对应一个凭证。
4. **解密**：在「已下载文件」里点原版 IPA 的「解密」（iPhone 客户端在「任务」页下载完成后、或「文件」页点「解密」）。有多个凭证时，可以选默认用哪个：
   - **自动识别**（默认）：网站会记下每个 IPA 是用哪个 Apple ID 下载的，解密时先用这个账号对应的凭证。没有账号记录的文件（这个功能之前下载的、上传的）就依次试每个凭证。凭证不对时很快就失败，所以基本不慢；
   - 也可以固定用 US / CN。
5. 解密完成后，同目录多出一个「应用名_版本_decrypted.ipa」，标着「已解密 · US」。

说明：

- 只能解密本站（或其他 ipatool 类工具）从 App Store 下载的原版 IPA：里面要有 `SC_Info` 授权文件。第三方网站下载的砸壳包已经是解密过的，网站会直接提示不用再解密。
- IPA 必须是凭证对应的 Apple ID 下载的。国区 App 用国区账号下载，就要用国区账号的凭证解。
- 解密后的 IPA 没有 Apple 的签名，不能「系统安装」，要证书签名或用 TrollStore 安装。
- 一次只解一个（解密时要把主程序读进内存），其余排队。每个 IPA 内部的逐页解密会分给服务器的多个 CPU 核同时做（`fairplay_fast.py`，结果和单核逐字节相同），并以较低优先级运行，不拖慢服务器上的其他服务。
- 凭证是按 Apple ID 区分的：从越狱设备导出时，`retrieve.py` 默认用设备上第一个有许可的 App 对应的账号。要导出另一个账号的凭证，加 `--ipa 这个账号下载的.ipa`，否则两次导出的会是同一个凭证（网页添加时会提示「这个凭证已经添加过了」）。
- 解密脚本在构建镜像时从 GitHub 下载（固定版本），要用新版本：`docker compose build --build-arg FAIRPLAY_COMMIT=提交号`。
- 数据目录要放在支持硬链接的磁盘上（ext4、btrfs、xfs、NTFS 都行，exFAT / FAT32 不行），用默认的 Docker 卷不用管。

---

## 连不上 Apple 时

有些网络里，本地 DNS 给出的 Apple CDN 节点时好时坏：有的连不上，有的能连上但 TLS 握手卡住，同一个节点这会儿行、过会儿又不行。表现是下载、登录、查版本时报 `TLS handshake timeout`。

网站内置了一个只转发加密流量的中转，ipatool 和网站自己访问 Apple 都经过它。每次连接 Apple 时：

1. 把握手的第一个包同时发给本地 DNS 最新给出的几个节点，加上最近 10 分钟里回应过的节点（每个域名最多记 3 个，过期自动忘掉），用最先回应的那个，其余断开。卡住的节点不会拖慢下载；
2. 这些都没回应时，同时问阿里、腾讯、Google、Cloudflare 的 DNS（走 HTTPS），它们给的节点往往不一样，再比一次；
3. 候选节点只用这个域名自己的 DNS 结果（Apple 的每个节点只服务一部分域名）。

握手和证书校验仍由 ipatool 自己完成。日志里的提示：

- `Apple 服务器 xxx：… 都没回应，改用 …`：本地 DNS 给的节点不通，已经换到能用的，不用处理；
- `Apple 服务器 xxx：所有 IP 都没回应`：这时确实连不上 Apple，稍后重试。

配置了 `HTTPS_PROXY` 时，Apple 的流量交给你的代理，只有查版本号的服务器（`uclient-api.itunes.apple.com`）仍由中转处理。

---

## 常用操作

| 操作 | 命令 |
|---|---|
| 查看日志 | `docker compose logs -f ipa-site` |
| 改了 .env 后生效 | `docker compose up -d` |
| 更新代码后重建 | 见[更新](#更新) |
| 停止 | `docker compose down` |
| 把 IPA 拷出容器（用 Docker 卷时） | `docker cp ipa-site:/data/downloads ./downloads` |
| 看解密凭证和对应关系 | `docker exec ipa-site ls -l /data/fairplay` |

`docker compose down -v` 会删除 `ipa-data` 卷：登录状态、钥匙串口令、证书、凭证、已下载的 IPA 全没了，确定要清空时才用。

---

## 常见问题

- **登录提示需要验证码**：先留空验证码点登录，Apple 设备上弹出 6 位验证码后填入再点登录（10 分钟内有效）。
- **下载报「App Not Available」**：Apple 不允许这个 Apple ID 通过 ipatool 获取这个 App。在 iPhone 的 App Store 里用同一个 Apple ID 点一次「获取」（开始下载后可取消），之后就能下载。大多数免费 App 勾选「自动获取许可」即可，不用手动获取。
- **下载、查版本时报 `TLS handshake timeout`，或连不上 `*.itunes.apple.com`**：见[连不上 Apple 时](#连不上-apple-时)，一般会自动换节点；日志里一直是「所有 IP 都没回应」时检查服务器网络。
- **下载速度时快时慢**：取决于当时分配到的 Apple 下载节点，和部署无关；可以同时下载几个提高总速度。
- **解密报「这个凭证解不开」**：IPA 不是这个凭证对应的 Apple ID 下载的。检查「解密凭证」里的对应关系，或换一个凭证。
- **解密报「已经是解密过的」或「没有 SC_Info 授权文件」**：这个 IPA 不是 App Store 原版（比如第三方网站下载的砸壳包），不用解密，直接签名或 TrollStore 安装。
- **解密报 `Operation not permitted`**：数据目录所在的磁盘不支持硬链接（exFAT / FAT32），换到 ext4、btrfs、NTFS 等磁盘。
- **Alist 上传报「资源配额不足」**：网盘空间或会员到期，和本程序无关。
- **改了 .env 没生效**：要用 `docker compose up -d`，不是 `restart`。
- **构建失败**：见[第 3 步](#第-3-步构建并启动)里的几种情况。

---

## 不用 Docker 直接运行

Windows / macOS / Linux 都可以：

1. 从 [ipatool releases](https://github.com/majd/ipatool/releases) 下载对应系统的 ipatool，放到 `server.py` 同目录（Windows 为 `ipatool.exe`）
2. `python server.py`（需要 Python 3.8+，无第三方依赖），打开 http://127.0.0.1:8686
3. 要用解密功能时（需要 Python 3.10+）：把 fairplay-decrypt 的 `decrypt.py`、`core.py` 放到 `server.py` 同目录的 `fairplay/` 里，再 `pip install cryptography`

默认只监听本机。上面的环境变量同样适用（例如 `IPA_HOST=0.0.0.0 IPA_PASSWORD=xxx python server.py`）；这时数据（登录状态、证书、凭证）放在 `server.py` 同目录。
