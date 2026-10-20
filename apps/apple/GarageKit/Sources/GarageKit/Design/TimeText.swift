import Foundation

/// Clock times in copy: "14:02", or "19 Oct 14:02" once the moment is more than a day old or on an
/// earlier day, so yesterday's time never reads as today's. 24-hour, in the given time zone.
enum TimeText {
    /// `HH:mm`.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(style(
            "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: timeZone
        ))
    }

    /// `d MMM HH:mm`, for example "19 Oct 14:02".
    static func dayClock(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(style(
            "\(day: .defaultDigits) \(month: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: timeZone
        ))
    }

    /// Whether `date` needs its day to be read right next to `now`: more than a day apart, or on
    /// another calendar day in `timeZone`.
    static func needsDate(_ date: Date, now: Date, timeZone: TimeZone) -> Bool {
        if abs(now.timeIntervalSince(date)) >= 86_400 { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return !calendar.isDate(date, inSameDayAs: now)
    }

    /// ``clock(_:timeZone:)``, or ``dayClock(_:timeZone:)`` when ``needsDate(_:now:timeZone:)``.
    static func stamp(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        needsDate(date, now: now, timeZone: timeZone) ? dayClock(date, timeZone: timeZone) : clock(date, timeZone: timeZone)
    }

    private static func style(_ format: Date.FormatString, timeZone: TimeZone) -> Date.VerbatimFormatStyle {
        var style = Date.VerbatimFormatStyle(format: format, timeZone: timeZone, calendar: Calendar(identifier: .gregorian))
        style.locale = Locale(identifier: "en_US_POSIX")
        return style
    }
}
