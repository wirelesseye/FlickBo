import Foundation

enum KeyboardLayout {
    static let letterRows: [[KeyboardKey]] = [
        Array("qwertyuiop").map(KeyboardKey.letter),
        Array("asdfghjkl").map(KeyboardKey.letter),
        Array("zxcvbnm").map(KeyboardKey.letter)
    ]

    static var thirdRow: [KeyboardKey] {
        [.shift] + letterRows[2] + [.delete]
    }

    static let controlRow: [KeyboardKey] = [
        .nextKeyboard, .space, .return
    ]
}

enum CharacterWidth: Equatable, Sendable {
    case half
    case full

    var toggled: CharacterWidth {
        self == .half ? .full : .half
    }

    /// U+0020 for half-width, the ideographic space U+3000 for full-width.
    var space: String {
        self == .full ? "\u{3000}" : " "
    }

    /// Converts printable ASCII (and a few Latin-1 signs) to the requested width.
    /// Symbols without a width counterpart, such as `「` or `…`, are returned unchanged.
    func apply(to text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch self {
            case .full: Self.fullWidthScalar(for: scalar) ?? scalar
            case .half: Self.halfWidthScalar(for: scalar) ?? scalar
            }
        }))
    }

    /// The same symbol in the other width, or `nil` when it has no counterpart.
    static func counterpart(of text: String) -> String? {
        let full = CharacterWidth.full.apply(to: text)
        if full != text { return full }
        let half = CharacterWidth.half.apply(to: text)
        return half != text ? half : nil
    }

    /// Whether `text` is one full-width symbol that also has a half-width form, counting
    /// the halfwidth CJK punctuation `｡｢｣､` that the width toggle itself does not produce.
    static func isFullWidthWithHalfCounterpart(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        if halfWidthScalar(for: scalar) != nil { return true }
        return ["。", "「", "」", "、"].contains(text)
    }

    private static let latin1Pairs: [(half: UInt32, full: UInt32)] = [
        (0xA2, 0xFFE0), // ¢
        (0xA3, 0xFFE1), // £
        (0xA5, 0xFFE5), // ¥
        (0xAC, 0xFFE2) // ¬
    ]

    private static func fullWidthScalar(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value
        if (0x21...0x7E).contains(value) {
            return Unicode.Scalar(value + 0xFEE0)
        }
        return latin1Pairs.first { $0.half == value }.flatMap { Unicode.Scalar($0.full) }
    }

    private static func halfWidthScalar(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value
        if (0xFF01...0xFF5E).contains(value) {
            return Unicode.Scalar(value - 0xFEE0)
        }
        return latin1Pairs.first { $0.full == value }.flatMap { Unicode.Scalar($0.half) }
    }
}

enum NumberLayout {
    static let rows: [[Character]] = [
        Array("123"),
        Array("456"),
        Array("789")
    ]

    static let zero: Character = "0"

    /// Half-width flick symbols for each digit key: center, left, up, right, down.
    /// `0` sits on the bottom row, so it has no downward flick.
    private static let halfWidthMappings: [Character: FlickKeyMapping] = [
        "1": FlickKeyMapping(["1", "(", "[", ")", "]"]),
        "2": FlickKeyMapping(["2", "「", "《", "」", "》"]),
        "3": FlickKeyMapping(["3", "{", "<", "}", ">"]),
        "4": FlickKeyMapping(["4", "+", "-", "*", "/"]),
        "5": FlickKeyMapping(["5", "=", "%", "^", "~"]),
        "6": FlickKeyMapping(["6", "$", "€", "¥", "£"]),
        "7": FlickKeyMapping(["7", "@", "#", "&", "_"]),
        "8": FlickKeyMapping(["8", "'", "\"", "`", "\\"]),
        "9": FlickKeyMapping(["9", ";", "|", "…", "·"]),
        "0": FlickKeyMapping(["0", ".", ":", "、"])
    ]

    static func mapping(for digit: Character, width: CharacterWidth) -> FlickKeyMapping {
        let base = halfWidthMappings[digit] ?? FlickKeyMapping([String(digit)])
        return base.map(width.apply(to:))
    }
}

/// Nine-key ABC layout: letters follow the phone keypad groups, and the top-left key
/// holds symbols common in English text, email addresses and URLs.
enum ABCFlickLayout {
    static let symbols = FlickKeyMapping(["'", "@", "#", "/", "-"])

    /// Letter keys in reading order; the first row starts after the symbol key.
    static let letterRows: [[FlickKeyMapping]] = [
        [FlickKeyMapping(["a", "b", "c"]), FlickKeyMapping(["d", "e", "f"])],
        [FlickKeyMapping(["g", "h", "i"]), FlickKeyMapping(["j", "k", "l"]), FlickKeyMapping(["m", "n", "o"])],
        [
            FlickKeyMapping(["p", "q", "r", "s"]),
            FlickKeyMapping(["t", "u", "v"]),
            FlickKeyMapping(["w", "x", "y", "z"])
        ]
    ]

    static func letters(
        _ mapping: FlickKeyMapping,
        letterCase: LetterCaseState,
        width: CharacterWidth
    ) -> FlickKeyMapping {
        mapping.map { width.apply(to: letterCase == .lowercase ? $0.lowercased() : $0.uppercased()) }
    }
}

/// Candidates offered after a digit or symbol is typed directly into the document.
enum SymbolVariants {
    private static let related: [String: [String]] = [
        "0": ["⓪", "⁰", "₀", "〇"],
        "1": ["①", "¹", "₁", "Ⅰ"],
        "2": ["②", "²", "₂", "Ⅱ"],
        "3": ["③", "³", "₃", "Ⅲ"],
        "4": ["④", "⁴", "₄", "Ⅳ"],
        "5": ["⑤", "⁵", "₅", "Ⅴ"],
        "6": ["⑥", "⁶", "₆", "Ⅵ"],
        "7": ["⑦", "⁷", "₇", "Ⅶ"],
        "8": ["⑧", "⁸", "₈", "Ⅷ"],
        "9": ["⑨", "⁹", "₉", "Ⅸ"],
        "(": ["【", "〔", "〖"],
        ")": ["】", "〕", "〗"],
        "[": ["【", "〔"],
        "]": ["】", "〕"],
        "{": ["〖"],
        "}": ["〗"],
        "「": ["『", "﹁", "｢"],
        "」": ["』", "﹂", "｣"],
        "《": ["〈", "«"],
        "》": ["〉", "»"],
        "<": ["≤", "〈", "«"],
        ">": ["≥", "〉", "»"],
        "+": ["±"],
        "-": ["—", "–", "−"],
        "*": ["×", "·"],
        "/": ["÷"],
        "=": ["≠", "≈", "≡"],
        "%": ["‰"],
        "~": ["〜", "≈"],
        "$": ["¢"],
        "¥": ["元"],
        "#": ["♯"],
        "'": ["‘", "’"],
        "\"": ["“", "”"],
        "|": ["‖"],
        "…": ["⋯"],
        "·": ["‧", "•"],
        ".": ["。", "｡"],
        "。": ["．", ".", "｡"],
        ",": ["、"],
        "、": ["，", ",", "､"],
        ":": ["："],
        "?": ["？"],
        "!": ["！"]
    ]

    /// The typed symbol first, then its other-width form, then related symbols.
    static func candidates(for symbol: String) -> [String] {
        var result = [symbol]
        if let counterpart = CharacterWidth.counterpart(of: symbol) {
            result.append(counterpart)
        }
        let key = CharacterWidth.half.apply(to: symbol)
        result += related[symbol] ?? related[key] ?? []
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
