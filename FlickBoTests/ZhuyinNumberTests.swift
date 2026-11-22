import XCTest

final class ZhuyinNumberTests: ChineseInputTestCase {
    private func zhuyinTokens(_ input: String) -> [ZhuyinInputToken] {
        input.map { character in
            switch character {
            case "ˉ": .tone(.first)
            case "ˊ": .tone(.second)
            case "ˇ": .tone(.third)
            case "ˋ": .tone(.fourth)
            case "˙": .tone(.neutral)
            default: .symbol(character)
            }
        }
    }

    func testSingleDigits() {
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "零"), "0")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "〇"), "0")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一"), "1")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "二"), "2")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "三"), "3")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "四"), "4")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "五"), "5")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "六"), "6")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "七"), "7")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "八"), "8")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "九"), "9")
    }

    func testDigitSequences() {
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一二三"), "123")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "二零二六"), "2026")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "二〇二六"), "2026")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "零零七"), "007")
    }

    func testPositionalNumbers() {
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "十"), "10")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "十三"), "13")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "二十"), "20")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "二十三"), "23")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "廿"), "20")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "卅"), "30")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一百"), "100")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一百零三"), "103")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一百二"), "120")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "兩百五"), "250")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一千零五"), "1005")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "兩千三"), "2300")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一萬"), "10000")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一萬五"), "15000")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一萬零五十"), "10050")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "十三萬"), "130000")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "一億"), "100000000")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "十億"), "1000000000")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "兩億三千萬"), "230000000")
        XCTAssertEqual(ChineseNumberConverter.arabicNumber(for: "壹拾參"), "13")
    }

    func testNonNumberWordsAreRejected() {
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: ""))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "十分"))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "第一"))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "兩"))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "百"))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "萬"))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "一百零"))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "十百"))
        XCTAssertNil(ChineseNumberConverter.arabicNumber(for: "你好"))
    }

    private struct StubLexiconStore: LexiconStore {
        let entries: [LexiconMatch]

        func syllableInventory() throws -> [String] {
            Array(Set(entries.flatMap { $0.pronunciation.map(\.base) }))
        }

        func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
            entries.filter { entry in
                entry.pronunciation.count == syllables.count
                    && zip(entry.pronunciation, syllables).allSatisfy { syllable, constraint in
                        syllable.base == constraint.base
                            && (constraint.tone == nil || constraint.tone == syllable.tone)
                    }
            }
        }

        func patternMatches(
            for patterns: [SyllableMatchPattern],
            resultLimit: Int,
            scanLimit: Int
        ) throws -> [LexiconMatch] {
            entries.filter { entry in
                entry.pronunciation.count == patterns.count
                    && zip(entry.pronunciation, patterns).allSatisfy { syllable, pattern in
                        pattern.accepts(base: syllable.base, tone: syllable.tone)
                    }
            }
        }
    }

    @MainActor
    func testPipelineOffersHalfAndFullWidthNumberCandidatesWithBadge() async throws {
        let store = StubLexiconStore(entries: [
            LexiconMatch(
                text: "十三",
                pronunciation: [
                    CanonicalSyllable(base: "ㄕ", tone: .second),
                    CanonicalSyllable(base: "ㄙㄢ", tone: .first)
                ],
                sourceWeight: 0.9
            ),
            LexiconMatch(
                text: "十",
                pronunciation: [CanonicalSyllable(base: "ㄕ", tone: .second)],
                sourceWeight: 0.8
            ),
            LexiconMatch(
                text: "三",
                pronunciation: [CanonicalSyllable(base: "ㄙㄢ", tone: .first)],
                sourceWeight: 0.8
            )
        ])
        let pipeline = try LexiconChineseInputPipeline(store: store)
        let candidates = try await pipeline.candidates(for: zhuyinTokens("ㄕˊㄙㄢˉ"))
        XCTAssertEqual(candidates.prefix(3).map(\.text), ["十三", "13", "１３"])

        let halfItem = CandidateItem.input(candidates[1])
        let fullItem = CandidateItem.input(candidates[2])
        XCTAssertNil(halfItem.badge)
        XCTAssertEqual(fullItem.badge, "全")
        XCTAssertEqual(fullItem.accessibilityLabel, "全形：１３")

        let button = CandidateButton()
        button.update(with: fullItem, adjustsTitleToFit: false)
        XCTAssertEqual(button.badgeText, "全")
        XCTAssertEqual(button.accessibilityLabel, "全形：１３")
        XCTAssertEqual(
            button.titleInsets.right,
            CandidateMetrics.contentInsets.right + CandidateMetrics.badgeWidth("全")
        )
    }

    func testSelectingNumberCandidateDoesNotLearnIntoUserStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlickBoNumberTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let learningStore = try UserLearningStore(
            url: directory.appendingPathComponent("user.sqlite3"),
            writable: true
        )
        let store = StubLexiconStore(entries: [
            LexiconMatch(
                text: "十三",
                pronunciation: [
                    CanonicalSyllable(base: "ㄕ", tone: .second),
                    CanonicalSyllable(base: "ㄙㄢ", tone: .first)
                ],
                sourceWeight: 0.9
            )
        ])
        let pipeline = try LexiconChineseInputPipeline(store: store, userLearningStore: learningStore)
        let candidates = try await pipeline.candidates(for: zhuyinTokens("ㄕˊㄙㄢˉ"))
        let fullCandidate = try XCTUnwrap(candidates.first { $0.text == "１３" })

        var engine = KeyboardEngine(mode: .zhuyin)
        for token in zhuyinTokens("ㄕˊㄙㄢˉ") {
            switch token {
            case let .symbol(ch): _ = engine.update(for: .zhuyin(ch))
            case let .tone(tone): _ = engine.update(for: .tone(tone))
            }
        }
        let update = engine.selectCandidate(fullCandidate, autoCommit: true)
        XCTAssertEqual(update.documentEffects, [.insertText("１３")])

        try await pipeline.recordCommittedSelection(
            chunks: engine.lastCommittedChunks,
            fullySelected: engine.lastCommitWasFullySelected
        )
        let snapshot = try learningStore.countSnapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testCurrentTimeFormatting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let afternoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 16, minute: 4)))
        XCTAssertEqual(
            CurrentTimeCandidates.formattedStrings(for: afternoon, calendar: calendar),
            ["16:04", "下午4:04", "4:04 PM"]
        )

        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 0, minute: 5)))
        XCTAssertEqual(
            CurrentTimeCandidates.formattedStrings(for: midnight, calendar: calendar),
            ["00:05", "上午12:05", "12:05 AM"]
        )

        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12, minute: 0)))
        XCTAssertEqual(
            CurrentTimeCandidates.formattedStrings(for: noon, calendar: calendar),
            ["12:00", "下午12:00", "12:00 PM"]
        )
    }

    @MainActor
    func testPipelineOffersCurrentTimeCandidatesWithBadge() async throws {
        let fixedDate = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 16, minute: 4))
        )
        let store = StubLexiconStore(entries: [
            LexiconMatch(
                text: "現在",
                pronunciation: [
                    CanonicalSyllable(base: "ㄒㄧㄢ", tone: .fourth),
                    CanonicalSyllable(base: "ㄗㄞ", tone: .fourth)
                ],
                sourceWeight: 0.9
            ),
            LexiconMatch(
                text: "時刻",
                pronunciation: [
                    CanonicalSyllable(base: "ㄕ", tone: .second),
                    CanonicalSyllable(base: "ㄎㄜ", tone: .fourth)
                ],
                sourceWeight: 0.9
            ),
            LexiconMatch(
                text: "時間",
                pronunciation: [
                    CanonicalSyllable(base: "ㄕ", tone: .second),
                    CanonicalSyllable(base: "ㄐㄧㄢ", tone: .first)
                ],
                sourceWeight: 0.9
            )
        ])
        let pipeline = try LexiconChineseInputPipeline(store: store, now: { fixedDate })

        for (reading, word) in [("ㄒㄧㄢˋㄗㄞˋ", "現在"), ("ㄕˊㄎㄜˋ", "時刻"), ("ㄕˊㄐㄧㄢˉ", "時間")] {
            let candidates = try await pipeline.candidates(for: zhuyinTokens(reading))
            XCTAssertEqual(
                candidates.prefix(4).map(\.text),
                [word, "16:04", "下午4:04", "4:04 PM"],
                reading
            )
            for index in 1...3 {
                let item = CandidateItem.input(candidates[index])
                XCTAssertEqual(item.badge, "現在的時間")
                XCTAssertEqual(item.accessibilityLabel, "現在的時間：\(candidates[index].text)")
            }
        }

        let nowCandidates = try await pipeline.candidates(for: zhuyinTokens("ㄒㄧㄢˋㄗㄞˋ"))
        let button = CandidateButton()
        button.update(with: .input(nowCandidates[1]), adjustsTitleToFit: false)
        XCTAssertEqual(button.badgeText, "現在的時間")
        XCTAssertEqual(
            button.titleInsets.right,
            CandidateMetrics.contentInsets.right + CandidateMetrics.badgeWidth("現在的時間")
        )
    }
}
