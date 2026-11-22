import Foundation

/// Symbol palette categories, in palette order. `recent` is filled from the
/// user's own picks; the others group rime-prelude's symbol shortcuts.
enum SymbolCategory: String, CaseIterable, Sendable {
    case recent
    case punctuation
    case shapes
    case arrows
    case math
    case numbers
    case units
    case letters

    var title: String {
        switch self {
        case .recent: "最近使用"
        case .punctuation: "標點"
        case .shapes: "圖形與符號"
        case .arrows: "箭頭"
        case .math: "數學與上下標"
        case .numbers: "編號"
        case .units: "單位、貨幣與日期"
        case .letters: "注音與外文字母"
        }
    }
}

/// Kaomoji palette categories, in palette order, after Mozc's emoticon palette.
enum KaomojiCategory: String, CaseIterable, Sendable {
    case recent
    case smile
    case sweat
    case surprise
    case sadness
    case displeasure

    var title: String {
        switch self {
        case .recent: "最近使用"
        case .smile: "開心"
        case .sweat: "冒汗"
        case .surprise: "驚訝"
        case .sadness: "難過"
        case .displeasure: "不滿"
        }
    }
}

struct PaletteSection<Category: Equatable & Sendable>: Equatable, Sendable {
    let category: Category
    let items: [String]
}

/// The symbol palette compiled from rime-prelude and the kaomoji palette
/// compiled from Mozc (`Generated/flickbo.symbols`, see `Tools/DictionaryCompiler/symbol_data.py`):
/// one `palette<TAB>category<TAB>value` line per entry, in palette order.
struct SymbolPalettes: Sendable {
    /// Sections for every category except `recent`, in palette order.
    let symbols: [PaletteSection<SymbolCategory>]
    let kaomoji: [PaletteSection<KaomojiCategory>]

    init(text: String) throws {
        var symbolItems: [SymbolCategory: [String]] = [:]
        var kaomojiItems: [KaomojiCategory: [String]] = [:]
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            guard !line.isEmpty else { continue }
            // The value may itself be a space, so fields are split exactly.
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[2].isEmpty, !fields[2].contains("\t") else {
                throw EmojiCatalogError.malformedLine(lineNumber)
            }
            let value = String(fields[2])
            switch fields[0] {
            case "symbol":
                guard let category = SymbolCategory(rawValue: String(fields[1])), category != .recent else {
                    throw EmojiCatalogError.malformedLine(lineNumber)
                }
                symbolItems[category, default: []].append(value)
            case "kaomoji":
                guard let category = KaomojiCategory(rawValue: String(fields[1])), category != .recent else {
                    throw EmojiCatalogError.malformedLine(lineNumber)
                }
                kaomojiItems[category, default: []].append(value)
            default:
                throw EmojiCatalogError.malformedLine(lineNumber)
            }
        }
        symbols = SymbolCategory.allCases.compactMap { category in
            symbolItems[category].map { PaletteSection(category: category, items: $0) }
        }
        kaomoji = KaomojiCategory.allCases.compactMap { category in
            kaomojiItems[category].map { PaletteSection(category: category, items: $0) }
        }
    }

    init(bundle: Bundle, resourceName: String = "flickbo", resourceExtension: String = "symbols") throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw EmojiCatalogError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }
}
