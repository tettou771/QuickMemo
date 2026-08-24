import Foundation
import CoreLocation

/// A memo that was composed but could not be uploaded yet.
/// Everything that describes *when and where the memo was taken* is captured
/// at compose time and replayed verbatim on a later upload attempt.
struct PendingMemo: Codable, Identifiable {
    let id: UUID
    let text: String
    let category: String
    let createdAt: Date
    let latitude: Double?
    let longitude: Double?

    init(text: String, category: MemoCategory, createdAt: Date, location: CLLocation?) {
        self.id = UUID()
        self.text = text
        self.category = category.rawValue
        self.createdAt = createdAt
        self.latitude = location?.coordinate.latitude
        self.longitude = location?.coordinate.longitude
    }

    var memoCategory: MemoCategory { MemoCategory(rawValue: category) ?? .diary }

    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

/// Persistent FIFO queue of memos waiting to be uploaded.
actor PendingMemoStore {
    static let shared = PendingMemoStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "pending_memos"
    /// Safety valve so a long offline stretch cannot grow the queue without bound
    private let maxCount = 200

    private var flushing = false

    // MARK: - Storage

    private func load() -> [PendingMemo] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([PendingMemo].self, from: data)) ?? []
    }

    private func store(_ memos: [PendingMemo]) {
        guard let data = try? JSONEncoder().encode(memos) else { return }
        defaults.set(data, forKey: storageKey)
    }

    var count: Int { load().count }

    func enqueue(_ memo: PendingMemo) {
        var memos = load()
        memos.append(memo)
        if memos.count > maxCount {
            memos.removeFirst(memos.count - maxCount)
        }
        store(memos)
    }

    // MARK: - Flush

    /// Try to upload everything queued. Stops at the first failure and keeps the
    /// remainder for the next attempt, so ordering and retries stay simple.
    /// - Returns: number of memos successfully uploaded.
    @discardableResult
    func flush() async -> Int {
        guard !flushing else { return 0 }
        guard WatchWebDAVService.shared.isConfigured else { return 0 }

        flushing = true
        defer { flushing = false }

        var memos = load()
        var sent = 0

        while let memo = memos.first {
            do {
                try await WatchWebDAVService.shared.upload(memo)
                memos.removeFirst()
                store(memos)
                sent += 1
            } catch {
                break
            }
        }

        return sent
    }
}
