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

    var body: some View {
        TabView {
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            JobsView()
                .tabItem { Label("任务", systemImage: "arrow.down.circle") }
            FilesView()
                .tabItem { Label("文件", systemImage: "folder") }
            AlistView()
                .tabItem { Label("Alist", systemImage: "cloud") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
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
