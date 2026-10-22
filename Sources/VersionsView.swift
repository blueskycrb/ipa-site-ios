import SwiftUI

struct VersionsView: View {
    let app: AppItem
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [String] = []
    @State private var display: [String: String] = [:]   // 版本 ID -> 版本号
    @State private var detail: [String: String] = [:]    // 版本 ID -> 说明文字
    @State private var loading = true
    @State private var message: String?
    @State private var filter = ""
    @State private var toast: String?

    private var shown: [String] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return versions }
        return versions.filter { $0.contains(f) || (display[$0] ?? "").contains(f) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("最新在前。点「查看」获取版本号；只能下载你的 Apple ID 有许可的 App。")
                        .font(.caption).foregroundColor(.secondary)
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在获取版本列表…").foregroundColor(.secondary)
                    }
                }
                if let message {
                    Text(message).foregroundColor(.red)
                }
                ForEach(shown, id: \.self) { vid in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(vid).font(.body.monospacedDigit())
                                if vid == versions.first {
                                    Text("最新").font(.caption2).padding(.horizontal, 5)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }
                            if let d = detail[vid] {
                                Text(d).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button("查看") { Task { await loadMeta(vid) } }.buttonStyle(.bordered)
                        Button("下载") { Task { await download(vid) } }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
            .navigationTitle(app.name ?? "历史版本")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: "筛选版本 ID 或版本号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) { ToastView(text: $toast) }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        do {
            versions = try await API.versions(app)
            if versions.isEmpty { message = "没有版本信息" }
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    private func loadMeta(_ vid: String) async {
        detail[vid] = "查询中…"
        do {
            let m = try await API.versionMeta(app, versionID: vid)
            display[vid] = m.displayVersion
            detail[vid] = "版本 \(m.displayVersion ?? "?") · \(String((m.releaseDate ?? "").prefix(10)))"
        } catch {
            detail[vid] = error.localizedDescription
        }
    }

    private func download(_ vid: String) async {
        let shownVersion = display[vid] ?? "ID \(vid)"
        do {
            try await API.download(app, versionID: vid, displayVersion: shownVersion)
            toast = "已加入下载队列：\(app.name ?? "") \(shownVersion)"
        } catch {
            toast = error.localizedDescription
        }
    }
}
