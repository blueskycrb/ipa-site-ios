import Foundation

// 与服务器上 ipa-site（server.py）的 HTTP 接口对应

enum Keys {
    static let server = "serverURL"
    static let sitePassword = "sitePassword"
    static let autoPurchase = "autoPurchase"
    static let country = "country"
    static let platform = "platform"
    static let installMode = "installMode"   // "trollstore" 或 "system"
    static let defaultServer = ""   // 首次使用在「设置」里填写
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 数据模型

struct Account: Decodable {
    let email: String?
    let name: String?
}

struct AlistInfo: Decodable {
    let enabled: Bool
    let dir: String?
    let auto: Bool?
}

struct InstallInfo: Decodable {
    let enabled: Bool
    let publicURL: String?
}

/// 服务器上登录过的一个 Apple ID
struct AccountEntry: Decodable, Identifiable {
    let id: String
    let email: String
    let name: String?
    let current: Bool
}

struct ServerStatus: Decodable {
    let ok: Bool
    let ipatool: String?
    let version: String?
    let account: Account?              // 当前账号（登录失效时为空）
    let accounts: [AccountEntry]?      // 所有账号（旧版服务器没有）
    let currentAccount: String?
    let alist: AlistInfo?
    let install: InstallInfo?
}

struct AppItem: Decodable, Identifiable, Hashable {
    let appID: Int?
    let bundleID: String?
    let name: String?
    let version: String?
    let price: Double?
    let icon: String?
    let seller: String?
    let size: Int?
    let formattedPrice: String?
    let genre: String?

    var id: String { bundleID ?? String(appID ?? 0) }

    enum CodingKeys: String, CodingKey {
        case appID = "id", bundleID, name, version, price, icon, seller, size, formattedPrice, genre
    }
}

struct Job: Decodable, Identifiable {
    let id: String
    let status: String
    let name: String?
    let icon: String?
    let size: Double?
    let downloaded: Double?
    let speed: Double?
    let error: String?
    let note: String?
    let file: String?
    let displayVersion: String?
    let startedAt: Double?
    let finishedAt: Double?
    let purchased: Bool?
    let accountEmail: String?
}

struct UploadRecord: Decodable {
    let status: String
    let sent: Double?
    let size: Double?
    let remote: String?
    let error: String?
}

/// 服务器记录的文件对应的 App 信息（旧版服务器没有这个字段）
struct FileApp: Decodable {
    let name: String?
    let version: String?
    let icon: String?
    let bundleID: String?
}

struct RemoteFile: Decodable, Identifiable {
    let name: String
    let size: Double
    let mtime: Double
    let alist: UploadRecord?
    let app: FileApp?
    var id: String { name }
}

struct Envelope: Decodable {
    let ok: Bool?
    let error: String?
}

struct LoginResponse: Decodable {
    let ok: Bool
    let error: String?
    let needCode: Bool?
    let restart: Bool?
    let account: Account?
}

struct VersionMeta: Decodable {
    let ok: Bool
    let displayVersion: String?
    let releaseDate: String?
}

struct AlistItem: Decodable, Identifiable {
    let name: String
    let size: Double?
    let modified: String?
    let app: FileApp?
    var id: String { name }
}

struct AlistPage: Decodable {
    let total: Int
    let items: [AlistItem]
    let dir: String?
}

/// 服务器上保存的签名证书（不含密码）
struct CertInfo: Decodable, Identifiable {
    let id: String
    let label: String?
    let cn: String?
    let certExpires: Double?
    let profileExpires: Double?
    let allDevices: Bool?
    let devices: Int?
    let matchesProfile: Bool?
    let profileName: String?
    let appID: String?
    let teamID: String?

    /// 证书和描述文件里先到期的那个时间
    var expires: Double? {
        [certExpires, profileExpires].compactMap { $0 }.min()
    }

    var isExpired: Bool { (expires ?? .infinity) < Date().timeIntervalSince1970 }
}

/// 服务器上用证书签好的 App
struct SignedItem: Decodable, Identifiable {
    let key: String
    let appName: String?
    let version: String?
    let bundleID: String?
    let sourceName: String?
    let size: Double?
    let icon: String?
    let certLabel: String?
    let certDeleted: Bool?
    let certExpires: Double?
    let teamID: String?
    let installURL: String?
    let trollstoreURL: String?

    var id: String { key }

    /// 签它的证书已经过期或被删除，装不上了
    var isDead: Bool {
        certDeleted == true || (certExpires ?? .infinity) < Date().timeIntervalSince1970
    }
}

private struct SignedResponse: Decodable { let items: [SignedItem] }
private struct UploadResponse: Decodable { let ok: Bool?; let error: String?; let name: String? }

/// 上传进度：URLSession 在后台线程回调
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void

    init(_ onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }
}

struct CertsResponse: Decodable {
    let zsign: Bool?
    let installEnabled: Bool?
    let certs: [CertInfo]
}

/// 导入证书时每个 p12 的结果
struct ImportResult: Decodable, Identifiable {
    let id = UUID()
    let file: String
    let ok: Bool
    let error: String?
    let cert: CertInfo?

    enum CodingKeys: String, CodingKey { case file, ok, error, cert }
}

private struct ImportResponse: Decodable {
    let ok: Bool?
    let error: String?
    let results: [ImportResult]?
}

/// 证书签名任务
struct SignJob: Decodable, Identifiable {
    let id: String
    let status: String          // queued / downloading / signing / done / error
    let name: String
    let downloaded: Double?
    let size: Double?
    let error: String?
    let appName: String?
    let version: String?
    let installURL: String?
    let trollstoreURL: String?
    let downloadURL: String?
}

private struct SignJobResponse: Decodable { let job: SignJob }
private struct SignJobsResponse: Decodable { let jobs: [SignJob] }
private struct LinkResponse: Decodable { let url: String?; let size: Double? }
private struct InstallResponse: Decodable { let ok: Bool; let url: String?; let source: String?; let error: String? }
private struct SearchResponse: Decodable { let apps: [AppItem]? }
/// 某个版本 ID 对应的版本号和发布日期
struct VersionInfo: Decodable {
    let displayVersion: String?
    let releaseDate: String?
}

private struct VersionsResponse: Decodable {
    let versions: [String]?
    let meta: [String: VersionInfo]?   // 服务器已经查过的版本（旧版服务器没有这个字段）
}
private struct JobsResponse: Decodable { let jobs: [Job]? }
private struct FilesResponse: Decodable { let files: [RemoteFile]? }

// MARK: - 请求

enum API {
    static var base: String {
        var s = (UserDefaults.standard.string(forKey: Keys.server) ?? Keys.defaultServer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty && !s.contains("://") { s = "http://" + s }
        return s
    }

    static func url(_ path: String, _ query: [String: String] = [:]) throws -> URL {
        if base.isEmpty { throw APIError(message: "请先在「设置」里填写服务器地址") }
        guard var comps = URLComponents(string: base + path) else {
            throw APIError(message: "服务器地址无效：\(base)")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let u = comps.url else { throw APIError(message: "服务器地址无效：\(base)") }
        return u
    }

    /// 网站设置了访问密码时，带上 HTTP Basic 认证（用户名随意）
    static func authorize(_ req: inout URLRequest) {
        if let pw = UserDefaults.standard.string(forKey: Keys.sitePassword), !pw.isEmpty {
            let token = Data("ios:\(pw)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    static func request(_ path: String, query: [String: String] = [:], method: String = "GET",
                        body: [String: Any]? = nil, timeout: TimeInterval = 60) throws -> URLRequest {
        var req = URLRequest(url: try url(path, query), timeoutInterval: timeout)
        req.httpMethod = method
        authorize(&req)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    static func send<T: Decodable>(_ type: T.Type, _ req: URLRequest, allowNotOK: Bool = false) async throws -> T {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError(message: "连不上服务器 \(base)：\(error.localizedDescription)")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError(message: "网站需要访问密码，请在「设置」里填写") }
        if !allowNotOK, let env = try? JSONDecoder().decode(Envelope.self, from: data), env.ok == false {
            throw APIError(message: env.error ?? "请求失败（HTTP \(code)）")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError(message: "服务器返回的内容无法识别（HTTP \(code)）")
        }
    }

    static func status() async throws -> ServerStatus {
        try await send(ServerStatus.self, request("/api/status", timeout: 40))
    }

    static func login(email: String, password: String, code: String) async throws -> LoginResponse {
        let body = ["email": email, "password": password, "code": code]
        // 首次登录 ipatool 要准备几分钟，服务器最多等 300 秒
        return try await send(LoginResponse.self, request("/api/login", method: "POST", body: body, timeout: 330),
                              allowNotOK: true)
    }

    /// 退出并移除一个账号（id 为空时是当前账号），其他账号不受影响
    static func logout(_ id: String? = nil) async throws {
        _ = try await send(Envelope.self, request("/api/logout", method: "POST", body: id.map { ["id": $0] } ?? [:]))
    }

    /// 切换当前账号：之后的搜索、下载都用这个账号
    static func switchAccount(_ id: String) async throws {
        _ = try await send(Envelope.self, request("/api/accounts/switch", method: "POST", body: ["id": id]))
    }

    static func search(_ q: String, platform: String, country: String, limit: Int = 20) async throws -> [AppItem] {
        let query = ["q": q, "limit": String(limit), "platform": platform, "country": country]
        return try await send(SearchResponse.self, request("/api/search", query: query)).apps ?? []
    }

    /// 返回版本 ID 列表（最新在前）和服务器已缓存的版本信息
    static func versions(_ app: AppItem) async throws -> ([String], [String: VersionInfo]) {
        let query = ["bundle": app.bundleID ?? "", "id": String(app.appID ?? 0)]
        let r = try await send(VersionsResponse.self, request("/api/versions", query: query, timeout: 120))
        return (r.versions ?? [], r.meta ?? [:])
    }

    static func versionMeta(_ app: AppItem, versionID: String) async throws -> VersionMeta {
        let query = ["bundle": app.bundleID ?? "", "id": String(app.appID ?? 0), "vid": versionID]
        // 服务器最多等 Apple 180 秒，再加上排队时间
        return try await send(VersionMeta.self, request("/api/version-meta", query: query, timeout: 300))
    }

    static func download(_ app: AppItem, versionID: String? = nil, displayVersion: String? = nil) async throws {
        let d = UserDefaults.standard
        var body: [String: Any] = [
            "bundleID": app.bundleID ?? "",
            "appID": app.appID ?? 0,
            "name": app.name ?? app.bundleID ?? "",
            "purchase": d.object(forKey: Keys.autoPurchase) as? Bool ?? true,
            "platform": d.string(forKey: Keys.platform) ?? "",
            "country": d.string(forKey: Keys.country) ?? "cn",
        ]
        if let icon = app.icon { body["icon"] = icon }
        if let size = app.size { body["size"] = size }
        if let versionID { body["versionID"] = versionID }
        if let displayVersion { body["displayVersion"] = displayVersion }
        _ = try await send(Envelope.self, request("/api/download", method: "POST", body: body))
    }

    static func jobs() async throws -> [Job] {
        try await send(JobsResponse.self, request("/api/jobs")).jobs ?? []
    }

    static func clearJobs() async throws {
        _ = try await send(Envelope.self, request("/api/jobs/clear", method: "POST", body: [:]))
    }

    static func files() async throws -> [RemoteFile] {
        try await send(FilesResponse.self, request("/api/files")).files ?? []
    }

    static func deleteFile(_ name: String) async throws {
        _ = try await send(Envelope.self, request("/api/files/" + encode(name), method: "DELETE"))
    }

    static func uploadToAlist(_ name: String) async throws {
        _ = try await send(Envelope.self, request("/api/alist/upload", method: "POST", body: ["name": name]))
    }

    static func fileURL(_ name: String) throws -> URL {
        try url("/files/" + encode(name))
    }

    static func alistList(query: String, offset: Int, limit: Int = 50, refresh: Bool = false) async throws -> AlistPage {
        var q = ["q": query, "offset": String(offset), "limit": String(limit)]
        if refresh { q["refresh"] = "1" }
        // 刷新时 Alist 要重新读网盘目录，几千个文件可能要半分钟以上
        return try await send(AlistPage.self, request("/api/alist/list", query: q, timeout: refresh ? 180 : 90))
    }

    /// 网盘直链（有时效），手机直接从网盘下载，不经过家里的上行带宽
    static func alistLink(_ name: String) async throws -> URL {
        let r = try await send(LinkResponse.self, request("/api/alist/link", query: ["name": name], timeout: 60))
        guard let s = r.url, let u = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            throw APIError(message: "Alist 没有返回可用的下载链接")
        }
        return u
    }

    static func certs() async throws -> CertsResponse {
        try await send(CertsResponse.self, request("/api/certs"))
    }

    /// 导入证书：files 可以是证书 zip 包，也可以是 p12 + 描述文件；密码留空时服务器会从压缩包里的 txt 找
    static func importCerts(_ files: [(name: String, data: Data)], password: String, label: String) async throws -> [ImportResult] {
        let body: [String: Any] = [
            "password": password,
            "label": label,
            "files": files.map { ["name": $0.name, "data": $0.data.base64EncodedString()] },
        ]
        let r = try await send(ImportResponse.self, request("/api/certs/import", method: "POST", body: body, timeout: 120),
                               allowNotOK: true)
        if let results = r.results, !results.isEmpty { return results }
        if r.error == "Not found" { throw APIError(message: "服务器版本太旧，不支持导入证书，请先更新服务器") }
        throw APIError(message: r.error ?? "导入失败")
    }

    /// 删除证书，用它签好的文件也会一起删除
    static func deleteCert(_ id: String) async throws {
        _ = try await send(Envelope.self, request("/api/certs/" + encode(id), method: "DELETE"))
    }

    /// 用证书签名一个 IPA；source 为 alist 或 server
    static func sign(source: String, name: String, cert: String) async throws -> SignJob {
        let body = ["source": source, "name": name, "cert": cert]
        return try await send(SignJobResponse.self, request("/api/sign", method: "POST", body: body)).job
    }

    static func signJobs() async throws -> [SignJob] {
        try await send(SignJobsResponse.self, request("/api/sign/jobs")).jobs
    }

    /// 签好的 App（最新在前）
    static func signed() async throws -> [SignedItem] {
        try await send(SignedResponse.self, request("/api/signed")).items
    }

    /// 换一个证书重签已经签好的 App
    static func resign(key: String, cert: String) async throws -> SignJob {
        let body = ["key": key, "cert": cert]
        return try await send(SignJobResponse.self, request("/api/signed/resign", method: "POST", body: body)).job
    }

    static func deleteSigned(_ key: String) async throws {
        _ = try await send(Envelope.self, request("/api/signed/" + encode(key), method: "DELETE"))
    }

    /// 把手机上的 IPA 传到服务器文件里（之后可以签名），返回服务器上的文件名；progress 在后台线程回调 0~1
    static func uploadIPA(_ file: URL, progress: @escaping (Double) -> Void) async throws -> String {
        var req = try request("/api/upload", query: ["name": file.lastPathComponent], method: "PUT", timeout: 600)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.upload(for: req, fromFile: file,
                                                               delegate: UploadProgressDelegate(progress))
        } catch {
            throw APIError(message: "上传到服务器失败：\(error.localizedDescription)")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError(message: "网站需要访问密码，请在「设置」里填写") }
        let r = try? JSONDecoder().decode(UploadResponse.self, from: data)
        guard r?.ok == true, let name = r?.name else {
            if r?.error == "Not found" { throw APIError(message: "服务器版本太旧，不支持上传 IPA，请先更新服务器") }
            throw APIError(message: r?.error ?? "上传失败（HTTP \(code)）")
        }
        return name
    }

    /// 返回安装链接：mode 为 trollstore 时是 apple-magnifier://install?url=…，否则是 itms-services://
    /// source 为 auto / server / alist（auto 时 Alist 里有就走网盘直链）
    static func installURL(_ name: String, mode: String, source: String = "auto") async throws -> (URL, String) {
        let query = ["name": name, "source": source, "mode": mode == "trollstore" ? "trollstore" : "itms"]
        let r = try await send(InstallResponse.self, request("/api/install", query: query, timeout: 60), allowNotOK: true)
        guard r.ok, let s = r.url, let u = URL(string: s) else {
            throw APIError(message: r.error ?? "生成安装链接失败")
        }
        return (u, r.source ?? source)
    }

    private static func encode(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }
}

func fmtSize(_ n: Double?) -> String {
    guard let n else { return "" }
    if n >= 1_073_741_824 { return String(format: "%.2f GB", n / 1_073_741_824) }
    return String(format: "%.1f MB", n / 1_048_576)
}

func fmtSize(_ n: Int?) -> String {
    fmtSize(n.map { Double($0) })
}
