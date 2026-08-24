import Foundation
import CoreLocation

struct MemoBuilder {
    enum Source: String {
        case iphone = "iphone"
        case appleWatch = "apple-watch"
    }

    /// `createdAt` is passed in rather than sampled here so that `created:` and
    /// the filename, which is derived from the same instant, cannot disagree.
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
