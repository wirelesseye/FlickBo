import XCTest

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let productionOpenCCURL = repositoryRoot.appendingPathComponent("Generated/flickzhuyin.opencc")
private let goldenURL = repositoryRoot.appendingPathComponent("FlickZhuyinTests/Fixtures/opencc-cases.tsv")

final class OpenCCConverterTests: XCTestCase {
    func testMatchesGoldenConversionsFromCompiler() throws {
        let store = try MappedOpenCCStore(url: productionOpenCCURL)
        let golden = try String(contentsOf: goldenURL, encoding: .utf8)
        var converters: [String: OpenCCConverter] = [:]
        var checked = 0
        for line in golden.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, 3, "malformed golden row: \(line)")
            guard fields.count == 3 else { continue }
            let converter = try converters[fields[0]] ?? store.converter(named: fields[0])
            converters[fields[0]] = converter
            XCTAssertEqual(converter.convert(fields[1]), fields[2], "\(fields[0]): \(fields[1])")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 200)
        XCTAssertEqual(
            Set(converters.keys),
            ["t2tw", "tw2t", "t2hk", "hk2t", "t2s", "s2t"]
        )
    }

    func testEveryVariantResolvesItsConversions() throws {
        let store = try MappedOpenCCStore(url: productionOpenCCURL)
        for variant in CharacterVariant.allCases {
            XCTAssertNoThrow(try CandidateTextConverter(variant: variant, store: store), "\(variant)")
        }
        XCTAssertThrowsError(try store.converter(named: "t2jp")) { error in
            XCTAssertEqual(error as? OpenCCStoreError, .unknownConversion("t2jp"))
        }
    }

    func testTextOutsideDictionariesIsUnchanged() throws {
        let converter = try MappedOpenCCStore(url: productionOpenCCURL).converter(named: "t2tw")
        XCTAssertEqual(converter.convert(""), "")
        XCTAssertEqual(converter.convert("abc 123"), "abc 123")
        XCTAssertEqual(converter.convert("ㄓㄨㄥˉ😀爲"), "ㄓㄨㄥˉ😀為")
    }

    func testCandidateTextConverterRoundTrips() throws {
        let store = try MappedOpenCCStore(url: productionOpenCCURL)
        let taiwan = try CandidateTextConverter(variant: .taiwan, store: store)
        XCTAssertEqual(taiwan.display("爲什麼"), "為什麼")
        XCTAssertEqual(taiwan.canonical("為什麼"), "爲什麼")
        XCTAssertEqual(taiwan.display("軟件"), "軟件", "vocabulary is ranked in the lexicon, not converted")

        XCTAssertEqual(try CandidateTextConverter(variant: .mainland, store: store).display("爲什麼"), "为什么")
        let traditional = try CandidateTextConverter(variant: .traditional, store: store)
        XCTAssertTrue(traditional.isIdentity)
        XCTAssertEqual(traditional.display("爲"), "爲")
    }

    func testRejectsInvalidFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let short = directory.appendingPathComponent("short.opencc")
        try Data("FZOPENCC".utf8).write(to: short)
        XCTAssertThrowsError(try MappedOpenCCStore(url: short))

        var data = try Data(contentsOf: productionOpenCCURL)
        data[0] = UInt8(ascii: "X")
        let badMagic = directory.appendingPathComponent("magic.opencc")
        try data.write(to: badMagic)
        XCTAssertThrowsError(try MappedOpenCCStore(url: badMagic)) { error in
            XCTAssertEqual(error as? OpenCCStoreError, .invalidFormat("bad magic"))
        }

        let truncated = directory.appendingPathComponent("truncated.opencc")
        try Data(contentsOf: productionOpenCCURL).prefix(4096).write(to: truncated)
        XCTAssertThrowsError(try MappedOpenCCStore(url: truncated))
    }
}

final class CharacterVariantPipelineTests: ChineseInputTestCase {
    private let wei = [SyllableConstraint(base: "ㄨㄟ", tone: .second)]

    private func pipeline(
        _ variant: CharacterVariant,
        learning: UserLearningStore? = nil
    ) throws -> LexiconChineseInputPipeline {
        let store = try MappedOpenCCStore(url: productionOpenCCURL)
        return try LexiconChineseInputPipeline(
            store: VariantFixtureStore(),
            userLearningStore: learning,
            textConverter: CandidateTextConverter(variant: variant, store: store)
        )
    }

    private var weiTokens: [ZhuyinInputToken] { [.symbol("ㄨ"), .symbol("ㄟ"), .tone(.second)] }
    private var ruanjianTokens: [ZhuyinInputToken] {
        [.symbol("ㄖ"), .symbol("ㄨ"), .symbol("ㄢ"), .tone(.third), .symbol("ㄐ"), .symbol("ㄧ"), .symbol("ㄢ"), .tone(.fourth)]
    }

    func testTaiwanMergesVariantsKeepingTheStrongerWeight() async throws {
        let candidates = try await pipeline(.taiwan).candidates(for: weiTokens)
        let words = candidates.filter { !$0.isRawFallback }
        XCTAssertEqual(words.first?.text, "為")
        XCTAssertEqual(words.first?.canonicalText, "爲")
        XCTAssertEqual(words.filter { $0.text == "為" }.count, 1)
        XCTAssertFalse(words.contains { $0.text == "爲" })
        XCTAssertEqual(Set(candidates.map(\.id)).count, candidates.count)
    }

    func testTraditionalKeepsLexiconForms() async throws {
        let words = try await pipeline(.traditional).candidates(for: weiTokens).filter { !$0.isRawFallback }
        XCTAssertEqual(words.prefix(2).map(\.text), ["爲", "為"])
    }

    func testMainlandConvertsToSimplified() async throws {
        let words = try await pipeline(.mainland).candidates(for: weiTokens).filter { !$0.isRawFallback }
        XCTAssertEqual(words.first?.text, "为")
        XCTAssertEqual(words.first?.canonicalText, "爲")
    }

    func testNoVariantOffersVocabularyUnderAnotherWordsReading() async throws {
        // 軟體 is read ㄖㄨㄢˇ ㄊㄧˇ; typing 軟件's ㄖㄨㄢˇ ㄐㄧㄢˋ never offers it.
        for variant in CharacterVariant.allCases {
            let words = try await pipeline(variant).candidates(for: ruanjianTokens)
            XCTAssertTrue(words.contains { $0.canonicalText == "軟件" }, "\(variant)")
            XCTAssertFalse(words.contains { $0.canonicalText == "軟體" || $0.text == "軟體" }, "\(variant)")
        }
    }

    func testLearningStoresCanonicalText() async throws {
        let url = temporaryURL("learning.sqlite3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let learning = try UserLearningStore(url: url, writable: true)
        let pipeline = try pipeline(.taiwan, learning: learning)
        try await pipeline.recordCommittedSelection(
            chunks: [SelectedChunk(text: "為", canonicalText: "爲", sourceTokens: weiTokens, pronunciation: wei)],
            fullySelected: true
        )
        let counts = try learning.countSnapshot()
        XCTAssertEqual(counts[try XCTUnwrap(UserWordKey(text: "爲", pronunciation: wei))], 1)
        XCTAssertNil(counts[try XCTUnwrap(UserWordKey(text: "為", pronunciation: wei))])
    }

    func testEngineKeepsCanonicalTextOfSelectedCandidate() throws {
        var engine = KeyboardEngine()
        for token in weiTokens {
            switch token {
            case let .symbol(character): _ = engine.update(for: .zhuyin(character))
            case let .tone(tone): _ = engine.update(for: .tone(tone))
            }
        }
        XCTAssertEqual(engine.mode, .zhuyin)
        let candidate = InputCandidate(
            id: CandidateID(text: "為", pronunciation: wei, tokenRange: 0..<3),
            text: "為",
            canonicalText: "爲",
            pronunciation: wei,
            score: 0,
            isRawFallback: false
        )
        let update = engine.selectCandidate(candidate, autoCommit: true)
        XCTAssertEqual(update.documentEffects, [.insertText("為")])
        XCTAssertEqual(engine.lastCommittedChunks.map(\.canonicalText), ["爲"])
    }
}

final class CharacterVariantProductionTests: XCTestCase {
    private let ruanjian = [SyllableConstraint(base: "ㄖㄨㄢ"), SyllableConstraint(base: "ㄐㄧㄢ")]
    private let ruanti = [SyllableConstraint(base: "ㄖㄨㄢ"), SyllableConstraint(base: "ㄊㄧ")]

    func testTaiwanStoreRanksTaiwanVocabularyByTheWordItReplaces() throws {
        let databaseURL = repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: databaseURL.path), "production dictionary not built")
        let plain = try SQLiteLexiconStore(url: databaseURL)
        let taiwan = try SQLiteLexiconStore(url: databaseURL, usesTaiwanWeights: true)
        func weight(_ store: SQLiteLexiconStore, _ text: String, _ syllables: [SyllableConstraint]) throws -> Double {
            try XCTUnwrap(try store.exactMatches(for: syllables).first { $0.text == text }?.sourceWeight)
        }
        let software = try weight(plain, "軟件", ruanjian)
        XCTAssertLessThan(try weight(plain, "軟體", ruanti), software)
        XCTAssertEqual(try weight(taiwan, "軟體", ruanti), software, accuracy: 1e-12)
        XCTAssertEqual(try weight(taiwan, "軟件", ruanjian), software, accuracy: 1e-12)
        // Added Taiwan words stay last outside Taiwan forms.
        let middleware = [
            SyllableConstraint(base: "ㄓㄨㄥ"), SyllableConstraint(base: "ㄐㄧㄝ"),
            SyllableConstraint(base: "ㄖㄨㄢ"), SyllableConstraint(base: "ㄊㄧ"),
        ]
        XCTAssertEqual(try weight(plain, "中介軟體", middleware), 0)
        XCTAssertGreaterThan(try weight(taiwan, "中介軟體", middleware), 0.3)

        // Abbreviated input scans by weight with a limit; the Taiwan weight counts there too.
        let patterns: [SyllableMatchPattern] = [.initial("ㄖ"), .initial("ㄊ")]
        let taiwanMatches = try taiwan.patternMatches(for: patterns, resultLimit: 64, scanLimit: 512)
        let plainMatches = try plain.patternMatches(for: patterns, resultLimit: 64, scanLimit: 512)
        let taiwanIndex = try XCTUnwrap(taiwanMatches.firstIndex { $0.text == "軟體" })
        XCTAssertLessThan(taiwanIndex, plainMatches.firstIndex { $0.text == "軟體" } ?? Int.max)
        XCTAssertEqual(try XCTUnwrap(taiwanMatches[taiwanIndex].sourceWeight), software, accuracy: 1e-12)
        let taiwanWeights = taiwanMatches.map { $0.sourceWeight ?? $0.pronunciationWeight ?? -1 }
        XCTAssertEqual(taiwanWeights, taiwanWeights.sorted(by: >))
    }

    func testProductionLexiconPrefersRegionalForms() async throws {
        let databaseURL = repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: databaseURL.path), "production dictionary not built")
        let openCC = try MappedOpenCCStore(url: productionOpenCCURL)
        let input: [ZhuyinInputToken] = [
            .symbol("ㄨ"), .symbol("ㄟ"), .tone(.fourth),
            .symbol("ㄕ"), .symbol("ㄣ"), .tone(.second),
            .symbol("ㄇ"), .symbol("ㄜ"), .tone(.neutral),
        ]
        let expectations: [(CharacterVariant, String)] = [
            (.taiwan, "為什麼"), (.hongKong, "為什麼"), (.mainland, "为什么"), (.traditional, "爲什麼"),
        ]
        for (variant, expected) in expectations {
            let pipeline = try LexiconChineseInputPipeline(
                store: SQLiteLexiconStore(url: databaseURL),
                textConverter: CandidateTextConverter(variant: variant, store: openCC)
            )
            let first = try await pipeline.candidates(for: input).first
            XCTAssertEqual(first?.text, expected, "\(variant)")
            XCTAssertEqual(first?.canonicalText, "爲什麼", "\(variant)")
        }
    }

    func testTaiwanReadingOfShenmeTypesWeishenme() async throws {
        let databaseURL = repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3")
        let grammarURL = repositoryRoot.appendingPathComponent("Generated/flickzhuyin.gram")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: databaseURL.path), "production dictionary not built")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: grammarURL.path), "production grammar not built")
        let pipeline = try LexiconChineseInputPipeline(
            store: SQLiteLexiconStore(url: databaseURL),
            decoder: Decoder(
                configuration: DecoderConfiguration(maximumCandidates: 30),
                grammar: OctagramGrammar(store: MappedGramStore(url: grammarURL))
            ),
            textConverter: CandidateTextConverter(
                variant: .taiwan,
                store: MappedOpenCCStore(url: productionOpenCCURL)
            )
        )
        let she: [ZhuyinInputToken] = [
            .symbol("ㄨ"), .symbol("ㄟ"), .tone(.fourth),
            .symbol("ㄕ"), .symbol("ㄜ"), .tone(.second),
            .symbol("ㄇ"), .symbol("ㄜ"), .tone(.neutral),
        ]
        let withTones = try await pipeline.candidates(for: she)
        XCTAssertEqual(withTones.first?.text, "為什麼")
        let toneless = try await pipeline.candidates(for: she.filter {
            if case .symbol = $0 { return true }
            return false
        })
        XCTAssertEqual(toneless.first?.text, "為什麼")
    }
}

private struct VariantFixtureStore: LexiconStore {
    func syllableInventory() throws -> [String] { ["ㄨㄟ", "ㄖㄨㄢ", "ㄐㄧㄢ"] }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        let readings: [[CanonicalSyllable]: [(String, Double)]] = [
            [CanonicalSyllable(base: "ㄨㄟ", tone: .second)]: [("爲", 0.8), ("為", 0.4)],
            [CanonicalSyllable(base: "ㄖㄨㄢ", tone: .third)]: [("軟", 0.5)],
            [CanonicalSyllable(base: "ㄐㄧㄢ", tone: .fourth)]: [("件", 0.5)],
            [
                CanonicalSyllable(base: "ㄖㄨㄢ", tone: .third),
                CanonicalSyllable(base: "ㄐㄧㄢ", tone: .fourth),
            ]: [("軟件", 0.7)],
        ]
        return readings.flatMap { reading, words -> [LexiconMatch] in
            guard reading.count == syllables.count,
                  zip(reading, syllables).allSatisfy({ $0.base == $1.base && ($1.tone == nil || $1.tone == $0.tone) })
            else { return [] }
            return words.map { LexiconMatch(text: $0.0, pronunciation: reading, sourceWeight: $0.1) }
        }
    }

    func patternMatches(
        for patterns: [SyllableMatchPattern],
        resultLimit: Int,
        scanLimit: Int
    ) throws -> [LexiconMatch] { [] }
}
