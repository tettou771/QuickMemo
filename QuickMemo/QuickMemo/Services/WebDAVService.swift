import Foundation
import CoreLocation

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
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd"
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

    // WebDAV endpoint: /remote.php/dav/files/<username>/<path>/<YYYY>/<MM>/<DD>/<filename>
    func uploadURL(filename: String, date: Date = Date()) -> URL? {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = savePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let year = DateFormatter.yearFormatter.string(from: date)
        let month = DateFormatter.monthFormatter.string(from: date)
        let day = DateFormatter.dayFormatter.string(from: date)
        let urlString = "\(base)/remote.php/dav/files/\(username)/\(path)/\(year)/\(month)/\(day)/\(filename)"
        return URL(string: urlString)
    }
}

enum WebDAVError: LocalizedError {
    case notConfigured
    case invalidURL
    case uploadFailed(Int)
    case networkError(Error)
    /// 401: the server rejected the stored credentials
    case unauthorized
    /// 429: Nextcloud's brute-force protection is throttling this IP
    case throttled

    /// Map a non-success HTTP status to an error, singling out the two that mean
    /// "stop retrying": repeating a rejected login only extends the throttle.
    static func from(status: Int) -> WebDAVError {
        switch status {
        case 401: return .unauthorized
        case 429: return .throttled
        default: return .uploadFailed(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "WebDAVが設定されていません"
        case .invalidURL: return "URLが不正です"
        case .uploadFailed(let code): return "アップロード失敗 (HTTP \(code))"
        case .networkError(let e): return "ネットワークエラー: \(e.localizedDescription)"
        case .unauthorized: return "認証エラー (HTTP 401)"
        case .throttled: return "サーバが一時的に受け付けていません (HTTP 429)"
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

    /// Upload a memo. `createdAt` is the moment the memo was composed, not the
    /// moment of upload, so a retried memo keeps its original timestamp and path.
    /// The filename is derived from it too, which makes a retry idempotent.
    func upload(_ memo: PendingMemo) async throws {
        let cfg = config
        guard cfg.isConfigured else { throw WebDAVError.notConfigured }

        let createdAt = memo.createdAt

        // Ensure date directory exists (e.g. /QuickMemo/2026/04/)
        try await ensureDateDirectory(config: cfg, date: createdAt)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = formatter.string(from: createdAt) + ".md"

        guard let url = cfg.uploadURL(filename: filename, date: createdAt) else {
            throw WebDAVError.invalidURL
        }

        let content = MemoBuilder.build(
            text: memo.text,
            category: memo.memoCategory,
            source: .iphone,
            createdAt: createdAt,
            location: memo.location
        )
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
                throw WebDAVError.from(status: status)
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
        let day = DateFormatter.dayFormatter.string(from: date)

        // Create each level: /QuickMemo, /QuickMemo/2026, /QuickMemo/2026/04, /QuickMemo/2026/04/06
        let paths = [savePath, "\(savePath)/\(year)", "\(savePath)/\(year)/\(month)", "\(savePath)/\(year)/\(month)/\(day)"]
        for path in paths {
            let urlString = "\(base)/remote.php/dav/files/\(cfg.username)/\(path)"
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            request.setValue(authHeader(cfg), forHTTPHeaderField: "Authorization")

            let status: Int
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                throw WebDAVError.networkError(error)
            }

            // 201 = created, 405 = already exists — both fine. Stop at the first
            // 401/429 instead of sending the remaining levels and the PUT: each
            // request with bad credentials counts as another failed login.
            if status == 401 || status == 429 {
                throw WebDAVError.from(status: status)
            }
        }
    }

    // MARK: - Auth

    private func authHeader(_ cfg: WebDAVConfig) -> String {
        let credentials = "\(cfg.username):\(cfg.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
