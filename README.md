# IPA 下载 · iPhone 客户端

连接内网服务器上的 [ipa-site](../ipa-site)（基于 ipatool 的 IPA 下载站）的原生 SwiftUI 客户端。
App 本身不运行 ipatool：搜索、下载、上传 Alist 都由服务器完成，App 负责操作和把 IPA 存到手机。

## 功能

- **搜索**：按平台搜索 App，下载最新版或从历史版本里挑一个下载（下载到服务器）
- **任务**：查看服务器上的下载进度、速度、用时
- **文件**：服务器上的 IPA 可以「存到手机」「传到 Alist」或删除；存到手机的 IPA 在「文件」App →「我的 iPhone」→「IPA 下载」里，也能通过分享发给 TrollStore 等工具
- **设置**：服务器地址、网站访问密码（如果设置了）、登录 Apple ID（支持双重认证）、自动获取免费 App 许可

## 获取 IPA

每次推送到 `main`，GitHub Actions 会在 macOS 上编译出**未签名**的 IPA：

1. 打开仓库的 **Actions** 页面，点最新一次成功的 “Build unsigned IPA”
2. 在页面底部 **Artifacts** 里下载 `IPASite-unsigned`（是个 zip，里面是 `IPASite-unsigned.ipa`）

也可以在 Actions 页面点 **Run workflow** 手动编译。

## 安装到 iPhone

未签名的 IPA 需要用你自己的 Apple ID 签名后安装，任选一种：

- **Sideloadly**（Windows / Mac）：手机用数据线连电脑，把 IPA 拖进 Sideloadly，填 Apple ID，点 Start。免费 Apple ID 签名 **7 天有效**，到期重新签一次即可（数据不会丢）。
- **AltStore**：装好 AltServer 后可以在手机上自动续签。
- **TrollStore**（支持的 iOS 版本才能用）：直接安装，永久有效。

首次打开 App：在「设置」里确认服务器地址（默认 `http://192.168.10.136:8686`），iOS 会询问是否允许访问本地网络，选「允许」。

## 本地开发

需要 macOS + Xcode 15 以上：

```bash
brew install xcodegen
xcodegen generate
open IPASite.xcodeproj
```
