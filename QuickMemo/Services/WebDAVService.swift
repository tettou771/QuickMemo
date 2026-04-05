import Foundation

private extension DateFormatter {
    static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()
    static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM"
        return f
    }()
}

struct WebDAVConfig {
    var serverURL: String  // e.g. "https://cloud.example.com"
    var username: String
    var password: String   // app password
    var savePath: String   // e.g. "/QuickMemo"

    var isConfigured: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    // WebDAV endpoint: /remote.php/dav/files/<username>/<path>/<YYYY>/<MM>/<filename>
    func uploadURL(filename: String, date: Date = Date()) -> URL? {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = savePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let year = DateFormatter.yearFormatter.string(from: date)
        let month = DateFormatter.monthFormatter.string(from: date)
        let urlString = "\(base)/remote.php/dav/files/\(username)/\(path)/\(year)/\(month)/\(filename)"
        return URL(string: urlString)
    }

    // Date folder path: <savePath>/<YYYY>/<MM>
    func dateFolderPath(date: Date = Date()) -> String {
        let path = savePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let year = DateFormatter.yearFormatter.string(from: date)
        let month = DateFormatter.monthFormatter.string(from: date)
        return "\(path)/\(year)/\(month)"
    }
}

enum WebDAVError: LocalizedError {
    case notConfigured
    case invalidURL
    case uploadFailed(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "WebDAVが設定されていません"
        case .invalidURL: return "URLが不正です"
        case .uploadFailed(let code): return "アップロード失敗 (HTTP \(code))"
        case .networkError(let e): return "ネットワークエラー: \(e.localizedDescription)"
        }
    }
}

class WebDAVService {
    static let shared = WebDAVService()

    private let defaults = UserDefaults.standard

    var config: WebDAVConfig {
        get {
            WebDAVConfig(
                serverURL: defaults.string(forKey: "webdav_server") ?? "",
                username: defaults.string(forKey: "webdav_user") ?? "",
                password: defaults.string(forKey: "webdav_pass") ?? "",
                savePath: defaults.string(forKey: "webdav_path") ?? "/QuickMemo"
            )
        }
        set {
            defaults.set(newValue.serverURL, forKey: "webdav_server")
            defaults.set(newValue.username, forKey: "webdav_user")
            defaults.set(newValue.password, forKey: "webdav_pass")
            defaults.set(newValue.savePath, forKey: "webdav_path")
        }
    }

    var isConfigured: Bool { config.isConfigured }

    // MARK: - Upload

    func saveMemo(text: String, category: MemoCategory) async throws {
        let cfg = config
        guard cfg.isConfigured else { throw WebDAVError.notConfigured }

        let now = Date()

        // Ensure date directory exists (e.g. /QuickMemo/2026/04/)
        try await ensureDateDirectory(config: cfg, date: now)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let filename = formatter.string(from: now) + ".md"

        guard let url = cfg.uploadURL(filename: filename, date: now) else {
            throw WebDAVError.invalidURL
        }

        let content = MemoBuilder.build(text: text, category: category, source: .iphone)
        let data = content.data(using: .utf8)!

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(cfg), forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 201 Created or 204 No Content = success
            guard (200...299).contains(status) else {
                throw WebDAVError.uploadFailed(status)
            }
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    // MARK: - Directory

    private func ensureDateDirectory(config cfg: WebDAVConfig, date: Date) async throws {
        let base = cfg.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let savePath = cfg.savePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let year = DateFormatter.yearFormatter.string(from: date)
        let month = DateFormatter.monthFormatter.string(from: date)

        // Create each level: /QuickMemo, /QuickMemo/2026, /QuickMemo/2026/04
        let paths = [savePath, "\(savePath)/\(year)", "\(savePath)/\(year)/\(month)"]
        for path in paths {
            let urlString = "\(base)/remote.php/dav/files/\(cfg.username)/\(path)"
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            request.setValue(authHeader(cfg), forHTTPHeaderField: "Authorization")

            // 201 = created, 405 = already exists — both OK
            let (_, _) = try await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Auth

    private func authHeader(_ cfg: WebDAVConfig) -> String {
        let credentials = "\(cfg.username):\(cfg.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
