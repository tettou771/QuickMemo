import Foundation

enum MemoCategory: String, CaseIterable, Identifiable {
    case diary = "diary"
    case photoMemo = "photo-memo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .diary:     return "日記"
        case .photoMemo: return "写真メモ"
        }
    }

    var emoji: String {
        switch self {
        case .diary:     return "📔"
        case .photoMemo: return "📷"
        }
    }
}
