import SwiftUI
import UniformTypeIdentifiers

/// 证书管理：查看服务器上的签名证书，导入新证书（zip 包或 p12 + 描述文件），删除过期的
struct CertsView: View {
    @State private var certs: [CertInfo] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var picking = false
    @State private var picked: [PickedFile] = []
    @State private var password = ""
    @State private var label = ""
    @State private var importing = false
    @State private var results: [ImportResult] = []
    @State private var message: String?
    @State private var listMessage: String?
    @State private var deleting: CertInfo?
    @State private var confirmDeleteExpired = false

    private struct PickedFile: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }

    private var now: Double { Date().timeIntervalSince1970 }
    private var expired: [CertInfo] { certs.filter { ($0.expires ?? .infinity) < now } }

    var body: some View {
        Form {
            Section {
                if !loaded {
                    HStack { ProgressView(); Text("加载中…").foregroundColor(.secondary) }
                } else if let e = loadError {
                    Text(e).font(.caption).foregroundColor(.red)
                } else if certs.isEmpty {
                    Text("还没有证书，在下面导入").foregroundColor(.secondary)
                }
                ForEach(certs) { c in
                    certRow(c)
                        .swipeActions {
                            Button("删除", role: .destructive) { deleting = c }
                        }
                }
                if let m = listMessage {
                    Text(m).font(.caption).foregroundColor(.red)
                }
                if !expired.isEmpty {
                    Button("删除 \(expired.count) 个过期证书", role: .destructive) { confirmDeleteExpired = true }
                }
            } header: {
                Text("服务器上的证书")
            } footer: {
                Text("左滑删除。删除证书时，用它签好的文件也会一起删除。")
            }

            Section {
                Button(picked.isEmpty ? "选择文件" : "重新选择") { picking = true }
                ForEach(picked) { f in
                    LabeledContent(f.name, value: f.data.count < 1_048_576 ? "\(max(1, f.data.count / 1024)) KB" : fmtSize(Double(f.data.count)))
                        .font(.caption)
                }
                SecureField("证书密码（压缩包里写了密码或没有密码就留空）", text: $password)
                TextField("备注名称（可不填，默认用压缩包名）", text: $label)
                Button(importing ? "导入中…" : "导入") { Task { await runImport() } }
                    .disabled(importing || picked.isEmpty)
                ForEach(results) { r in
                    resultRow(r)
                }
                if let m = message {
                    Text(m).font(.caption).foregroundColor(.red)
                }
            } header: {
                Text("导入证书")
            } footer: {
                Text("可以一次选多个证书 zip 包，也可以同时选 .p12 和 .mobileprovision。压缩包里写着密码的 txt 会自动识别，p12 和描述文件会自动配对。从微信 / QQ 收到的证书包，先「用其他应用打开 → 存储到文件」，再在这里选。证书只保存在你的服务器上。")
            }
        }
        .navigationTitle("证书管理")
        .task { await load() }
        .refreshable { await load() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .data], allowsMultipleSelection: true) { result in
            pick(result)
        }
        .confirmationDialog("删除这个证书？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible,
                            presenting: deleting) { c in
            Button("删除 \(c.label ?? c.cn ?? c.id)", role: .destructive) { Task { await delete([c]) } }
        } message: { _ in
            Text("用这个证书签好的文件也会一起删除。")
        }
        .confirmationDialog("删除所有过期证书？", isPresented: $confirmDeleteExpired, titleVisibility: .visible) {
            Button("删除 \(expired.count) 个", role: .destructive) { Task { await delete(expired) } }
        } message: {
            Text("用这些证书签好的文件也会一起删除。")
        }
    }

    private func certRow(_ c: CertInfo) -> some View {
        // 剩余天数；已过期时为负数
        let left = c.expires.map { $0 < now ? -1 : Int(($0 - now) / 86400) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(c.label ?? c.cn ?? c.id).font(.body.bold())
            if let cn = c.cn { Text(cn).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            Text("证书到 \(fmtDate(c.certExpires)) · 描述文件到 \(fmtDate(c.profileExpires))")
                .font(.caption).foregroundColor(.secondary)
            Text(c.allDevices == true ? "所有设备（企业）" : "\(c.devices ?? 0) 台设备")
                .font(.caption).foregroundColor(.secondary)
            if let left {
                if left < 0 {
                    Text("已过期，签出来的包装不上").font(.caption).foregroundColor(.red)
                } else if left <= 7 {
                    Text(left == 0 ? "不到 1 天就过期" : "\(left) 天后过期").font(.caption).foregroundColor(.orange)
                }
            }
            if c.matchesProfile == false {
                Text("这个证书不在描述文件里，签出来的包装不上").font(.caption).foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func resultRow(_ r: ImportResult) -> some View {
        if r.ok, let c = r.cert {
            Label(c.matchesProfile == false ? "已添加 \(c.label ?? "")（证书和描述文件不匹配）" : "已添加 \(c.label ?? "")",
                  systemImage: c.matchesProfile == false ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption)
                .foregroundColor(c.matchesProfile == false ? .orange : .green)
        } else {
            Label("\(r.file)：\(r.error ?? "导入失败")", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    private func fmtDate(_ t: Double?) -> String {
        guard let t else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func load() async {
        do {
            certs = try await API.certs().certs
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func pick(_ result: Result<[URL], Error>) {
        results = []
        message = nil
        do {
            var files: [PickedFile] = []
            for url in try result.get() {
                // 从「文件」App 选的文件要先申请访问权限
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                files.append(PickedFile(name: url.lastPathComponent, data: try Data(contentsOf: url)))
            }
            if files.reduce(0, { $0 + $1.data.count }) > 30 * 1024 * 1024 {
                message = "文件太大了（超过 30 MB），证书包一般只有几十 KB，是不是选错了？"
                picked = []
            } else {
                picked = files
            }
        } catch {
            message = "读取文件失败：\(error.localizedDescription)"
        }
    }

    private func runImport() async {
        importing = true
        message = nil
        results = []
        do {
            results = try await API.importCerts(picked.map { (name: $0.name, data: $0.data) }, password: password, label: label)
            if results.contains(where: { $0.ok }) {
                picked = []
                password = ""
                label = ""
                await load()
            }
        } catch {
            message = error.localizedDescription
        }
        importing = false
    }

    private func delete(_ list: [CertInfo]) async {
        listMessage = nil
        for c in list {
            do {
                try await API.deleteCert(c.id)
            } catch {
                listMessage = error.localizedDescription
                break
            }
        }
        await load()
    }
}
