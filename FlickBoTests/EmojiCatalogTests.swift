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

    func testSearchRanksExactThenPrefixThenContainedWords() throws {
        let catalog = try EmojiCatalog(text: """
        animals\t0.6\t🐱\tcat face
        animals\t0.7\t🐈\tcat
        animals\t1.0\t🐼\tpanda
        animals\t0.6\t🦉\towl
        symbols\t0.6\t❤️\tred heart

        """, maximumVersion: EmojiVersion(major: 17, minor: 0))
        // rime-emoji writes a selector after most emoji; 🫠 is not in this catalog.
        let table = try EmojiTable(text: "熊貓\t🐼️\n貓\t🐈️ 🐱️\n貓頭鷹\t🦉️\n貓咪\t🐱️ 🫠\n愛心\t❤️\n")
        let index = EmojiSearchIndex(table: table, catalog: catalog)

        XCTAssertEqual(index.search("貓"), ["🐈", "🐱", "🦉", "🐼"])
        XCTAssertEqual(index.search(" 心 "), ["❤️"])
        XCTAssertEqual(index.search("狗"), [])
        XCTAssertEqual(index.search(""), [])
        XCTAssertEqual(index.search("貓", limit: 1), ["🐈"])
    }

    func testSearchMatchesEnglishNamesOnlyForLatinQueries() throws {
        let catalog = try EmojiCatalog(text: "animals\t0.6\t🐱\tcat face\nsmileys\t0.6\t😸\tgrinning cat with smiling eyes\nanimals\t0.6\t🐸\tfrog\n")
        let index = EmojiSearchIndex(table: try EmojiTable(text: ""), catalog: catalog)
        XCTAssertEqual(index.search("Cat"), ["🐱", "😸"])
        XCTAssertEqual(index.search("rog"), ["🐸"])
    }

    func testProductionSearchFindsCatsForChineseAndEnglish() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try EmojiCatalog(
            text: String(contentsOf: root.appendingPathComponent("Generated/flickbo.emojicatalog"), encoding: .utf8),
            maximumVersion: EmojiVersion(major: 17, minor: 0)
        )
        let table = try EmojiTable(url: root.appendingPathComponent("Generated/flickbo.emoji"))
        let keywords = try EmojiKeywordTable(
            text: String(contentsOf: root.appendingPathComponent("Generated/flickbo.emojikeywords"), encoding: .utf8)
        )
        XCTAssertEqual(keywords.entries.count, 1914)
        let index = EmojiSearchIndex(table: table, catalog: catalog, keywords: keywords)
        let cats = index.search("貓")
        XCTAssertEqual(cats.first, "🐈")
        // CLDR adds the cat faces, which rime-emoji does not list under 貓.
        XCTAssertTrue(cats.contains("🐱") && cats.contains("😸"), "\(cats)")
        XCTAssertTrue(index.search("cat").contains("🐈"))
        XCTAssertTrue(index.search("笑").contains("😄"))
        XCTAssertTrue(index.search("台灣").contains("🇹🇼"))
    }

    func testKeywordTermsJoinRimeWordsWithoutRepeats() throws {
        let catalog = try EmojiCatalog(
            text: "animals\t0.7\t🐈\tcat\nsmileys\t0.6\t😸\tgrinning cat\n",
            maximumVersion: EmojiVersion(major: 17, minor: 0)
        )
        let keywords = try EmojiKeywordTable(text: "🐈\t貓\t小貓\n😸\t微笑的貓臉\t笑臉\n")
        let index = EmojiSearchIndex(table: try EmojiTable(text: "貓\t🐈️\n"), catalog: catalog, keywords: keywords)
        XCTAssertEqual(index.search("貓"), ["🐈", "😸"])
        XCTAssertEqual(index.search("笑臉"), ["😸"])
        XCTAssertThrowsError(try EmojiKeywordTable(text: "🐈\n")) { error in
            XCTAssertEqual(error as? EmojiCatalogError, .malformedLine(1))
        }
    }

    @MainActor
    func testSearchQueryKeepsMarkedTextApartAndReplacesItOnInsert() {
        let query = EmojiSearchQuery()
        let applier = DocumentEffectApplier(client: query)
        applier.apply([.setMarkedText("ㄇㄠ", caret: 2)])
        XCTAssertEqual(query.committedText, "")
        XCTAssertEqual(query.markedText, "ㄇㄠ")
        applier.apply([.insertText("貓")])
        XCTAssertEqual(query.committedText, "貓")
        XCTAssertEqual(query.markedText, "")
        applier.apply([.setMarkedText("ㄇ", caret: 1), .unmarkText, .deleteBackward, .deleteBackward, .moveCursor(by: -1)])
        XCTAssertEqual(query.committedText, "")
        XCTAssertTrue(query.isEmpty)
        applier.apply([.insertText("貓咪")])
        query.clear()
        XCTAssertTrue(query.isEmpty)
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
