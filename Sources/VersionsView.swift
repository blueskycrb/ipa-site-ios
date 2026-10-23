import SwiftUI

/// 限制同时进行的任务数：查询版本号时最多同时查几个（和服务器的上限一致）
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

/// 查找条件：版本号（14.8.40 / 14.8）或发布日期（2026-09 / 2026-09-24）
enum VersionQuery {
    case version([Int])
    case date(String)

    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: "-").map(String.init)
        if (2...3).contains(parts.count), parts[0].count == 4, parts.allSatisfy({ Int($0) != nil }) {
            // 日期：补零成 2026-09-04 的格式，方便和 Apple 返回的日期按字符串比较
            self = .date(parts.enumerated().map { $0.offset == 0 ? $0.element : String(format: "%02d", Int($0.element)!) }
                .joined(separator: "-"))
            return
        }
        let numbers = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        self = .version(numbers)
    }

    /// 某个版本和查找条件比较：小于为负、等于（前缀相同）为 0、大于为正；没有信息时返回 nil
    func compare(_ info: VersionInfo) -> Int? {
        switch self {
        case .version(let target):
            guard let v = info.displayVersion else { return nil }
            let have = v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            for (i, t) in target.enumerated() {
                let a = i < have.count ? have[i] : 0
                if a != t { return a < t ? -1 : 1 }
            }
            return 0
        case .date(let target):
            guard let d = info.releaseDate else { return nil }
            let head = String(d.prefix(target.count))
            return head == target ? 0 : (head < target ? -1 : 1)
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
    @State private var found: [String]?          // 查找结果（最新在前）
    @State private var findStatus: String?
    @State private var findTask: Task<Void, Never>?

    /// 打开时自动查询的最新版本数，其余手动点「查看」
    private let autoCount = 5

    private var shown: [String] {
        if let found { return found }
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return versions }
        // 输入时先在已知的版本里即时筛选；回车再去查找没查过的版本
        return versions.filter { $0.contains(f) || (info[$0]?.displayVersion ?? "").contains(f) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("最新的 \(autoCount) 个版本会自动显示版本号，其余点「查看」。在上方输入版本号（如 14.8.40、14.8）或日期（如 2026-09）后回车，可以直接找到对应版本。")
                        .font(.caption).foregroundColor(.secondary)
                    if let status = findStatus {
                        HStack(spacing: 8) {
                            if findTask != nil { ProgressView().controlSize(.small) }
                            Text(status).font(.caption)
                            Spacer()
                            if findTask != nil {
                                Button("取消") { cancelFind() }.font(.caption)
                            } else if found != nil {
                                Button("显示全部") {
                                    found = nil
                                    findStatus = nil
                                    filter = ""
                                }
                                .font(.caption)
                            }
                        }
                    }
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
                               onLookUp: {
                                   failed[vid] = nil
                                   Task { _ = await fetch(vid) }
                               },
                               onDownload: { Task { await download(vid) } })
                        .task {
                            if versions.prefix(autoCount).contains(vid) { _ = await fetch(vid) }
                        }
                }
            }
            .navigationTitle(app.name ?? "历史版本")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: "版本号或日期，回车查找")
            .onSubmit(of: .search) { startFind() }
            .onChange(of: filter) { newValue in
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    cancelFind()
                    found = nil
                    findStatus = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        cancelFind()
                        dismiss()
                    }
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

    /// 查询一个版本的版本号（已知的直接返回）；同时最多 3 个
    private func fetch(_ vid: String) async -> VersionInfo? {
        if let known = info[vid] { return known }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if let known = info[vid] { return known }
        guard !Task.isCancelled else { return nil }
        querying.insert(vid)
        defer { querying.remove(vid) }
        do {
            let m = try await API.versionMeta(app, versionID: vid)
            let v = VersionInfo(displayVersion: m.displayVersion, releaseDate: m.releaseDate)
            info[vid] = v
            failed[vid] = nil
            return v
        } catch {
            if !Task.isCancelled { failed[vid] = error.localizedDescription }
            return nil
        }
    }

    private func startFind() {
        cancelFind()
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard let query = VersionQuery(text) else {
            findStatus = "请输入版本号（如 14.8.40）或日期（如 2026-09）"
            return
        }
        findTask = Task { await find(query, text: text) }
    }

    private func cancelFind() {
        findTask?.cancel()
        findTask = nil
    }

    /// 版本 ID 越大发布越晚，版本号和日期也随之增大，所以可以二分查找。
    /// 每轮同时问 3 个点，把范围缩小到四分之一；问过的版本服务器会记住。
    private func find(_ query: VersionQuery, text: String) async {
        let asc = Array(versions.reversed())   // 从旧到新
        var lo = 0, hi = asc.count
        var asked = 0
        func status() { findStatus = "正在查找「\(text)」…（已查 \(asked) 个版本）" }
        status()

        // 找到第一个「不小于」查找条件的版本
        while lo < hi {
            let probes = hi - lo <= 3 ? Array(lo..<hi) : [1, 2, 3].map { lo + (hi - lo) * $0 / 4 }
            let results: [(Int, Int?)] = await withTaskGroup(of: (Int, Int?).self) { group in
                for p in probes {
                    group.addTask { (p, await fetch(asc[p]).flatMap { query.compare($0) }) }
                }
                var collected: [(Int, Int?)] = []
                for await r in group { collected.append(r) }
                return collected
            }
            if Task.isCancelled { return }
            asked += results.count
            status()
            var cmps: [Int: Int] = [:]
            for (p, c) in results {
                if let c { cmps[p] = c }
            }
            guard cmps.count == probes.count else {
                findStatus = "有版本查询失败，查找中断，可以稍后再试"
                findTask = nil
                return
            }
            if let first = probes.first(where: { cmps[$0]! >= 0 }) {
                let before = probes.last(where: { $0 < first })
                lo = before.map { $0 + 1 } ?? lo
                hi = first
            } else {
                lo = probes.last! + 1
            }
        }

        // 从找到的位置往后收集匹配的版本（14.8 会匹配 14.8.x 的所有版本，最多 30 个）
        var matches: [String] = []
        var i = lo
        while i < asc.count, matches.count < 30 {
            guard let v = await fetch(asc[i]), let c = query.compare(v), c == 0 else { break }
            matches.append(asc[i])
            i += 1
        }
        if Task.isCancelled { return }
        if matches.isEmpty {
            let near = [lo - 1, lo].filter { $0 >= 0 && $0 < asc.count }.map { asc[$0] }
            found = Array(near.reversed())
            findStatus = "没有找到「\(text)」，下面是最接近的版本"
        } else {
            found = Array(matches.reversed())
            findStatus = "找到 \(matches.count) 个版本"
        }
        findTask = nil
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
    var onLookUp: () -> Void
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
                        Text("版本号未查询").font(.subheadline).foregroundColor(.secondary)
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
            if info == nil && !querying {
                Button(failure == nil ? "查看" : "重试", action: onLookUp).buttonStyle(.bordered)
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
