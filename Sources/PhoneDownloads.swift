import Foundation

/// 把服务器上的 IPA 下载到手机的「文稿」目录（在「文件」App 里可见）
final class PhoneDownloads: NSObject, ObservableObject {
    static let shared = PhoneDownloads()

    struct Item {
        var received: Int64 = 0
        var total: Int64 = 0
        var error: String?
        var done = false
        var viaAlist = false
    }

    @Published var active: [String: Item] = [:]
    @Published var localFiles: [URL] = []

    private var session: URLSession!
    private var names: [Int: String] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        localFiles = urls
            .filter { ["ipa", "pkg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func isRunning(_ name: String) -> Bool {
        guard let item = active[name] else { return false }
        return !item.done && item.error == nil
    }

    /// remote 为空时从服务器下载；传入网盘直链时直接从网盘下载
    func start(_ name: String, from remote: URL? = nil) {
        guard !isRunning(name) else { return }
        do {
            var req: URLRequest
            if let remote {
                req = URLRequest(url: remote)   // 直链自带签名，不能再加网站密码的认证头
            } else {
                req = URLRequest(url: try API.fileURL(name))
                API.authorize(&req)
            }
            let task = session.downloadTask(with: req)
            names[task.taskIdentifier] = name
            active[name] = Item(viaAlist: remote != nil)
            task.resume()
        } catch {
            active[name] = Item(error: error.localizedDescription)
        }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        active[url.lastPathComponent] = nil
        refresh()
    }

    static func size(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}

extension PhoneDownloads: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let name = names[downloadTask.taskIdentifier] else { return }
        active[name]?.received = totalBytesWritten
        active[name]?.total = totalBytesExpectedToWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = names[downloadTask.taskIdentifier] else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            active[name]?.error = code == 401 ? "需要网站访问密码" : "下载失败（HTTP \(code)）"
            return
        }
        let dest = Self.folder.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            active[name]?.done = true
            refresh()
        } catch {
            active[name]?.error = error.localizedDescription
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let name = names.removeValue(forKey: task.taskIdentifier) else { return }
        if let error { active[name]?.error = error.localizedDescription }
    }
}
