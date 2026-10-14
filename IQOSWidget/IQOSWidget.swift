import SwiftUI
import WidgetKit

struct IQOSEntry: TimelineEntry {
    let date: Date
    let sticks: Int
    let limit: Int
    var remaining: Int { max(0, limit - sticks) }
    var progress: Double { limit > 0 ? min(1, Double(sticks) / Double(limit)) : 0 }

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
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(entry.color.opacity(0.18), lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: max(entry.progress, 0.001))
                        .stroke(
                            AngularGradient(colors: [entry.color.opacity(0.55), entry.color],
                                            center: .center,
                                            startAngle: .degrees(0),
                                            endAngle: .degrees(360 * max(entry.progress, 0.001))),
                            style: StrokeStyle(lineWidth: 11, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -3) {
                        Text("\(entry.sticks)")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                        Text("από \(entry.limit)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)

                Text(entry.remaining == 0 ? "Όριο!" : "Απομένουν \(entry.remaining)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(entry.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(entry.color.opacity(0.16), in: Capsule())
            }
        }
    }
}

/// Φόντο: απαλή διαβάθμιση στο χρώμα της κατάστασης (στην οθόνη κλειδώματος το αφήνουμε του συστήματος).
struct IQOSBackground: View {
    @Environment(\.widgetFamily) private var family
    let entry: IQOSEntry

    var body: some View {
        if family == .systemSmall {
            LinearGradient(colors: [entry.color.opacity(0.28), Color(uiColor: .systemBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color.clear
        }
    }
}

struct IQOSWidget: Widget {
    let kind = "IQOSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IQOSProvider()) { entry in
            IQOSWidgetView(entry: entry)
                .containerBackground(for: .widget) { IQOSBackground(entry: entry) }
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
