import XCTest

final class EmojiCatalogTests: XCTestCase {
    private let sample = """
    smileys\t1.0\t😀\tgrinning face
    smileys\t16.0\t🫩\tface with bags under eyes
    people\t0.6\t👋\twaving hand
    flags\t2.0\t🇹🇼\tflag: Taiwan

    """

    func testCatalogGroupsEntriesInPaletteOrderAndHidesNewerEmoji() throws {
        let catalog = try EmojiCatalog(text: sample, maximumVersion: EmojiVersion(major: 15, minor: 1))
        XCTAssertEqual(catalog.sections.map(\.category), [.smileys, .people, .flags])
        XCTAssertEqual(catalog.sections[0].entries, [EmojiEntry(emoji: "😀", name: "grinning face")])

        let newer = try EmojiCatalog(text: sample, maximumVersion: EmojiVersion(major: 16, minor: 0))
        XCTAssertEqual(newer.sections[0].entries.map(\.emoji), ["😀", "🫩"])
    }

    func testCatalogRejectsMalformedLines() {
        for (text, line) in [("smileys\t1.0\t😀\n", 1), ("smileys\t1.0\t😀\tx\nrecent\t1.0\t😀\tx\n", 2), ("gadgets\t1.0\t📱\tphone\n", 1)] {
            XCTAssertThrowsError(try EmojiCatalog(text: text)) { error in
                XCTAssertEqual(error as? EmojiCatalogError, .malformedLine(line))
            }
        }
    }

    func testProductionCatalogLoadsFromKeyboardResource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Generated/flickbo.emojicatalog")
        let text = try String(contentsOf: url, encoding: .utf8)
        let catalog = try EmojiCatalog(text: text, maximumVersion: EmojiVersion(major: 17, minor: 0))
        XCTAssertEqual(catalog.sections.map(\.category), Array(EmojiCategory.allCases.dropFirst()))
        XCTAssertEqual(catalog.sections.reduce(0) { $0 + $1.entries.count }, 1914)
        XCTAssertEqual(catalog.sections.first?.entries.first?.emoji, "😀")
    }

    func testSupportedVersionFollowsIOSReleases() {
        func version(_ major: Int, _ minor: Int) -> EmojiVersion {
            EmojiVersion.supported(byOSVersion: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
        XCTAssertEqual(version(17, 0), EmojiVersion(major: 15, minor: 0))
        XCTAssertEqual(version(17, 4), EmojiVersion(major: 15, minor: 1))
        XCTAssertEqual(version(18, 3), EmojiVersion(major: 15, minor: 1))
        XCTAssertEqual(version(18, 4), EmojiVersion(major: 16, minor: 0))
        XCTAssertEqual(version(26, 3), EmojiVersion(major: 16, minor: 0))
        XCTAssertEqual(version(26, 4), EmojiVersion(major: 17, minor: 0))
        XCTAssertEqual(version(27, 0), EmojiVersion(major: 17, minor: 0))
        XCTAssertNil(EmojiVersion("16"))
        XCTAssertLessThan(EmojiVersion(major: 15, minor: 1), EmojiVersion(major: 16, minor: 0))
    }

    func testRecentEmojiMovesRepeatsToTheFrontAndKeepsTheLimit() throws {
        let suite = "EmojiCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentEmojiStore(defaults: defaults)
        store.record("😀")
        store.record("👋")
        store.record("😀")
        XCTAssertEqual(store.emoji, ["😀", "👋"])
        for index in 0..<40 { store.record(String(UnicodeScalar(0x1F400 + index)!)) }
        XCTAssertEqual(store.emoji.count, RecentEmojiStore.limit)
        XCTAssertEqual(store.emoji.first, "\u{1F427}")
    }

    func testCommitCompositionKeepsPendingTextAndClearsComposition() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.commitComposition(), .none)
        _ = engine.update(for: .zhuyin("ㄓ"))
        XCTAssertFalse(engine.composition.isEmpty)
        XCTAssertEqual(
            engine.commitComposition(),
            KeyboardUpdate(documentEffects: [.unmarkText], invalidatesCandidates: true)
        )
        XCTAssertTrue(engine.composition.isEmpty)
        XCTAssertEqual(engine.commitComposition(), .none)
    }
}
