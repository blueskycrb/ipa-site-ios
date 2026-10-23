import SwiftUI

@main
struct IPASiteApp: App {
    var body: some Scene {
        WindowGroup {
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
        }
    }
}
