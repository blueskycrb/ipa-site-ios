# 获取 credential.bin：Windows / Linux + Docker + 越狱 iPad

本教程把已经走通的获取流程整理在一起：用 GitHub Actions 编译设备工具，在 Windows 或 Linux 的 Docker 容器里通过 Wi-Fi SSH 操作越狱 iPad，按指定应用的 Bundle ID 获取 `credential.bin`，最后导入本项目的解密凭证管理。

第 2–7 节使用 Windows CMD；Linux 用户先阅读第 1 节的账号说明，再跳到 [Linux + Docker 获取步骤](#linux-docker)。

不需要自己有 Mac。原生工具仍需 Xcode 编译，这一步由 GitHub 的 macOS runner 完成；Docker 负责运行 Python 和 SSH，提取实际在 iPad 上进行。

本流程已有 **iPadOS 16.5 + Dopamine** 的成功使用记录，其他系统和越狱环境需自行验证。

## 1. 先理解凭据属于哪个账号

- `credential.bin` 是 16 字节的 FairPlay 凭据，用于匹配相应账号/许可密钥的 App Store IPA；不是 Apple ID 登录密码。
- 本目录的脚本支持 `--bundle-id`：读取指定已安装 App 的许可。**以下载该 App 的 App Store 账号为准，不以当前登录的账号为准。**
- 切换到另一个账号后，要用该账号从 App Store 下载一个应用，再指定这个应用的 Bundle ID。不要只切账号后继续读取旧应用。
- `US.bin`、`CN.bin` 是你自己起的名字。文件没有国家/地区字段，也不是同地区所有账号通用的密钥。两个文件不同不能证明一个是 US、另一个是 CN。
- 已解密、重签名或侧载的 IPA 可能没有需要的 App Store 许可，不能代替设备上由目标账号下载的正版应用。
- 换账号登录不等于旧文件立即失效；但不能保证它适用于未来所有许可。是否匹配，应以对应原版 IPA 的实际解密结果为准。

## 2. 准备环境和目录

准备 Windows 的 Git、OpenSSH 客户端、Docker Desktop（Linux 容器模式），以及已启用越狱、安装 OpenSSH、允许 root SSH 登录的 iPad。Windows 和 iPad 应在互通的局域网中；在 iPad 的 Wi-Fi 详情里查看 IP。

下面所有 Windows 命令都在 **CMD（命令提示符）** 中执行，每条命令都是一行。PowerShell 的变量语法不同，不要混用。

首次下载仓库：

```cmd
git clone https://github.com/blueskycrb/ipa-site-ios.git
cd ipa-site-ios\tools\credential-retrieval
```

如果已有仓库，更新后进入 `tools\credential-retrieval` 即可。后续 Docker 命令都在这个目录运行。

## 3. 准备设备工具：不需要本地 Mac

1. 打开仓库的 [Actions → Build credential tools](https://github.com/blueskycrb/ipa-site-ios/actions/workflows/build-credential-tools.yml)。自己 fork 的仓库应使用自己仓库里的 Actions 页面。
2. 点击 **Run workflow**，选择 `main`，运行并等待成功。此 workflow 只编译工具，不获取账号凭据，不发布客户端 Release。
3. 打开成功的运行，在 **Artifacts** 中下载 `credential-tools`。
4. 解压下载的 ZIP，得到 `credential-tools.tar.gz`，把这个 tar.gz 放到当前 `tools\credential-retrieval` 目录。
5. 在 CMD 中解压：

```cmd
tar -xzf credential-tools.tar.gz
```

解压后的结构应为：

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

已有本流程下载的 `bundle` 时可直接放到这里。不要只解开外层 ZIP 而漏掉 tar.gz，也不要把文件放成 `bundle\bundle\...`。

## 4. 配置并验证 SSH 密钥登录

首次配置请打开 **[越狱 iPad SSH 详细教程（Dopamine）](SSH.md)**，按顺序完成：

1. 在 iPad 上确认越狱生效、安装 OpenSSH 服务端、查看 Wi-Fi IP。
2. 在 Windows CMD 生成专用密钥并复制 `.pub` 公钥。
3. 用 mobile 的终端密码登录 iPad，执行 `sudo -i` 获取 root 权限。
4. 将公钥追加到 root 的 `authorized_keys`，设置权限。
5. 在电脑新开 CMD，确认 root 公钥登录免密码返回 `0`。

详细教程区分了 Windows、Linux 和 iPad 中执行的命令，说明密码提示、公钥粘贴、Ctrl + D 结束输入、成功输出和连接错误。已有 root 密码登录的用户也有快捷安装方法。

**已经配置成功时无需重做。** 在当前 Windows CMD 设置实际 IP 并验证即可：

```cmd
set "IPAD_IP=192.168.1.50"
ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i "%USERPROFILE%\.ssh\fairplay_ipad" root@%IPAD_IP% "id -u"
```

直接返回 `0`，且全程不要求密码，才继续下面的 Docker 步骤。新开 CMD 窗口要重新设置 IP；仅 mobile 登录成功还不满足提取脚本要求。

## 5. 构建 Docker 镜像

在 `tools\credential-retrieval` 目录运行：

```cmd
if not exist data mkdir data
docker build -t fairplay-wifi-retriever .
docker run --rm fairplay-wifi-retriever --help
```

帮助中应有 `--bundle-id`、`--ssh-host`、`--ssh-key`。更新脚本后，需要重新运行 `docker build`。

## 6. 按 Bundle ID 提取

先保持 iPad 已解锁、越狱生效，并确认目标 App 是目标账号从 App Store 下载的。脚本会暂时复制目标 App、重启 `fairplayd` 并触发许可请求，完成后清理临时文件；iPad 需要有容纳 App 副本的剩余空间。

### 示例 A：从 ChatGPT 获取目标账号的凭据

ChatGPT 的 Bundle ID 是 `com.openai.chat`。**只有该安装确实来自你的美区账号时，才将结果记作 US。**

```cmd
docker run --rm -v "%cd%\bundle:/bundle:ro" -v "%cd%\data:/data" -v "%USERPROFILE%\.ssh\fairplay_ipad:/run/secrets/ipad_key:ro" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host %IPAD_IP% --ssh-port 22 --bundle-id com.openai.chat --output-dir /data/credential-us
```

日志应包含下面的信息（名称和许可路径以实际安装为准）：

```text
selected-app: {"name": "ChatGPT", "bundle_id": "com.openai.chat", "license": "..."}
credential ready: /data/credential-us/credential.bin
```

Windows 上的文件就是当前目录下的 `data\credential-us\credential.bin`。

### 示例 B：指定另一个账号下载的应用

例如已确认目标应用的 Bundle ID 为 `com.ss.iphone.ugc.Live.lite`，且它是另一个账号下载的：

```cmd
docker run --rm -v "%cd%\bundle:/bundle:ro" -v "%cd%\data:/data" -v "%USERPROFILE%\.ssh\fairplay_ipad:/run/secrets/ipad_key:ro" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host %IPAD_IP% --ssh-port 22 --bundle-id com.ss.iphone.ugc.Live.lite --output-dir /data/credential-account2
```

结果在 `data\credential-account2\credential.bin`。换应用时替换 `--bundle-id`，换账号时使用不同的输出目录。

**输出目录必须尚不存在**。只预先创建 `data`，不要创建其下的 `credential-us`。重复提取时可改用 `/data/credential-us-2`，保留旧文件。

指定 Bundle ID 后，找不到该应用的受支持许可就会报错，不会自动改读其他应用。若省略 `--bundle-id`，则默认选排序后第一个具有受支持许可的应用，可能读到旧账号，因此多账号时应显式指定。

## 7. 检查并导入本项目

在 CMD 查看结果大小：

```cmd
for %F in ("data\credential-us\credential.bin") do @echo %~zF bytes
```

应为 `16 bytes`。这是长度检查，不代表已验证地区或能解密所有 IPA。若把命令写进 `.bat`，需将 `%F` 和 `%~zF` 分别改为 `%%F` 和 `%%~zF`。

导入现有功能：

1. 网页右上角「解密凭证」，或 iPhone 客户端「设置 → 解密凭证」。
2. 输入易识别的名称（如 `US`、`CN`，同地区多个账号可用 `US2`），选择本次的 `credential.bin` 并添加。也可先复制并改名为 `US.bin` 后导入。
3. 给该凭据选择**实际下载目标应用的 Apple ID**。
4. 用同一账号下载的原版 IPA 进行一次解密，确认是否匹配。服务端配置详见 [server/README.md](../../server/README.md)。

无需把 SSH 密钥交给下载服务。私钥、生成的凭据和包含个人许可的文件不要上传 GitHub；本目录忽略 `data/`、`bundle/` 和生成的二进制文件，Docker 构建也只接收四个运行文件。

<a id="linux-docker"></a>

## Linux + Docker 获取步骤

使用同一套脚本和设备工具，不需要在 Linux 上安装 Xcode 或重新编译 iOS 程序。以下命令在 **Linux Bash** 中执行，每条一行；不要使用 Windows 的 `%cd%`、`%USERPROFILE%`。

### L1. 环境与网络

Linux 主机需要 Git、OpenSSH 客户端、tar、unzip 和 Docker Engine。Ubuntu/Debian 可安装基础工具：

```bash
sudo apt-get update
sudo apt-get install -y git openssh-client tar unzip
```

Docker 尚未安装时，按 [Docker Engine 官方安装说明](https://docs.docker.com/engine/install/)选择对应发行版。确认 `docker info` 能正常显示服务端信息；如果提示无权访问 Docker socket，下面的 `docker build`、`docker run` 前加 `sudo` 即可，无需把整个终端切换成 root。

Linux 主机和容器都必须能访问 iPad 的 SSH 地址。局域网内可使用 iPad 的 Wi-Fi IP；云服务器不能直接访问家里的 `192.168.x.x`，需先建立能到达 iPad 的 VPN/路由，或改在同一局域网的 Linux 电脑上运行。

iPad 需要保持越狱生效、已安装 OpenSSH、允许 root SSH 登录；目标应用必须由要提取凭据的 App Store 账号下载。应用选择与账号关系见第 1 节。

### L2. 下载脚本和设备工具

首次下载：

```bash
git clone https://github.com/blueskycrb/ipa-site-ios.git
cd ipa-site-ios/tools/credential-retrieval
```

已有仓库则更新后进入 `tools/credential-retrieval`。后面的命令均在这个目录运行。

按第 3 节在 GitHub Actions 运行 **Build credential tools**，下载 artifact `credential-tools`。将下载的 `credential-tools.zip` 放入当前目录，然后解压两层：

```bash
unzip credential-tools.zip
tar -xzf credential-tools.tar.gz
ls -l bundle
```

确认 `bundle/` 里直接包含第 3 节列出的五个文件。若已有解压好的 `bundle/`，复制到当前目录即可。

### L3. 配置 SSH 密钥登录

首次配置请按 **[越狱 iPad SSH 详细教程](SSH.md)** 操作：第三节选择 Linux Bash 命令，然后通过 mobile 登录、`sudo -i` 切换 root，并将公钥安装到 root 的目录。无需预先允许 root 密码登录。

如果已经配置成功，在当前 Linux Bash 中设置实际 IP 并验证：

```bash
IPAD_IP=192.168.1.50
ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i "$HOME/.ssh/fairplay_ipad" "root@$IPAD_IP" 'id -u'
```

应免密码直接返回 `0`。私钥保存在当前 Linux 用户的 `~/.ssh/fairplay_ipad`；新开 shell 后需要重新设置 `IPAD_IP`。失败时先按详细教程的排错章节处理，再运行 Docker。

### L4. 构建并提取

```bash
mkdir -p data
docker build -t fairplay-wifi-retriever .
docker run --rm fairplay-wifi-retriever --help
```

帮助中应包含 `--bundle-id`。保持 iPad 解锁并留有复制目标 App 所需的空间；提取会重启 `fairplayd`，并清理本次创建的临时文件。

例如读取 ChatGPT（`com.openai.chat`），以下是一整行命令：

```bash
docker run --rm --mount "type=bind,source=$(pwd)/bundle,target=/bundle,readonly" --mount "type=bind,source=$(pwd)/data,target=/data" --mount "type=bind,source=$HOME/.ssh/fairplay_ipad,target=/run/secrets/ipad_key,readonly" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host "$IPAD_IP" --ssh-port 22 --bundle-id com.openai.chat --output-dir /data/credential-us
```

仅当这个 ChatGPT 确实由美区账号下载时，才把结果标记为 US。核对日志里的 `selected-app` 是否为 `com.openai.chat`，以及最后是否出现 `credential ready: /data/credential-us/credential.bin`。

其他账号示例，读取指定应用并使用独立目录：

```bash
docker run --rm --mount "type=bind,source=$(pwd)/bundle,target=/bundle,readonly" --mount "type=bind,source=$(pwd)/data,target=/data" --mount "type=bind,source=$HOME/.ssh/fairplay_ipad,target=/run/secrets/ipad_key,readonly" -e FAIRPLAY_SSH_KEY=/run/secrets/ipad_key fairplay-wifi-retriever --bundle /bundle --ssh-host "$IPAD_IP" --ssh-port 22 --bundle-id com.ss.iphone.ugc.Live.lite --output-dir /data/credential-account2
```

`--bundle-id` 换成目标应用，`--output-dir` 换成新的目录。只需预先创建 `data/`，**不要预先创建 `data/credential-us/` 或 `data/credential-account2/`**。重复提取时可用 `/data/credential-us-2`。

### L5. 文件权限、检查与导入

结果位于当前目录的 `data/credential-us/credential.bin`。默认 rootful Docker 会以 root 身份写入，目录权限为 `700`、文件为 `600`，普通用户可能无法读取；成功后将这次输出交还给当前 Linux 用户：

```bash
sudo chown -R "$(id -u):$(id -g)" data/credential-us
stat -c '%s bytes' data/credential-us/credential.bin
```

如果使用 rootless Docker 且当前用户已经能读取文件，可跳过 `chown`。提取到其他目录时，同步替换这两条命令的路径。

应显示 `16 bytes`。然后按第 7 节从网页或客户端添加该文件，选择其实际对应的 Apple ID，并用同账号下载的原版 IPA 验证解密。16 字节和目录名都不能用来确认地区。

### Linux 常见问题

| 现象 | 排查方法 |
|---|---|
| `bind source path does not exist` | 确认当前目录、`bundle/`、`data/`、私钥路径正确；本文使用 `--mount`，缺少文件会直接报错。 |
| `permission denied` 访问 Docker socket | 使用 `sudo docker ...`，保持在原用户终端执行，让 `$HOME` 仍指向保存私钥的用户目录。 |
| 容器无法读取挂载文件，主机启用了 SELinux | 检查 SELinux 拒绝日志，按发行版配置容器 bind mount 的访问标签；不要直接给整个 `~/.ssh` 目录改标签或关闭 SELinux。 |
| 主机能 SSH，容器却连接超时 | 检查 Docker 出站路由、防火墙和 VPN 路由；在原生 Linux Docker Engine 上，可临时给提取命令添加 `--network host` 诊断桥接网络问题。 |
| 已显示成功，但普通用户打不开结果 | 按 L5 修复本次输出目录的属主，保留文件的私有权限。 |

其他许可格式、Bundle ID、账号混淆等问题见下面的通用排查表。

## 常见问题

| 现象 | 排查方法 |
|---|---|
| `invalid spec ... too many colons` | CMD 里用了 PowerShell 变量。使用本文的 `%cd%`、`%USERPROFILE%`，不要使用 `${env:USERPROFILE}`。 |
| `unrecognized arguments: --bundle-id` | 运行的是旧镜像。确认当前目录的脚本已更新，再重新 `docker build`。 |
| `bundle is missing files` | 检查 tar.gz 是否已解开，以及五个文件是否都直接位于 `bundle`。 |
| `--output-dir must name a new directory` | 换一个未存在的输出目录，保留此前结果。 |
| `Permission denied (publickey)` | 用第 4 步命令确认 root 密钥登录；确认公钥属于 root，私钥没有口令，挂载的私钥是一个真实文件。 |
| Windows 能 SSH，Docker 连接超时 | 检查 Docker/VPN/防火墙是否能访问 iPad 的局域网地址和 22 端口，确认 IP 未变化。 |
| `no supported installed App Store license found for ...` | 核对 Bundle ID 大小写，确认应用由目标账号从 App Store 安装；侧载应用或不支持的许可格式不能用于此流程。 |
| FairPlay observer/trigger 报错或超时 | 确认越狱仍生效、设备解锁、有足够空间，保存错误信息再排查；SSH 成功不等于系统版本和原生工具一定兼容。 |
| 两个账号得到同一文件 | 检查两次 `selected-app` 以及应用的实际下载账号。切换 App Store 登录不会自动替换旧 App 的许可。 |
| 能否判断 bin 是 US/CN | 不能从这 16 字节识别地区；需记录下载账号与提取来源，地区标签仅便于管理。 |

## 实现来源

原生工具来自 [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)，本流程固定使用提交 [`7f80db2ef37634073fab06b3aad1aa0cf24561a1`](https://github.com/EthanArbuckle/fairplay-decrypt/tree/7f80db2ef37634073fab06b3aad1aa0cf24561a1)。GitHub Actions 从该提交编译设备工具，不包含你的账号信息。

`retrieve.py` / `native_ssh.py` 基于该提交的 `credential-retrieval` 脚本，增加 Wi-Fi SSH、指定密钥、按 Bundle ID 精确选择应用、打印选择结果及输出长度校验。Docker 入口将只读挂载的 Windows 私钥复制到临时容器内并设为 `600`，避免 Windows 挂载权限导致 OpenSSH 拒绝读取；`--rm` 在容器退出后移除容器。

本目录作为独立工具使用，不参与现有 iOS 客户端编译和服务器启动。
