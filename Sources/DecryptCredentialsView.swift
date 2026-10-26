import SwiftUI

/// 解密凭证：fairplay-decrypt 从越狱设备导出的 16 字节 credential.bin，每个 Apple ID 一个，按地区命名（US、CN…），
/// 并对应到服务器上登录的 Apple ID —— 解密时先用下载这个 IPA 的账号对应的凭证。
struct DecryptCredentialsView: View {
    @AppStorage(Keys.decryptCredential) private var defaultCredential = "auto"
    @State private var creds: [DecryptCredential] = []
    @State private var reason: String?
    @State private var emails: [String] = []   // 服务器上登录的 Apple ID
    @State private var loaded = false
    @State private var loadError: String?
    @State private var name = ""
    @State private var picking = false
    @State private var adding = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var deleting: DecryptCredential?

    var body: some View {
        Form {
            if let reason {
                Section {
                    Text(reason).font(.caption).foregroundColor(.orange)
                }
            }

            Section {
                if !loaded {
                    HStack { ProgressView(); Text("加载中…").foregroundColor(.secondary) }
                } else if let e = loadError {
                    Text(e).font(.caption).foregroundColor(.red)
                } else if creds.isEmpty {
                    Text("还没有凭证，在下面添加").foregroundColor(.secondary)
                }
                ForEach(creds) { c in
                    credentialRow(c)
                        .swipeActions {
                            Button("删除", role: .destructive) { deleting = c }
                        }
                }
            } header: {
                Text("凭证")
            } footer: {
                Text("给每个凭证选它对应的 Apple ID（「设置 → Apple ID」里登录的账号），一个 Apple ID 只对应一个凭证。左滑删除。")
            }

            if creds.count > 1 {
                Section {
                    Picker("点「解密」时用", selection: $defaultCredential) {
                        Text("自动识别").tag("auto")
                        ForEach(creds) { c in
                            Text(c.name).tag(c.name)
                        }
                    }
                } footer: {
                    Text("自动识别：先用下载这个 IPA 的 Apple ID 对应的凭证；以前下载的、上传的文件没有账号记录，就依次试每个凭证，凭证不对时很快就失败。")
                }
            }

            Section {
                TextField("名称，例如 US、CN", text: $name)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button(adding ? "添加中…" : "选择 credential.bin 并添加") { picking = true }
                    .disabled(adding)
                if let m = message {
                    Text(m).font(.caption).foregroundColor(messageIsError ? .red : .green)
                }
            } header: {
                Text("添加凭证")
            } footer: {
                Text("凭证是 fairplay-decrypt 从越狱设备导出的 16 字节 credential.bin，每个 Apple ID 一个，只保存在你的服务器上。文件名是 US.bin、CN.bin 这样时名称可以不填，也可以一次选多个。")
            }
        }
        .navigationTitle("解密凭证")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $picking) {
            DocumentPicker { urls in Task { await add(urls) } }
                .ignoresSafeArea()
        }
        .confirmationDialog("删除这个凭证？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible,
                            presenting: deleting) { c in
            Button("删除 \(c.name)", role: .destructive) { Task { await delete(c) } }
        } message: { _ in
            Text("删除后就不能用它解密了，要用时再添加。")
        }
    }

    private func credentialRow(_ c: DecryptCredential) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.name).font(.body.bold())
            Picker("对应 Apple ID", selection: Binding(get: { selectedEmail(c) },
                                                    set: { v in Task { await link(c, v) } })) {
                Text("未对应").tag("")
                ForEach(emailOptions(c), id: \.self) { e in
                    Text(emails.contains(e) ? e : "\(e)（未登录）").tag(e)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// 已登录的 Apple ID，加上这个凭证已经对应、但现在没登录的那个
    private func emailOptions(_ c: DecryptCredential) -> [String] {
        guard let e = c.email, !emails.contains(where: { same($0, e) }) else { return emails }
        return emails + [e]
    }

    private func selectedEmail(_ c: DecryptCredential) -> String {
        guard let e = c.email else { return "" }
        return emails.first(where: { same($0, e) }) ?? e
    }

    private func same(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    private func say(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private func load() async {
        do {
            let r = try await API.decryptCredentials()
            creds = r.credentials
            reason = r.reason
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        emails = ((try? await API.status())?.accounts ?? []).map(\.email)
        loaded = true
    }

    private func add(_ urls: [URL]) async {
        let typed = name.trimmingCharacters(in: .whitespaces)
        if urls.count > 1 && !typed.isEmpty {
            say("一次选多个文件时名称要留空，每个凭证用自己的文件名（US.bin → US）", error: true)
            return
        }
        adding = true
        var added: [String] = []
        for url in urls {
            // 选择器是复制模式，文件已经在 App 的临时目录里，读完就删
            let raw = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            let stem = url.deletingPathExtension().lastPathComponent
            let n = typed.isEmpty && stem.lowercased() != "credential" ? stem : typed
            guard let data = raw, data.count == 16 else {
                say("\(url.lastPathComponent) 不是 16 字节的凭证文件，可能选错了", error: true)
                break
            }
            guard !n.isEmpty else {
                say("文件名是 credential.bin，请先填名称（例如 US、CN）再选", error: true)
                break
            }
            do {
                creds = try await API.addDecryptCredential(name: n, data: data)
                added.append(n.uppercased())
            } catch {
                say("\(url.lastPathComponent)：\(error.localizedDescription)", error: true)
                break
            }
        }
        if !added.isEmpty {
            name = ""
            say("已添加 \(added.joined(separator: "、"))，在上面选它对应的 Apple ID", error: false)
        }
        adding = false
    }

    private func link(_ c: DecryptCredential, _ email: String) async {
        do {
            creds = try await API.linkDecryptCredential(c.name, email: email)
            say(email.isEmpty ? "\(c.name) 已取消对应" : "\(c.name) 已对应 \(email)", error: false)
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func delete(_ c: DecryptCredential) async {
        do {
            creds = try await API.deleteDecryptCredential(c.name)
            if defaultCredential == c.name { defaultCredential = "auto" }
        } catch {
            say(error.localizedDescription, error: true)
        }
    }
}
