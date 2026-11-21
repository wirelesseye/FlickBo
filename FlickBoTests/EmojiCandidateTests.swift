import XCTest

private let productionEmojiURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Generated/flickbo.emoji")

final class EmojiCandidateTests: ChineseInputTestCase {
    private let nihao = [
        SyllableConstraint(base: "ㄋㄧ", tone: .third),
        SyllableConstraint(base: "ㄏㄠ", tone: .third),
    ]

    func testTableParsesWordsAndRejectsMalformedLines() throws {
        let table = try EmojiTable(text: "你好\t👋 🙂\n笑\t😄️\n")
        XCTAssertEqual(table.wordCount, 2)
        XCTAssertEqual(table.emoji(for: "你好"), ["👋", "🙂"])
        XCTAssertEqual(table.emoji(for: "中文"), [])
        XCTAssertThrowsError(try EmojiTable(text: "你好\t👋\n笑 😄\n")) { error in
            XCTAssertEqual(error as? EmojiTableError, .malformedLine(2))
        }
    }

    func testProductionTableHasRepresentativeWords() throws {
        let table = try EmojiTable(url: productionEmojiURL)
        XCTAssertGreaterThan(table.wordCount, 4000)
        XCTAssertEqual(table.emoji(for: "笑"), ["😄️", "😸️"])
        XCTAssertTrue(table.emoji(for: "高興").contains("😊️"))
    }

    func testProductionPipelineOffersEmojiAfterXiao() async throws {
        let root = productionEmojiURL.deletingLastPathComponent()
        let grammarURL = root.appendingPathComponent("flickbo.gram")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: grammarURL.path), "run build-grammar first")
        let pipeline = try LexiconChineseInputPipeline(
            store: try SQLiteLexiconStore(url: root.appendingPathComponent("flickbo.sqlite3"), usesTaiwanWeights: true),
            decoder: Decoder(
                configuration: DecoderConfiguration(maximumCandidates: 30),
                grammar: OctagramGrammar(store: try MappedGramStore(url: grammarURL))
            ),
            textConverter: try CandidateTextConverter(
                variant: .taiwan,
                store: try MappedOpenCCStore(url: root.appendingPathComponent("flickbo.opencc"))
            ),
            emojiTable: try EmojiTable(url: productionEmojiURL)
        )
        let candidates = try await pipeline.candidates(for: tokens("ㄒㄧㄠ") + [.tone(.fourth)])
        let texts = candidates.map(\.text)
        let xiao = try XCTUnwrap(texts.firstIndex(of: "笑"), "\(texts.prefix(10))")
        XCTAssertLessThan(xiao, LexiconChineseInputPipeline.emojiSourceCandidateLimit)
        XCTAssertEqual(Array(texts[(xiao + 1)...(xiao + 2)]), ["😄️", "😸️"])
        XCTAssertFalse(candidates[0].isEmoji)
    }

    func testEmojiFollowsTheWordAndNeverLeads() async throws {
        let pipeline = try LexiconChineseInputPipeline(
            store: try makeFixtureStore(),
            emojiTable: try EmojiTable(text: "你好\t👋 🙂\n")
        )
        let candidates = try await pipeline.candidates(for: tokens("ㄋㄧㄏㄠ"))
        let word = try XCTUnwrap(candidates.firstIndex { $0.text == "你好" })
        XCTAssertFalse(candidates[0].isEmoji)
        XCTAssertEqual(candidates[word + 1].text, "👋")
        XCTAssertEqual(candidates[word + 2].text, "🙂")
        XCTAssertTrue(candidates[word + 1].isEmoji)
        XCTAssertEqual(candidates[word + 1].pronunciation, candidates[word].pronunciation)
        XCTAssertEqual(candidates.filter(\.isEmoji).count, 2)
        XCTAssertNotEqual(
            CandidateItem.input(candidates[word + 1]).accessibilityIdentifier,
            CandidateItem.input(candidates[word]).accessibilityIdentifier
        )
    }

    func testOnlyLeadingCandidatesOfferEmoji() async throws {
        let zhi = SyllableConstraint(base: "ㄓ")
        let words = Array("之只知紙支志").enumerated().map { index, character in
            LexiconMatch(
                text: String(character),
                pronunciation: [CanonicalSyllable(base: "ㄓ", tone: .first)],
                sourceWeight: 0.9 - Double(index) * 0.1
            )
        }
        let store = StubLexiconStore(inventory: ["ㄓ"], responses: [[zhi]: words])
        let plain = try LexiconChineseInputPipeline(store: store)
        let ranked = try await plain.candidates(for: tokens("ㄓ")).filter { !$0.isRawFallback }.map(\.text)
        let limit = LexiconChineseInputPipeline.emojiSourceCandidateLimit
        XCTAssertGreaterThan(ranked.count, limit)
        let pipeline = try LexiconChineseInputPipeline(
            store: store,
            emojiTable: try EmojiTable(text: "\(ranked[0])\t😀\n\(ranked[limit])\t🐢\n")
        )
        let candidates = try await pipeline.candidates(for: tokens("ㄓ"))
        XCTAssertEqual(candidates.filter(\.isEmoji).map(\.text), ["😀"])
    }

    func testWithoutTableThereAreNoEmoji() async throws {
        let pipeline = try LexiconChineseInputPipeline(store: try makeFixtureStore())
        let candidates = try await pipeline.candidates(for: tokens("ㄋㄧㄏㄠ"))
        XCTAssertFalse(candidates.contains(where: \.isEmoji))
    }

    func testSelectedEmojiIsNotLearned() async throws {
        let url = temporaryURL("learning.sqlite3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let learning = try UserLearningStore(url: url, writable: true)
        let pipeline = try LexiconChineseInputPipeline(store: try makeFixtureStore(), userLearningStore: learning)
        let word = SelectedChunk(text: "你好", sourceTokens: tokens("ㄋㄧㄏㄠ"), pronunciation: nihao)
        let emoji = SelectedChunk(text: "👋", sourceTokens: tokens("ㄋㄧㄏㄠ"), pronunciation: nihao, isEmoji: true)
        try await pipeline.recordCommittedSelection(chunks: [word, emoji], fullySelected: true)
        let counts = try learning.countSnapshot()
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts[try XCTUnwrap(UserWordKey(text: "你好", pronunciation: nihao))], 1)
        try await pipeline.recordCommittedSelection(chunks: [emoji], fullySelected: true)
        XCTAssertEqual(try learning.countSnapshot().count, 1)
    }

    func testSelectingEmojiMarksTheChunkAndEndsGrammarContext() {
        var engine = KeyboardEngine()
        for symbol in "ㄋㄧㄏㄠ" {
            _ = engine.update(for: .zhuyin(symbol))
        }
        let word = InputCandidate(
            id: CandidateID(text: "你好", pronunciation: nihao, tokenRange: 0..<4),
            text: "你好",
            pronunciation: nihao,
            score: 0,
            isRawFallback: false
        )
        _ = engine.selectCandidate(.emoji("👋", for: word))
        XCTAssertEqual(engine.composition.markedText, "👋")
        XCTAssertEqual(engine.composition.selectedChunks.map(\.isEmoji), [true])

        var composition = ZhuyinComposition()
        composition.pieces = [
            .selected(SelectedChunk(text: "你好", sourceTokens: [], pronunciation: nihao)),
            .selected(SelectedChunk(text: "👋", sourceTokens: [], pronunciation: nihao, isEmoji: true)),
            .selected(SelectedChunk(text: "中", sourceTokens: [], pronunciation: [])),
            .token(.symbol("ㄨ")),
        ]
        composition.caretIndex = 4
        XCTAssertEqual(composition.precedingContext.text, "中")
        XCTAssertFalse(composition.precedingContext.reachesStart)
    }
}
