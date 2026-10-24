# IPA 下载

自己搭的 App Store IPA 下载服务，分两部分：

| 部分 | 目录 | 说明 |
|---|---|---|
| **下载服务（服务端）** | [`server/`](server/) | 基于 [ipatool](https://github.com/majd/ipatool)，Docker 部署在自己的服务器上：登录 Apple ID、搜索、下载 IPA、上传 Alist、生成安装链接，自带网页 |
| **iPhone 客户端** | 仓库根目录 | SwiftUI App，连接上面的服务端使用；GitHub Actions 自动编译未签名 IPA |

```
iPhone 客户端 / 网页  ──HTTP(S)──▶  下载服务（Docker）  ──ipatool──▶  App Store
                                         │
                                         └──▶  Alist（可选，网盘直链下载 / 安装）
```

---

## 一、部署下载服务（Docker）

```bash
git clone https://github.com/blueskycrb/ipa-site-ios.git
cd ipa-site-ios/server
cp .env.example .env      # 至少填 IPA_PASSWORD，其他按需
vi .env
docker compose up -d --build
```

浏览器打开 `http://服务器IP:8686`，登录 Apple ID 即可使用。

**所有配置项（`.env`）的说明、外网访问、HTTPS、Alist、常见问题，见 [server/README.md](server/README.md)。** 配置模板 [server/.env.example](server/.env.example) 里每一项也都有注释。

常用的几项：

| 变量 | 作用 |
|---|---|
| `IPA_PASSWORD` | 网站访问密码（对外开放时必填） |
| `IPA_COUNTRY` | Apple ID 所在地区，如 `cn` |
| `ALIST_URL` / `ALIST_USERNAME` / `ALIST_PASSWORD` / `ALIST_DIR` | 上传到 Alist |
| `ALIST_AUTO_UPLOAD` | `1` 下载完自动上传，`0` 手动 |
| `IPA_PUBLIC_URL` | https 地址，iPhone「系统安装」需要 |

改完 `.env` 要运行 `docker compose up -d` 才生效。

---

## 二、iPhone 客户端

### 功能

- **搜索**：按平台搜索 App，下载最新版或从历史版本里挑一个（下载到服务器）
- **任务**：服务器上的下载进度、速度、用时；完成后可直接安装
- **文件**：服务器上的 IPA 可以安装、存到手机（从服务器或 Alist 网盘直链）、传到 Alist、删除；证书签名过的 App 可以直接安装，证书过期后换证书重签；手机里的 IPA（「文件」App 选择，或从微信、Safari「用其他应用打开」）可以导入后证书签名安装
- **Alist**：浏览 Alist 上传目录，用网盘直链存到手机或安装，不受家里上行带宽限制；改版 IPA 可以用自己的证书签名后安装
- **分享到「IPA 下载」**：在微信、Safari、「文件」等 App 里分享 IPA → 选「IPA 下载」，直接传到服务器并用证书签名（签好后在「文件」页安装）；分享证书 zip / p12 / 描述文件则直接导入证书。第一次用要在「设置 → 服务器」点「复制配置给分享扩展」
- **设置**：服务器地址、网站访问密码、多个 Apple ID 登录和切换（支持双重认证）、安装方式（系统安装 / TrollStore）、证书管理（从「文件」选证书 zip 导入、删除过期证书）、检查更新

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
