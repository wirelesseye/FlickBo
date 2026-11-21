import Foundation

enum EmojiTableError: Error, Equatable {
    case resourceNotFound(String)
    case malformedLine(Int)
}

/// Word → emoji table compiled from rime-emoji (`Generated/flickbo.emoji`,
/// see `Tools/DictionaryCompiler/emoji_data.py`): one `word<TAB>emoji emoji…`
/// line per word, keyed by OpenCC Standard Traditional text like the lexicon.
struct EmojiTable: Sendable {
    private let emojiByWord: [String: [String]]

    init(text: String) throws {
        var table: [String: [String]] = [:]
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw EmojiTableError.malformedLine(lineNumber)
            }
            table[String(fields[0])] = fields[1].split(separator: " ").map(String.init)
        }
        emojiByWord = table
    }

    init(url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }

    init(bundle: Bundle, resourceName: String = "flickbo", resourceExtension: String = "emoji") throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw EmojiTableError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }
        try self.init(url: url)
    }

    var wordCount: Int { emojiByWord.count }

    func emoji(for word: String) -> [String] {
        emojiByWord[word] ?? []
    }
}
