import Foundation

/// Emoji palette categories, in palette order. `recent` is filled from the
/// user's own picks; the others follow the Unicode emoji groups.
enum EmojiCategory: String, CaseIterable, Sendable {
    case recent
    case smileys
    case people
    case animals
    case food
    case travel
    case activities
    case objects
    case symbols
    case flags

    var title: String {
        switch self {
        case .recent: "最近使用"
        case .smileys: "笑臉與情緒"
        case .people: "人物與身體"
        case .animals: "動物與自然"
        case .food: "食物與飲料"
        case .travel: "旅行與地點"
        case .activities: "活動"
        case .objects: "物品"
        case .symbols: "符號"
        case .flags: "旗幟"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .smileys: "face.smiling"
        case .people: "hand.wave"
        case .animals: "pawprint"
        case .food: "fork.knife"
        case .travel: "car"
        case .activities: "soccerball"
        case .objects: "lightbulb"
        case .symbols: "heart"
        case .flags: "flag"
        }
    }
}

struct EmojiEntry: Equatable, Sendable {
    let emoji: String
    /// CLDR short name, in English.
    let name: String
}

struct EmojiSection: Equatable, Sendable {
    let category: EmojiCategory
    let entries: [EmojiEntry]
}

enum EmojiCatalogError: Error, Equatable {
    case resourceNotFound(String)
    case malformedLine(Int)
}

/// The emoji palette compiled from Unicode `emoji-test.txt`
/// (`Generated/flickbo.emojicatalog`, see `Tools/DictionaryCompiler/emoji_data.py`):
/// one `group<TAB>version<TAB>emoji<TAB>name` line per emoji, in CLDR order.
struct EmojiCatalog: Sendable {
    /// Sections for every category except `recent`, in palette order.
    let sections: [EmojiSection]

    /// Leaves out emoji newer than `maximumVersion`, which the system font
    /// would draw as an empty box.
    init(text: String, maximumVersion: EmojiVersion = .supportedBySystem) throws {
        var entries: [EmojiCategory: [EmojiEntry]] = [:]
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let category = EmojiCategory(rawValue: String(fields[0])),
                  category != .recent,
                  let version = EmojiVersion(String(fields[1])),
                  !fields[2].isEmpty
            else {
                throw EmojiCatalogError.malformedLine(lineNumber)
            }
            guard version <= maximumVersion else { continue }
            entries[category, default: []].append(EmojiEntry(emoji: String(fields[2]), name: String(fields[3])))
        }
        sections = EmojiCategory.allCases.compactMap { category in
            entries[category].map { EmojiSection(category: category, entries: $0) }
        }
    }

    init(
        bundle: Bundle,
        resourceName: String = "flickbo",
        resourceExtension: String = "emojicatalog",
        maximumVersion: EmojiVersion = .supportedBySystem
    ) throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw EmojiCatalogError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }
        try self.init(text: String(contentsOf: url, encoding: .utf8), maximumVersion: maximumVersion)
    }
}

struct EmojiVersion: Comparable, Sendable {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    static func < (lhs: EmojiVersion, rhs: EmojiVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// The newest emoji version Apple's emoji font draws on this system.
    static var supportedBySystem: EmojiVersion {
        supported(byOSVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// iOS releases that added each emoji version (iOS 18 was followed by 26).
    static func supported(byOSVersion version: OperatingSystemVersion) -> EmojiVersion {
        switch (version.majorVersion, version.minorVersion) {
        case let (major, minor) where major > 26 || (major == 26 && minor >= 4):
            EmojiVersion(major: 17, minor: 0)
        case let (major, minor) where major > 18 || (major == 18 && minor >= 4):
            EmojiVersion(major: 16, minor: 0)
        case let (major, minor) where major > 17 || (major == 17 && minor >= 4):
            EmojiVersion(major: 15, minor: 1)
        default:
            EmojiVersion(major: 15, minor: 0)
        }
    }
}

/// The user's recently picked palette items, newest first. Each palette keeps
/// its own list under its own key, in the extension's own defaults so it
/// works without Full Access.
struct RecentEmojiStore {
    static let emojiKey = "recentEmoji"
    static let symbolKey = "recentSymbols"
    static let kaomojiKey = "recentKaomoji"
    static let limit = 32

    let defaults: UserDefaults
    var key: String = Self.emojiKey

    var emoji: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func record(_ emoji: String) {
        var list = self.emoji.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: key)
    }
}
