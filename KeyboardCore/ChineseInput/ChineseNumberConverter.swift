import Foundation

enum ChineseNumberConverter {
    /// Converts a Chinese numeral string (such as `"十三"`, `"一百二"`, `"一二三"`,
    /// `"二〇二六"`) into its half-width Arabic numeral string (`"13"`, `"120"`,
    /// `"123"`, `"2026"`). Returns `nil` if `text` is not a valid Chinese number.
    static func arabicNumber(for text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let characters = Array(text)
        if let digits = parseDigitSequence(characters) {
            return digits
        }
        if let value = parsePositional(characters) {
            return String(value)
        }
        return nil
    }

    // MARK: - Digit-by-Digit Parsing

    private static func parseDigitSequence(_ characters: [Character]) -> String? {
        var result = ""
        result.reserveCapacity(characters.count)
        for character in characters {
            guard let digit = standaloneDigit(for: character) else { return nil }
            result.append(Character(String(digit)))
        }
        return result.isEmpty ? nil : result
    }

    private static func standaloneDigit(for character: Character) -> Int? {
        switch character {
        case "零", "〇": 0
        case "一", "壹": 1
        case "二", "貳": 2
        case "三", "參", "叁": 3
        case "四", "肆": 4
        case "五", "伍": 5
        case "六", "陸": 6
        case "七", "柒": 7
        case "八", "捌": 8
        case "九", "玖": 9
        default: nil
        }
    }

    // MARK: - Positional Parsing

    private enum Token {
        case zero
        case digit(Int)
        case twoLiang
        case smallMultiplier(Int)
        case largeMultiplier(Int)
    }

    private static func token(for character: Character) -> Token? {
        switch character {
        case "零", "〇": .zero
        case "一", "壹": .digit(1)
        case "二", "貳": .digit(2)
        case "兩": .twoLiang
        case "三", "參", "叁": .digit(3)
        case "四", "肆": .digit(4)
        case "五", "伍": .digit(5)
        case "六", "陸": .digit(6)
        case "七", "柒": .digit(7)
        case "八", "捌": .digit(8)
        case "九", "玖": .digit(9)
        case "十", "拾": .smallMultiplier(10)
        case "廿": .smallMultiplier(20)
        case "卅": .smallMultiplier(30)
        case "百", "佰": .smallMultiplier(100)
        case "千", "仟": .smallMultiplier(1000)
        case "萬": .largeMultiplier(10_000)
        case "億": .largeMultiplier(100_000_000)
        default: nil
        }
    }

    private static func parsePositional(_ characters: [Character]) -> Int? {
        var total = 0
        var section = 0
        var pendingDigit: Int?
        var pendingIsLiang = false
        var lastSmallMultiplier = Int.max
        var lastLargeMultiplier = Int.max
        var lastAppliedMultiplier: Int?
        var sawZero = false
        var hasMultiplier = false

        for character in characters {
            guard let token = token(for: character) else { return nil }
            switch token {
            case .zero:
                guard hasMultiplier, pendingDigit == nil, !sawZero else { return nil }
                sawZero = true
            case let .digit(digit):
                guard pendingDigit == nil else { return nil }
                pendingDigit = digit
                pendingIsLiang = false
            case .twoLiang:
                guard pendingDigit == nil else { return nil }
                pendingDigit = 2
                pendingIsLiang = true
            case let .smallMultiplier(multiplier):
                guard multiplier < lastSmallMultiplier else { return nil }
                hasMultiplier = true
                if multiplier == 10 {
                    guard !pendingIsLiang else { return nil }
                    let factor = pendingDigit ?? 1
                    section += factor * 10
                } else if multiplier == 20 || multiplier == 30 {
                    guard pendingDigit == nil else { return nil }
                    section += multiplier
                } else {
                    guard let factor = pendingDigit, factor >= 1 else { return nil }
                    section += factor * multiplier
                }
                pendingDigit = nil
                pendingIsLiang = false
                lastSmallMultiplier = multiplier
                lastAppliedMultiplier = multiplier
                sawZero = false
            case let .largeMultiplier(multiplier):
                guard multiplier < lastLargeMultiplier else { return nil }
                hasMultiplier = true
                if let digit = pendingDigit {
                    if !sawZero, lastSmallMultiplier != Int.max, lastSmallMultiplier > 10 {
                        section += digit * (lastSmallMultiplier / 10)
                    } else {
                        section += digit
                    }
                    pendingDigit = nil
                    pendingIsLiang = false
                } else if sawZero {
                    return nil
                }
                guard section > 0 else { return nil }
                total += section * multiplier
                section = 0
                lastSmallMultiplier = Int.max
                lastLargeMultiplier = multiplier
                lastAppliedMultiplier = multiplier
                sawZero = false
            }
        }

        guard hasMultiplier else { return nil }
        if let digit = pendingDigit {
            guard !pendingIsLiang else { return nil }
            if !sawZero, let mult = lastAppliedMultiplier, mult >= 100 {
                section += digit * (mult / 10)
            } else {
                section += digit
            }
        } else if sawZero {
            return nil
        }
        return total + section
    }
}
