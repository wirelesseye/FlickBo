import Foundation

/// The region whose character forms candidates use. Taiwan also ranks Taiwan
/// vocabulary by the frequency of the word it replaces (see SQLiteLexiconStore).
enum CharacterVariant: String, CaseIterable, Sendable {
    case taiwan
    case hongKong
    case mainland
    /// OpenCC Standard Traditional, the form the bundled lexicon uses.
    case traditional

    /// Name shown in the app's settings and the keyboard's character-variant menu.
    var title: String {
        switch self {
        case .taiwan: "臺灣"
        case .hongKong: "香港"
        case .mainland: "中國大陸（簡體）"
        case .traditional: "傳承字形"
        }
    }

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
}
