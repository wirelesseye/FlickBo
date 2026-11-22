import Foundation

enum RelativeYearCandidates {
    private static let yearOffsets: [String: Int] = [
        "去年": -1,
        "今年": 0,
        "明年": 1,
    ]

    private static let heavenlyStems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    private static let earthlyBranches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]

    static func yearOffset(for word: String) -> Int? {
        yearOffsets[word]
    }

    static func badge(for word: String) -> String {
        word
    }

    /// Formats the year at `yearOffset` years from `date` as Arabic (`2026`),
    /// Chinese (`2026年`), ROC (`民國115年`), and sexagenary cycle (`丙午`).
    static func formattedStrings(
        for date: Date,
        yearOffset: Int,
        calendar: Calendar = .current
    ) -> [String] {
        let gregorian = gregorianCalendar(matching: calendar)
        let currentYear = gregorian.component(.year, from: date)
        let targetYear = currentYear + yearOffset

        var results = [
            "\(targetYear)",
            "\(targetYear)年",
        ]
        let rocYear = targetYear - 1911
        if rocYear >= 1 {
            results.append("民國\(rocYear)年")
        }
        results.append(sexagenaryYear(for: targetYear))
        return results
    }

    static func sexagenaryYear(for gregorianYear: Int) -> String {
        let stemIndex = ((gregorianYear - 4) % 10 + 10) % 10
        let branchIndex = ((gregorianYear - 4) % 12 + 12) % 12
        return heavenlyStems[stemIndex] + earthlyBranches[branchIndex]
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
