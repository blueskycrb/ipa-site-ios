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
            .filter { ["ipa", "tipa", "pkg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 把「文件」App 或其他 App（微信、Safari 下载…）里的 IPA 复制进来，显示在「手机上的文件」里。
    /// 文件可能很大，在后台线程调用。返回复制后的位置。
    static func importFile(_ url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        guard ext == "ipa" || ext == "tipa" else {
            throw APIError(message: "\(url.lastPathComponent) 不是 IPA 文件")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            return url   // 本来就在这里
        }
        let stem = url.deletingPathExtension().lastPathComponent
        var dest = folder.appendingPathComponent(url.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            n += 1
            dest = folder.appendingPathComponent("\(stem)_\(n).\(url.pathExtension)")
        }
        // 别的 App「用其他应用打开」时，系统先把文件放在 Documents/Inbox，搬出来就行
        if url.path.contains("/Documents/Inbox/") {
            try fm.moveItem(at: url, to: dest)
        } else {
            try fm.copyItem(at: url, to: dest)
        }
        return dest
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
