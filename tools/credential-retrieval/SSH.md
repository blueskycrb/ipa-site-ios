# 越狱 iPad 的 SSH 配置详解（Dopamine）

目标：让电脑用专用 SSH 密钥以 **root** 身份连接 iPad，最后运行 `id -u` 返回 `0`，而且不需要输入密码。完成后再回到 [获取 credential.bin 教程](README.md)运行 Docker。

适用场景是 Dopamine 越狱的 iPad，例如本流程使用的 iPadOS 16.5。不同 OpenSSH 软件包的默认设置可能不同，按每一步的实际结果判断。

## 一、先分清账号、密码和命令位置

| 名称 | 用途 |
|---|---|
| Apple ID / App Store 账号 | 下载应用、决定需要哪一个 FairPlay 凭据，不用于 SSH 登录。 |
| `mobile` | iPad 上的普通系统用户，Dopamine 环境通常先用它登录，再通过 `sudo` 管理系统。 |
| `root` | iPad 的管理员用户，本提取脚本要求用它连接。 |
| mobile 的终端密码 | 通常是配置 Dopamine 时设置的终端密码；不是 iPad 锁屏密码，也不是 Apple ID 密码。 |
| `fairplay_ipad` | 留在电脑上的 SSH 私钥，Docker 会读取它。不要把它粘贴到 iPad 或发到 GitHub。 |
| `fairplay_ipad.pub` | 与私钥配对的公钥，需要加入 iPad 的 root 用户的 `authorized_keys`。 |

后文会明确标注命令在哪里执行。**不要复制命令提示符本身**：

| 看到的提示符示例 | 当前在哪里 |
|---|---|
| `C:\Users\你的用户名>` | Windows CMD，支持 `%USERPROFILE%`。 |
| `PS C:\Users\你的用户名>` | Windows PowerShell；本文 Windows 命令请改用 CMD。 |
| `user@linux:~$` | Linux 电脑的 Bash。 |
| `iPad:~ mobile$` | 已连接到 iPad，以 mobile 身份操作。 |
| `iPad:~ root#` | 已连接到 iPad，以 root 身份操作。实际设备名和提示符样式可以不同。 |

路线是：**iPad 启用 SSH → 电脑生成密钥 → mobile 登录 → sudo 切到 root → 安装公钥 → 电脑验证 root 密钥登录**。这条路线不要求先开放 root 密码登录。

## 二、在 iPad 上准备

1. 打开 Dopamine，确认当前已越狱。重启 iPad 后通常需要重新启用越狱；只看到 Dopamine 图标不代表越狱当前生效。
2. 打开 Sileo（或当前使用的越狱包管理器），搜索并安装 **OpenSSH**。确认安装的是包含 SSH 服务端的包；只有 OpenSSH Client 客户端不能让电脑连进来。按包管理器提示完成安装。
3. 确认知道 mobile 的终端密码。如果忘记，使用当前 Dopamine 版本提供的终端密码设置/重置功能；不同版本入口名称可能不同。不要反复猜测 `alpine`，也不要把 Apple ID 密码填进去。
4. 打开 iPad「设置 → Wi-Fi → 当前网络右侧的 ⓘ」，记下 **IP 地址**。例如 `192.168.1.50`。不要抄成路由器地址或 Wi-Fi MAC 地址。
5. 电脑和 iPad 连接到能互通的局域网。访客 Wi-Fi、AP 隔离、部分 VPN 会阻止设备互访。配置和提取期间保持 iPad 解锁。

本教程走 Wi-Fi，不需要插 USB，也不需要在电脑安装 iTunes。若使用云端 Linux，必须先有到 iPad 所在网络的路由/VPN；云服务器不能直接访问家里的私有 IP。

## 三、在电脑上生成专用密钥

Windows 和 Linux **二选一**。每台电脑有自己的私钥；以后在哪台机器运行 Docker，就要在那里准备可用的密钥。

### Windows：CMD

按 `Win + R`，输入 `cmd`，回车。在新窗口检查 SSH：

```cmd
ssh -V
```

如果提示不是内部或外部命令，在 Windows「设置 → 可选功能」中添加 **OpenSSH 客户端**，完成后重新打开 CMD。Windows 不需要安装 OpenSSH 服务端。

设置 iPad 地址，以下示例必须替换为你自己的 IP：

```cmd
set "IPAD_IP=192.168.1.50"
```

查看是否已有密钥：

```cmd
dir "%USERPROFILE%\.ssh\fairplay_ipad*"
```

若已存在 `fairplay_ipad` 和 `fairplay_ipad.pub` 且此前配置可用，保留它们，跳过生成。首次没有文件时执行：

```cmd
if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
ssh-keygen -t ed25519 -f "%USERPROFILE%\.ssh\fairplay_ipad"
```

出现 `Enter passphrase` 时直接回车，`Enter same passphrase again` 再回车。当前 Docker 入口不支持交互式私钥口令或 SSH agent，因此这里使用无口令的专用密钥。如果提示文件已存在并询问是否覆盖，输入 `n`，不要覆盖已有密钥。

显示公钥：

```cmd
type "%USERPROFILE%\.ssh\fairplay_ipad.pub"
```

复制整行 `ssh-ed25519 AAAA...`，包含密钥类型和完整公钥字符。屏幕上自动折行不代表公钥分成多行。**不要读取或复制不带 `.pub` 的私钥文件。**

保留这个窗口，下一步连接 iPad。IP 变量只在当前窗口有效，新开 CMD 需重新运行 `set`。

### Linux：Bash

先确认安装了 OpenSSH 客户端，Ubuntu/Debian 可用 `sudo apt-get install openssh-client`。然后执行：

```bash
IPAD_IP=192.168.1.50
ls -l "$HOME/.ssh/fairplay_ipad" "$HOME/.ssh/fairplay_ipad.pub"
```

如果文件已存在且可用，跳过生成；如果不存在：

```bash
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$HOME/.ssh/fairplay_ipad"
chmod 600 "$HOME/.ssh/fairplay_ipad"
```

在两次 passphrase 提示处直接回车；已有文件不要覆盖。显示并复制完整的一行公钥：

```bash
cat "$HOME/.ssh/fairplay_ipad.pub"
```

`IPAD_IP` 只在当前 shell 中有效，新开终端需重新设置。

## 四、从电脑登录 iPad，再切换到 root

### 4.1 在电脑上发起连接

Windows CMD：

```cmd
ssh mobile@%IPAD_IP%
```

Linux Bash：

```bash
ssh "mobile@$IPAD_IP"
```

第一次连接可能询问 `Are you sure you want to continue connecting (yes/no/[fingerprint])?`。确认 IP 是自己的 iPad，并核对主机指纹后输入 `yes`。如需独立查看指纹，可在 iPad 的本地终端（例如已安装的 NewTerm）用 root 权限运行 `ssh-keygen -lf` 读取 SSH 主机公钥；Dopamine rootless 环境的公钥通常在 `/var/jb/etc/ssh/ssh_host_ed25519_key.pub`，具体以安装的软件包为准。主机指纹和上一节生成的用户公钥是不同的东西。

接下来 `mobile@... password:` 要输入 **mobile 的终端密码**。输入时屏幕不会显示字符或星号，这是正常现象；输入完成按回车。

出现 iPad 的命令提示符后，下面命令已经是在 iPad 上运行了，不要再执行 Windows 的 `type`、`dir` 或 Docker 命令。

### 4.2 在 iPad 的 SSH 会话中获取 root shell

```sh
whoami
sudo -i
```

`whoami` 应显示 `mobile`；`sudo -i` 若要求密码，输入 **mobile 的密码**。切换后检查：

```sh
id -u
echo "$HOME"
```

`id -u` 必须返回 **`0`**。`$HOME` 通常是 `/var/root`；使用下面的 `$HOME` 命令即可，不必自行改成固定路径。

如果 `sudo` 不存在、密码不正确或提示 mobile 没有 sudo 权限，先解决越狱环境的管理员访问，再继续。可以在 iPad 的本地终端完成同样操作；如果已经知道 root 密码且允许 root 登录，也可直接以 root 登录。不要在仍为 mobile 的会话里安装下面的公钥，否则会写进错误用户的目录。

**已经能用 root 密钥登录的用户可以直接跳到第六节验证，不用重配密码或重复生成密钥。**

## 五、在 iPad 的 root 会话中安装公钥

以下命令在上一步 `id -u` 返回 `0` 的会话中执行：

```sh
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
printf '\n' >> "$HOME/.ssh/authorized_keys"
cat >> "$HOME/.ssh/authorized_keys"
```

最后一条执行后，终端会等待输入，**不是卡住了**。按下面的顺序操作：

1. 粘贴第三节复制的公钥，内容以 `ssh-ed25519 ` 开头。不要粘贴 CMD 提示符、引号或代码块符号。
2. 按一次 **Enter**，确保公钥后面有换行。
3. 在空行处按一次 **Ctrl + D**，结束输入，回到 iPad 命令提示符。这里不是 Ctrl + C。

然后执行：

```sh
chmod 600 "$HOME/.ssh/authorized_keys"
chown "$(id -u):$(id -g)" "$HOME/.ssh" "$HOME/.ssh/authorized_keys"
ls -ld "$HOME/.ssh"
ls -l "$HOME/.ssh/authorized_keys"
```

目录权限应类似 `drwx------`，文件应类似 `-rw-------`，属主是 root。上面的 `>>` 是追加，保留已有公钥；不要改成 `>` 覆盖已有内容。添加 `authorized_keys` 通常立即生效，无需重启 iPad。

**先保留这个已经登录的会话**，在电脑另开一个终端验证。这样即使新连接失败，仍能回来修复。

## 六、在电脑新窗口验证 root 免密码登录

### Windows CMD

新窗口需要重新设置 IP：

```cmd
set "IPAD_IP=192.168.1.50"
ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i "%USERPROFILE%\.ssh\fairplay_ipad" root@%IPAD_IP% "id -u"
```

### Linux Bash

```bash
IPAD_IP=192.168.1.50
ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i "$HOME/.ssh/fairplay_ipad" "root@$IPAD_IP" 'id -u'
```

**成功标准：直接输出 `0` 并回到电脑提示符，全程不要求密码。** `BatchMode=yes` 会禁止密码交互，因此这一步通过才符合 Docker 脚本的连接方式。

如果只是 `ssh mobile@...` 成功，或 root 连接仍需要输入密码，都不算完成。

成功后，原来的 mobile → `sudo -i` 会话可以输入两次 `exit`：第一次退出 root shell，第二次退出 mobile 的 SSH 连接，回到电脑。若最初就是直接 root 登录，只需一次 `exit`。随后回到 [Windows / Linux Docker 提取教程](README.md)，从构建镜像步骤继续。

## 七、可选：已经能用 root 密码登录时的快捷安装

如果你的 iPad **原本就允许 root 密码登录**，可以跳过第四、五节的手工粘贴，用以下命令安装公钥。不要为了使用这个快捷方式专门开放 root 密码登录。

Windows CMD：

```cmd
type "%USERPROFILE%\.ssh\fairplay_ipad.pub" | ssh root@%IPAD_IP% "umask 077; mkdir -p ~/.ssh; printf '\n' >> ~/.ssh/authorized_keys; cat >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
```

Linux Bash：

```bash
ssh-copy-id -i "$HOME/.ssh/fairplay_ipad.pub" "root@$IPAD_IP"
```

这里要求的是 **root 密码**，不一定与 mobile 密码相同。完成后仍需按第六节验证。

## 八、按错误定位问题

| 错误或现象 | 含义与下一步 |
|---|---|
| Windows 找不到 `ssh` / `ssh-keygen` | 安装 Windows OpenSSH 客户端，然后重开 CMD。 |
| `Connection timed out` / `No route to host` | 还没到账号验证阶段。核对 iPad 当前 IP、Wi-Fi 隔离、VPN/路由、防火墙、越狱是否生效。 |
| `Connection refused` | 目标地址可达但端口没有接受 SSH；检查 OpenSSH 服务端是否已安装并启动，以及是否用了非默认端口。 |
| 密码输入时没有任何显示 | 正常；输入终端密码后按回车，不要当成键盘失效。 |
| mobile 密码被拒绝 | 检查是否错用 Apple ID 或锁屏密码；使用/重置 mobile 的终端密码。 |
| `sudo: ...` 报错 | 尚未获得 root 权限。先修复 sudo/密码或使用已有的管理员访问方式，不要继续往 mobile 的目录里装公钥。 |
| `Permission denied (publickey)` | 网络已连通，但密钥认证失败。核对私钥与公钥是否配对、公钥是否完整且为单行、是否安装到了 root 的 HOME、目录/文件权限和属主。 |
| `Enter passphrase for key ...` | 私钥有口令。当前 Docker 不支持此交互；另建无口令专用密钥并安装其公钥，或在明确知道旧口令时自行调整。不要覆盖正在使用的密钥。 |
| `Identity file ... not accessible` | 私钥路径不对或文件不存在。检查 `.pub` 是公钥，`-i` 指定的是不带 `.pub` 的私钥。 |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | 主机指纹与记录不同，可能是重装 SSH 或 IP 被其他设备占用。先确认设备和新指纹；确认后再移除该 IP 的旧记录，不要直接关闭主机密钥检查。 |
| 电脑免密成功，Docker 失败 | 检查挂载的私钥路径、容器到 iPad 的网络；参照主教程的 Docker 排查。电脑和容器有各自的 SSH 主机记录。 |

### 检查端口是否可达

Windows CMD 可调用 PowerShell 的网络检查，先确保 `%IPAD_IP%` 已设置：

```cmd
powershell -NoProfile -Command "Test-NetConnection -ComputerName '%IPAD_IP%' -Port 22"
```

`TcpTestSucceeded : True` 只表示 TCP 22 可达，不代表已成功登录。Linux 可直接用 `ssh -o ConnectTimeout=8 "mobile@$IPAD_IP"` 检查连接阶段。

### root 密钥仍被拒绝时

先在保留的 iPad root 会话中重新执行第五节的权限检查。确认 root 的 SSH 策略允许公钥登录：`PubkeyAuthentication yes`，且 `PermitRootLogin` 不是 `no`。`PermitRootLogin prohibit-password`（旧名 `without-password`）允许 root 公钥登录，可以用于本流程，无需改成密码登录。

Dopamine rootless 常见的 sshd 程序路径是 `/var/jb/usr/sbin/sshd`，配置通常在 `/var/jb/etc/ssh/sshd_config`，但应以实际软件包和服务启动参数为准。若这个程序确实存在，可在 iPad root 会话查看配置解析结果：

```sh
/var/jb/usr/sbin/sshd -T | grep -E '^(port|pubkeyauthentication|permitrootlogin|authorizedkeysfile) '
```

如果存在按用户/地址生效的 `Match` 规则或服务使用其他配置文件，单独 `-T` 的输出不一定代表这次连接的最终配置。先确认实际规则，保留当前会话，备份配置；修改后用相同 sshd 程序和配置参数运行 `-t` 检查语法，再按所安装服务的方式重载。不要直接套用网上的路径或重启命令。

需要更多连接诊断时，在第六节的验证命令里加 `-v`。记录错误类型即可；不要分享私钥内容或账号密码。

### 已确认设备身份后清理旧主机记录

只有确认 IP 和新指纹属于自己的 iPad 后，才在电脑执行。Windows CMD：

```cmd
ssh-keygen -R "%IPAD_IP%"
```

Linux Bash：

```bash
ssh-keygen -R "$IPAD_IP"
```

然后先普通 SSH 连接、核对并接受新指纹，再运行第六节的 BatchMode 验证。本文使用默认 22 端口；若你自己改过端口，所有 SSH 命令都需指定 `-p`，提取命令的 `--ssh-port` 也要同步修改。
