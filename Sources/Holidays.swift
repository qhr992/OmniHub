import Foundation

/// Next public holiday in mainland China, for the countdown on the home page.
/// Dates are computed (fixed days, lunar festivals through the Chinese
/// calendar, Qingming by its solar-term formula), so there is no table to update.
/// Only the festival day itself is counted — not the surrounding days off.
enum Holidays {
    struct Holiday {
        let name: String
        let date: Date
    }

    private static var cache: [Int: [Holiday]] = [:]

    static func holidays(inYear year: Int) -> [Holiday] {
        if let cached = cache[year] { return cached }
        let gregorian = Calendar(identifier: .gregorian)
        func day(_ month: Int, _ day: Int) -> Date? {
            gregorian.date(from: DateComponents(year: year, month: month, day: day))
        }
        // 21st-century formula for the Qingming solar term.
        let short = year % 100
        let qingming = Int(Double(short) * 0.2422 + 4.81) - short / 4

        var list: [Holiday] = []
        func add(_ name: String, _ date: Date?) { if let date { list.append(Holiday(name: name, date: date)) } }
        add("New Year", day(1, 1))
        add("Spring Festival", lunar(month: 1, day: 1, inYear: year))
        add("Qingming", day(4, qingming))
        add("Labor Day", day(5, 1))
        add("Dragon Boat", lunar(month: 5, day: 5, inYear: year))
        add("Mid-Autumn", lunar(month: 8, day: 15, inYear: year))
        add("National Day", day(10, 1))
        list.sort { $0.date < $1.date }
        cache[year] = list
        return list
    }

    /// The Gregorian day in `year` on which the given lunar date falls.
    private static func lunar(month: Int, day: Int, inYear year: Int) -> Date? {
        let gregorian = Calendar(identifier: .gregorian)
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = gregorian.timeZone
        guard var cursor = gregorian.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        for _ in 0..<366 {
            let parts = chinese.dateComponents([.month, .day], from: cursor)
            if parts.month == month, parts.day == day, parts.isLeapMonth != true { return cursor }
            guard let next = gregorian.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    /// The next holiday on or after `today`, with the number of days to go.
    static func next(from today: Date = Date()) -> (holiday: Holiday, days: Int)? {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: today)
        let year = calendar.component(.year, from: start)
        for candidate in holidays(inYear: year) + holidays(inYear: year + 1) where candidate.date >= start {
            let days = calendar.dateComponents([.day], from: start, to: candidate.date).day ?? 0
            return (candidate, days)
        }
        return nil
    }

    /// "49d to New Year" / "New Year today".
    static func countdownText(from today: Date = Date()) -> String {
        guard let (holiday, days) = next(from: today) else { return "" }
        return days == 0 ? "\(holiday.name) today" : "\(days)d to \(holiday.name)"
    }
}
