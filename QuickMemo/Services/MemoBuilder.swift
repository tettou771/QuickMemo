import Foundation

struct MemoBuilder {
    enum Source: String {
        case iphone = "iphone"
        case appleWatch = "apple-watch"
    }

    static func build(text: String, category: MemoCategory, source: Source) -> String {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let isoDate = formatter.string(from: now)

        return """
        ---
        tags: [\(category.rawValue)]
        created: \(isoDate)
        source: \(source.rawValue)
        ---

        #\(category.rawValue) \(text)
        """
    }
}
