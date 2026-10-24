import SwiftUI

@main
struct IPASiteApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @ObservedObject private var updater = Updater.shared
    @Environment(\.openURL) private var openURL
    @State private var showUpdate = false
    @State private var tab = "search"
    @State private var opened: String?

    var body: some View {
        TabView(selection: $tab) {
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag("search")
            JobsView()
                .tabItem { Label("任务", systemImage: "arrow.down.circle") }
                .tag("jobs")
            FilesView()
                .tabItem { Label("文件", systemImage: "folder") }
                .tag("files")
            AlistView()
                .tabItem { Label("Alist", systemImage: "cloud") }
                .tag("alist")
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag("settings")
        }
        .onOpenURL { url in
            // 别的 App「用其他应用打开」传来的 IPA：放进「手机上的文件」，切到「文件」页
            guard url.isFileURL else { return }
            Task {
                do {
                    let dest = try await Task.detached { try PhoneDownloads.importFile(url) }.value
                    PhoneDownloads.shared.refresh()
                    tab = "files"
                    opened = "已导入 \(dest.lastPathComponent)，在「文件」页「手机上的文件」里点「证书签名」，签好后会弹出安装。"
                } catch {
                    opened = "导入失败：\(error.localizedDescription)"
                }
            }
        }
        .alert("导入 IPA", isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(opened ?? "")
        }
        .task {
            // 启动时悄悄检查一次更新，有新版才提示
            await updater.check()
            showUpdate = updater.hasUpdate
        }
        .alert("发现新版本", isPresented: $showUpdate) {
            Button("用 TrollStore 安装") {
                if let url = updater.trollStoreURL { openURL(url) }
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("\(updater.latest?.version ?? "")（\(updater.latest?.build ?? 0)），当前 \(updater.currentVersion)（\(updater.currentBuild)）\n\(updater.latest?.notes.components(separatedBy: "\n").first ?? "")")
        }
    }
}
