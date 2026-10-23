import SwiftUI

struct FilesView: View {
    @ObservedObject private var phone = PhoneDownloads.shared
    @State private var files: [RemoteFile] = []
    @State private var alist: AlistInfo?
    @State private var install: InstallInfo?
    @State private var message: String?
    @State private var toast: String?
    @State private var confirmDelete: RemoteFile?

    var body: some View {
        NavigationStack {
            List {
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
                Section {
                    if phone.localFiles.isEmpty {
                        Text("还没有存到手机的 IPA").foregroundColor(.secondary)
                    }
                    ForEach(phone.localFiles, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.subheadline).lineLimit(2)
                                Text(fmtSize(PhoneDownloads.size(of: url))).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { phone.delete(url) }
                        }
                    }
                } header: {
                    Text("手机上的文件")
                } footer: {
                    Text("也可以在「文件」App →「我的 iPhone」→「IPA 下载」里找到。点分享按钮可以发送给 TrollStore 等工具安装。左滑删除。")
                }
            }
            .navigationTitle("文件")
            .refreshable { await refresh() }
            .task {
                phone.refresh()
                let status = try? await API.status()
                alist = status?.alist
                install = status?.install
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
                if install?.enabled == true && file.app?.bundleID != nil {
                    InstallButton(name: file.name, toast: $toast)
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
