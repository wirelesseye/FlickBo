import XCTest

final class SymbolPaletteTests: XCTestCase {
    func testPalettesGroupItemsInPaletteOrderAndKeepSpaces() throws {
        let palettes = try SymbolPalettes(text: "symbol\tmath\t±\nsymbol\tpunctuation\t\u{3000}\nsymbol\tarrows\t→\nkaomoji\tsweat\t(^_^;)\nkaomoji\tsmile\t(^^)\n")
        XCTAssertEqual(palettes.symbols.map(\.category), [.punctuation, .arrows, .math])
        XCTAssertEqual(palettes.symbols[0].items, ["\u{3000}"])
        XCTAssertEqual(palettes.kaomoji.map(\.category), [.smile, .sweat])
        XCTAssertEqual(palettes.kaomoji[1].items, ["(^_^;)"])
    }

    func testPalettesRejectMalformedLines() {
        for (text, line) in [
            ("symbol\tshapes\n", 1),
            ("symbol\tshapes\t☆\nsymbol\trecent\t★\n", 2),
            ("kaomoji\tshapes\t(^^)\n", 1),
            ("emoji\tsmileys\t😀\n", 1),
            ("symbol\tshapes\t\n", 1),
        ] {
            XCTAssertThrowsError(try SymbolPalettes(text: text)) { error in
                XCTAssertEqual(error as? EmojiCatalogError, .malformedLine(line))
            }
        }
    }

    func testProductionPalettesLoadFromKeyboardResource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Generated/flickbo.symbols")
        let palettes = try SymbolPalettes(text: String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(palettes.symbols.map(\.category), Array(SymbolCategory.allCases.dropFirst()))
        XCTAssertEqual(palettes.kaomoji.map(\.category), Array(KaomojiCategory.allCases.dropFirst()))
        XCTAssertEqual(palettes.symbols.reduce(0) { $0 + $1.items.count }, 2173)
        XCTAssertEqual(palettes.kaomoji.reduce(0) { $0 + $1.items.count }, 199)
        XCTAssertEqual(palettes.symbols.first?.items.prefix(3), ["\u{3000}", "，", "。"])
        XCTAssertTrue(palettes.symbols.last?.items.contains("ㄅ") ?? false)
    }

    func testEachPaletteKeepsItsOwnRecentItems() throws {
        let suite = "SymbolPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let emoji = RecentEmojiStore(defaults: defaults)
        let symbols = RecentEmojiStore(defaults: defaults, key: RecentEmojiStore.symbolKey)
        let kaomoji = RecentEmojiStore(defaults: defaults, key: RecentEmojiStore.kaomojiKey)
        emoji.record("😀")
        symbols.record("☆")
        kaomoji.record("(^^)")
        XCTAssertEqual(emoji.emoji, ["😀"])
        XCTAssertEqual(symbols.emoji, ["☆"])
        XCTAssertEqual(kaomoji.emoji, ["(^^)"])
    }

    func testClearRequestClearsEveryPaletteOnce() throws {
        let suite = "SymbolPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = [RecentEmojiStore.emojiKey, RecentEmojiStore.symbolKey, RecentEmojiStore.kaomojiKey]
            .map { RecentEmojiStore(defaults: defaults, key: $0) }
        stores.forEach { $0.record("☆") }

        XCTAssertFalse(RecentEmojiStore.clearAll(ifRequested: 0, in: defaults))
        XCTAssertEqual(stores.map(\.emoji), [["☆"], ["☆"], ["☆"]])

        XCTAssertTrue(RecentEmojiStore.clearAll(ifRequested: 1, in: defaults))
        XCTAssertEqual(stores.map(\.emoji), [[], [], []])

        // Picks made after a request has been handled are kept until the next request.
        stores[1].record("→")
        XCTAssertFalse(RecentEmojiStore.clearAll(ifRequested: 1, in: defaults))
        XCTAssertEqual(stores[1].emoji, ["→"])
        XCTAssertTrue(RecentEmojiStore.clearAll(ifRequested: 2, in: defaults))
        XCTAssertEqual(stores[1].emoji, [])
    }
}
