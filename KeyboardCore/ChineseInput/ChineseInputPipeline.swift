import Foundation
import os

protocol ChineseInputPipeline: Sendable {
    /// `precedingText` is committed text immediately left of the input, used
    /// as grammar context. It is never stored.
    func candidates(for tokens: [ZhuyinInputToken], precedingText: String) async throws -> [InputCandidate]
    func suggestions(after precedingText: String) async throws -> [String]
    func recordCommittedSelection(chunks: [SelectedChunk], fullySelected: Bool) async throws
}

extension ChineseInputPipeline {
    func candidates(for tokens: [ZhuyinInputToken]) async throws -> [InputCandidate] {
        try await candidates(for: tokens, precedingText: "")
    }

    func suggestions(after precedingText: String) async throws -> [String] { [] }

    func recordCommittedSelection(chunks: [SelectedChunk], fullySelected: Bool) async throws {}
}

final class LexiconChineseInputPipeline: ChineseInputPipeline, @unchecked Sendable {
    private let parser: SyllableParser
    private let matcher: DictionaryMatcher
    private let decoder: Decoder
    private let store: any LexiconStore
    private let bundledStore: any LexiconStore
    private let userLearningStore: UserLearningStore?
    private let textConverter: CandidateTextConverter
    private let emojiTable: EmojiTable?
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(
        label: "com.wirelesseye.FlickBo.ChineseInputPipeline",
        qos: .userInitiated
    )

    convenience init(
        bundle: Bundle,
        resourceName: String = "flickbo",
        resourceExtension: String = "sqlite3",
        grammarResourceExtension: String? = "gram",
        decoder: Decoder = Decoder(),
        userLearningStore: UserLearningStore? = nil,
        characterVariant: CharacterVariant = .traditional,
        openCCResourceExtension: String = "opencc",
        includesEmoji: Bool = false,
        emojiResourceExtension: String = "emoji"
    ) throws {
        let store = try SQLiteLexiconStore(
            bundle: bundle,
            resourceName: resourceName,
            resourceExtension: resourceExtension,
            usesTaiwanWeights: characterVariant == .taiwan
        )
        var decoder = decoder
        if decoder.grammar == nil, let grammarResourceExtension {
            do {
                let grammarStore = try MappedGramStore(
                    bundle: bundle,
                    resourceName: resourceName,
                    resourceExtension: grammarResourceExtension
                )
                decoder = Decoder(
                    scorer: decoder.scorer,
                    configuration: decoder.configuration,
                    grammar: OctagramGrammar(store: grammarStore)
                )
            } catch {
                // Ranking without a grammar is still usable; keep typing working.
                Logger(subsystem: "com.wirelesseye.FlickBo", category: "ChineseInput")
                    .error("grammar unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        var textConverter = CandidateTextConverter.identity
        if characterVariant != .traditional {
            do {
                let openCC = try MappedOpenCCStore(
                    bundle: bundle,
                    resourceName: resourceName,
                    resourceExtension: openCCResourceExtension
                )
                textConverter = try CandidateTextConverter(variant: characterVariant, store: openCC)
            } catch {
                // Candidates in the lexicon's own form are still usable.
                Logger(subsystem: "com.wirelesseye.FlickBo", category: "ChineseInput")
                    .error("character conversion unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        var emojiTable: EmojiTable?
        if includesEmoji {
            do {
                emojiTable = try EmojiTable(
                    bundle: bundle,
                    resourceName: resourceName,
                    resourceExtension: emojiResourceExtension
                )
            } catch {
                // Word candidates are unaffected; only the emoji are missing.
                Logger(subsystem: "com.wirelesseye.FlickBo", category: "ChineseInput")
                    .error("emoji unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        try self.init(
            store: store,
            decoder: decoder,
            userLearningStore: userLearningStore,
            textConverter: textConverter,
            emojiTable: emojiTable
        )
    }

    init(
        store: any LexiconStore,
        decoder: Decoder = Decoder(),
        userLearningStore: UserLearningStore? = nil,
        textConverter: CandidateTextConverter = .identity,
        emojiTable: EmojiTable? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        bundledStore = store
        self.userLearningStore = userLearningStore
        self.textConverter = textConverter
        self.emojiTable = emojiTable
        self.now = now
        let combined = CombinedLexiconStore(bundled: store, learned: userLearningStore)
        self.store = combined
        parser = try SyllableParser(store: combined)
        matcher = DictionaryMatcher(store: combined)
        self.decoder = decoder
    }

    func recordCommittedSelection(chunks: [SelectedChunk], fullySelected: Bool) async throws {
        guard let userLearningStore, !chunks.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let entries = try self.learningEntries(chunks: chunks, fullySelected: fullySelected)
                    try userLearningStore.record(entries)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func learningEntries(
        chunks: [SelectedChunk],
        fullySelected: Bool
    ) throws -> [(key: UserWordKey, isLearned: Bool)] {
        // An emoji is not a word: skip it, and do not learn a phrase containing it.
        let fullySelected = fullySelected && !chunks.contains(where: \.isEmoji)
        let chunks = chunks.filter { !$0.isEmoji }
        guard !chunks.isEmpty else { return [] }
        var entries: [(key: UserWordKey, isLearned: Bool)] = chunks.compactMap { chunk in
            UserWordKey(text: chunk.canonicalText, pronunciation: chunk.pronunciation).map { ($0, false) }
        }
        guard fullySelected else { return entries }
        let text = chunks.map(\.canonicalText).joined()
        let pronunciation = chunks.flatMap(\.pronunciation)
        guard let key = UserWordKey(text: text, pronunciation: pronunciation),
              (2...8).contains(key.syllableCount)
        else { return entries }
        guard let bundled = try? bundledStore.exactMatches(for: pronunciation) else {
            return entries
        }
        let exists = bundled.contains { match in
            match.text == text && match.pronunciation.map { String($0.tone.digit) }.joined() == key.toneKey
        }
        guard !exists else { return entries }
        if entries.count == 1 && entries[0].key == key {
            entries[0].isLearned = true
        } else {
            entries.append((key, true))
        }
        return entries
    }

    func candidates(for tokens: [ZhuyinInputToken], precedingText: String) async throws -> [InputCandidate] {
        guard !tokens.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(
                        returning: try self.makeCandidates(for: tokens, precedingText: precedingText)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func suggestions(after precedingText: String) async throws -> [String] {
        guard let grammar = decoder.grammar as? OctagramGrammar else { return [] }
        let converter = textConverter
        return await withCheckedContinuation { continuation in
            queue.async {
                let suggestions = grammar.suggestions(after: converter.canonical(precedingText))
                guard !converter.isIdentity else {
                    continuation.resume(returning: suggestions)
                    return
                }
                var seen = Set<String>()
                continuation.resume(returning: suggestions.map(converter.display).filter { seen.insert($0).inserted })
            }
        }
    }

    private func makeCandidates(
        for tokens: [ZhuyinInputToken],
        precedingText displayedPrecedingText: String
    ) throws -> [InputCandidate] {
        let precedingText = textConverter.canonical(displayedPrecedingText)
        let counts = (try? userLearningStore?.countSnapshot()) ?? [:]
        let decoder = Decoder(
            scorer: UserFrequencyScorer(base: self.decoder.scorer, counts: counts),
            configuration: self.decoder.configuration,
            grammar: self.decoder.grammar
        )
        let syllableLattice = parser.lattice(for: tokens)
        let wordLattice = try matcher.buildLattice(from: syllableLattice)
        let decoded = try decoder.decode(
            syllableLattice: syllableLattice,
            wordLattice: wordLattice,
            precedingText: precedingText
        )
        let candidates = Self.mergedByText(decoded.map(InputCandidate.init(decoded:)))
        var result: [InputCandidate]
        if candidates.contains(where: \.isRawFallback) {
            result = candidates
        } else {
            let limit = decoder.configuration.maximumCandidates
            result = Array(candidates.prefix(max(0, limit - 1)))
            if let fallback = rawFallback(for: tokens, lattice: syllableLattice) {
                result.append(fallback)
            }
        }
        let exactCharacters = try exactSingleCharacterCandidates(
            lattice: syllableLattice,
            precedingText: precedingText,
            excludingTexts: Set(result.map(\.text)),
            decoder: decoder
        )
        let promoted = exactCharacters.filter { candidate in
            guard let key = UserWordKey(text: candidate.text, pronunciation: candidate.pronunciation) else {
                return false
            }
            return (counts[key] ?? 0) >= 2
        }
        if promoted.isEmpty {
            result.append(contentsOf: exactCharacters)
            return withCurrentTime(
                withNumbers(
                    withEmoji(localized(result), tokenCount: tokens.count),
                    tokenCount: tokens.count
                ),
                tokenCount: tokens.count
            )
        }
        let ranked = (result.filter { !$0.isRawFallback } + promoted).sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.text < rhs.text : lhs.score < rhs.score
        }
        let promotedTexts = Set(promoted.map(\.text))
        result = ranked + result.filter(\.isRawFallback)
        result.append(contentsOf: exactCharacters.filter { !promotedTexts.contains($0.text) })
        return withCurrentTime(
            withNumbers(
                withEmoji(localized(result), tokenCount: tokens.count),
                tokenCount: tokens.count
            ),
            tokenCount: tokens.count
        )
    }

    /// Inserts current 24-hour and 12-hour time candidates right after full-coverage
    /// trigger words (`現在`, `時刻`, `時間`), similar to `withEmoji`.
    private func withCurrentTime(_ candidates: [InputCandidate], tokenCount: Int) -> [InputCandidate] {
        var seen = Set(candidates.map(\.text))
        var result: [InputCandidate] = []
        result.reserveCapacity(candidates.count)
        var formattedTimes: [String]?
        for candidate in candidates {
            result.append(candidate)
            guard !candidate.isRawFallback,
                  !candidate.isEmoji,
                  candidate.id.tokenRange == 0..<tokenCount,
                  CurrentTimeCandidates.shouldOffer(for: candidate.text)
            else { continue }
            let times = formattedTimes ?? CurrentTimeCandidates.formattedStrings(for: now())
            formattedTimes = times
            for time in times where seen.insert(time).inserted {
                result.append(.time(time, tokenCount: tokenCount))
            }
        }
        return result
    }

    /// Inserts half-width and full-width numeric candidates right after any
    /// full-coverage Chinese number candidate, similar to `withEmoji`.
    private func withNumbers(_ candidates: [InputCandidate], tokenCount: Int) -> [InputCandidate] {
        var seen = Set(candidates.map(\.text))
        var result: [InputCandidate] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            result.append(candidate)
            guard !candidate.isRawFallback,
                  !candidate.isEmoji,
                  candidate.id.tokenRange == 0..<tokenCount,
                  let number = ChineseNumberConverter.arabicNumber(for: candidate.text)
            else { continue }
            if seen.insert(number).inserted {
                result.append(.number(number, tokenCount: tokenCount, isFullWidth: false))
            }
            let fullWidth = CharacterWidth.full.apply(to: number)
            if seen.insert(fullWidth).inserted {
                result.append(.number(fullWidth, tokenCount: tokenCount, isFullWidth: true))
            }
        }
        return result
    }

    /// Word candidates within this many leading positions get their emoji.
    static let emojiSourceCandidateLimit = 3

    /// Inserts the emoji of the leading word candidates right after each word,
    /// so the first candidate stays a word. Only candidates covering the whole
    /// input qualify, since selecting one replaces all of it.
    private func withEmoji(_ candidates: [InputCandidate], tokenCount: Int) -> [InputCandidate] {
        guard let emojiTable else { return candidates }
        var seen = Set<String>()
        var result: [InputCandidate] = []
        result.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            result.append(candidate)
            guard index < Self.emojiSourceCandidateLimit,
                  !candidate.isRawFallback,
                  candidate.id.tokenRange == 0..<tokenCount
            else { continue }
            // Upstream keys are mostly Standard Traditional; the shown form
            // catches the few written in Taiwan forms.
            var emoji = emojiTable.emoji(for: candidate.canonicalText)
            if emoji.isEmpty, candidate.text != candidate.canonicalText {
                emoji = emojiTable.emoji(for: candidate.text)
            }
            for text in emoji where seen.insert(text).inserted {
                result.append(.emoji(text, for: candidate))
            }
        }
        return result
    }

    /// Converts ranked canonical candidates into the chosen character variant.
    /// Candidates that become identical (爲 and 為 both show as 為 in Taiwan)
    /// keep the better ranked one, so the variant inherits the higher weight.
    private func localized(_ candidates: [InputCandidate]) -> [InputCandidate] {
        guard !textConverter.isIdentity else { return candidates }
        var seen = Set<String>()
        var result: [InputCandidate] = []
        result.reserveCapacity(candidates.count)
        func append(_ candidate: InputCandidate, text: String) {
            guard seen.insert(text).inserted else { return }
            result.append(
                InputCandidate(
                    id: CandidateID(text: text, pronunciation: candidate.pronunciation, tokenRange: candidate.id.tokenRange),
                    text: text,
                    canonicalText: candidate.canonicalText,
                    pronunciation: candidate.pronunciation,
                    score: candidate.score,
                    isRawFallback: candidate.isRawFallback
                )
            )
        }
        for candidate in candidates {
            guard !candidate.isRawFallback else {
                result.append(candidate)
                continue
            }
            append(candidate, text: textConverter.display(candidate.text))
        }
        return result
    }

    private func exactSingleCharacterCandidates(
        lattice: SyllableLattice,
        precedingText: String,
        excludingTexts excluded: Set<String>,
        decoder: Decoder
    ) throws -> [InputCandidate] {
        let tokenCount = lattice.tokenCount
        guard tokenCount > 0 else { return [] }
        let tokenRange = 0..<tokenCount
        var bestByText: [String: (score: Double, constraint: SyllableConstraint)] = [:]
        for edge in lattice.outgoingEdges[0]
        where edge.tokenRange == tokenRange && edge.completeness == .complete {
            for match in try store.exactMatches(for: [edge.constraint]) {
                guard match.text.count == 1,
                      match.pronunciation.count == 1,
                      let syllable = match.pronunciation.first,
                      !excluded.contains(match.text)
                else { continue }
                let score = try decoder.scorer.cost(
                    for: WordEdge(
                        tokenRange: tokenRange,
                        text: match.text,
                        pronunciation: match.pronunciation,
                        sourceWeight: match.sourceWeight,
                        pronunciationWeight: match.pronunciationWeight,
                        syllableEdges: [edge]
                    )
                ) + decoder.grammarCost(context: precedingText, word: match.text, isRear: true)
                if let existing = bestByText[match.text], existing.score <= score {
                    continue
                }
                bestByText[match.text] = (
                    score,
                    SyllableConstraint(base: syllable.base, tone: syllable.tone)
                )
            }
        }
        return bestByText
            .map { text, entry in
                InputCandidate(
                    id: CandidateID(
                        text: text,
                        pronunciation: [entry.constraint],
                        tokenRange: tokenRange
                    ),
                    text: text,
                    pronunciation: [entry.constraint],
                    score: entry.score,
                    isRawFallback: false
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.text < rhs.text
            }
    }

    private static func mergedByText(_ candidates: [InputCandidate]) -> [InputCandidate] {
        var bestIndexByText: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() where !candidate.isRawFallback {
            guard let bestIndex = bestIndexByText[candidate.text] else {
                bestIndexByText[candidate.text] = index
                continue
            }
            if candidate.score < candidates[bestIndex].score {
                bestIndexByText[candidate.text] = index
            }
        }
        return candidates.enumerated().compactMap { index, candidate in
            guard candidate.isRawFallback || bestIndexByText[candidate.text] == index else {
                return nil
            }
            return candidate
        }
    }

    private func rawFallback(
        for tokens: [ZhuyinInputToken],
        lattice: SyllableLattice
    ) -> InputCandidate? {
        let path = coveragePath(for: lattice)
        guard !path.isEmpty else { return nil }
        let configuration = decoder.configuration
        let score = path.reduce(0.0) { total, edge in
            let penalty: Double
            switch edge.completeness {
            case .complete: penalty = configuration.completeRawCost
            case .incomplete: penalty = configuration.incompleteRawCost
            case .fallback: penalty = configuration.fallbackRawCost
            }
            return total + edge.parserCost + penalty
        }
        return InputCandidate.rawFallback(
            tokens: tokens,
            pronunciation: path.map(\.constraint),
            score: score
        )
    }

    private func coveragePath(for lattice: SyllableLattice) -> [SyllableEdge] {
        let tokenCount = lattice.tokenCount
        var canReachEnd = Array(repeating: false, count: tokenCount + 1)
        canReachEnd[tokenCount] = true
        for position in stride(from: tokenCount - 1, through: 0, by: -1) {
            canReachEnd[position] = lattice.outgoingEdges[position].contains {
                canReachEnd[$0.tokenRange.upperBound]
            }
        }
        var path: [SyllableEdge] = []
        var position = 0
        while position < tokenCount {
            guard let edge = lattice.outgoingEdges[position]
                .filter({ canReachEnd[$0.tokenRange.upperBound] })
                .sorted(by: Self.pathPreference)
                .first
            else {
                return []
            }
            path.append(edge)
            position = edge.tokenRange.upperBound
        }
        return path
    }

    private static func pathPreference(_ lhs: SyllableEdge, _ rhs: SyllableEdge) -> Bool {
        if completenessRank(lhs.completeness) != completenessRank(rhs.completeness) {
            return completenessRank(lhs.completeness) < completenessRank(rhs.completeness)
        }
        if lhs.tokenRange.upperBound != rhs.tokenRange.upperBound {
            return lhs.tokenRange.upperBound > rhs.tokenRange.upperBound
        }
        if lhs.parserCost != rhs.parserCost {
            return lhs.parserCost < rhs.parserCost
        }
        return lhs.tokenRange.lowerBound < rhs.tokenRange.lowerBound
    }

    private static func completenessRank(_ completeness: SyllableCompleteness) -> Int {
        switch completeness {
        case .complete: 0
        case .incomplete: 1
        case .fallback: 2
        }
    }
}
