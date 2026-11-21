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
    let text: String
    let pronunciation: [SyllableConstraint]
    let score: Double
    let isRawFallback: Bool

    init(
        id: CandidateID,
        text: String,
        pronunciation: [SyllableConstraint],
        score: Double,
        isRawFallback: Bool
    ) {
        self.id = id
        self.text = text
        self.pronunciation = pronunciation
        self.score = score
        self.isRawFallback = isRawFallback
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
        case let .input(candidate): candidate.id.accessibilityIdentifier
        case let .suggestion(text): "suggestion-\(text)"
        case let .symbol(text): "symbol-\(text)"
        }
    }

    /// Small corner mark: `注` for raw Zhuyin candidates, `全` for full-width symbols
    /// that also exist in half width.
    var badge: String? {
        switch self {
        case let .input(candidate): candidate.isRawFallback ? "注" : nil
        case .suggestion: nil
        case let .symbol(text): CharacterWidth.isFullWidthWithHalfCounterpart(text) ? "全" : nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case let .input(candidate): candidate.isRawFallback ? "注音：\(candidate.text)" : candidate.text
        case let .suggestion(text): "建議：\(text)"
        case let .symbol(text): badge == nil ? text : "全形：\(text)"
        }
    }
}
