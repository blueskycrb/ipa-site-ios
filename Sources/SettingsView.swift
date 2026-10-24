import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage(Keys.server) private var server = Keys.defaultServer
    @AppStorage(Keys.sitePassword) private var sitePassword = ""
    @AppStorage(Keys.autoPurchase) private var autoPurchase = true
    @AppStorage(Keys.country) private var country = "cn"
    @AppStorage(Keys.installMode) private var installMode = "system"
    @ObservedObject private var updater = Updater.shared
    @Environment(\.openURL) private var openURL
    @State private var status: ServerStatus?
    @State private var statusError: String?
    @State private var checking = false
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needCode = false
    @State private var loginMessage: String?
    @State private var loggingIn = false
    @State private var adding = false
    @State private var removing: AccountEntry?
    @State private var copiedConfig = false

    private var accounts: [AccountEntry] { status?.accounts ?? [] }

    /// 需要显示登录表单：正在添加账号，或者当前账号没登录 / 登录失效
    private var showLoginForm: Bool { adding || (status != nil && status?.account == nil) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器地址，例如 http://192.168.1.10:8686", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("网站访问密码（没设置就留空）", text: $sitePassword)
                    Button(checking ? "连接中…" : "测试连接") { Task { await check() } }
                        .disabled(checking)
                    if let s = status {
                        Label("已连接 · ipatool \(s.version ?? "?")", systemImage: "checkmark.circle")
                            .foregroundColor(.green)
                    }
                    if let e = statusError {
                        Text(e).font(.caption).foregroundColor(.red)
                    }
                    Button("复制配置给分享扩展") {
                        // 只留在本机、5 分钟后自动清掉，避免密码通过「通用剪贴板」同步到别的设备
                        UIPasteboard.general.setItems(
                            [["public.utf8-plain-text": ShareConfig.encode(server: server, password: sitePassword)]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                        copiedConfig = true
                    }
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
                    if copiedConfig {
                        Text("已复制（5 分钟内有效）。在别的 App 里分享 IPA 或证书 → 选「IPA 下载」→ 点「从剪贴板读取」→「保存」。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    Text("服务器")
                } footer: {
                    Text("分享扩展（在微信、Safari、「文件」里分享到「IPA 下载」）和 App 的设置不互通，第一次使用要把服务器配置复制过去一次。")
                }

                Section {
                    // 账号列表：点一下切换，左滑退出
                    ForEach(accounts) { a in
                        Button {
                            Task { await switchTo(a) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.email).foregroundColor(.primary)
                                    if let n = a.name, !n.trimmingCharacters(in: .whitespaces).isEmpty {
                                        Text(n).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if a.current {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                        .swipeActions {
                            Button("退出", role: .destructive) { removing = a }
                        }
                    }
                    if status?.accounts == nil, let acc = status?.account {
                        // 旧版服务器只支持一个账号
                        LabeledContent("已登录", value: acc.email ?? "")
                        Button("退出登录", role: .destructive) { Task { await logout(nil) } }
                    }
                    if let cur = accounts.first(where: { $0.current }), status?.account == nil {
                        Text("\(cur.email) 的登录已失效，请在下面重新登录").font(.caption).foregroundColor(.orange)
                    }
                    if showLoginForm {
                        TextField("Apple ID 邮箱", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                        SecureField("Apple ID 密码", text: $password)
                            .textContentType(.password)
                        if needCode {
                            TextField("6 位验证码", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                        }
                        Button(loginButtonTitle) { Task { await login() } }
                            .disabled(loggingIn || email.isEmpty || password.isEmpty)
                        if adding && !accounts.isEmpty {
                            Button("取消添加") {
                                adding = false
                                resetLoginForm()
                            }
                            .foregroundColor(.secondary)
                        }
                    } else if status?.accounts != nil {
                        Button("添加 Apple ID") {
                            resetLoginForm()
                            adding = true
                        }
                    }
                    if let m = loginMessage {
                        Text(m).font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Apple ID")
                } footer: {
                    Text("点账号切换，左滑退出。搜索、下载、查看历史版本都用当前账号（打勾的）。同一个 Apple ID 再登录一次就是重新登录。账号密码只发给你的服务器。")
                }

                Section("下载选项") {
                    Toggle("没有许可时自动获取（仅限免费 App）", isOn: $autoPurchase)
                    TextField("商店地区（如 cn、us）", text: $country)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("安装方式", selection: $installMode) {
                        Text("系统安装").tag("system")
                        Text("TrollStore").tag("trollstore")
                    }
                    .pickerStyle(.segmented)
                    if installMode == "system" {
                        if status?.install?.enabled == true {
                            LabeledContent("已启用", value: status?.install?.publicURL ?? "")
                        } else {
                            Text("未启用：需要先给网站配好 https 地址（例如 Lucky 反代 + 证书），再在服务器 .env 里设置 IPA_PUBLIC_URL。")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("安装")
                } footer: {
                    Text(installMode == "trollstore"
                         ? "可选：点「TrollStore 安装」会把下载链接交给 TrollStore（需 2.0 以上），任何 IPA 都能装，包括 Alist 里的改版 IPA。"
                         : "系统安装（默认）：用 iOS 官方的安装方式，只对本站从 App Store 下载的 IPA 有效，装好后打开时可能需要手机登录同一个 Apple ID。点「安装」后回到主屏幕查看进度。")
                }

                Section {
                    NavigationLink("证书管理（导入 / 删除）") { CertsView() }
                    if !API.base.isEmpty, let url = URL(string: API.base + "/sign") {
                        Link("打开网页版签名页", destination: url)
                    }
                } header: {
                    Text("证书签名")
                } footer: {
                    Text("在「Alist」页点「证书签名」，服务器用你上传的 p12 证书重签后自动弹出安装。适合改版 / 砸壳的 IPA；App Store 原版 IPA 是加密的，重签后会闪退，请用系统安装。")
                }

                Section {
                    LabeledContent("当前版本", value: "\(updater.currentVersion)（\(updater.currentBuild)）")
                    if let r = updater.latest {
                        if updater.hasUpdate {
                            LabeledContent("最新版本", value: "\(r.version)（\(r.build)）")
                            if !r.notes.isEmpty {
                                Text(r.notes).font(.caption).foregroundColor(.secondary).lineLimit(6)
                            }
                            Button("用 TrollStore 安装最新版") {
                                if let url = updater.trollStoreURL { openURL(url) }
                            }
                            Link("在浏览器打开下载页", destination: r.pageURL)
                        } else {
                            Text("已是最新版本").foregroundColor(.green)
                        }
                    }
                    Button(updater.checking ? "检查中…" : "检查更新") {
                        Task { await updater.check() }
                    }
                    .disabled(updater.checking)
                    if let e = updater.error {
                        Text(e).font(.caption).foregroundColor(.red)
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("新版本从 GitHub（\(Updater.repo)）的 Release 下载，交给 TrollStore 安装，设置和已存的文件都会保留。")
                }

                if let a = status?.alist, a.enabled {
                    Section("Alist") {
                        LabeledContent("上传目录", value: a.dir ?? "/")
                        LabeledContent("下载完自动上传", value: a.auto == true ? "是" : "否")
                    }
                }
            }
            .navigationTitle("设置")
            .task { await check() }
            .confirmationDialog("退出这个 Apple ID？",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible,
                                presenting: removing) { a in
                Button("退出并移除 \(a.email)", role: .destructive) { Task { await logout(a.id) } }
            } message: { _ in
                Text("服务器上这个账号的登录会被清除，其他账号不受影响。")
            }
        }
    }

    private var loginButtonTitle: String {
        if loggingIn { return needCode ? "验证中…" : "登录中…首次可能要等几分钟" }
        return needCode ? "提交验证码" : "登录"
    }

    private func check() async {
        checking = true
        do {
            status = try await API.status()
            statusError = nil
            // 当前账号登录失效时，预先填好它的邮箱，方便重新登录
            if status?.account == nil, email.isEmpty, let cur = accounts.first(where: { $0.current }) {
                email = cur.email
            }
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
        checking = false
    }

    private func resetLoginForm() {
        email = ""
        password = ""
        code = ""
        needCode = false
        loginMessage = nil
    }

    private func switchTo(_ a: AccountEntry) async {
        guard !a.current else { return }
        do {
            try await API.switchAccount(a.id)
            loginMessage = "已切换到 \(a.email)，之后的搜索和下载都用这个账号"
        } catch {
            loginMessage = error.localizedDescription
        }
        await check()
    }

    private func login() async {
        loggingIn = true
        do {
            let r = try await API.login(email: email, password: password, code: needCode ? code : "")
            if r.ok {
                password = ""
                code = ""
                needCode = false
                adding = false
                loginMessage = "登录成功，已切换到 \(r.account?.email ?? email)"
                email = ""
                await check()
            } else {
                loginMessage = r.error
                if r.needCode == true { needCode = true }
                if r.restart == true {
                    code = ""
                    needCode = false
                }
            }
        } catch {
            loginMessage = error.localizedDescription
        }
        loggingIn = false
    }

    private func logout(_ id: String?) async {
        do {
            try await API.logout(id)
            loginMessage = "已退出"
        } catch {
            loginMessage = error.localizedDescription
        }
        await check()
    }
}
