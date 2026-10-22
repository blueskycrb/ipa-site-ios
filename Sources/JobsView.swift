import SwiftUI

struct JobsView: View {
    @State private var jobs: [Job] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Text(message).foregroundColor(.red)
                }
                if jobs.isEmpty && message == nil {
                    Text("暂无任务").foregroundColor(.secondary)
                }
                ForEach(jobs) { job in
                    JobRow(job: job)
                }
            }
            .navigationTitle("下载任务")
            .toolbar {
                Button("清除已完成") {
                    Task {
                        try? await API.clearJobs()
                        await refresh()
                    }
                }
            }
            .refreshable { await refresh() }
            .task {
                // 页面显示期间每 1.5 秒刷新一次
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    private func refresh() async {
        do {
            jobs = try await API.jobs()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(url: job.icon, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name ?? "")
                    + Text(job.displayVersion.map { "  \($0)" } ?? "").foregroundColor(.secondary)
                Text(statusText).font(.caption).foregroundColor(statusColor)
                if job.status == "running" {
                    if let size = job.size, size > 0, let done = job.downloaded {
                        ProgressView(value: min(done / size, 1))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if let note = job.note {
                    Text(note).font(.caption2).foregroundColor(.secondary)
                }
                if let err = job.error {
                    Text(err).font(.caption2).foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch job.status {
        case "queued":
            return "排队中"
        case "running":
            var s = "下载中"
            if let d = job.downloaded, d > 0 {
                s += " \(fmtSize(d))"
                if let size = job.size { s += " / \(fmtSize(size))" }
            }
            if let sp = job.speed, sp > 0 { s += " · \(fmtSize(sp))/s" }
            return s
        case "done":
            var s = "完成，在「文件」里可以存到手机"
            if job.purchased == true { s += "（已自动获取许可）" }
            if let a = job.startedAt, let b = job.finishedAt { s += " · 用时 \(Int(b - a)) 秒" }
            return s
        default:
            return "失败"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case "done": return .green
        case "error": return .red
        default: return .accentColor
        }
    }
}
