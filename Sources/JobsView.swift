import SwiftUI

struct JobsView: View {
    @State private var jobs: [Job] = []
    @State private var decryptJobs: [DecryptJob] = []
    @State private var message: String?
    @State private var toast: String?
    @State private var installEnabled = false
    @State private var decryptEnabled = false   // 服务器支持解密（旧版服务器没有）
    @State private var showAccount = false   // 有多个账号时，每个任务显示用的是哪个账号

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let message {
                        Text(message).foregroundColor(.red)
                    }
                    if jobs.isEmpty && message == nil {
                        Text("暂无任务").foregroundColor(.secondary)
                    }
                    ForEach(jobs) { job in
                        JobRow(job: job, installEnabled: installEnabled, decryptEnabled: decryptEnabled,
                               showAccount: showAccount, toast: $toast)
                    }
                } header: {
                    if !decryptJobs.isEmpty { Text("下载") }
                }
                if !decryptJobs.isEmpty {
                    Section("解密") {
                        ForEach(decryptJobs) { job in
                            DecryptJobRow(job: job, toast: $toast)
                        }
                    }
                }
            }
            .navigationTitle("下载任务")
            .toolbar {
                Button("清除已完成") {
                    Task {
                        try? await API.clearJobs()
                        if decryptEnabled { try? await API.clearDecryptJobs() }
                        await refresh()
                    }
                }
            }
            .refreshable { await refresh() }
            .overlay(alignment: .bottom) { ToastView(text: $toast) }
            .task {
                let status = try? await API.status()
                installEnabled = status?.install?.enabled == true
                decryptEnabled = status?.decrypt?.available == true
                showAccount = (status?.accounts?.count ?? 0) > 1
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
        if decryptEnabled {
            decryptJobs = (try? await API.decryptJobs()) ?? decryptJobs
        }
    }
}

struct JobRow: View {
    let job: Job
    let installEnabled: Bool
    let decryptEnabled: Bool
    let showAccount: Bool
    @Binding var toast: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(url: job.icon, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name ?? "")
                    + Text(job.displayVersion.map { "  \($0)" } ?? "").foregroundColor(.secondary)
                Text(statusText).font(.caption).foregroundColor(statusColor)
                if showAccount, let email = job.accountEmail {
                    Text("账号：\(email)").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
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
                if job.status == "done", let file = job.file {
                    HStack {
                        // 本站下载的文件都有 App Store 信息，系统安装也可用
                        InstallButton(name: file, systemAvailable: installEnabled, toast: $toast)
                        if decryptEnabled {
                            // 用下载它的 Apple ID 对应的凭证解密，进度在下面「解密」里
                            DecryptButton(name: file, toast: $toast)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
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
            var s = "完成"
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

/// 一个解密任务；完成后可以把解密后的文件存到手机 / 导出，证书签名，或用 TrollStore 安装
struct DecryptJobRow: View {
    let job: DecryptJob
    @Binding var toast: String?
    @ObservedObject private var phone = PhoneDownloads.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(url: job.icon, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.appName ?? job.name)
                    + Text(job.version.map { "  \($0)" } ?? "").foregroundColor(.secondary)
                Text(statusText).font(.caption).foregroundColor(statusColor)
                if let email = job.accountEmail {
                    Text("下载账号：\(email)").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                if job.status == "running" {
                    ProgressView().progressViewStyle(.linear)
                }
                if job.status == "done", let msg = job.message {
                    Text(msg).font(.caption2).foregroundColor(.secondary)
                }
                if let err = job.error {
                    Text(err).font(.caption2).foregroundColor(.red)
                }
                if job.status == "done", let file = job.file {
                    if let item = phone.active[file] {
                        PhoneProgressLine(item: item)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            SaveToPhoneButton(name: file, alistAvailable: false, phone: phone, toast: $toast)
                            // 存到手机以后可以导出：交给 TrollStore、存到「文件」、AirDrop 等
                            if let local = phone.localFiles.first(where: { $0.lastPathComponent == file }) {
                                ShareLink(item: local) {
                                    Label("导出", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        HStack {
                            // 解密后没有 Apple 的签名，不能系统安装：TrollStore 模式下会显示「TrollStore 安装」
                            InstallButton(name: file, systemAvailable: false, toast: $toast)
                            SignButton(name: file, source: "server", toast: $toast)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        let cred = job.used ?? job.credential.flatMap { $0 == "auto" ? nil : $0 } ?? "自动识别"
        switch job.status {
        case "queued":
            return "排队中 · \(cred)"
        case "running":
            return "解密中 · " + (job.log.flatMap { $0.isEmpty ? nil : $0 } ?? cred)
        case "done":
            var s = "完成 · \(cred)"
            if let a = job.startedAt, let b = job.finishedAt { s += " · 用时 \(Int(b - a)) 秒" }
            return s
        default:
            return "失败" + (job.used.map { " · \($0)" } ?? "")
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
