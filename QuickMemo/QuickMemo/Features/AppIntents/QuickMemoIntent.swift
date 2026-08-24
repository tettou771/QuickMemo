import AppIntents

struct QuickMemoIntent: AppIntent {
    static var title: LocalizedStringResource = "クイックメモ"
    static var description: IntentDescription = "QuickMemoを開いてすぐメモを取ります"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct QuickMemoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickMemoIntent(),
            phrases: [
                "\(.applicationName)でメモ",
                "\(.applicationName)でメモを取る",
                "\(.applicationName)を開く",
            ],
            shortTitle: "クイックメモ",
            systemImageName: "mic.circle"
        )
    }
}
