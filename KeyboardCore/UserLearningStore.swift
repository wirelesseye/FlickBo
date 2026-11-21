import Foundation
import SQLite3

private let learningTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct UserWordKey: Hashable, Sendable {
    let text: String
    let baseKey: String
    let toneKey: String

    var syllableCount: Int { toneKey.count }

    var initialKey: String {
        baseKey.split(separator: "\u{1f}").map { String($0.prefix(1)) }.joined(separator: "\u{1f}")
    }

    var isValid: Bool {
        let bases = baseKey.split(separator: "\u{1f}")
        return !text.isEmpty && text.count == bases.count && bases.count == toneKey.count
            && (1...8).contains(bases.count)
            && toneKey.allSatisfy { "12345".contains($0) }
            && text.unicodeScalars.allSatisfy(Self.isHan)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}

extension UserWordKey {
    private static let toneMarks: [Character: Character] = ["ˉ": "1", "ˊ": "2", "ˇ": "3", "ˋ": "4", "˙": "5"]

    /// Builds a key from a typed zhuyin reading such as "ㄋㄧˇ ㄏㄠˇ". Syllables are
    /// separated by spaces; a missing tone mark means first tone. The tone mark
    /// follows the syllable, as on the keyboard; a leading neutral mark is accepted too. Returns nil if the reading is malformed or does not
    /// have one syllable per character.
    init?(text: String, reading: String) {
        var bases: [String] = []
        var tones = ""
        for word in reading.split(whereSeparator: \.isWhitespace) {
            var characters = Array(word)
            var tone: Character = "1"
            if characters.first == "˙" {
                tone = "5"
                characters.removeFirst()
            } else if let last = characters.last, let digit = Self.toneMarks[last] {
                tone = digit
                characters.removeLast()
            }
            guard (1...3).contains(characters.count),
                  characters.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x3105...0x312F).contains($0.value) } })
            else { return nil }
            bases.append(String(characters))
            tones.append(tone)
        }
        self.init(text: text, baseKey: bases.joined(separator: "\u{1f}"), toneKey: tones)
        guard isValid else { return nil }
    }

    /// Display form of the reading, e.g. "ㄋㄧˇ ㄏㄠˇ".
    var readingText: String {
        let marks = Dictionary(uniqueKeysWithValues: Self.toneMarks.map { ($1, $0) })
        return zip(baseKey.split(separator: "\u{1f}"), toneKey).map { base, digit in
            switch digit {
            case "1": String(base)
            default: base + String(marks[digit] ?? " ")
            }
        }.joined(separator: " ")
    }
}

struct UserWordRecord: Equatable, Sendable {
    let key: UserWordKey
    let count: Int
    let isLearned: Bool
}

enum UserLearningError: Error {
    case database(String)
    case unsupportedSchema(Int)
}

/// A separate database in the App Group. The bundled dictionary is never opened for writing.
final class UserLearningStore: @unchecked Sendable {
    static let fileName = "user-learning.sqlite3"
    static let schemaVersion = 3

    private let queue = DispatchQueue(label: "com.wirelesseye.FlickBo.UserLearningStore")
    private let database: OpaquePointer
    private let writable: Bool
    private var cachedCounts: [UserWordKey: Int] = [:]
    private var lastDataVersion: Int?

    init(url: URL, writable: Bool) throws {
        self.writable = writable
        var handle: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw UserLearningError.database("open: \(status)")
        }
        database = handle
        do {
            sqlite3_busy_timeout(handle, 1000)
            let version = try Self.scalar(handle, sql: "PRAGMA user_version")
            if writable && version < Self.schemaVersion {
                var sql = ""
                if version == 0 { sql += Self.learnedSchema }
                if version < 2 { sql += Self.customSchema }
                // Seeded once at migration, so deleting a built-in word sticks.
                for word in Self.builtInCustomWords {
                    sql += """
                        INSERT OR IGNORE INTO custom_entry
                        (text, base_key, tone_key, initial_key, syllable_count, created_at)
                        VALUES ('\(word.text)', '\(word.baseKey)', '\(word.toneKey)',
                        '\(word.initialKey)', \(word.syllableCount), 0);

                        """
                }
                try Self.execute(handle, sql: sql + "PRAGMA user_version = \(Self.schemaVersion);")
            } else if !(1...Self.schemaVersion).contains(version) {
                // A read-only connection can still read an older file; it just lacks newer tables.
                throw UserLearningError.unsupportedSchema(version)
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    /// Custom words every install starts with; the user may delete them.
    private static let builtInCustomWords: [UserWordKey] = [
        UserWordKey(text: "滑注音", reading: "ㄏㄨㄚˊ ㄓㄨˋ ㄧㄣ"),
    ].compactMap { $0 }

    private static let learnedSchema = """
        CREATE TABLE IF NOT EXISTS user_entry (
            text TEXT NOT NULL,
            base_key TEXT NOT NULL,
            tone_key TEXT NOT NULL,
            initial_key TEXT NOT NULL,
            syllable_count INTEGER NOT NULL,
            selection_count INTEGER NOT NULL,
            is_learned INTEGER NOT NULL,
            PRIMARY KEY (text, base_key, tone_key)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS user_entry_base
        ON user_entry(base_key, syllable_count);
        CREATE INDEX IF NOT EXISTS user_entry_initial
        ON user_entry(initial_key, syllable_count, selection_count DESC);

        """

    /// Words the user typed in by hand. Unlike `user_entry` these are editable and
    /// are not touched by `clear()`.
    private static let customSchema = """
        CREATE TABLE IF NOT EXISTS custom_entry (
            text TEXT NOT NULL,
            base_key TEXT NOT NULL,
            tone_key TEXT NOT NULL,
            initial_key TEXT NOT NULL,
            syllable_count INTEGER NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (text, base_key, tone_key)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS custom_entry_base
        ON custom_entry(base_key, syllable_count);
        CREATE INDEX IF NOT EXISTS custom_entry_initial
        ON custom_entry(initial_key, syllable_count);

        """

    func countSnapshot() throws -> [UserWordKey: Int] {
        try queue.sync {
            let version = try Self.scalar(database, sql: "PRAGMA data_version")
            if lastDataVersion == version { return cachedCounts }
            var counts: [UserWordKey: Int] = [:]
            try query(
                "SELECT text, base_key, tone_key, selection_count, is_learned FROM user_entry"
            ) { statement in
                let entry = try Self.record(statement)
                counts[entry.key] = entry.count
            }
            cachedCounts = counts
            lastDataVersion = version
            return counts
        }
    }

    func exactRecords(baseKey: String, syllableCount: Int) throws -> [UserWordRecord] {
        try records(
            sql: """
                SELECT text, base_key, tone_key, selection_count, is_learned
                FROM user_entry WHERE base_key = ? AND syllable_count = ? AND is_learned = 1
                ORDER BY selection_count DESC LIMIT 256
                """,
            key: baseKey,
            syllableCount: syllableCount
        )
    }

    func patternRecords(initialKey: String, syllableCount: Int, scanLimit: Int) throws -> [UserWordRecord] {
        try records(
            sql: """
                SELECT text, base_key, tone_key, selection_count, is_learned
                FROM user_entry WHERE initial_key = ? AND syllable_count = ? AND is_learned = 1
                ORDER BY selection_count DESC LIMIT ?
                """,
            key: initialKey,
            syllableCount: syllableCount,
            limit: scanLimit
        )
    }

    func record(_ entries: [(key: UserWordKey, isLearned: Bool)]) throws {
        guard writable, !entries.isEmpty else { return }
        try queue.sync {
            try Self.execute(database, sql: "BEGIN IMMEDIATE")
            do {
                let sql = """
                    INSERT INTO user_entry
                    (text, base_key, tone_key, initial_key, syllable_count, selection_count, is_learned)
                    VALUES (?, ?, ?, ?, ?, 1, ?)
                    ON CONFLICT(text, base_key, tone_key) DO UPDATE SET
                    selection_count = selection_count + 1,
                    is_learned = MAX(is_learned, excluded.is_learned)
                    """
                let statement = try Self.prepare(database, sql: sql)
                defer { sqlite3_finalize(statement) }
                for entry in entries where entry.key.isValid {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try Self.bind(entry.key.text, at: 1, to: statement)
                    try Self.bind(entry.key.baseKey, at: 2, to: statement)
                    try Self.bind(entry.key.toneKey, at: 3, to: statement)
                    try Self.bind(entry.key.initialKey, at: 4, to: statement)
                    sqlite3_bind_int(statement, 5, Int32(entry.key.syllableCount))
                    sqlite3_bind_int(statement, 6, entry.isLearned ? 1 : 0)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
                }
                try Self.execute(database, sql: "COMMIT")
                lastDataVersion = nil
            } catch {
                try? Self.execute(database, sql: "ROLLBACK")
                throw error
            }
        }
    }

    // MARK: Custom words

    /// All custom words, newest first.
    func customWords() throws -> [UserWordKey] {
        try queue.sync {
            var result: [UserWordKey] = []
            try query(
                "SELECT text, base_key, tone_key, 0, 1 FROM custom_entry ORDER BY created_at DESC, text"
            ) { statement in
                result.append(try Self.record(statement).key)
            }
            return result
        }
    }

    /// Returns false when the word with this reading already exists.
    @discardableResult
    func addCustomWord(_ key: UserWordKey) throws -> Bool {
        guard writable, key.isValid else { return false }
        return try queue.sync {
            let statement = try Self.prepare(database, sql: """
                INSERT OR IGNORE INTO custom_entry
                (text, base_key, tone_key, initial_key, syllable_count, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            try Self.bind(key.text, at: 1, to: statement)
            try Self.bind(key.baseKey, at: 2, to: statement)
            try Self.bind(key.toneKey, at: 3, to: statement)
            try Self.bind(key.initialKey, at: 4, to: statement)
            sqlite3_bind_int(statement, 5, Int32(key.syllableCount))
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            return sqlite3_changes(database) > 0
        }
    }

    func removeCustomWord(_ key: UserWordKey) throws {
        guard writable else { return }
        try queue.sync {
            let statement = try Self.prepare(
                database,
                sql: "DELETE FROM custom_entry WHERE text = ? AND base_key = ? AND tone_key = ?"
            )
            defer { sqlite3_finalize(statement) }
            try Self.bind(key.text, at: 1, to: statement)
            try Self.bind(key.baseKey, at: 2, to: statement)
            try Self.bind(key.toneKey, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    func customExactRecords(baseKey: String, syllableCount: Int) throws -> [UserWordRecord] {
        try records(
            sql: """
                SELECT text, base_key, tone_key, 0, 1
                FROM custom_entry WHERE base_key = ? AND syllable_count = ?
                ORDER BY created_at DESC LIMIT 256
                """,
            key: baseKey,
            syllableCount: syllableCount
        )
    }

    func customPatternRecords(initialKey: String, syllableCount: Int, scanLimit: Int) throws -> [UserWordRecord] {
        try records(
            sql: """
                SELECT text, base_key, tone_key, 0, 1
                FROM custom_entry WHERE initial_key = ? AND syllable_count = ?
                ORDER BY created_at DESC LIMIT ?
                """,
            key: initialKey,
            syllableCount: syllableCount,
            limit: scanLimit
        )
    }

    func clear() throws {
        guard writable else { return }
        try queue.sync {
            try Self.execute(database, sql: "DELETE FROM user_entry")
            cachedCounts = [:]
            lastDataVersion = nil
        }
    }

    private func records(sql: String, key: String, syllableCount: Int, limit: Int? = nil) throws -> [UserWordRecord] {
        try queue.sync {
            var result: [UserWordRecord] = []
            try query(sql) { statement in
                try Self.bind(key, at: 1, to: statement)
                sqlite3_bind_int(statement, 2, Int32(syllableCount))
                if let limit { sqlite3_bind_int(statement, 3, Int32(limit)) }
            } row: { statement in
                result.append(try Self.record(statement))
            }
            return result
        }
    }

    private func query(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
        try query(sql, bind: { _ in }, row: row)
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void,
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try Self.prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw error() }
            try row(statement)
        }
    }

    private static func record(_ statement: OpaquePointer) throws -> UserWordRecord {
        guard let text = sqlite3_column_text(statement, 0),
              let base = sqlite3_column_text(statement, 1),
              let tone = sqlite3_column_text(statement, 2)
        else { throw UserLearningError.database("null word") }
        return UserWordRecord(
            key: UserWordKey(
                text: String(cString: text),
                baseKey: String(cString: base),
                toneKey: String(cString: tone)
            ),
            count: Int(sqlite3_column_int(statement, 3)),
            isLearned: sqlite3_column_int(statement, 4) != 0
        )
    }

    private static func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw UserLearningError.database(String(cString: sqlite3_errmsg(database))) }
        return statement
    }

    private static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, learningTransient) == SQLITE_OK else {
            throw UserLearningError.database("bind failed")
        }
    }

    private static func scalar(_ database: OpaquePointer, sql: String) throws -> Int {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UserLearningError.database(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UserLearningError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func error() -> UserLearningError {
        .database(String(cString: sqlite3_errmsg(database)))
    }
}
