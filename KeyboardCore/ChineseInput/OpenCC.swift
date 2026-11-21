import Darwin
import Foundation

enum OpenCCStoreError: Error, Equatable {
    case resourceNotFound(String)
    case openFailed(String)
    case invalidFormat(String)
    case unknownConversion(String)
}

/// Read-only view of an FZOpenCC file (see Tools/DictionaryCompiler/opencc_data.py).
///
/// Like `MappedGramStore`, the file is memory-mapped so only the pages of the
/// dictionaries actually used are faulted in, and they stay clean and evictable.
final class MappedOpenCCStore: @unchecked Sendable {
    static let magic: [UInt8] = Array("FZOPENCC".utf8)
    static let formatVersion = 1
    static let headerSize = 32

    struct Dictionary {
        let entryCount: Int
        let entriesOffset: Int
    }

    private let mapping: UnsafeMutableRawPointer
    private let mappingSize: Int
    private let stringsOffset: Int
    private let dictionaries: [Dictionary]
    private let conversions: [String: [[Int]]]

    var conversionNames: [String] { conversions.keys.sorted() }

    convenience init(
        bundle: Bundle,
        resourceName: String = "flickzhuyin",
        resourceExtension: String = "opencc"
    ) throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw OpenCCStoreError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }
        try self.init(url: url)
    }

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw OpenCCStoreError.openFailed("\(url.lastPathComponent): errno \(errno)")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw OpenCCStoreError.openFailed("\(url.lastPathComponent): fstat errno \(errno)")
        }
        let size = Int(status.st_size)
        guard size >= Self.headerSize else {
            throw OpenCCStoreError.invalidFormat("file is smaller than the header")
        }
        guard let pointer = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
              pointer != MAP_FAILED
        else {
            throw OpenCCStoreError.openFailed("\(url.lastPathComponent): mmap errno \(errno)")
        }
        mapping = pointer
        mappingSize = size

        do {
            let base = UnsafeRawPointer(pointer)
            func u32(_ offset: Int) throws -> Int {
                guard offset >= 0, offset <= size - 4 else {
                    throw OpenCCStoreError.invalidFormat("offset \(offset) out of bounds")
                }
                return Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            guard Array(UnsafeRawBufferPointer(start: base, count: 8)) == Self.magic else {
                throw OpenCCStoreError.invalidFormat("bad magic")
            }
            guard try u32(8) == Self.formatVersion else {
                throw OpenCCStoreError.invalidFormat("unsupported format version")
            }
            let dictCount = try u32(12)
            let conversionCount = try u32(16)
            let dictTable = try u32(20)
            let conversionTable = try u32(24)
            let stringsOffset = try u32(28)
            guard stringsOffset <= size else {
                throw OpenCCStoreError.invalidFormat("strings out of bounds")
            }
            self.stringsOffset = stringsOffset
            let stringsSize = size - stringsOffset

            func string(_ offset: Int, _ length: Int) throws -> String {
                guard length >= 0, offset >= 0, offset <= stringsSize - length else {
                    throw OpenCCStoreError.invalidFormat("string out of bounds")
                }
                let bytes = UnsafeRawBufferPointer(start: base + stringsOffset + offset, count: length)
                return String(decoding: bytes, as: UTF8.self)
            }

            var dictionaries: [Dictionary] = []
            for index in 0..<dictCount {
                let row = dictTable + 16 * index
                let entryCount = try u32(row + 8)
                let entriesOffset = try u32(row + 12)
                guard entriesOffset >= Self.headerSize,
                      entryCount <= (stringsOffset - entriesOffset) / 16
                else {
                    throw OpenCCStoreError.invalidFormat("dictionary \(index) out of bounds")
                }
                for entry in 0..<entryCount {
                    let entryRow = entriesOffset + 16 * entry
                    let keyOffset = try u32(entryRow), keyLength = try u32(entryRow + 4)
                    let valueOffset = try u32(entryRow + 8), valueLength = try u32(entryRow + 12)
                    guard keyLength > 0,
                          keyOffset <= stringsSize - keyLength,
                          valueOffset <= stringsSize - valueLength
                    else {
                        throw OpenCCStoreError.invalidFormat("dictionary \(index) entry \(entry) out of bounds")
                    }
                }
                dictionaries.append(Dictionary(entryCount: entryCount, entriesOffset: entriesOffset))
            }
            self.dictionaries = dictionaries

            var conversions: [String: [[Int]]] = [:]
            for index in 0..<conversionCount {
                let row = conversionTable + 16 * index
                let name = try string(try u32(row), try u32(row + 4))
                let stepCount = try u32(row + 8)
                var cursor = try u32(row + 12)
                var steps: [[Int]] = []
                for _ in 0..<stepCount {
                    let count = try u32(cursor)
                    var step: [Int] = []
                    for position in 0..<count {
                        let dictionary = try u32(cursor + 4 + 4 * position)
                        guard dictionary < dictCount else {
                            throw OpenCCStoreError.invalidFormat("conversion \(name) uses unknown dictionary")
                        }
                        step.append(dictionary)
                    }
                    steps.append(step)
                    cursor += 4 + 4 * count
                }
                conversions[name] = steps
            }
            self.conversions = conversions
        } catch {
            munmap(pointer, size)
            throw error
        }
    }

    deinit {
        munmap(mapping, mappingSize)
    }

    func converter(named name: String) throws -> OpenCCConverter {
        guard let steps = conversions[name] else {
            throw OpenCCStoreError.unknownConversion(name)
        }
        return OpenCCConverter(store: self, steps: steps)
    }

    // MARK: Lookup

    private struct Entry {
        let keyOffset: Int
        let keyLength: Int
        let valueOffset: Int
        let valueLength: Int
    }

    private func entry(_ dictionary: Dictionary, _ index: Int) -> Entry {
        let base = UnsafeRawPointer(mapping) + dictionary.entriesOffset + 16 * index
        func u32(_ offset: Int) -> Int {
            Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
        return Entry(keyOffset: u32(0), keyLength: u32(4), valueOffset: u32(8), valueLength: u32(12))
    }

    private func bytes(_ offset: Int, _ length: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: UnsafeRawPointer(mapping) + stringsOffset + offset, count: length)
    }

    /// Longest key in `dictionary` that is a prefix of `text[start...]`, ending
    /// on one of `boundaries` (the UTF-8 offsets of character ends after `start`).
    /// Returns the end offset and the value bytes.
    fileprivate func longestPrefix(
        in dictionaryIndex: Int,
        text: UnsafeBufferPointer<UInt8>,
        start: Int,
        boundaries: ArraySlice<Int>
    ) -> (end: Int, value: UnsafeRawBufferPointer)? {
        let dictionary = dictionaries[dictionaryIndex]
        var best: (end: Int, value: UnsafeRawBufferPointer)?
        var low = 0
        for end in boundaries {
            let prefix = UnsafeBufferPointer(rebasing: text[start..<end])
            // First entry whose key is >= prefix; longer prefixes only move it right.
            var high = dictionary.entryCount
            while low < high {
                let middle = (low + high) / 2
                if compare(entry(dictionary, middle), prefix) < 0 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < dictionary.entryCount else { break }
            let candidate = entry(dictionary, low)
            let key = bytes(candidate.keyOffset, candidate.keyLength)
            guard key.count >= prefix.count,
                  memcmp(key.baseAddress!, prefix.baseAddress!, prefix.count) == 0
            else { break }
            if key.count == prefix.count {
                best = (end, bytes(candidate.valueOffset, candidate.valueLength))
            }
        }
        return best
    }

    private func compare(_ entry: Entry, _ prefix: UnsafeBufferPointer<UInt8>) -> Int {
        let key = bytes(entry.keyOffset, entry.keyLength)
        let common = min(key.count, prefix.count)
        if common > 0 {
            let result = memcmp(key.baseAddress!, prefix.baseAddress!, common)
            if result != 0 { return Int(result) }
        }
        return key.count - prefix.count
    }
}

/// One OpenCC conversion chain. Each step is a short-circuit dictionary group:
/// at every position the first dictionary with any prefix match contributes
/// its longest matching key; unmatched characters are copied unchanged.
struct OpenCCConverter: @unchecked Sendable {
    fileprivate let store: MappedOpenCCStore
    fileprivate let steps: [[Int]]

    func convert(_ text: String) -> String {
        guard !text.isEmpty, text.utf8.contains(where: { $0 >= 0x80 }) else { return text }
        var bytes = Array(text.utf8)
        for step in steps {
            bytes = convert(bytes, step: step)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func convert(_ input: [UInt8], step: [Int]) -> [UInt8] {
        // End offset of every character, so matches never split a scalar.
        var boundaries: [Int] = []
        boundaries.reserveCapacity(input.count)
        for (index, byte) in input.enumerated() where index > 0 && byte & 0xC0 != 0x80 {
            boundaries.append(index)
        }
        boundaries.append(input.count)

        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        input.withUnsafeBufferPointer { text in
            var position = 0
            var boundaryIndex = 0
            while position < text.count {
                let ends = boundaries[boundaryIndex...]
                var matched: (end: Int, value: UnsafeRawBufferPointer)?
                for dictionary in step {
                    matched = store.longestPrefix(in: dictionary, text: text, start: position, boundaries: ends)
                    if matched != nil { break }
                }
                let end: Int
                if let matched {
                    output.append(contentsOf: matched.value)
                    end = matched.end
                } else {
                    end = boundaries[boundaryIndex]
                    output.append(contentsOf: text[position..<end])
                }
                position = end
                while boundaryIndex < boundaries.count, boundaries[boundaryIndex] <= position {
                    boundaryIndex += 1
                }
            }
        }
        return output
    }
}

/// Converts between the lexicon's canonical text and what the user sees.
struct CandidateTextConverter: Sendable {
    static let identity = CandidateTextConverter(output: nil, context: nil)

    private let output: OpenCCConverter?
    private let context: OpenCCConverter?

    private init(output: OpenCCConverter?, context: OpenCCConverter?) {
        self.output = output
        self.context = context
    }

    init(variant: CharacterVariant, store: MappedOpenCCStore) throws {
        try self.init(
            output: variant.outputConversion.map(store.converter(named:)),
            context: variant.contextConversion.map(store.converter(named:))
        )
    }

    var isIdentity: Bool { output == nil }

    func display(_ canonical: String) -> String {
        output?.convert(canonical) ?? canonical
    }

    func canonical(_ display: String) -> String {
        context?.convert(display) ?? display
    }
}
