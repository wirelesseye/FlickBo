import Foundation

struct CandidateID: Hashable, Sendable {
    let text: String
    let pronunciation: [SyllableConstraint]
    let tokenRange: Range<Int>

    var accessibilityIdentifier: String {
        let pronunciationKey = pronunciation
            .map { "\($0.base)\($0.tone?.rawValue ?? 0)" }
            .joined(separator: "-")
        return "candidate-\(tokenRange.lowerBound)-\(tokenRange.upperBound)-\(pronunciationKey)"
    }
}

struct InputCandidate: Equatable, Identifiable, Sendable {
    let id: CandidateID
    /// What the user sees and what is inserted, in the chosen character variant.
    let text: String
    /// The same candidate in the lexicon's OpenCC Standard form, used for
    /// user learning so it survives switching character variants.
    let canonicalText: String
    let pronunciation: [SyllableConstraint]
    let score: Double
    let isRawFallback: Bool
    /// An emoji offered for the word candidate before it; inserted like a
    /// word but never recorded by user learning.
    let isEmoji: Bool
    /// Whether this candidate is a full-width form that also has a half-width
    /// counterpart (e.g. full-width numbers like `１３`), shown with a `全` badge.
    let isFullWidth: Bool

    init(
        id: CandidateID,
        text: String,
        canonicalText: String? = nil,
        pronunciation: [SyllableConstraint],
        score: Double,
        isRawFallback: Bool,
        isEmoji: Bool = false,
        isFullWidth: Bool = false
    ) {
        self.id = id
        self.text = text
        self.canonicalText = canonicalText ?? text
        self.pronunciation = pronunciation
        self.score = score
        self.isRawFallback = isRawFallback
        self.isEmoji = isEmoji
        self.isFullWidth = isFullWidth
    }

    /// `emoji` offered for `word`, covering the same input.
    static func emoji(_ emoji: String, for word: InputCandidate) -> InputCandidate {
        InputCandidate(
            id: CandidateID(text: emoji, pronunciation: word.pronunciation, tokenRange: word.id.tokenRange),
            text: emoji,
            pronunciation: word.pronunciation,
            score: word.score,
            isRawFallback: false,
            isEmoji: true
        )
    }

    /// Numeric candidate covering all `tokenCount` active tokens, not recorded by user learning.
    static func number(_ text: String, tokenCount: Int, isFullWidth: Bool = false) -> InputCandidate {
        InputCandidate(
            id: CandidateID(text: text, pronunciation: [], tokenRange: 0..<tokenCount),
            text: text,
            pronunciation: [],
            score: 0,
            isRawFallback: false,
            isFullWidth: isFullWidth
        )
    }

    init(decoded: DecodedCandidate) {
        self.init(
            id: CandidateID(
                text: decoded.text,
                pronunciation: decoded.pronunciation,
                tokenRange: decoded.tokenRange
            ),
            text: decoded.text,
            pronunciation: decoded.pronunciation,
            score: decoded.score,
            isRawFallback: decoded.segments.allSatisfy { segment in
                if case .raw = segment {
                    return true
                }
                return false
            }
        )
    }

    static func rawFallback(
        tokens: [ZhuyinInputToken],
        pronunciation: [SyllableConstraint] = [],
        score: Double
    ) -> InputCandidate? {
        guard !tokens.isEmpty else { return nil }
        let text = tokens.map(\.displayText).joined()
        return InputCandidate(
            id: CandidateID(text: text, pronunciation: pronunciation, tokenRange: 0..<tokens.count),
            text: text,
            pronunciation: pronunciation,
            score: score,
            isRawFallback: true
        )
    }
}

enum CandidateItem: Equatable, Sendable {
    case input(InputCandidate)
    case suggestion(String)
    /// A width or related variant of the digit or symbol just typed.
    case symbol(String)

    var text: String {
        switch self {
        case let .input(candidate): candidate.text
        case let .suggestion(text), let .symbol(text): text
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case let .input(candidate):
            candidate.isEmoji ? "emoji-\(candidate.text)" : candidate.id.accessibilityIdentifier
        case let .suggestion(text): "suggestion-\(text)"
        case let .symbol(text): "symbol-\(text)"
        }
    }

    /// Small corner mark: `注` for raw Zhuyin candidates, `全` for full-width symbols
    /// or full-width numeric candidates that also exist in half width.
    var badge: String? {
        switch self {
        case let .input(candidate):
            if candidate.isRawFallback { return "注" }
            return candidate.isFullWidth ? "全" : nil
        case .suggestion:
            return nil
        case let .symbol(text):
            return CharacterWidth.isFullWidthWithHalfCounterpart(text) ? "全" : nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case let .input(candidate):
            if candidate.isRawFallback { return "注音：\(candidate.text)" }
            return candidate.isFullWidth ? "全形：\(candidate.text)" : candidate.text
        case let .suggestion(text):
            return "建議：\(text)"
        case let .symbol(text):
            return badge == nil ? text : "全形：\(text)"
        }
    }
}
