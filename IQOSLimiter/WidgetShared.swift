import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Κοινή κατάσταση ανάμεσα στο app και στο widget (App Group) + ο κανόνας «τι μέρα είναι».
enum IQOSShared {
    static let group = "group.com.yourname.iqoslimiter"
    /// Η «μέρα» αλλάζει στις 04:00 (όχι τα μεσάνυχτα), ώστε τα βραδινά να μετράνε στην ίδια μέρα.
    static let dayStartHour = 4

    private static let keyDay    = "widget.day"
    private static let keySticks = "widget.sticks"
    private static let keyLimit  = "widget.limit"

    private static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    static func dayKey(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let shifted = Calendar.current.date(byAdding: .hour, value: -dayStartHour, to: date) ?? date
        return fmt.string(from: shifted)
    }

    /// Η επόμενη 04:00 — τότε το widget πρέπει να δείξει 0 ακόμα κι αν δεν έτρεξε το app.
    static func nextDayStart(after date: Date = Date()) -> Date {
        Calendar.current.nextDate(after: date,
                                  matching: DateComponents(hour: dayStartHour, minute: 0),
                                  matchingPolicy: .nextTime) ?? date.addingTimeInterval(3600)
    }

    /// Γράφει την κατάσταση της ημέρας και ζητά ανανέωση του widget μόνο αν άλλαξε κάτι.
    static func publish(sticks: Int, limit: Int) {
        let d = defaults
        let day = dayKey()
        let changed = d.string(forKey: keyDay) != day
            || d.integer(forKey: keySticks) != sticks
            || d.integer(forKey: keyLimit) != limit
        guard changed else { return }
        d.set(day, forKey: keyDay)
        d.set(sticks, forKey: keySticks)
        d.set(limit, forKey: keyLimit)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static func read() -> (sticks: Int, limit: Int) {
        let d = defaults
        let limit = d.object(forKey: keyLimit) == nil ? 5 : d.integer(forKey: keyLimit)
        // Αν τα δεδομένα είναι από άλλη μέρα, σήμερα δεν έχει μετρηθεί τίποτα ακόμα.
        let sticks = d.string(forKey: keyDay) == dayKey() ? d.integer(forKey: keySticks) : 0
        return (sticks, limit)
    }
}
