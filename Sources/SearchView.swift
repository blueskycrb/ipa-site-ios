import SwiftUI

struct SearchView: View {
    @AppStorage(Keys.platform) private var platform = ""
    @AppStorage(Keys.country) private var country = "cn"
    @State private var query = ""
    @State private var apps: [AppItem] = []
    @State private var loading = false
    @State private var message: String?
    @State private var versionsFor: AppItem?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("平台", selection: $platform) {
                        Text("iPhone").tag("")
                        Text("iPad").tag("ipad")
                        Text("macOS").tag("macos")
                        Text("Apple TV").tag("appletv")
                        Text("watchOS").tag("watchos")
                        Text("visionOS").tag("visionos")
                    }
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("搜索中…").foregroundColor(.secondary)
                    }
                }
                if let message {
                    Text(message).foregroundColor(.red)
                }
                ForEach(apps) { app in
                    AppRow(app: app,
                           onDownload: { Task { await download(app) } },
                           onVersions: { versionsFor = app })
                }
            }
            .navigationTitle("搜索 App")
            .searchable(text: $query, prompt: "App 名称，例如：微信")
            .onSubmit(of: .search) { Task { await search() } }
            .sheet(item: $versionsFor) { app in VersionsView(app: app) }
            .overlay(alignment: .bottom) { ToastView(text: $toast) }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true
        message = nil
        do {
            apps = try await API.search(q, platform: platform, country: country)
            if apps.isEmpty { message = "没有找到相关 App" }
        } catch {
            apps = []
            message = error.localizedDescription
        }
        loading = false
    }

    private func download(_ app: AppItem) async {
        do {
            try await API.download(app)
            toast = "已加入下载队列：\(app.name ?? "")"
        } catch {
            toast = error.localizedDescription
        }
    }
}

struct AppRow: View {
    let app: AppItem
    var onDownload: () -> Void
    var onVersions: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(url: app.icon, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name ?? "").font(.headline).lineLimit(1)
                Text(app.seller ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundColor(.secondary)
                HStack {
                    Button("下载最新版", action: onDownload).buttonStyle(.borderedProminent)
                    Button("历史版本", action: onVersions).buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = ["v\(app.version ?? "?")"]
        parts.append((app.price ?? 0) > 0 ? (app.formattedPrice ?? "付费") : "免费")
        if app.size != nil { parts.append(fmtSize(app.size)) }
        return parts.joined(separator: " · ")
    }
}
