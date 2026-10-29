# IPA 下载

获取解密凭据：直接阅读本页的 [credential.bin 完整教程（Windows / Linux + Docker）](#credential-bin)，从 iPad 配置到提取、导入按顺序操作即可。

自己搭的 App Store IPA 下载服务，分两部分：

| 部分 | 目录 | 说明 |
|---|---|---|
| **下载服务（服务端）** | [`server/`](server/) | 基于 [ipatool](https://github.com/majd/ipatool)，Docker 部署在自己的服务器上：登录 Apple ID、搜索、下载 IPA、上传 Alist、生成安装链接、证书签名、解密，自带网页 |
| **iPhone 客户端** | 仓库根目录 | SwiftUI App，连接上面的服务端使用；GitHub Actions 自动编译未签名 IPA |

```
iPhone 客户端 / 网页  ──HTTP(S)──▶  下载服务（Docker）  ──ipatool──▶  App Store
                                         │
                                         └──▶  Alist（可选，网盘直链下载 / 安装）
```

### 仓库目录

```
ipa-site-ios/
├── server/                        下载服务（部署时只用这个目录），每个文件的作用见 server/README.md
├── Sources/                       iPhone 客户端代码
│   ├── IPASiteApp.swift           App 入口、底部标签页、接收「用其他应用打开」传来的 IPA、启动时检查更新
│   ├── API.swift                  和服务端通信的接口、数据模型（分享扩展也用这个文件）
│   ├── SearchView.swift           「搜索」页
│   ├── VersionsView.swift         历史版本列表、按版本号 / 日期查找
│   ├── JobsView.swift             「任务」页：下载任务、解密任务
│   ├── FilesView.swift            「文件」页：服务器上的文件、手机上的文件、证书签名的 App
│   ├── AlistView.swift            「Alist」页
│   ├── SettingsView.swift         「设置」页：服务器、Apple ID、安装方式、证书和解密凭证入口、检查更新
│   ├── CertsView.swift            证书管理
│   ├── DecryptCredentialsView.swift  解密凭证（添加、对应 Apple ID、选默认凭证）
│   ├── Components.swift           公用控件：安装、证书签名、解密、存到手机按钮，提示条，文件选择器
│   ├── PhoneDownloads.swift       存到手机的下载、手机上的文件
│   └── Updater.swift              从 GitHub Releases 检查新版本
├── ShareExtension/                分享扩展：在别的 App 里把 IPA / 证书分享到「IPA 下载」
├── Resources/Assets.xcassets      App 图标
├── project.yml                    XcodeGen 工程描述（App 版本号 MARKETING_VERSION 在这里）
└── .github/workflows/build.yml    App 代码有改动时编译未签名 IPA 并发布 Release
```

---

## 一、部署下载服务（Docker）

**完整安装步骤、部署后每个目录放什么、更新、备份迁移、所有配置项，见 [server/README.md](server/README.md)。** 最简单的流程：

```bash
git clone https://github.com/blueskycrb/ipa-site-ios.git
cd ipa-site-ios/server
cp .env.example .env      # 至少填 IPA_PASSWORD 和 IPA_MAC_ADDRESS，其他按需
vi .env
docker compose up -d --build
```

浏览器打开 `http://服务器IP:8686`，登录 Apple ID 即可使用。配置模板 [server/.env.example](server/.env.example) 里每一项都有注释。

常用的几项：

| 变量 | 作用 |
|---|---|
| `IPA_PASSWORD` | 网站访问密码（对外开放时必填） |
| `IPA_MAC_ADDRESS` | 容器的 MAC 地址，ipatool 用它当设备标识（必填，生成方法见 `.env.example`） |
| `IPA_COUNTRY` | Apple ID 所在地区，如 `cn` |
| `ALIST_URL` / `ALIST_USERNAME` / `ALIST_PASSWORD` / `ALIST_DIR` | 上传到 Alist |
| `ALIST_AUTO_UPLOAD` | `1` 下载完自动上传，`0` 手动 |
| `IPA_PUBLIC_URL` | https 地址，iPhone「系统安装」需要 |

改完 `.env` 要运行 `docker compose up -d` 才生效。

---

## 二、iPhone 客户端

### 功能

- **搜索**：按平台搜索 App，下载最新版或从历史版本里挑一个（下载到服务器）
- **任务**：服务器上的下载进度、速度、用时；完成后可直接安装，或者点「解密」（用下载它的 Apple ID 对应的凭证），解密完直接证书签名或 TrollStore 安装
- **文件**：服务器上的 IPA 可以安装、存到手机（从服务器或 Alist 网盘直链）、传到 Alist、解密、删除；解密后的 IPA 标着「已解密 · US」，可以证书签名；证书签名过的 App 可以直接安装，证书过期后换证书重签；手机里的 IPA（「文件」App 选择，或从微信、Safari「用其他应用打开」）可以导入后证书签名安装
- **Alist**：浏览 Alist 上传目录，用网盘直链存到手机或安装，不受家里上行带宽限制；改版 IPA 可以用自己的证书签名后安装
- **分享到「IPA 下载」**：在微信、Safari、「文件」等 App 里分享 IPA → 选「IPA 下载」，直接传到服务器并用证书签名（签好后在「文件」页安装）；分享证书 zip / p12 / 描述文件则直接导入证书。第一次用要在「设置 → 服务器」点「复制配置给分享扩展」
- **设置**：服务器地址、网站访问密码、多个 Apple ID 登录和切换（支持双重认证）、安装方式（系统安装 / TrollStore）、证书管理（从「文件」选证书 zip 导入、删除过期证书）、解密凭证（添加 US.bin / CN.bin，对应 Apple ID，选默认凭证）、检查更新

### 获取与安装

每次 App 代码有改动，GitHub Actions 会编译**未签名**的 IPA 并发布到 [Releases](https://github.com/blueskycrb/ipa-site-ios/releases)（只改服务端或文档不会发版）。最新版固定下载地址：

```
https://github.com/blueskycrb/ipa-site-ios/releases/latest/download/IPASite.ipa
```

- **TrollStore**：在 Safari 地址栏打开下面的链接，直接安装最新版；之后 App 启动时会自动检查更新，有新版提示用 TrollStore 安装（也可在「设置 → 关于」手动检查）

  ```
  apple-magnifier://install?url=https%3A%2F%2Fgithub.com%2Fblueskycrb%2Fipa-site-ios%2Freleases%2Flatest%2Fdownload%2FIPASite.ipa
  ```

- **Sideloadly / AltStore**：下载上面的 IPA，用自己的 Apple ID 签名安装。免费 Apple ID 签名 7 天有效，到期重签即可（数据不会丢）

首次打开 App：在「设置」里填服务器地址（如 `http://192.168.1.10:8686` 或你的 https 域名）和网站访问密码，点「测试连接」。iOS 询问是否允许访问本地网络时选「允许」。

### 本地开发

需要 macOS + Xcode 15 以上：

```bash
brew install xcodegen
xcodegen generate
open IPASite.xcodeproj
```

---

<a id="credential-bin"></a>

## 三、获取 credential.bin 完整教程

适用于 **Windows 或 Linux + Docker + 越狱 iPad**。本流程已有 iPadOS 16.5 + Dopamine 的成功使用记录；其他系统和越狱环境需验证兼容性。

不需要自己有 Mac：GitHub Actions 用 macOS 编译设备工具，电脑上的 Docker 通过 Wi-Fi SSH 让 iPad 执行提取。**下面就是完整流程，无需切换到其他教程页面。**

按顺序完成：准备 iPad → 设置 root 密码 → 下载工具 → 生成 SSH 密钥 → 安装公钥 → 验证免密登录 → Docker 提取 → 导入凭据。电脑命令选择自己的操作系统那一组；标注“iPad”的命令不要在电脑本地执行。

### 第 1 步：准备环境，确认账号

| 位置 | 需要准备 |
|---|---|
| iPad | Dopamine 越狱生效、OpenSSH 服务端、NewTerm，以及由目标 App Store 账号下载的应用。 |
| Windows | Git、OpenSSH 客户端、Docker Desktop（Linux 容器模式）。本文使用 **CMD**，不是 PowerShell。 |
| Linux | Git、OpenSSH 客户端、tar、unzip、Docker Engine。本文使用 **Bash**。 |
| 网络 | 电脑和容器都能访问 iPad 的 Wi-Fi IP 和 SSH 端口，本文用默认端口 `22`。 |

Windows 按 `Win + R`，输入 `cmd`，回车。如果 `ssh -V` 提示找不到命令，在 Windows「设置 → 可选功能」安装 **OpenSSH 客户端**，再重开 CMD。

Ubuntu/Debian 安装基础工具：

```bash
sudo apt-get update
sudo apt-get install -y git openssh-client tar unzip
```

Linux 未安装 Docker 时，按 [Docker Engine 官方安装说明](https://docs.docker.com/engine/install/)选择发行版。`docker info` 应能显示服务端信息；若无权访问 Docker socket，后面的 `docker build`、`docker run` 前加 `sudo`，保持在原用户的终端操作。

**先确认提取的是哪个账号：**

- 脚本读取指定已安装应用的 App Store 许可，以**下载这个应用的账号**为准。仅切换 App Store 登录，不会把旧应用的许可换成新账号。
- 要提取另一个账号，先用那个账号从 App Store 下载一个应用，再指定它的 Bundle ID。侧载、重签名、已经解密的应用不能保证具有所需许可。
- `credential.bin` 是 16 字节的 FairPlay 凭据，不是 Apple ID 登录密码。`US.bin`、`CN.bin` 是自定义标签，文件本身没有地区字段，也不是同地区账号通用的密钥。
- 切换账号不代表旧文件立即失效，但也不能保证凭据适用于未来所有许可；以相应原版 IPA 的实际解密结果为准。

### 第 2 步：在 iPad 上安装 SSH、设置 root 密码

**以下在 iPad 上操作。**

1. 打开 Dopamine，确认当前越狱已生效。重启 iPad 后通常需要重新启用越狱。
2. 在 Sileo 等越狱包管理器中安装 **OpenSSH 服务端**和适用于当前系统的 **NewTerm**。只安装 OpenSSH Client 客户端不能让电脑连进来。
3. 打开「设置 → Wi-Fi → 当前网络右侧 ⓘ」，记下 **IP 地址**，例如 `192.168.1.50`，不要抄成路由器地址。
4. 电脑和 iPad 使用能互通的网络；提取期间保持 iPad 解锁。访客 Wi-Fi、AP 隔离、VPN 可能阻止连接。云服务器不能直接访问家里的 `192.168.x.x`，需要先打通 VPN/路由，或在家中的电脑执行。

打开 **NewTerm**，设置或更改 root 密码：

```sh
sudo passwd root
```

按提示依次输入：

1. sudo 若要求 `Password:`，输入 **mobile 的终端密码**，通常是配置 Dopamine 时设置的密码。已有 sudo 授权缓存时可能不问。
2. `New password:`：输入你想设置的 **新 root 密码**。
3. `Retype new password:`：再输入一次同样的新 root 密码，确认更新成功。

输入密码时**不显示字符或星号是正常现象**。这不是 Apple ID 密码或锁屏密码。`sudo passwd root` 不会同时修改 mobile 的密码；如果 `id -u` 已返回 `0`，也可直接执行 `passwd root`。已有可用 root 密码时无需重置。

设置 root 密码并不自动允许 root 通过 SSH 密码登录。如果服务端只允许 root 公钥登录，第 5 步可以先用 mobile 登录、再切换 root，无需为了提取开放 root 密码登录。

### 第 3 步：下载项目和设备工具

**回到电脑操作。** 首次下载仓库；如果已有仓库，更新后直接进入 `tools/credential-retrieval`。

Windows CMD：

```cmd
git clone https://github.com/blueskycrb/ipa-site-ios.git
cd ipa-site-ios\tools\credential-retrieval
```

Linux Bash：

```bash
git clone https://github.com/blueskycrb/ipa-site-ios.git
cd ipa-site-ios/tools/credential-retrieval
```

接下来取得 iPad 上运行的五个工具文件：

1. 打开 [Actions → Build credential tools](https://github.com/blueskycrb/ipa-site-ios/actions/workflows/build-credential-tools.yml)，点击 **Run workflow**，选择 `main`，等待成功。自己 fork 的项目使用自己仓库的 Actions。
2. 打开成功的运行，在 **Artifacts** 下载 `credential-tools`。它只包含工具，不包含你的账号凭据，也不会发布客户端 Release。
3. 解压下载的 ZIP，得到 `credential-tools.tar.gz`，把 tar.gz 放到电脑当前的 `tools/credential-retrieval` 目录。Linux 也可在终端用 `unzip credential-tools.zip` 解开外层。
4. 两个系统都可在当前目录执行：

```sh
tar -xzf credential-tools.tar.gz
```

确认目录结构如下。已有本流程的完整 `bundle` 可直接复制进来：

```text
tools/credential-retrieval/
├── Dockerfile
├── docker-entrypoint.sh
├── retrieve.py
├── native_ssh.py
└── bundle/
    ├── credential.ios
    ├── driver.ios
    ├── trigger.ios
    ├── static-key-table.bin
    └── core4-word-table.bin
```

不要只解开 ZIP 而漏掉 tar.gz，也不要放成 `bundle/bundle/...`。后面的 Docker 命令始终在这个工具目录运行。

### 第 4 步：在电脑生成 SSH 密钥

SSH 密钥由两个文件组成：`fairplay_ipad` 是**私钥，留在电脑**；`fairplay_ipad.pub` 是**公钥，装到 iPad**。每台执行 Docker 的电脑都需要有自己的可用密钥。已能用该密钥以 root 免密码登录的用户可直接到第 7 步验证，不必重新生成。

**Windows CMD：**先将下面的 IP 换成自己的，再检查是否已有密钥。

```cmd
set "IPAD_IP=192.168.1.50"
dir "%USERPROFILE%\.ssh\fairplay_ipad*"
```

首次没有文件时才生成：

```cmd
if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
ssh-keygen -t ed25519 -f "%USERPROFILE%\.ssh\fairplay_ipad"
```

**Linux Bash：**

```bash
IPAD_IP=192.168.1.50
ls -l "$HOME/.ssh/fairplay_ipad" "$HOME/.ssh/fairplay_ipad.pub"
```

首次没有文件时才生成：

```bash
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$HOME/.ssh/fairplay_ipad"
chmod 600 "$HOME/.ssh/fairplay_ipad"
```

生成时，`Enter passphrase` 和 `Enter same passphrase again` **都直接回车**：当前 Docker 入口不支持交互式私钥口令或 SSH agent，需要无口令的专用密钥。如果询问是否覆盖已有文件，输入 `n`，保留原密钥。

显示公钥并复制完整的一行，以 `ssh-ed25519 ` 开头。Windows CMD：

```cmd
type "%USERPROFILE%\.ssh\fairplay_ipad.pub"
```

Linux Bash：

```bash
cat "$HOME/.ssh/fairplay_ipad.pub"
```

不要复制命令提示符，不要把公钥手动拆成多行，更不要读取或复制不带 `.pub` 的私钥。`IPAD_IP` 只对当前终端有效，新开窗口需要重新设置。

### 第 5 步：从电脑连接 iPad，确认 root 身份

先用刚设置的 root 密码试连接。**命令在电脑上输入。**

Windows CMD：

```cmd
ssh root@%IPAD_IP%
```

Linux Bash：

```bash
ssh "root@$IPAD_IP"
```

首次连接会显示主机指纹，确认 IP 是自己的 iPad、核对指纹后输入 `yes`。如需独立核对，可在 iPad NewTerm 中用管理员权限对实际 SSH 主机公钥运行 `ssh-keygen -lf`；Dopamine rootless 常见位置是 `/var/jb/etc/ssh/ssh_host_ed25519_key.pub`。主机指纹不是第 4 步的用户公钥。

若提示 root 的 `password:`，输入第 2 步设置的 **root 密码**。成功后出现类似 `iPad:~ root#`，此时输入的命令已经在 iPad 上执行。

**如果 root 密码登录被禁止，但网络连接正常：**改用 mobile 登录。Windows CMD：

```cmd
ssh mobile@%IPAD_IP%
```

Linux Bash：

```bash
ssh "mobile@$IPAD_IP"
```

输入 **mobile 的终端密码**。成功后，在 **iPad SSH 会话**中执行：

```sh
sudo -i
```

sudo 若要求密码，仍输入 **mobile 密码**。无论走哪条路线，最后在 iPad 会话中检查：

```sh
id -u
echo "$HOME"
```

`id -u` 必须返回 **`0`**，`$HOME` 通常为 `/var/root`。如果 sudo 不存在、密码不正确或 mobile 无 sudo 权限，先解决管理员访问，再继续；也可在 iPad NewTerm 中取得 root 后完成下一步。**不要在 mobile 身份下安装公钥，否则会装到错误的用户目录。**

### 第 6 步：把公钥安装到 iPad 的 root 用户

**以下在刚才 `id -u` 返回 `0` 的 iPad 会话中输入，不是在电脑本地输入。**

```sh
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
printf '\n' >> "$HOME/.ssh/authorized_keys"
cat >> "$HOME/.ssh/authorized_keys"
```

最后一条会停下来等待输入，**不是卡住**。依次操作：

1. 粘贴第 4 步复制的整行 `ssh-ed25519 AAAA...` 公钥，不要加引号。
2. 按一次 **Enter**，让光标到新的一行。
3. 在空行按 **Ctrl + D**，结束输入，回到 iPad 提示符。

接着执行：

```sh
chmod 600 "$HOME/.ssh/authorized_keys"
chown "$(id -u):$(id -g)" "$HOME/.ssh" "$HOME/.ssh/authorized_keys"
ls -ld "$HOME/.ssh"
ls -l "$HOME/.ssh/authorized_keys"
```

目录权限应类似 `drwx------`，文件应类似 `-rw-------`，属主为 root。`>>` 是追加，保留已有公钥，不要改成覆盖用的 `>`。添加公钥通常立即生效，无需重启设备。

**保留这个会话，电脑另开一个终端验证**，失败时还可以回来修复。

### 第 7 步：在电脑验证 root 免密码登录

**Windows：另开 CMD**，重新设置实际 IP：

```cmd
set "IPAD_IP=192.168.1.50"
ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i "%USERPROFILE%\.ssh\fairplay_ipad" root@%IPAD_IP% "id -u"
```

**Linux：另开 Bash 终端**：

```bash
IPAD_IP=192.168.1.50
ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i "$HOME/.ssh/fairplay_ipad" "root@$IPAD_IP" 'id -u'
```

**成功标准：不询问任何密码，直接输出 `0`，然后回到电脑提示符。** 仅 mobile 登录成功，或 root 仍要求密码，都不算完成。`BatchMode=yes` 的验证方式与 Docker 脚本相符。

确认成功后，原会话若直接 root 登录，输入一次 `exit`；若从 mobile 执行了 `sudo -i`，输入两次 `exit`，回到电脑。在下面使用的电脑终端中进入第 3 步的工具目录，并确保 `IPAD_IP` 已设置。

### 第 8 步：构建 Docker 镜像并提取

Windows CMD：

```cmd
if not exist data mkdir data
docker build -t fairplay-wifi-retriever .
docker run --rm fairplay-wifi-retriever --help
```

Linux Bash：

```bash
mkdir -p data
docker build -t fairplay-wifi-retriever .
docker run --rm fairplay-wifi-retriever --help
```

帮助中应出现 `--bundle-id`、`--ssh-host`、`--ssh-key`。更新脚本后需重新构建镜像。保持 iPad 解锁并有容纳目标 App 副本的剩余空间；脚本会临时复制 App、重启 `fairplayd`、触发许可请求，完成后清理临时文件。

#### 示例 A：指定 ChatGPT，保存到 credential-us

ChatGPT 的 Bundle ID 为 `com.openai.chat`。**只有这次安装确实由你的美区账号下载，才把它标记为 US。** 以下每条 Docker 命令都是一行。

Windows CMD：

```cmd
docker run --rm -v "%cd%\bundle:/bundle:ro" -v "%cd%\data:/data" -v "%USERPROFILE%\.ssh\fairplay_ipad:/run/secrets/ipad_key:ro" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host %IPAD_IP% --ssh-port 22 --bundle-id com.openai.chat --output-dir /data/credential-us
```

Linux Bash：

```bash
docker run --rm --mount "type=bind,source=$(pwd)/bundle,target=/bundle,readonly" --mount "type=bind,source=$(pwd)/data,target=/data" --mount "type=bind,source=$HOME/.ssh/fairplay_ipad,target=/run/secrets/ipad_key,readonly" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host "$IPAD_IP" --ssh-port 22 --bundle-id com.openai.chat --output-dir /data/credential-us
```

日志应包含下列信息，名称和许可路径以实际安装为准：

```text
selected-app: {"name": "ChatGPT", "bundle_id": "com.openai.chat", "license": "..."}
credential ready: /data/credential-us/credential.bin
```

结果在电脑当前工具目录的 **`data/credential-us/credential.bin`**。

#### 示例 B：指定另一个账号下载的应用

例如已确认目标应用 Bundle ID 是 `com.ss.iphone.ugc.Live.lite`，并由另一个账号下载，使用独立目录保存。

Windows CMD：

```cmd
docker run --rm -v "%cd%\bundle:/bundle:ro" -v "%cd%\data:/data" -v "%USERPROFILE%\.ssh\fairplay_ipad:/run/secrets/ipad_key:ro" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host %IPAD_IP% --ssh-port 22 --bundle-id com.ss.iphone.ugc.Live.lite --output-dir /data/credential-account2
```

Linux Bash：

```bash
docker run --rm --mount "type=bind,source=$(pwd)/bundle,target=/bundle,readonly" --mount "type=bind,source=$(pwd)/data,target=/data" --mount "type=bind,source=$HOME/.ssh/fairplay_ipad,target=/run/secrets/ipad_key,readonly" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host "$IPAD_IP" --ssh-port 22 --bundle-id com.ss.iphone.ugc.Live.lite --output-dir /data/credential-account2
```

结果在 **`data/credential-account2/credential.bin`**。换应用改 `--bundle-id`，换账号使用不同输出目录。

只预先创建 `data`，**不要预先创建 `credential-us` 等输出子目录**。它们必须尚不存在；重复提取可改为 `/data/credential-us-2`。指定 Bundle ID 后，找不到该应用的受支持许可就会报错，不会改读其他应用。省略 `--bundle-id` 则可能选到旧账号的应用，多账号应始终指定。

### 第 9 步：检查文件并导入现有服务

Windows CMD 查看大小：

```cmd
for %F in ("data\credential-us\credential.bin") do @echo %~zF bytes
```

如果写进 `.bat` 文件，将 `%F` 和 `%~zF` 分别改成 `%%F`、`%%~zF`。

Linux 默认 rootful Docker 生成的文件可能属于 root，目录权限为 `700`、文件为 `600`。成功后把**本次输出目录**交还当前用户，再检查大小：

```bash
sudo chown -R "$(id -u):$(id -g)" data/credential-us
stat -c '%s bytes' data/credential-us/credential.bin
```

rootless Docker 下若已能读取结果，可跳过 `chown`；其他输出目录同步替换路径。两个系统都应显示 **`16 bytes`**，但长度正确并不能验证地区或解密有效性。

导入步骤：

1. 打开网页右上角「解密凭证」，或 iPhone 客户端「设置 → 解密凭证」。
2. 填名称，如 `US`、`CN` 或同地区另一账号的 `US2`，选择提取的 `credential.bin` 添加。也可先复制并改名为 `US.bin` 后导入。
3. 在列表中给它选择**实际下载目标应用的 Apple ID**。
4. 用同一账号下载的原版 IPA 解密一次，验证是否匹配。

SSH 私钥不需要交给下载服务；私钥、生成的凭据和个人许可不要上传 GitHub。工具目录的 `data/`、`bundle/` 和二进制产物已设为 Git 忽略，Docker 构建只接收运行所需文件。

### 常见问题：按出现的位置排查

| 现象 | 处理方法 |
|---|---|
| Windows 找不到 `ssh` | 安装 OpenSSH 客户端，重新打开 CMD。 |
| SSH `Connection timed out` / `No route to host` | 核对 iPad 实际 IP、越狱状态、Wi-Fi 隔离、VPN 和防火墙；此时尚未进入密码验证。 |
| SSH `Connection refused` | 检查 OpenSSH 服务端是否安装并启动，以及实际监听端口。 |
| 密码输入时没有显示 | 正常，输入对应用户的终端密码后按回车。 |
| root 密码被拒绝 | 可能是密码错误或 SSH 不允许 root 密码登录；改走 mobile → `sudo -i` 的路线。设置 root 密码不会自动开放远程密码登录。 |
| sudo 报错 | 先修复 mobile 密码或管理员权限，确认 `id -u` 是 `0` 后才安装 root 公钥。 |
| `Permission denied (publickey)` | 核对公私钥配对、公钥完整单行、安装在 root 的 HOME，以及 `.ssh` 的 `700`、`authorized_keys` 的 `600` 权限和 root 属主。 |
| `Enter passphrase for key` | 私钥带口令，当前容器不支持交互解锁；另建无口令专用密钥并安装公钥，不要覆盖原密钥。 |
| `Identity file ... not accessible` | `-i` 应指向存在的不带 `.pub` 的私钥。 |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | 先核对是否重装 SSH 或 IP 被别的设备占用；确认设备和新指纹后才清理该 IP 的旧记录，不要关闭主机检查。 |
| CMD 中 `too many colons` | 使用 `%cd%`、`%USERPROFILE%`，不要混用 PowerShell 的 `${env:USERPROFILE}`。 |
| `unrecognized arguments: --bundle-id` | 当前镜像太旧，在更新的工具目录重新 `docker build`。 |
| `bundle is missing files` | 确认 ZIP、tar.gz 两层均已解开，五个文件直接位于 `bundle`。 |
| `--output-dir must name a new directory` | 换用未存在的输出目录，保留旧文件。 |
| Linux `bind source path does not exist` | 检查当前目录、`bundle`、`data`、私钥文件是否存在。 |
| Linux 无权访问 Docker socket | 在原用户终端使用 `sudo docker ...`，让 `$HOME` 仍指向保存私钥的用户目录。 |
| Linux SELinux 拒绝容器读取挂载 | 查看拒绝日志，按发行版配置 bind mount 标签；不要直接给整个 `~/.ssh` 改标签或关闭 SELinux。 |
| 电脑能 SSH，Docker 连接超时 | 检查容器的出站路由、防火墙、VPN；原生 Linux Docker Engine 可临时加 `--network host` 排查桥接网络问题。 |
| `no supported installed App Store license found for ...` | 核对 Bundle ID 大小写，确认应用由目标账号从 App Store 安装，许可格式受支持。 |
| FairPlay observer/trigger 报错或超时 | 确认越狱、解锁、剩余空间，记录实际错误再排查；SSH 成功不代表原生工具一定兼容当前系统。 |
| 两个账号提取到相同文件 | 核对两次 `selected-app` 和应用实际下载账号，切换 App Store 登录不会替换旧应用许可。 |
| Linux 显示提取成功但打不开文件 | 按第 9 步修复本次输出目录属主。 |

Windows CMD 检查 TCP 22 是否可达，先设置 `IPAD_IP`：

```cmd
powershell -NoProfile -Command "Test-NetConnection -ComputerName '%IPAD_IP%' -Port 22"
```

`TcpTestSucceeded : True` 只说明端口可达。进一步诊断可在第 7 步的 SSH 验证命令中加 `-v`，不要分享私钥或密码。

如果已确认是自己的 iPad 更换了主机密钥，Windows CMD 用 `ssh-keygen -R "%IPAD_IP%"`，Linux 用 `ssh-keygen -R "$IPAD_IP"` 清理旧记录，再普通 SSH 连接、核对接受新指纹，最后做免密验证。

root 公钥仍被拒绝时，应检查服务端允许 `PubkeyAuthentication yes`，且 `PermitRootLogin` 不是 `no`。`PermitRootLogin prohibit-password`（旧名 `without-password`）允许 root 公钥登录，无需改成密码登录。Dopamine rootless 常见配置在 `/var/jb/etc/ssh/sshd_config`，具体以实际软件包和启动参数为准；修改前保留现有会话、备份配置，并用对应 sshd 的 `-t` 检查语法后按服务要求重载。若自己改过端口，所有 SSH 命令的 `-p` 和提取命令的 `--ssh-port` 都要同步修改。

### 工具来源

原生工具来自 [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)，工作流固定提交 [`7f80db2ef37634073fab06b3aad1aa0cf24561a1`](https://github.com/EthanArbuckle/fairplay-decrypt/tree/7f80db2ef37634073fab06b3aad1aa0cf24561a1)。本项目的 `tools/credential-retrieval` 在其脚本上增加 Wi-Fi SSH、指定密钥、按 Bundle ID 精确选择、打印来源和输出长度检查。

容器入口把只读挂载的私钥复制到临时位置并设为 `600`，避免 Windows 挂载权限导致 OpenSSH 拒绝读取；`--rm` 在退出后移除容器。该工具独立使用，不参与客户端编译和服务器启动。
