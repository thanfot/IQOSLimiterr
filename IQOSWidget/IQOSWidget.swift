import SwiftUI
import WidgetKit

struct IQOSEntry: TimelineEntry {
    let date: Date
    let sticks: Int
    let limit: Int
    var remaining: Int { max(0, limit - sticks) }

    var color: Color {
        switch remaining {
        case 0:  return .red
        case 1:  return .orange
        default: return .green
        }
    }
}

struct IQOSProvider: TimelineProvider {
    func placeholder(in context: Context) -> IQOSEntry {
        IQOSEntry(date: .now, sticks: 3, limit: 5)
    }

    func getSnapshot(in context: Context, completion: @escaping (IQOSEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IQOSEntry>) -> Void) {
        // Το app ζητά ανανέωση σε κάθε αλλαγή· μέχρι τότε ανανεώνουμε στην αλλαγή μέρας (04:00).
        completion(Timeline(entries: [current()], policy: .after(IQOSShared.nextDayStart())))
    }

    private func current() -> IQOSEntry {
        let s = IQOSShared.read()
        return IQOSEntry(date: .now, sticks: s.sticks, limit: s.limit)
    }
}

struct IQOSWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: IQOSEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text("\(entry.sticks)/\(entry.limit)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                Text("−\(entry.remaining)")
                    .font(.system(size: 11, weight: .medium))
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.sticks)/\(entry.limit) sticks")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Απομένουν \(entry.remaining)")
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 4) {
                Text("\(entry.sticks)/\(entry.limit)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.color)
                    .minimumScaleFactor(0.6)
                Text("Απομένουν \(entry.remaining)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct IQOSWidget: Widget {
    let kind = "IQOSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IQOSProvider()) { entry in
            IQOSWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("IQOS Limiter")
        .description("Sticks σήμερα και πόσα απομένουν.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct IQOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        IQOSWidget()
    }
}
