import Foundation

/// 检查 GitHub 上的最新 Release（公开仓库，不需要登录），有新版时交给 TrollStore 安装
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "blueskycrb/ipa-site-ios"

    struct Release {
        let version: String
        let build: Int
        let notes: String
        let ipaURL: URL
        let pageURL: URL
    }

    @Published var latest: Release?
    @Published var checking = false
    @Published var error: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    var hasUpdate: Bool {
        (latest?.build ?? 0) > currentBuild
    }

    /// TrollStore 的「从链接安装」：apple-magnifier://install?url=…
    var trollStoreURL: URL? {
        guard let ipa = latest?.ipaURL.absoluteString,
              let encoded = ipa.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "apple-magnifier://install?url=" + encoded)
    }

    private struct GHAsset: Decodable {
        let name: String
        let browser_download_url: String
    }

    private struct GHRelease: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String
        let assets: [GHAsset]
    }

    func check() async {
        await MainActor.run {
            checking = true
            error = nil
        }
        var found: Release?
        var failure: String?
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!,
                                 timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw APIError(message: "GitHub 返回 HTTP \(code)") }
            let r = try JSONDecoder().decode(GHRelease.self, from: data)
            // tag 形如 v1.3.0-b12：版本号 1.3.0，编译号 12
            let parts = r.tag_name.dropFirst().components(separatedBy: "-b")
            guard parts.count == 2, let build = Int(parts[1]),
                  let asset = r.assets.first(where: { $0.name.hasSuffix(".ipa") }),
                  let ipa = URL(string: asset.browser_download_url),
                  let page = URL(string: r.html_url) else {
                throw APIError(message: "最新 Release 的格式不对（\(r.tag_name)）")
            }
            found = Release(version: parts[0], build: build, notes: r.body ?? "", ipaURL: ipa, pageURL: page)
        } catch {
            failure = "检查更新失败：\(error.localizedDescription)"
        }
        let result = found, message = failure
        await MainActor.run {
            if let result { latest = result }
            self.error = message
            checking = false
        }
    }
}
