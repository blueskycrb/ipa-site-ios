import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @ObservedObject private var phone = PhoneDownloads.shared
    @State private var files: [RemoteFile] = []
    @State private var alist: AlistInfo?
    @State private var install: InstallInfo?
    @State private var message: String?
    @State private var toast: String?
    @State private var confirmDelete: RemoteFile?
    @State private var signed: [SignedItem] = []
    @State private var certs: [CertInfo] = []
    @State private var importing = false
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            List {
                if !signed.isEmpty {
                    Section {
                        ForEach(signed) { s in
                            SignedAppRow(item: s, certs: certs, toast: $toast) { await loadSigned() }
                                .swipeActions {
                                    Button("删除", role: .destructive) { Task { await deleteSigned(s) } }
                                }
                        }
                    } header: {
                        Text("证书签名的 App")
                    } footer: {
                        Text("证书过期后点「换证书重签」：新证书和原来的是同一个团队时，直接覆盖安装，App 数据保留；不是同一个团队要先删除手机上的旧 App。左滑删除。")
                    }
                }
                if !phone.localFiles.isEmpty {
                    phoneSection   // 有文件时放在服务器文件前面，导入后不用往下翻
                }
                Section("服务器上的文件") {
                    if let message {
                        Text(message).foregroundColor(.red)
                    }
                    if files.isEmpty && message == nil {
                        Text("暂无文件").foregroundColor(.secondary)
                    }
                    ForEach(files) { file in
                        remoteRow(file)
                    }
                }
                if phone.localFiles.isEmpty {
                    phoneSection
                }
            }
            .navigationTitle("文件")
            .toolbar {
                Button {
                    importing = true
                } label: {
                    Label("导入 IPA", systemImage: "square.and.arrow.down")
                }
            }
            .sheet(isPresented: $importing) {
                DocumentPicker { urls in
                    Task { await importPicked(urls) }
                }
                .ignoresSafeArea()
            }
            .alert("导入 IPA", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importResult ?? "")
            }
            .refreshable {
                await refresh()
                await loadSigned()
            }
            .task {
                phone.refresh()
                let status = try? await API.status()
                alist = status?.alist
                install = status?.install
                await loadSigned()
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            .confirmationDialog("删除服务器上的文件？",
                                isPresented: Binding(get: { confirmDelete != nil },
                                                     set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: confirmDelete) { file in
                Button("删除 \(file.name)", role: .destructive) {
                    Task { await delete(file) }
                }
            }
            .overlay(alignment: .bottom) { ToastView(text: $toast) }
        }
    }

    private var phoneSection: some View {
        Section {
            if phone.localFiles.isEmpty {
                Text("还没有手机上的 IPA，点右上角「导入 IPA」").foregroundColor(.secondary)
            }
            ForEach(phone.localFiles, id: \.self) { url in
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.lastPathComponent).font(.subheadline).lineLimit(2)
                    Text(fmtSize(PhoneDownloads.size(of: url))).font(.caption).foregroundColor(.secondary)
                    HStack {
                        SignButton(name: url.lastPathComponent, source: "phone", localFile: url,
                                   onDone: { await loadSigned() }, toast: $toast)
                        Spacer()
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button("删除", role: .destructive) { phone.delete(url) }
                }
            }
        } header: {
            Text("手机上的文件")
        } footer: {
            Text("右上角「导入 IPA」可以从「文件」App 选；在微信、Safari 等 App 里也可以「用其他应用打开 → IPA 下载」。点「证书签名」会先传到服务器，签好后弹出安装。也可以在「文件」App →「我的 iPhone」→「IPA 下载」里找到。左滑删除。")
        }
    }

    private func importPicked(_ urls: [URL]) async {
        var imported: [String] = []
        var failed: [String] = []
        for url in urls {
            do {
                let dest = try await Task.detached { try PhoneDownloads.importFile(url) }.value
                imported.append(dest.lastPathComponent)
            } catch {
                failed.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        phone.refresh()
        var lines: [String] = []
        if !imported.isEmpty {
            lines.append("已导入 \(imported.count) 个：" + imported.joined(separator: "、")
                         + "\n在「手机上的文件」里点「证书签名」，签好后会弹出安装。")
        }
        if !failed.isEmpty {
            lines.append("没导入：\n" + failed.joined(separator: "\n"))
        }
        importResult = lines.isEmpty ? "没有选择文件" : lines.joined(separator: "\n\n")
    }

    @ViewBuilder
    private func remoteRow(_ file: RemoteFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                if let icon = file.app?.icon {
                    AppIconView(url: icon, size: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let appName = file.app?.name {
                        (Text(appName).font(.subheadline.weight(.semibold))
                            + Text(file.app?.version.map { "  v\($0)" } ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary))
                            .lineLimit(1)
                        Text(file.name).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    } else {
                        Text(file.name).font(.subheadline).lineLimit(2)
                    }
                    Text("\(fmtSize(file.size)) · \(Date(timeIntervalSince1970: file.mtime).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let up = file.alist {
                alistLine(up)
            }
            if let item = phone.active[file.name] {
                PhoneProgressLine(item: item)
            }
            HStack {
                SaveToPhoneButton(name: file.name, alistAvailable: alist?.enabled == true && file.alist?.status != "error",
                                  phone: phone, toast: $toast)
                InstallButton(name: file.name, systemAvailable: install?.enabled == true && file.app?.bundleID != nil,
                              toast: $toast)
                if file.app?.uploaded == true {
                    // 自己传上来的 IPA 不能系统安装，直接给签名按钮
                    SignButton(name: file.name, source: "server", onDone: { await loadSigned() }, toast: $toast)
                }
                if alist?.enabled == true {
                    Button(file.alist?.status == "done" ? "重传" : "传到 Alist") {
                        Task { await upload(file) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(file.alist?.status == "queued" || file.alist?.status == "running")
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = file
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func alistLine(_ up: UploadRecord) -> some View {
        switch up.status {
        case "queued":
            Text("Alist：排队中").font(.caption).foregroundColor(.accentColor)
        case "running":
            let total = up.size ?? 0
            VStack(alignment: .leading, spacing: 2) {
                Text("Alist：上传中 \(fmtSize(up.sent)) / \(fmtSize(up.size))").font(.caption).foregroundColor(.accentColor)
                ProgressView(value: total > 0 ? min((up.sent ?? 0) / total, 1) : 0)
            }
        case "done":
            Text("Alist：已上传到 \(up.remote ?? "")").font(.caption).foregroundColor(.green).lineLimit(1)
        default:
            Text("Alist 上传失败：\(up.error ?? "")").font(.caption).foregroundColor(.red)
        }
    }

    private func refresh() async {
        do {
            files = try await API.files()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadSigned() async {
        signed = (try? await API.signed()) ?? []
        certs = (try? await API.certs().certs) ?? []
    }

    private func deleteSigned(_ s: SignedItem) async {
        do {
            try await API.deleteSigned(s.key)
            toast = "已删除"
        } catch {
            toast = error.localizedDescription
        }
        await loadSigned()
    }

    private func upload(_ file: RemoteFile) async {
        do {
            try await API.uploadToAlist(file.name)
            await refresh()
        } catch {
            toast = error.localizedDescription
        }
    }

    private func delete(_ file: RemoteFile) async {
        do {
            try await API.deleteFile(file.name)
            toast = "已删除"
            await refresh()
        } catch {
            toast = error.localizedDescription
        }
    }
}
