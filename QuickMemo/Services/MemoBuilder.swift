import Foundation
import CoreLocation

struct MemoBuilder {
    enum Source: String {
        case iphone = "iphone"
        case appleWatch = "apple-watch"
    }

    static func build(text: String, category: MemoCategory, source: Source, location: CLLocation? = nil) -> String {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let isoDate = formatter.string(from: now)

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
