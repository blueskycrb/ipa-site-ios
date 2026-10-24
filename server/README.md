# IPA 下载站（服务端）

基于 [ipatool](https://github.com/majd/ipatool) 的 App Store IPA 下载服务，用 Docker 部署在自己的服务器上，配一个网页和一个 iPhone 客户端（见仓库根目录）。只用 Python 标准库，镜像里自带 Linux 版 ipatool。

**功能**

- 网页登录 Apple ID（支持双重认证、多个账号随时切换），搜索 App，下载最新版或任意历史版本
- 历史版本按版本号或日期查找（如 14.8.40、2026-09）
- 文件以「应用名_版本.ipa」命名，列表显示图标和版本
- 下载完自动上传到 Alist（可选），可浏览 Alist 目录、用网盘直链下载
- iPhone 一键安装：系统安装（itms-services，需要 HTTPS）或交给 TrollStore 安装
- 证书签名：上传自己的 p12 证书 + 描述文件，选 Alist / 服务器上的 IPA 用 zsign 重签后安装（网页 `/sign`）
- 访问密码、IPv4 / IPv6、多任务并行下载

---

## 快速部署（Docker Compose）

需要：Linux 服务器（x86_64 或 ARM64）、Docker 和 Docker Compose 插件。

```bash
# 1. 获取代码
git clone https://github.com/blueskycrb/ipa-site-ios.git
cd ipa-site-ios/server

# 2. 写配置（至少填 IPA_PASSWORD，各项说明见下文）
cp .env.example .env
vi .env

# 3. 如果 .env 里设置了 IPA_DATA=./data，先建好数据目录
mkdir -p data && chown 1000:1000 data

# 4. 构建并启动
docker compose up -d --build

# 5. 查看日志，确认看到「访问密码: 已设置」
docker compose logs -f ipa-site
```

然后浏览器打开 `http://服务器IP:8686`，用户名随便填、密码填 `IPA_PASSWORD`，在网页右上角「登录 Apple ID」。

构建时会从 GitHub 官方 releases 下载 ipatool 并校验 SHA-256；想换版本：`docker compose build --build-arg IPATOOL_VERSION=x.y.z`。

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
| `IPA_BIND` / `IPA_BIND6` | `0.0.0.0` / `[::]` | 端口 8686 绑定的 IPv4 / IPv6 地址。只让本机反向代理访问时改成 `127.0.0.1` / `[::1]` |
| `IPA_DATA` | 空 | 数据存放位置。留空用 Docker 卷 `ipa-data`；填目录（如 `./data`）则存到该目录，需先 `chown 1000:1000` |
| `DOMAIN` | 空 | 只在用自带 Caddy（`--profile https`）时需要，见下文 |

### docker-compose.yml 里的其他设置

- `mac_address`：ipatool 用网卡 MAC 生成「设备标识」，固定下来后重建容器 Apple 仍认为是同一台设备，不用重新登录。和局域网其他设备重复时换一个 `02:` 开头的地址（换了要重新登录 Apple ID）。
- `HTTPS_PROXY`：服务器访问 Apple 需要走代理时取消注释，例如 `http://192.168.1.2:7890`。

---

## 访问方式

| 场景 | 做法 |
|---|---|
| 局域网 | 直接 `http://服务器IP:8686` |
| 外网（推荐） | Tailscale 等组网工具，不用开放公网端口 |
| 外网 IPv6 | 防火墙放行 8686，用 DDNS 域名访问；务必设置 `IPA_PASSWORD` |
| 外网 + HTTPS | Lucky / Nginx / Caddy 反向代理到 `http://127.0.0.1:8686` 并配证书；或用自带 Caddy：`.env` 填 `DOMAIN`、`IPA_BIND=127.0.0.1`、`IPA_BIND6=[::1]`，然后 `docker compose --profile https up -d --build` |

用 http 暴露到公网时，访问密码是明文传输的，长期在外网用建议加 HTTPS。

---

## 在 iPhone 上安装下载的 App

在网页或 iPhone 客户端的文件列表里点「安装」：

- **系统安装**（默认）：iOS 官方的在线安装（itms-services）。需要设置 `IPA_PUBLIC_URL`（https），只对本站从 App Store 下载的 IPA 有效；装好后打开时可能需要手机登录同一个 Apple ID。
- **TrollStore 安装**：打开 `apple-magnifier://install?url=…` 交给 TrollStore 下载安装，任何 IPA 都行（包括 Alist 里的改版 IPA）。

安装链接带签名、6 小时内有效，所以 iOS 安装器不用网站密码也能下载。文件在 Alist 里有副本时，优先用网盘直链，不占家里的上行带宽。

---

## 证书签名

网页首页右上角「证书签名」（`/sign`），或 iPhone 客户端「Alist」页每个 IPA 的「证书签名」按钮。

1. 在 `/sign` 页点「上传证书」，直接选证书 zip 压缩包（可以一次选多个），或者同时选 `.p12` 和 `.mobileprovision`：
   - 压缩包里写着密码的 txt（如「密码：1234」）会自动识别，识别不到再在密码框里填；
   - 一个压缩包里有多套证书也行，按「描述文件里是否包含这个证书」自动配对；
   - 证书名称默认用压缩包名 / 文件夹名，同一套证书重复导入会自动跳过；
   - 只支持 zip，rar / 7z 请先解压或重新打包成 zip。

   导入后页面会显示证书名称、有效期、支持的设备数，并检查证书是否在描述文件里（不在的话签出来装不上）。
2. 在左边选 Alist 或服务器上的 IPA，点「签名」：服务器先从网盘取回文件，再用 [zsign](https://github.com/zhlynn/zsign) 重签（镜像里已编译好）。
3. 签好后点「安装」（系统在线安装，需要 `IPA_PUBLIC_URL`），也可以交给 TrollStore 或直接下载。最近 20 个签好的文件会保留，可以随时重新安装。

注意：

- App Store 原版 IPA 是加密的，重签后打开会闪退；原版请用「系统安装」。证书签名适合改版 / 砸壳的 IPA。
- 个人 / 开发者证书需要描述文件里包含手机的 UDID；企业证书不需要，但可能被苹果吊销（掉签）。
- 证书和密码保存在数据目录的 `certs/` 里，只在你的服务器上。

---

## 常用操作

| 操作 | 命令 |
|---|---|
| 查看日志 | `docker compose logs -f ipa-site` |
| 改了 .env 后生效 | `docker compose up -d` |
| 更新代码后重建 | `git pull && docker compose up -d --build` |
| 停止 | `docker compose down` |
| 把 IPA 拷出容器（用 Docker 卷时） | `docker cp ipa-site:/data/downloads ./downloads` |

`docker compose down -v` 会删除 `ipa-data` 卷：登录状态、钥匙串口令、已下载的 IPA 全没了，确定要清空时才用。

### 数据目录里有什么

| 路径 | 内容 |
|---|---|
| `.ipatool/` | 第一个 Apple ID 的 ipatool 登录状态（已加密） |
| `accounts/<id>/.ipatool/` | 后来添加的其他 Apple ID 的登录状态，每个账号一个目录 |
| `accounts.json` | 账号列表和当前使用的账号 |
| `certs/<id>/` | 上传的签名证书、描述文件和证书密码（权限 600）。**不要外传** |
| `signed/` | 证书签名后的 IPA（最多保留 20 个） |
| `.keychain-passphrase` | 解密上面登录状态的口令，首次启动自动生成。**删了就要重新登录 Apple ID，也不要外传** |
| `.link-secret` | 安装链接的签名密钥，自动生成 |
| `.version-cache.json` | 查过的历史版本号和发布日期（不会变，查一次就记住，删了只是要重新查） |
| `downloads/` | 下载的 IPA；`downloads/.meta.json` 记录每个文件的应用名、版本、图标 |

---

## 常见问题

- **登录提示需要验证码**：先留空验证码点登录，Apple 设备上弹出 6 位验证码后填入再点登录（10 分钟内有效）。
- **下载报「App Not Available」**：Apple 不允许这个 Apple ID 通过 ipatool 获取这个 App。在 iPhone 的 App Store 里用同一个 Apple ID 点一次「获取」（开始下载后可取消），之后就能下载。大多数免费 App 勾选「自动获取许可」即可，不用手动获取。
- **下载速度时快时慢**：取决于当时分配到的 Apple 下载节点，和部署无关；可以同时下载几个提高总速度。
- **历史版本 / 下载最新版报连不上 `uclient-api.itunes.apple.com`**：有些网络里这个 Apple 服务器的部分 IP 不通。程序内置的中转会自动换用能连通的 IP，一般无需处理。
- **Alist 上传报「资源配额不足」**：网盘空间或会员到期，和本程序无关。
- **改了 .env 没生效**：要用 `docker compose up -d`，不是 `restart`。

---

## 不用 Docker 直接运行

Windows / macOS / Linux 都可以：

1. 从 [ipatool releases](https://github.com/majd/ipatool/releases) 下载对应系统的 ipatool，放到 `server.py` 同目录（Windows 为 `ipatool.exe`）
2. `python server.py`（需要 Python 3.8+，无第三方依赖），打开 http://127.0.0.1:8686

默认只监听本机。上面的环境变量同样适用（例如 `IPA_HOST=0.0.0.0 IPA_PASSWORD=xxx python server.py`）。
