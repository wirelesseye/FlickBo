import Foundation

enum CurrentTimeCandidates {
    static let badge = "現在的時間"
    private static let triggerWords: Set<String> = ["現在", "時刻", "時間"]

    static func shouldOffer(for word: String) -> Bool {
        triggerWords.contains(word)
    }

    /// Formats `date` in the given `calendar` as 24-hour (`16:04`), 12-hour Chinese
    /// (`下午4:04`), and 12-hour English (`4:04 PM`).
    static func formattedStrings(for date: Date, calendar: Calendar = .current) -> [String] {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour24 = components.hour, let minute = components.minute else { return [] }

        let minuteText = minute < 10 ? "0\(minute)" : "\(minute)"
        let hour24Text = hour24 < 10 ? "0\(hour24)" : "\(hour24)"

        let isAM = hour24 < 12
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let zhPeriod = isAM ? "上午" : "下午"
        let enPeriod = isAM ? "AM" : "PM"

        return [
            "\(hour24Text):\(minuteText)",
            "\(zhPeriod)\(hour12):\(minuteText)",
            "\(hour12):\(minuteText) \(enPeriod)",
        ]
    }
}
