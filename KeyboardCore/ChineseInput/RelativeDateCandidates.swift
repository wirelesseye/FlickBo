import Foundation

enum RelativeDateCandidates {
    private static let dayOffsets: [String: Int] = [
        "前天": -2,
        "昨天": -1,
        "今天": 0,
        "明天": 1,
        "後天": 2,
    ]

    private static let weekdayNames = [
        "星期日",
        "星期一",
        "星期二",
        "星期三",
        "星期四",
        "星期五",
        "星期六",
    ]

    static func dayOffset(for word: String) -> Int? {
        dayOffsets[word]
    }

    static func badge(for word: String) -> String {
        "\(word)的日期"
    }

    /// Formats the date at `dayOffset` days from `date` as ISO (`2026-11-22`),
    /// slash (`2026/11/22`), Chinese (`2026年11月22日`), ROC (`民國115年11月22日`),
    /// and weekday (`星期日`).
    static func formattedStrings(
        for date: Date,
        dayOffset: Int,
        calendar: Calendar = .current
    ) -> [String] {
        guard let targetDate = calendar.date(byAdding: .day, value: dayOffset, to: date) else {
            return []
        }
        let gregorian = gregorianCalendar(matching: calendar)
        let components = gregorian.dateComponents([.year, .month, .day, .weekday], from: targetDate)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let weekday = components.weekday,
              (1...7).contains(weekday)
        else { return [] }

        let paddedMonth = month < 10 ? "0\(month)" : "\(month)"
        let paddedDay = day < 10 ? "0\(day)" : "\(day)"

        var results = [
            "\(year)-\(paddedMonth)-\(paddedDay)",
            "\(year)/\(paddedMonth)/\(paddedDay)",
            "\(year)年\(month)月\(day)日",
        ]
        let rocYear = year - 1911
        if rocYear >= 1 {
            results.append("民國\(rocYear)年\(month)月\(day)日")
        }
        results.append(weekdayNames[weekday - 1])
        return results
    }

    private static func gregorianCalendar(matching calendar: Calendar) -> Calendar {
        if calendar.identifier == .gregorian {
            return calendar
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }
}
