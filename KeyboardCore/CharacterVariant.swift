import Foundation

/// The region whose character forms (and, for Taiwan, vocabulary) candidates use.
enum CharacterVariant: String, CaseIterable, Sendable {
    case taiwan
    case hongKong
    case mainland
    /// OpenCC Standard Traditional, the form the bundled lexicon uses.
    case traditional

    /// Canonical (OpenCC Standard) -> this region.
    var outputConversion: String? {
        switch self {
        case .taiwan: "t2tw"
        case .hongKong: "t2hk"
        case .mainland: "t2s"
        case .traditional: nil
        }
    }

    /// This region -> canonical, for the grammar context before the cursor.
    var contextConversion: String? {
        switch self {
        case .taiwan: "tw2t"
        case .hongKong: "hk2t"
        case .mainland: "s2t"
        case .traditional: nil
        }
    }

    /// Regional vocabulary offered as extra candidates (軟件 -> 軟體).
    var phraseConversion: String? {
        self == .taiwan ? "tw-phrases" : nil
    }
}
