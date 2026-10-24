import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 分享扩展：在微信、Safari、「文件」等 App 里把 IPA 或证书包分享到「IPA 下载」。
// 用证书签名安装的 App 没有 App Group，扩展和主 App 之间不能共享文件，所以扩展直接把文件传到服务器：
// IPA 上传后可以顺手签名（签好后在主 App「文件」页安装），证书包（zip / p12 / 描述文件）直接导入。

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.context = extensionContext
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    struct File: Identifiable {
        let id = UUID()
        let url: URL
        var name: String { url.lastPathComponent }
        var isIPA: Bool { ["ipa", "tipa"].contains(url.pathExtension.lowercased()) }
        var size: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    }

    struct Line: Identifiable {
        let id = UUID()
        let ok: Bool
        let text: String
    }

    weak var context: NSExtensionContext?
    @Published var files: [File] = []
    @Published var loading = true
    @Published var certs: [CertInfo] = []
    @Published var certError: String?
    @Published var working = false
    @Published var status: String?
    @Published var results: [Line] = []
    @Published var done = false
    private var folder: URL?

    /// 全是 IPA 时上传 / 签名；否则当作证书文件导入
    var ipaMode: Bool { !files.isEmpty && files.allSatisfy(\.isIPA) }

    func load() async {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folder = dir
        for p in providers.prefix(10) {
            do {
                files.append(File(url: try await Self.copy(p, into: dir)))
            } catch {
                results.append(Line(ok: false, text: "读取分享的文件失败：\(error.localizedDescription)"))
            }
        }
        loading = false
        await loadCerts()
    }

    func loadCerts() async {
        guard ipaMode, !API.base.isEmpty else { return }
        do {
            certs = try await API.certs().certs.filter { !$0.isExpired }
            certError = nil
        } catch {
            certError = error.localizedDescription
        }
    }

    /// 上传 IPA；cert 不为空时上传后用它签名
    func upload(sign cert: String?) async {
        working = true
        for f in files {
            do {
                status = "上传 \(f.name)…"
                let name = try await API.uploadIPA(f.url) { p in
                    Task { @MainActor in
                        if self.working { self.status = "上传 \(f.name)：\(Int(p * 100))%" }
                    }
                }
                guard let cert else {
                    results.append(Line(ok: true, text: "已上传：\(name)"))
                    continue
                }
                status = "签名 \(f.name)：排队中…"
                let job = try await API.sign(source: "server", name: name, cert: cert)
                try await waitSigned(job.id, name: f.name)
                results.append(Line(ok: true, text: "已签名：\(name)"))
            } catch {
                results.append(Line(ok: false, text: "\(f.name)：\(error.localizedDescription)"))
            }
        }
        working = false
        status = nil
        done = true
    }

    private func waitSigned(_ id: String, name: String) async throws {
        while true {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard let j = try await API.signJobs().first(where: { $0.id == id }) else {
                throw APIError(message: "签名任务不见了，可能服务器重启过")
            }
            switch j.status {
            case "done":
                return
            case "error":
                throw APIError(message: j.error ?? "签名失败")
            case "signing":
                status = "签名 \(name)：签名中…"
            default:
                status = "签名 \(name)：排队中…"
            }
        }
    }

    func importCerts(password: String) async {
        working = true
        status = "导入证书中…"
        do {
            let data = try files.map { (name: $0.name, data: try Data(contentsOf: $0.url)) }
            for r in try await API.importCerts(data, password: password, label: "") {
                if r.ok, let c = r.cert {
                    let mismatch = c.matchesProfile == false
                    results.append(Line(ok: !mismatch, text: "已添加证书：\(c.label ?? "")" + (mismatch ? "（证书和描述文件不匹配）" : "")))
                } else {
                    results.append(Line(ok: false, text: "\(r.file)：\(r.error ?? "导入失败")"))
                }
            }
            done = results.contains { $0.ok }
        } catch {
            results.append(Line(ok: false, text: error.localizedDescription))
        }
        working = false
        status = nil
    }

    func close() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        context?.completeRequest(returningItems: nil)
    }

    /// 把分享来的文件复制到扩展自己的临时目录（系统给的路径只在回调里有效）
    nonisolated static func copy(_ p: NSItemProvider, into dir: URL) async throws -> URL {
        let fileType = p.registeredTypeIdentifiers.first { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .data) || t.conforms(to: .package)
        }
        if let fileType {
            return try await withCheckedThrowingContinuation { cont in
                _ = p.loadFileRepresentation(forTypeIdentifier: fileType) { url, error in
                    guard let url else {
                        cont.resume(throwing: error ?? APIError(message: "拿不到文件"))
                        return
                    }
                    do {
                        cont.resume(returning: try place(url, suggested: p.suggestedName, in: dir))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        // 有的 App 只给文件地址
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
            guard let url = item as? URL else { throw APIError(message: "拿不到文件") }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try place(url, suggested: nil, in: dir)
        }
        throw APIError(message: "分享来的不是文件")
    }

    nonisolated private static func place(_ src: URL, suggested: String?, in dir: URL) throws -> URL {
        // 系统给的临时文件一般保留原文件名；没有扩展名时用分享方提供的名字
        var name = src.lastPathComponent
        if src.pathExtension.isEmpty, let s = suggested, !s.isEmpty {
            name = s
        }
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    @AppStorage(Keys.server) private var server = ""
    @AppStorage(Keys.sitePassword) private var sitePassword = ""
    @State private var editing = false
    @State private var serverDraft = ""
    @State private var passwordDraft = ""
    @State private var pasteMessage: String?
    @State private var cert = ""            // 空 = 只上传不签名
    @State private var certPassword = ""

    private var needsSetup: Bool {
        editing || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                filesSection
                if needsSetup {
                    setupSection
                } else {
                    actionSection
                }
                if !model.results.isEmpty {
                    resultSection
                }
            }
            .navigationTitle("IPA 下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.done ? "完成" : "取消") { model.close() }
                        .disabled(model.working)
                }
            }
            .onReceive(model.$certs) { list in
                // 默认选第一个证书：分享 IPA 过来多半是要签名安装
                if cert.isEmpty, let first = list.first { cert = first.id }
            }
        }
    }

    private var filesSection: some View {
        Section {
            if model.loading {
                HStack { ProgressView(); Text("读取文件…").foregroundColor(.secondary) }
            } else if model.files.isEmpty {
                Text("没有收到文件").foregroundColor(.secondary)
            }
            ForEach(model.files) { f in
                LabeledContent(f.name, value: ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                    .font(.caption)
            }
        } header: {
            Text(model.files.isEmpty ? "文件" : (model.ipaMode ? "要上传的 IPA" : "要导入的证书文件"))
        }
    }

    private var setupSection: some View {
        Section {
            TextField("服务器地址，例如 http://192.168.1.10:8686", text: $serverDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("网站访问密码（没设置就留空）", text: $passwordDraft)
            Button("从剪贴板读取") { paste() }
            Button("保存") {
                server = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                sitePassword = passwordDraft
                editing = false
                Task { await model.loadCerts() }
            }
            .disabled(serverDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let m = pasteMessage {
                Text(m).font(.caption).foregroundColor(.secondary)
            }
        } header: {
            Text("连接服务器")
        } footer: {
            Text("分享扩展和「IPA 下载」App 的设置不互通，第一次用要设置一次：在 App「设置 → 服务器」点「复制配置给分享扩展」，再回到这里点「从剪贴板读取」。也可以直接手动填。")
        }
        .onAppear {
            if serverDraft.isEmpty { serverDraft = server }
            if passwordDraft.isEmpty { passwordDraft = sitePassword }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if model.ipaMode {
                Picker("证书签名", selection: $cert) {
                    Text("不签名，只上传").tag("")
                    ForEach(model.certs) { c in
                        Text(c.label ?? c.cn ?? c.id).tag(c.id)
                    }
                }
                if let e = model.certError {
                    Text(e).font(.caption).foregroundColor(.red)
                }
                Button(cert.isEmpty ? "上传到服务器" : "上传并签名") {
                    Task { await model.upload(sign: cert.isEmpty ? nil : cert) }
                }
                .disabled(model.working || model.done)
            } else if !model.files.isEmpty {
                SecureField("证书密码（压缩包里写了密码或没有密码就留空）", text: $certPassword)
                Button("导入证书") {
                    Task { await model.importCerts(password: certPassword) }
                }
                .disabled(model.working || model.done)
            }
            if let s = model.status {
                HStack {
                    ProgressView()
                    Text(s).font(.caption)
                }
            }
            Button("修改服务器设置") {
                serverDraft = server
                passwordDraft = sitePassword
                editing = true
            }
            .font(.caption)
            .disabled(model.working)
        } header: {
            Text("服务器：\(API.base)")
        } footer: {
            Text(model.ipaMode
                 ? "上传期间不要关闭这个页面。签好后打开「IPA 下载」→「文件」→「证书签名的 App」点「安装」；只上传的在「服务器上的文件」里。"
                 : "支持证书 zip 包、.p12 + .mobileprovision；压缩包里写着密码的 txt 会自动识别。导入后在 App「设置 → 证书管理」里可以看到。")
        }
    }

    private var resultSection: some View {
        Section("结果") {
            ForEach(model.results) { r in
                Label(r.text, systemImage: r.ok ? "checkmark.circle" : "xmark.circle")
                    .font(.caption)
                    .foregroundColor(r.ok ? .green : .red)
            }
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, let cfg = ShareConfig.decode(text) else {
            pasteMessage = "剪贴板里没有配置：请先在「IPA 下载」App「设置 → 服务器」点「复制配置给分享扩展」"
            return
        }
        serverDraft = cfg.server
        passwordDraft = cfg.password
        pasteMessage = "已读取，点「保存」"
    }
}
