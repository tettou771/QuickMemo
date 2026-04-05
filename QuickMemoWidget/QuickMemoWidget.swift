import WidgetKit
import SwiftUI

struct QuickMemoEntry: TimelineEntry {
    let date: Date
}

struct QuickMemoProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickMemoEntry {
        QuickMemoEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickMemoEntry) -> Void) {
        completion(QuickMemoEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickMemoEntry>) -> Void) {
        let entry = QuickMemoEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct QuickMemoWidgetView: View {
    var entry: QuickMemoEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bubble.left.fill")
                    .font(.title2)
            }
        case .accessoryCorner:
            Image(systemName: "bubble.left.fill")
                .font(.title3)
                .widgetLabel("メモ")
        case .accessoryRectangular:
            HStack {
                Image(systemName: "bubble.left.fill")
                    .font(.title3)
                Text("QuickMemo")
                    .font(.headline)
            }
        case .accessoryInline:
            Label("QuickMemo", systemImage: "bubble.left.fill")
        default:
            Image(systemName: "bubble.left.fill")
        }
    }
}

struct QuickMemoWidget: Widget {
    let kind = "QuickMemoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickMemoProvider()) { entry in
            QuickMemoWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("QuickMemo")
        .description("タップしてメモを取る")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
