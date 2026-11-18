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

/// Why automatic uploads are paused.
///
/// Retrying with credentials the server has already rejected only feeds
/// Nextcloud's brute-force protection, which then throttles the whole IP with
/// HTTP 429 (this happened in Nov 2026 after the app password stopped working).
/// So after a 401 we stay quiet until new settings arrive from the iPhone, and
/// after a 429 until a cooldown passes.
enum UploadBlock: String {
    case unauthorized
    case throttled
}

/// Persistent FIFO queue of memos waiting to be uploaded.
actor PendingMemoStore {
    static let shared = PendingMemoStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "pending_memos"
    /// Safety valve so a long offline stretch cannot grow the queue without bound
    private let maxCount = 200

    private var flushing = false

    private let blockKey = "pending_memos_block"
    private let blockUntilKey = "pending_memos_block_until"
    /// How long to stay quiet after a 429 before trying again on our own
    private let throttleCooldown: TimeInterval = 30 * 60

    // MARK: - Block state

    /// The reason uploads are currently paused, or nil when they may go ahead.
    /// A throttle block expires on its own; an auth block lasts until cleared.
    func currentBlock() -> UploadBlock? {
        guard let raw = defaults.string(forKey: blockKey),
              let block = UploadBlock(rawValue: raw) else { return nil }
        if block == .throttled,
           Date().timeIntervalSince1970 >= defaults.double(forKey: blockUntilKey) {
            clearBlock()
            return nil
        }
        return block
    }

    /// Call when new credentials arrive, or once an upload succeeds.
    func clearBlock() {
        defaults.removeObject(forKey: blockKey)
        defaults.removeObject(forKey: blockUntilKey)
    }

    /// Note a failed upload. Returns the block it caused, if the error was one
    /// that makes further automatic retries pointless.
    @discardableResult
    func recordFailure(_ error: Error) -> UploadBlock? {
        let block: UploadBlock
        switch error as? WatchWebDAVError {
        case .unauthorized: block = .unauthorized
        case .throttled: block = .throttled
        default: return nil
        }
        defaults.set(block.rawValue, forKey: blockKey)
        if block == .throttled {
            defaults.set(Date().addingTimeInterval(throttleCooldown).timeIntervalSince1970,
                         forKey: blockUntilKey)
        }
        return block
    }

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
    /// - Parameter userInitiated: an explicit retry from the user goes ahead even
    ///   while blocked (one attempt); automatic triggers stay quiet instead.
    @discardableResult
    func flush(userInitiated: Bool = false) async -> Int {
        guard !flushing else { return 0 }
        guard WatchWebDAVService.shared.isConfigured else { return 0 }
        if !userInitiated, currentBlock() != nil { return 0 }

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
                // The server accepted us, so whatever blocked us is over
                clearBlock()
            } catch {
                recordFailure(error)
                break
            }
        }

        return sent
    }
}
