import SwiftUI

/// 浏览服务器配置的 Alist 上传目录；文件直接从网盘直链下载，不经过家里的上行带宽
struct AlistView: View {
    @ObservedObject private var phone = PhoneDownloads.shared
    @State private var items: [AlistItem] = []
    @State private var total = 0
    @State private var dir: String?
    @State private var query = ""
    @State private var loading = false
    @State private var message: String?
    @State private var toast: String?
    @State private var status: ServerStatus?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let message {
                        Text(message).foregroundColor(.red)
                    }
                    if loading && items.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取 Alist 目录…").foregroundColor(.secondary)
                        }
                    }
                    ForEach(items) { item in
                        AlistRow(item: item, installEnabled: status?.install?.enabled == true,
                                 phone: phone, toast: $toast)
                    }
                    if items.count < total {
                        Button(loading ? "加载中…" : "加载更多（还有 \(total - items.count) 个）") {
                            Task { await load(reset: false) }
                        }
                        .disabled(loading)
                    }
                } header: {
                    if total > 0 {
                        Text("\(dir ?? "") · 共 \(total) 个文件")
                    }
                } footer: {
                    Text("从这里存到手机或安装，都是用网盘直链下载，不受家里宽带上行限速影响。系统安装只对本站从 App Store 下载的 IPA 有效；改版 / 砸壳的 IPA 用「证书签名」（证书在网页上传）或 TrollStore 安装。")
                }
            }
            .navigationTitle("Alist")
            .searchable(text: $query, prompt: "搜索文件名")
            .onSubmit(of: .search) { Task { await load(reset: true) } }
            .onChange(of: query) { newValue in
                if newValue.isEmpty { Task { await load(reset: true) } }
            }
            .refreshable { await load(reset: true) }
            .toolbar {
                Button("刷新目录") { Task { await load(reset: true, refresh: true) } }
                    .disabled(loading)
            }
            .task {
                if status == nil { status = try? await API.status() }
                if items.isEmpty { await load(reset: true) }
            }
            .overlay(alignment: .bottom) { ToastView(text: $toast) }
        }
    }

    private func load(reset: Bool, refresh: Bool = false) async {
        guard !loading else { return }
        loading = true
        if refresh { toast = "正在让 Alist 重新读取网盘目录，文件多时要等半分钟以上" }
        do {
            let page = try await API.alistList(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                               offset: reset ? 0 : items.count, refresh: refresh)
            items = reset ? page.items : items + page.items
            total = page.total
            dir = page.dir
            message = page.total == 0 ? (query.isEmpty ? "目录是空的" : "没有找到相关文件") : nil
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }
}

struct AlistRow: View {
    let item: AlistItem
    let installEnabled: Bool
    @ObservedObject var phone: PhoneDownloads
    @Binding var toast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                if let icon = item.app?.icon {
                    AppIconView(url: icon, size: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let appName = item.app?.name {
                        Text(appName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.name).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                    } else {
                        Text(item.name).font(.subheadline).lineLimit(2)
                    }
                    Text("\(fmtSize(item.size)) · \(shortDate(item.modified))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let p = phone.active[item.name] {
                PhoneProgressLine(item: p)
            }
            HStack {
                Button("存到手机") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(phone.isRunning(item.name))
                InstallButton(name: item.name, systemAvailable: installEnabled && item.app?.bundleID != nil,
                              toast: $toast)
                SignButton(name: item.name, source: "alist", toast: $toast)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func save() {
        Task {
            do {
                let url = try await API.alistLink(item.name)
                phone.start(item.name, from: url)
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}
