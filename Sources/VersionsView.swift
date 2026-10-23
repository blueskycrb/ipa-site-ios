import SwiftUI

/// 限制同时进行的任务数：自动查询版本号时最多同时查几个
actor Limiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct VersionsView: View {
    let app: AppItem
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [String] = []
    @State private var info: [String: VersionInfo] = [:]   // 版本 ID -> 版本号、发布日期
    @State private var querying: Set<String> = []
    @State private var failed: [String: String] = [:]
    @State private var limiter = Limiter(3)
    @State private var loading = true
    @State private var message: String?
    @State private var filter = ""
    @State private var toast: String?

    private var shown: [String] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return versions }
        return versions.filter { $0.contains(f) || (info[$0]?.displayVersion ?? "").contains(f) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("最新在前。版本号和发布日期会在滑到时自动查询（每个版本要问 Apple，可能要几秒到一分钟），查过的服务器会记住，下次直接显示；只能下载你的 Apple ID 有许可的 App。")
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
                    VersionRow(vid: vid, info: info[vid], isLatest: vid == versions.first,
                               querying: querying.contains(vid), failure: failed[vid],
                               onRetry: {
                                   failed[vid] = nil
                                   Task { await lookUp(vid) }
                               },
                               onDownload: { Task { await download(vid) } })
                        .task { await lookUp(vid) }
                }
            }
            .navigationTitle(app.name ?? "历史版本")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: "筛选版本号或版本 ID")
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
            let (ids, known) = try await API.versions(app)
            info.merge(known) { old, _ in old }
            versions = ids
            if ids.isEmpty { message = "没有版本信息" }
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    /// 行出现时自动查询版本号；滑走（任务被取消）的行不再排队
    private func lookUp(_ vid: String) async {
        guard info[vid] == nil, !querying.contains(vid), failed[vid] == nil else { return }
        await limiter.acquire()
        guard !Task.isCancelled, info[vid] == nil else {
            await limiter.release()
            return
        }
        querying.insert(vid)
        do {
            let m = try await API.versionMeta(app, versionID: vid)
            info[vid] = VersionInfo(displayVersion: m.displayVersion, releaseDate: m.releaseDate)
        } catch {
            // 滑走导致的取消不算失败，下次滑到时再查（服务器那边多半已经查完记住了）
            if !Task.isCancelled { failed[vid] = error.localizedDescription }
        }
        querying.remove(vid)
        await limiter.release()
    }

    private func download(_ vid: String) async {
        let shownVersion = info[vid]?.displayVersion ?? "ID \(vid)"
        do {
            try await API.download(app, versionID: vid, displayVersion: shownVersion)
            toast = "已加入下载队列：\(app.name ?? "") \(shownVersion)"
        } catch {
            toast = error.localizedDescription
        }
    }
}

struct VersionRow: View {
    let vid: String
    let info: VersionInfo?
    let isLatest: Bool
    let querying: Bool
    let failure: String?
    var onRetry: () -> Void
    var onDownload: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let v = info?.displayVersion {
                        Text(v).font(.headline)
                    } else if querying {
                        ProgressView().controlSize(.mini)
                        Text("查询版本号…").font(.subheadline).foregroundColor(.secondary)
                    } else {
                        Text("版本号未知").font(.subheadline).foregroundColor(.secondary)
                    }
                    if isLatest {
                        Text("最新").font(.caption2).padding(.horizontal, 5)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(detail).font(.caption).foregroundColor(.secondary)
                if let failure {
                    Text(failure).font(.caption2).foregroundColor(.red).lineLimit(2)
                }
            }
            Spacer()
            if failure != nil {
                Button("重试", action: onRetry).buttonStyle(.bordered)
            }
            Button("下载", action: onDownload).buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
    }

    private var detail: String {
        let date = String((info?.releaseDate ?? "").prefix(10))
        return date.isEmpty ? "ID \(vid)" : "\(date) · ID \(vid)"
    }
}
