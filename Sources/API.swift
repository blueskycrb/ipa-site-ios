import Foundation

// 与服务器上 ipa-site（server.py）的 HTTP 接口对应

enum Keys {
    static let server = "serverURL"
    static let sitePassword = "sitePassword"
    static let autoPurchase = "autoPurchase"
    static let country = "country"
    static let platform = "platform"
    static let installMode = "installMode"   // "trollstore" 或 "system"
    static let defaultServer = "http://192.168.10.136:8686"
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

struct ServerStatus: Decodable {
    let ok: Bool
    let ipatool: String?
    let version: String?
    let account: Account?
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

private struct LinkResponse: Decodable { let url: String?; let size: Double? }
private struct InstallResponse: Decodable { let ok: Bool; let url: String?; let source: String?; let error: String? }
private struct SearchResponse: Decodable { let apps: [AppItem]? }
private struct VersionsResponse: Decodable { let versions: [String]? }
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

    static func logout() async throws {
        _ = try await send(Envelope.self, request("/api/logout", method: "POST", body: [:]))
    }

    static func search(_ q: String, platform: String, country: String, limit: Int = 20) async throws -> [AppItem] {
        let query = ["q": q, "limit": String(limit), "platform": platform, "country": country]
        return try await send(SearchResponse.self, request("/api/search", query: query)).apps ?? []
    }

    static func versions(_ app: AppItem) async throws -> [String] {
        let query = ["bundle": app.bundleID ?? "", "id": String(app.appID ?? 0)]
        return try await send(VersionsResponse.self, request("/api/versions", query: query, timeout: 120)).versions ?? []
    }

    static func versionMeta(_ app: AppItem, versionID: String) async throws -> VersionMeta {
        let query = ["bundle": app.bundleID ?? "", "id": String(app.appID ?? 0), "vid": versionID]
        return try await send(VersionMeta.self, request("/api/version-meta", query: query, timeout: 120))
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
