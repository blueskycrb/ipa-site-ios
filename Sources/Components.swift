import SwiftUI

struct AppIconView: View {
    let url: String?
    var size: CGFloat = 48

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { image in
            image.resizable()
        } placeholder: {
            Color.secondary.opacity(0.15)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// 安装按钮。按「设置」里的安装方式：
/// - TrollStore：打开 apple-magnifier://install?url=…，TrollStore 自己下载并安装，任何 IPA 都行
/// - 系统安装：打开 itms-services:// 链接，只对本站从 App Store 下载的 IPA 有效（systemAvailable）
struct InstallButton: View {
    let name: String
    let systemAvailable: Bool
    @Binding var toast: String?
    @AppStorage(Keys.installMode) private var mode = "system"
    @Environment(\.openURL) private var openURL
    @State private var working = false

    private var useTrollStore: Bool {
        mode == "trollstore" && [".ipa", ".tipa"].contains { name.lowercased().hasSuffix($0) }
    }

    var body: some View {
        if useTrollStore || systemAvailable {
            Button(working ? "准备中…" : (useTrollStore ? "TrollStore 安装" : "安装")) {
                Task { await install() }
            }
            .buttonStyle(.bordered)
            .disabled(working)
        }
    }

    private func install() async {
        working = true
        do {
            let (url, source) = try await API.installURL(name, mode: useTrollStore ? "trollstore" : "system")
            let from = source == "alist" ? "从 Alist 网盘" : "从服务器"
            toast = useTrollStore ? "\(from)交给 TrollStore 下载安装" : "\(from)安装：在弹窗里点「安装」，再回到主屏幕看进度"
            openURL(url) { accepted in
                if !accepted {
                    toast = useTrollStore ? "打不开 TrollStore：请确认已安装 TrollStore（2.0 以上）" : "系统没有接受安装链接"
                }
            }
        } catch {
            toast = error.localizedDescription
        }
        working = false
    }
}

/// 「证书签名」：用服务器上保存的 p12 证书重签这个 IPA，签好后自动弹出安装。
/// 证书在「设置 → 证书管理」导入；有多个证书时先选一个。手机上的文件（localFile）先传到服务器再签。
struct SignButton: View {
    let name: String
    let source: String   // "alist"、"server" 或 "phone"（手机上的文件）
    var localFile: URL? = nil
    var onDone: (() async -> Void)? = nil
    @Binding var toast: String?
    @AppStorage(Keys.installMode) private var mode = "system"
    @Environment(\.openURL) private var openURL
    @State private var progress: String?
    @State private var certs: [CertInfo] = []
    @State private var choosing = false

    private var signable: Bool {
        name.range(of: #"\.(ipa|tipa)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    var body: some View {
        if signable {
            Button(progress ?? "证书签名") { Task { await begin() } }
                .buttonStyle(.bordered)
                .disabled(progress != nil)
                .confirmationDialog("用哪个证书签名？", isPresented: $choosing, titleVisibility: .visible) {
                    ForEach(certs) { c in
                        Button(c.label ?? c.cn ?? c.id) { Task { await run(c.id) } }
                    }
                }
        }
    }

    private func begin() async {
        do {
            let r = try await API.certs()
            guard r.zsign != false else {
                toast = "服务器上还没有签名工具，请更新服务器（docker compose up -d --build）"
                return
            }
            certs = r.certs
            if certs.isEmpty {
                toast = "还没有证书：请先在「设置 → 证书管理」导入证书"
            } else if certs.count == 1 {
                await run(certs[0].id)
            } else {
                choosing = true
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    private func run(_ cert: String) async {
        progress = "排队中…"
        do {
            var src = source
            var file = name
            if let localFile {
                progress = "上传 0%"
                file = try await API.uploadIPA(localFile) { p in
                    DispatchQueue.main.async { progress = "上传 \(Int(p * 100))%" }
                }
                src = "server"
                progress = "排队中…"
            }
            let job = try await API.sign(source: src, name: file, cert: cert)
            let j = try await waitForSignJob(job.id) { progress = $0 }
            progress = nil
            let link = (mode == "trollstore" ? j.trollstoreURL : nil) ?? j.installURL ?? j.trollstoreURL
            if let s = link, let url = URL(string: s) {
                toast = "签名完成：\(j.appName ?? name)，在弹窗里点「安装」"
                openURL(url)
            }
            await onDone?()
        } catch {
            progress = nil
            toast = error.localizedDescription
        }
    }
}

/// 等签名任务完成，过程中用 onProgress 报告进度（排队中 / 取回 xx% / 签名中…）
@MainActor
func waitForSignJob(_ id: String, onProgress: (String) -> Void) async throws -> SignJob {
    while true {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard let j = try await API.signJobs().first(where: { $0.id == id }) else {
            throw APIError(message: "签名任务不见了，可能服务器重启过")
        }
        switch j.status {
        case "downloading":
            if let size = j.size, size > 0 {
                onProgress("取回 \(Int((j.downloaded ?? 0) / size * 100))%")
            } else {
                onProgress("取回中…")
            }
        case "signing":
            onProgress("签名中…")
        case "done":
            return j
        case "error":
            throw APIError(message: j.error ?? "签名失败")
        default:
            onProgress("排队中…")
        }
    }
}

/// 一个签好的 App：安装，或者证书过期后换新证书重签（同一团队的证书可以直接覆盖安装，数据保留）
struct SignedAppRow: View {
    let item: SignedItem
    let certs: [CertInfo]
    @Binding var toast: String?
    let onChange: () async -> Void
    @AppStorage(Keys.installMode) private var mode = "system"
    @Environment(\.openURL) private var openURL
    @State private var progress: String?
    @State private var otherTeam: CertInfo?

    private var installLink: URL? {
        let s = (mode == "trollstore" ? item.trollstoreURL : nil) ?? item.installURL ?? item.trollstoreURL
        return s.flatMap { URL(string: $0) }
    }

    private var certLine: String {
        var line = "证书：" + (item.certLabel ?? "已删除")
        if let t = item.certExpires { line += " · 到 " + dayString(t) }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                AppIconView(url: item.icon, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.appName ?? item.sourceName ?? "") \(item.version ?? "")").font(.subheadline).lineLimit(2)
                    Text("\(item.bundleID ?? "") · \(fmtSize(item.size))").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Text(certLine).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    if item.isDead {
                        Text("证书\(item.certDeleted == true ? "已删除" : "已过期")，装不上了，请换证书重签")
                            .font(.caption).foregroundColor(.red)
                    }
                }
            }
            HStack {
                if !item.isDead, let url = installLink {
                    Button(url.scheme == "apple-magnifier" ? "TrollStore 安装" : "安装") {
                        toast = "在弹窗里点「安装」，再回到主屏幕看进度"
                        openURL(url)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Menu {
                    ForEach(certs) { c in
                        Button(menuTitle(c)) { choose(c) }
                    }
                } label: {
                    Text(progress ?? "换证书重签")
                }
                .buttonStyle(.bordered)
                .disabled(progress != nil || certs.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .confirmationDialog("换成另一个团队的证书？",
                            isPresented: Binding(get: { otherTeam != nil }, set: { if !$0 { otherTeam = nil } }),
                            titleVisibility: .visible,
                            presenting: otherTeam) { c in
            Button("仍然用「\(c.label ?? c.id)」重签") { Task { await run(c) } }
        } message: { _ in
            Text("新证书和原来的不是同一个团队，iOS 不允许直接覆盖安装：要先删除手机上的旧 App 再装，App 里的数据会丢。")
        }
    }

    private func menuTitle(_ c: CertInfo) -> String {
        let name = c.label ?? c.cn ?? c.id
        if c.isExpired { return "\(name)（已过期）" }
        if let t = item.teamID, let ct = c.teamID {
            return t == ct ? "\(name)（同一团队，覆盖安装保留数据）" : "\(name)（不同团队）"
        }
        return name
    }

    private func choose(_ c: CertInfo) {
        if c.isExpired {
            toast = "「\(c.label ?? c.id)」也已经过期了，请换一个证书"
        } else if let t = item.teamID, let ct = c.teamID, t != ct {
            otherTeam = c
        } else {
            Task { await run(c) }
        }
    }

    private func run(_ c: CertInfo) async {
        progress = "排队中…"
        do {
            let job = try await API.resign(key: item.key, cert: c.id)
            let j = try await waitForSignJob(job.id) { progress = $0 }
            progress = nil
            let link = (mode == "trollstore" ? j.trollstoreURL : nil) ?? j.installURL ?? j.trollstoreURL
            if let s = link, let url = URL(string: s) {
                toast = "重签完成：\(j.appName ?? item.appName ?? "")，在弹窗里点「安装」"
                openURL(url)
            }
            await onChange()
        } catch {
            progress = nil
            toast = error.localizedDescription
        }
    }
}

func dayString(_ t: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date(timeIntervalSince1970: t))
}

/// 「存到手机」：可以选从服务器下载，或从 Alist 网盘直链下载（不占家里上行带宽）
struct SaveToPhoneButton: View {
    let name: String
    let alistAvailable: Bool
    @ObservedObject var phone: PhoneDownloads
    @Binding var toast: String?

    var body: some View {
        if alistAvailable {
            Menu {
                Button("从 Alist 下载（不限速）") { fromAlist() }
                Button("从服务器下载") { phone.start(name) }
            } label: {
                Text("存到手机")
            }
            .buttonStyle(.borderedProminent)
            .disabled(phone.isRunning(name))
        } else {
            Button("存到手机") { phone.start(name) }
                .buttonStyle(.borderedProminent)
                .disabled(phone.isRunning(name))
        }
    }

    private func fromAlist() {
        Task {
            do {
                let url = try await API.alistLink(name)
                phone.start(name, from: url)
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}

/// 存到手机的进度 / 结果
struct PhoneProgressLine: View {
    let item: PhoneDownloads.Item

    var body: some View {
        let via = item.viaAlist ? "（经 Alist）" : ""
        if let err = item.error {
            Text("存到手机失败\(via)：\(err)").font(.caption).foregroundColor(.red)
        } else if item.done {
            Text("已存到手机\(via)").font(.caption).foregroundColor(.green)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("正在存到手机\(via) \(fmtSize(Double(item.received))) / \(fmtSize(Double(item.total)))")
                    .font(.caption).foregroundColor(.accentColor)
                ProgressView(value: item.total > 0 ? Double(item.received) / Double(item.total) : 0)
            }
        }
    }
}

func shortDate(_ s: String?) -> String {
    String((s ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
}

/// 底部短暂提示
struct ToastView: View {
    @Binding var text: String?

    var body: some View {
        if let t = text {
            Text(t)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 12)
                .padding(.horizontal, 16)
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if text == t { text = nil }
                }
        }
    }
}
