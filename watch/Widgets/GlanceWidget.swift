import SwiftUI
import WidgetKit

@main
struct GrokWatchWidgets: WidgetBundle {
    var body: some Widget { GlanceWidget() }
}

struct GlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "glance", provider: GlanceProvider()) { entry in
            GlanceView(glance: entry.glance)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Grok Bot")
        .description("Unread Bot messages.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: Glance?
}

/// The app reloads this timeline whenever the unread state changes.
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, glance: Glance(unreadBots: [.init(agentID: "", name: "Raven", unread: 2)], runningCount: 0))
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : GlanceEntry(date: .now, glance: Glance.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        completion(Timeline(entries: [GlanceEntry(date: .now, glance: Glance.load())], policy: .never))
    }
}

struct GlanceView: View {
    @Environment(\.widgetFamily) private var family
    let glance: Glance?

    private var total: UInt32 { glance?.totalUnread ?? 0 }
    private var summary: String { total == 0 ? "All read" : "\(total) unread" }

    var body: some View {
        content.widgetURL(glance?.unreadBots.first.map { DeepLink.bot($0.agentID) })
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: total == 0 ? "bubble.left" : "bubble.left.fill").font(.caption)
                    if total > 0 { Text("\(total)").font(.title3.weight(.semibold)).minimumScaleFactor(0.6) }
                }
            }
            .widgetAccentable()
        case .accessoryCorner:
            Image(systemName: total == 0 ? "bubble.left" : "bubble.left.fill")
                .font(.title3)
                .widgetLabel(summary)
        case .accessoryInline:
            Label("Grok Bot · \(summary)", systemImage: "bubble.left.fill")
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Label("Grok Bot", systemImage: "bubble.left.fill").font(.headline).widgetAccentable()
                    Spacer()
                    if let running = glance?.runningCount, running > 0 {
                        Image(systemName: "ellipsis").accessibilityLabel("\(running) working")
                    }
                }
                if let bots = glance?.unreadBots, !bots.isEmpty {
                    ForEach(bots.prefix(2), id: \.agentID) { bot in
                        Text("\(bot.name) · \(bot.unread)").lineLimit(1)
                    }
                } else {
                    Text(glance == nil ? "Open Grokwatch to sign in" : "All caught up").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
