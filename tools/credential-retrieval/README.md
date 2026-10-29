# 获取 credential.bin：Windows + Docker + 越狱 iPad

本教程把已经走通的获取流程整理在一起：用 GitHub Actions 编译设备工具，在 Windows 的 Docker 容器里通过 Wi-Fi SSH 操作越狱 iPad，按指定应用的 Bundle ID 获取 `credential.bin`，最后导入本项目的解密凭证管理。

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

下例 `192.168.1.50` 只是示例地址，换成自己的 iPad IP。`set` 变量只对当前 CMD 窗口生效，新开窗口要重新设置。

```cmd
set "IPAD_IP=192.168.1.50"
```

如果已经有 `%USERPROFILE%\.ssh\fairplay_ipad`，且它能免密码以 root 登录 iPad，跳过生成与安装公钥，直接验证。不要覆盖已有密钥。

首次生成专用密钥：

```cmd
if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
ssh-keygen -t ed25519 -f "%USERPROFILE%\.ssh\fairplay_ipad"
```

当前 Docker 入口不接入 SSH agent，需使用无口令的专用密钥：生成时在 passphrase 提示处直接回车两次。私钥保存在 Windows 本地；只有 `.pub` 公钥安装到 iPad。

先用你已设置的 root SSH 密码登录确认连接；首次连接核对主机指纹后接受：

```cmd
ssh root@%IPAD_IP%
```

出现 iPad 的 root 提示符后，输入 `exit` 回到 Windows CMD，再安装公钥（此命令会要求 root 密码）：

```cmd
type "%USERPROFILE%\.ssh\fairplay_ipad.pub" | ssh root@%IPAD_IP% "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
```

如果 root 密码登录尚未配置，请先在越狱环境中设置 root 密码和 SSH 登录方式；只能够以 mobile 登录还不满足这个脚本的条件。

验证密钥登录（不应再要求密码）：

```cmd
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "%USERPROFILE%\.ssh\fairplay_ipad" root@%IPAD_IP% "id -u"
```

返回 `0` 才说明以 root 登录成功。

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
