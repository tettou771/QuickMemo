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

enum WatchWebDAVError: Error {
    /// 401: the server rejected the stored credentials
    case unauthorized
    /// 429: Nextcloud's brute-force protection is throttling this IP
    case throttled
    case badStatus(Int)

    /// Single out the two statuses that mean "stop retrying": repeating a
    /// rejected login only extends the throttle.
    static func from(status: Int) -> WatchWebDAVError {
        switch status {
        case 401: return .unauthorized
        case 429: return .throttled
        default: return .badStatus(status)
        }
    }
}

class WatchWebDAVService {
    static let shared = WatchWebDAVService()

    private let defaults = UserDefaults.standard

    var serverURL: String { defaults.string(forKey: "webdav_server") ?? "" }
    var username: String { defaults.string(forKey: "webdav_user") ?? "" }
    var password: String { defaults.string(forKey: "webdav_pass") ?? "" }
    var savePath: String { defaults.string(forKey: "webdav_path") ?? "/QuickMemo" }

    var isConfigured: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    func applyConfig(_ config: [String: Any]) {
        if let v = config["server"] as? String { defaults.set(v, forKey: "webdav_server") }
        if let v = config["user"] as? String { defaults.set(v, forKey: "webdav_user") }
        if let v = config["pass"] as? String { defaults.set(v, forKey: "webdav_pass") }
        if let v = config["path"] as? String { defaults.set(v, forKey: "webdav_path") }
    }

    // MARK: - Upload

    /// Upload a memo. `createdAt` is the moment the memo was composed, not the
    /// moment of upload, so a retried memo keeps its original timestamp and path.
    /// The filename is derived from it too, which makes a retry idempotent.
    func upload(_ memo: PendingMemo) async throws {
        guard isConfigured else { throw URLError(.userAuthenticationRequired) }

        let createdAt = memo.createdAt
        try await ensureDateDirectory(date: createdAt)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = formatter.string(from: createdAt) + ".md"

        let year = DateFormatter.yearFormatter.string(from: createdAt)
        let month = DateFormatter.monthFormatter.string(from: createdAt)
        let day = DateFormatter.dayFormatter.string(from: createdAt)
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = savePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/remote.php/dav/files/\(username)/\(path)/\(year)/\(month)/\(day)/\(filename)"

        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        let content = WatchMemoBuilder.build(
            text: memo.text,
            category: memo.memoCategory,
            source: .appleWatch,
            createdAt: createdAt,
            location: memo.location
        )
        let data = content.data(using: .utf8)!

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw WatchWebDAVError.from(status: status)
        }
    }

    // MARK: - Directory

    private func ensureDateDirectory(date: Date) async throws {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sp = savePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let year = DateFormatter.yearFormatter.string(from: date)
        let month = DateFormatter.monthFormatter.string(from: date)
        let day = DateFormatter.dayFormatter.string(from: date)

        let paths = [sp, "\(sp)/\(year)", "\(sp)/\(year)/\(month)", "\(sp)/\(year)/\(month)/\(day)"]
        for p in paths {
            let urlString = "\(base)/remote.php/dav/files/\(username)/\(p)"
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 201 = created, 405 = already exists — both fine. Stop at the first
            // 401/429 instead of sending the remaining levels and the PUT: each
            // request with bad credentials counts as another failed login.
            if status == 401 || status == 429 {
                throw WatchWebDAVError.from(status: status)
            }
        }
    }

    private func authHeader() -> String {
        let credentials = "\(username):\(password)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }
}

// MARK: - MemoBuilder for Watch

struct WatchMemoBuilder {
    enum Source: String {
        case appleWatch = "apple-watch"
    }

    static func build(
        text: String,
        category: MemoCategory,
        source: Source,
        createdAt: Date,
        location: CLLocation? = nil
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let isoDate = formatter.string(from: createdAt)

        var frontmatter = """
        ---
        tags: [\(category.rawValue)]
        created: \(isoDate)
        source: \(source.rawValue)
        """

        if let location {
            let lat = String(format: "%.6f", location.coordinate.latitude)
            let lon = String(format: "%.6f", location.coordinate.longitude)
            frontmatter += "\nlocation: [\(lat), \(lon)]"
        }

        frontmatter += "\n---"

        return """
        \(frontmatter)

        #\(category.rawValue) \(text)
        """
    }
}
