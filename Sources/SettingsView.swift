import SwiftUI

struct SettingsView: View {
    @AppStorage(Keys.server) private var server = Keys.defaultServer
    @AppStorage(Keys.sitePassword) private var sitePassword = ""
    @AppStorage(Keys.autoPurchase) private var autoPurchase = true
    @AppStorage(Keys.country) private var country = "cn"
    @AppStorage(Keys.installMode) private var installMode = "trollstore"
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如 http://192.168.10.136:8686", text: $server)
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
                } header: {
                    Text("服务器")
                }

                Section {
                    if let acc = status?.account {
                        LabeledContent("已登录", value: acc.email ?? "")
                        Button("退出登录", role: .destructive) { Task { await logout() } }
                    } else {
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
                        if let m = loginMessage {
                            Text(m).font(.caption).foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Apple ID")
                } footer: {
                    Text("账号密码只发给你的服务器，由服务器上的 ipatool 登录 Apple。")
                }

                Section("下载选项") {
                    Toggle("没有许可时自动获取（仅限免费 App）", isOn: $autoPurchase)
                    TextField("商店地区（如 cn、us）", text: $country)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("安装方式", selection: $installMode) {
                        Text("TrollStore").tag("trollstore")
                        Text("系统安装").tag("system")
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
                         ? "点「TrollStore 安装」会把下载链接交给 TrollStore（需 2.0 以上），它自己下载并安装，任何 IPA 都行，不用先存到手机。"
                         : "系统安装只对本站从 App Store 下载的 IPA 有效，装好后打开时可能需要手机登录同一个 Apple ID。点「安装」后回到主屏幕查看进度。")
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
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
        checking = false
    }

    private func login() async {
        loggingIn = true
        do {
            let r = try await API.login(email: email, password: password, code: needCode ? code : "")
            if r.ok {
                password = ""
                code = ""
                needCode = false
                loginMessage = "登录成功"
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

    private func logout() async {
        do {
            try await API.logout()
        } catch {
            loginMessage = error.localizedDescription
        }
        await check()
    }
}
