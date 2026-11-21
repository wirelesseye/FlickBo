import Foundation

extension UserWordKey {
    init?(text: String, pronunciation: [SyllableConstraint]) {
        guard !pronunciation.isEmpty,
              pronunciation.allSatisfy({ $0.tone != nil })
        else { return nil }
        self.init(
            text: text,
            baseKey: pronunciation.map(\.base).joined(separator: "\u{1f}"),
            toneKey: pronunciation.compactMap { $0.tone.map { String($0.digit) } }.joined()
        )
        guard isValid else { return nil }
    }

    init?(text: String, pronunciation: [CanonicalSyllable]) {
        self.init(
            text: text,
            baseKey: pronunciation.map(\.base).joined(separator: "\u{1f}"),
            toneKey: pronunciation.map { String($0.tone.digit) }.joined()
        )
        guard isValid else { return nil }
    }
}

struct CombinedLexiconStore: LexiconStore {
    let bundled: any LexiconStore
    let learned: UserLearningStore?

    func syllableInventory() throws -> [String] { try bundled.syllableInventory() }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        let bundledMatches = try bundled.exactMatches(for: syllables)
        guard let learned, !syllables.isEmpty else { return bundledMatches }
        let baseKey = syllables.map(\.base).joined(separator: "\u{1f}")
        let custom = ((try? learned.customExactRecords(baseKey: baseKey, syllableCount: syllables.count)) ?? [])
            .compactMap { Self.match($0, sourceWeight: Self.customWeight) }
        let records = (try? learned.exactRecords(baseKey: baseKey, syllableCount: syllables.count)) ?? []
        let personal = custom + records.compactMap { Self.match($0) }
        return bundledMatches + personal.filter { match in
            zip(syllables, match.pronunciation).allSatisfy { constraint, syllable in
                constraint.tone == nil || constraint.tone == syllable.tone
            }
        }
    }

    func patternMatches(
        for patterns: [SyllableMatchPattern],
        resultLimit: Int,
        scanLimit: Int
    ) throws -> [LexiconMatch] {
        let bundledMatches = try bundled.patternMatches(
            for: patterns, resultLimit: resultLimit, scanLimit: scanLimit
        )
        guard let learned, resultLimit > 0, scanLimit > 0,
              let initialKey = SQLiteLexiconStore.initialKey(for: patterns)
        else { return bundledMatches }
        let custom = ((try? learned.customPatternRecords(
            initialKey: initialKey, syllableCount: patterns.count, scanLimit: scanLimit
        )) ?? []).compactMap { Self.match($0, sourceWeight: Self.customWeight) }
        let records = (try? learned.patternRecords(
            initialKey: initialKey,
            syllableCount: patterns.count,
            scanLimit: scanLimit
        )) ?? []
        let personal = (custom + records.compactMap { Self.match($0) }).filter { match in
            zip(patterns, match.pronunciation).allSatisfy { pattern, syllable in
                pattern.accepts(base: syllable.base, tone: syllable.tone)
            }
        }
        return Array((personal + bundledMatches).prefix(resultLimit))
    }

    /// Hand-entered words rank above everything the dictionary scores.
    private static let customWeight = 1.0

    private static func match(_ record: UserWordRecord, sourceWeight: Double = 0.01) -> LexiconMatch? {
        let bases = record.key.baseKey.split(separator: "\u{1f}").map(String.init)
        let tones = record.key.toneKey.compactMap(MandarinTone.init(digit:))
        guard bases.count == tones.count, !bases.isEmpty else { return nil }
        let pronunciation = zip(bases, tones).map { CanonicalSyllable(base: $0, tone: $1) }
        return LexiconMatch(
            text: record.key.text,
            pronunciation: pronunciation,
            sourceWeight: sourceWeight
        )
    }
}

struct UserFrequencyScorer: DecoderScorer {
    let base: any DecoderScorer
    let counts: [UserWordKey: Int]

    func cost(for word: WordEdge) throws -> Double {
        let cost = try base.cost(for: word)
        guard let key = UserWordKey(text: word.text, pronunciation: word.pronunciation),
              let count = counts[key], count >= 2
        else { return cost }
        return max(0, cost - min(2.5, 0.75 * log2(Double(count))))
    }

    func cost(forRaw edge: SyllableEdge) throws -> Double {
        try base.cost(forRaw: edge)
    }
}
