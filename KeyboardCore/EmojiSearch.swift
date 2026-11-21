import Foundation

/// CLDR zh_Hant emoji names and keywords (`Generated/flickbo.emojikeywords`):
/// one `emoji<TAB>name<TAB>keyword...` line per emoji, in catalog order.
struct EmojiKeywordTable: Sendable {
    let entries: [(emoji: String, terms: [String])]

    init(text: String) throws {
        var entries: [(emoji: String, terms: [String])] = []
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields.contains(where: \.isEmpty) else {
                throw EmojiCatalogError.malformedLine(lineNumber)
            }
            entries.append((fields[0], Array(fields.dropFirst())))
        }
        self.entries = entries
    }

    init(bundle: Bundle, resourceName: String = "flickbo", resourceExtension: String = "emojikeywords") throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw EmojiCatalogError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }
}

/// Finds palette emoji for a search query. Chinese queries match the
/// rime-emoji words (`flickbo.emoji`) and the CLDR zh_Hant names and
/// keywords; queries with Latin letters also match the CLDR English names in
/// the catalog. Results are limited to emoji in the
/// catalog, so they use its presentation and hide emoji the system cannot draw.
struct EmojiSearchIndex: Sendable {
    private struct Term: Sendable {
        let text: String
        let emoji: [String]
    }

    private let words: [Term]
    private let names: [Term]

    init(table: EmojiTable, catalog: EmojiCatalog, keywords: EmojiKeywordTable? = nil) {
        var catalogEmoji: [String: String] = [:]
        var names: [Term] = []
        for section in catalog.sections {
            for entry in section.entries {
                catalogEmoji[Self.matchKey(entry.emoji)] = entry.emoji
                names.append(Term(text: entry.name.lowercased(), emoji: [entry.emoji]))
            }
        }
        // One term per text: rime-emoji's picks first, then CLDR's in catalog order.
        var emojiByText: [String: [String]] = [:]
        func add(_ text: String, _ emoji: [String]) {
            for item in emoji {
                guard let mapped = catalogEmoji[Self.matchKey(item)] else { continue }
                if !(emojiByText[text]?.contains(mapped) ?? false) {
                    emojiByText[text, default: []].append(mapped)
                }
            }
        }
        for (word, emoji) in table.words.sorted(by: { $0.key < $1.key }) {
            add(word, emoji)
        }
        for entry in keywords?.entries ?? [] {
            for term in entry.terms {
                add(term.lowercased(), [entry.emoji])
            }
        }
        words = emojiByText
            .map { Term(text: $0.key, emoji: $0.value) }
            .sorted { ($0.text.count, $0.text) < ($1.text.count, $1.text) }
        self.names = names
    }

    /// Emoji whose word or name equals, starts with or contains the query, in
    /// that order; shorter words come first within each group.
    func search(_ query: String, limit: Int = 80) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var terms = words
        if query.contains(where: { $0.isASCII && $0.isLetter }) {
            terms += names
        }
        var ranked: [(rank: Int, length: Int, order: Int, term: Term)] = []
        for (order, term) in terms.enumerated() {
            let rank: Int
            if term.text == query {
                rank = 0
            } else if term.text.hasPrefix(query) || term.text.contains(" " + query) {
                rank = 1
            } else if term.text.contains(query) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, term.text.count, order, term))
        }
        ranked.sort { ($0.rank, $0.length, $0.order) < ($1.rank, $1.length, $1.order) }
        var seen = Set<String>()
        var results: [String] = []
        for item in ranked {
            for emoji in item.term.emoji where seen.insert(emoji).inserted {
                results.append(emoji)
                if results.count == limit { return results }
            }
        }
        return results
    }

    /// rime-emoji appends U+FE0F to most emoji; the catalog uses fully
    /// qualified sequences. Comparing without the selector matches both.
    private static func matchKey(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
    }
}
