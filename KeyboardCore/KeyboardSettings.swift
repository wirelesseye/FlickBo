import Foundation
import OSLog

enum KeyboardSettings {
    private static let logger = Logger(subsystem: "com.wirelesseye.FlickBo", category: "AppGroup")
    private static let originalBundleIdentifier = "com.wirelesseye.FlickBo"
    private static let originalAppGroup = "group." + originalBundleIdentifier
    static let showsDirectionalSymbolsKey = "showsDirectionalSymbols"
    static let autoCommitCompositionKey = "autoCommitComposition"
    static let remembersSelectionsKey = "remembersSelections"
    static let abcUsesFlickLayoutKey = "abcUsesFlickLayout"
    static let characterVariantKey = "characterVariant"
    static let showsEmojiCandidatesKey = "showsEmojiCandidates"
    static let recentItemsClearRequestKey = "recentItemsClearRequest"

    private static let appGroupCandidates: [String] = {
        guard let bundleID = Bundle.main.bundleIdentifier,
              bundleID.hasPrefix(originalBundleIdentifier + ".") else {
            return [originalAppGroup]
        }

        // SideStore normally adds the same team suffix to the app ID and App Group.
        // The extension keeps its own suffix after the rewritten parent app ID.
        let teamID = bundleID.dropFirst(originalBundleIdentifier.count + 1)
            .prefix(while: { $0 != "." })
        guard teamID.utf8.count == 10,
              teamID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            return [originalAppGroup]
        }
        return ["\(originalAppGroup).\(teamID)", originalAppGroup]
    }()

    private static var sharedContainer: (identifier: String, url: URL)? {
        for identifier in appGroupCandidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return (identifier, url)
            }
        }
        return nil
    }

    static var appGroupIdentifier: String? { sharedContainer?.identifier }

    static var sharedDefaults: UserDefaults? {
        guard let identifier = appGroupIdentifier else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    static func logAppGroupStatus() {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        if let identifier = appGroupIdentifier {
            logger.notice("\(bundleID, privacy: .public) uses \(identifier, privacy: .public)")
        } else {
            let candidates = appGroupCandidates.joined(separator: ", ")
            logger.error("\(bundleID, privacy: .public) cannot access App Group: \(candidates, privacy: .public)")
        }
    }

    static var showsDirectionalSymbols: Bool {
        get { boolValue(for: showsDirectionalSymbolsKey) }
        set { sharedDefaults?.set(newValue, forKey: showsDirectionalSymbolsKey) }
    }

    static var autoCommitComposition: Bool {
        get { boolValue(for: autoCommitCompositionKey) }
        set { sharedDefaults?.set(newValue, forKey: autoCommitCompositionKey) }
    }

    static var remembersSelections: Bool {
        get { boolValue(for: remembersSelectionsKey) }
        set { sharedDefaults?.set(newValue, forKey: remembersSelectionsKey) }
    }

    /// Per-mode full-width preference; mode names are `zhuyin`, `number` and `abc`.
    /// Zhuyin defaults to full-width punctuation, the other modes to half-width.
    static func usesFullWidth(inMode mode: String) -> Bool {
        sharedDefaults?.object(forKey: fullWidthKey(mode)) as? Bool ?? (mode == "zhuyin")
    }

    static func setUsesFullWidth(_ value: Bool, inMode mode: String) {
        sharedDefaults?.set(value, forKey: fullWidthKey(mode))
    }

    private static func fullWidthKey(_ mode: String) -> String {
        "usesFullWidth." + mode
    }

    /// Offers rime-emoji emoji after matching word candidates.
    static var showsEmojiCandidates: Bool {
        get { boolValue(for: showsEmojiCandidatesKey) }
        set { sharedDefaults?.set(newValue, forKey: showsEmojiCandidatesKey) }
    }

    static var abcUsesFlickLayout: Bool {
        get { boolValue(for: abcUsesFlickLayoutKey) }
        set { sharedDefaults?.set(newValue, forKey: abcUsesFlickLayoutKey) }
    }

    /// Character forms for Chinese candidates; defaults to Taiwan.
    static var characterVariant: CharacterVariant {
        get {
            (sharedDefaults?.string(forKey: characterVariantKey)).flatMap(CharacterVariant.init(rawValue:)) ?? .taiwan
        }
        set { sharedDefaults?.set(newValue.rawValue, forKey: characterVariantKey) }
    }

    /// Counts the app's requests to clear the palettes' recent items. The
    /// recent items live in the keyboard's own defaults, out of the app's
    /// reach, so the keyboard clears them when it sees the count go up.
    static var recentItemsClearRequest: Int {
        sharedDefaults?.integer(forKey: recentItemsClearRequestKey) ?? 0
    }

    /// Returns false when the shared settings are unavailable.
    @discardableResult
    static func requestClearingRecentItems() -> Bool {
        guard let defaults = sharedDefaults else { return false }
        defaults.set(defaults.integer(forKey: recentItemsClearRequestKey) + 1, forKey: recentItemsClearRequestKey)
        return true
    }

    static var userLearningURL: URL? {
        sharedContainer?.url.appendingPathComponent(UserLearningStore.fileName)
    }

    private static func boolValue(for key: String) -> Bool {
        sharedDefaults?.object(forKey: key) as? Bool ?? true
    }
}
