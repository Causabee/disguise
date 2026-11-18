import Compression
import Foundation

/// F020: what the shipped lists say of a word — a first name, a surname, an ordinary German word.
/// Read on the device, from files inside the app; nothing is fetched, and no word is sent anywhere
/// because of them. Read only by the review's decision (`NameDecision`) and by the one veto of the
/// sender check (N7, the new rules); no other code that finds or disguises a name reads
/// them (3-spec.md, "The lists"; AC-17).
public protocol NameKnowing: Sendable {
    /// Nil when the list could not be read: nothing may then be said of the word by it.
    func isFirstName(_ word: String) -> Bool?
    func isSurname(_ word: String) -> Bool?
}

extension NameKnowing {
    /// On either name list. Nil when a list could not be read and the other does not have it.
    public func isName(_ word: String) -> Bool? {
        let first = isFirstName(word), last = isSurname(word)
        if first == true || last == true { return true }
        if first == nil || last == nil { return nil }
        return false
    }
}

/// The commonest ordinary words, ranked: 1 is the commonest.
public protocol WordRanking: Sendable {
    /// The rank among the commonest words; nil when the word is not among them. `readable` false:
    /// the list could not be read, and no rank is known.
    func rank(_ word: String) -> Int?
    var readable: Bool { get }
}

/// A packed word list, unpacked once into one block of bytes and an index of where each word
/// starts, sorted, searched by halving: memory stays near the unpacked size (no hash set, no
/// `String` a word).
final class PackedWords: @unchecked Sendable {
    /// The unpacked words, one a line, kept as they came from the unpacker: no second copy.
    private let bytes: Data
    /// Start of each word, in the order of the words' bytes.
    private let sorted: [UInt32]
    /// Each word's place in the file (its rank, for the list of ordinary words), by `sorted`.
    private let ranks: [UInt32]?
    let count: Int

    init?(data: Data, ranked: Bool) {
        var bytes = data
        if bytes.last != 0x0A { bytes.append(0x0A) }
        var starts: [UInt32] = []
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buffer = raw.bindMemory(to: UInt8.self)
            var lines = 0
            for b in buffer where b == 0x0A { lines += 1 }
            starts.reserveCapacity(lines)
            var start = 0
            for i in 0..<buffer.count where buffer[i] == 0x0A {
                if i > start { starts.append(UInt32(start)) }
                start = i + 1
            }
        }
        guard !starts.isEmpty else { return nil }
        self.count = starts.count
        if ranked {
            let order = bytes.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                return starts.indices.sorted { Self.less(b, starts[$0], starts[$1]) }
            }
            sorted = order.map { starts[$0] }
            ranks = order.map { UInt32($0 + 1) }
        } else {
            sorted = starts // written sorted by the build script
            ranks = nil
        }
        self.bytes = bytes
    }

    private static func less(_ bytes: UnsafeBufferPointer<UInt8>, _ a: UInt32, _ b: UInt32) -> Bool {
        var i = Int(a), j = Int(b)
        while true {
            let x = bytes[i], y = bytes[j]
            if x == 0x0A { return y != 0x0A }
            if y == 0x0A { return false }
            if x != y { return x < y }
            i += 1; j += 1
        }
    }

    private func find(_ word: String) -> Int? {
        let key = Array(NameKnowledge.fold(word).utf8)
        guard !key.isEmpty else { return nil }
        return bytes.withUnsafeBytes { raw -> Int? in
            let b = raw.bindMemory(to: UInt8.self)
            /// -1, 0, 1: the word at `start` against `key`.
            func compare(_ start: UInt32) -> Int {
                var i = Int(start)
                for w in key {
                    let x = b[i]
                    if x == 0x0A { return -1 }
                    if x != w { return x < w ? -1 : 1 }
                    i += 1
                }
                return b[i] == 0x0A ? 0 : 1
            }
            var low = 0, high = sorted.count - 1
            while low <= high {
                let mid = (low + high) / 2
                switch compare(sorted[mid]) {
                case 0: return mid
                case -1: low = mid + 1
                default: high = mid - 1
                }
            }
            return nil
        }
    }

    func contains(_ word: String) -> Bool { find(word) != nil }
    func rank(_ word: String) -> Int? {
        guard let i = find(word) else { return nil }
        return ranks.map { Int($0[i]) } ?? i + 1
    }

    /// Bytes held: the words, and four bytes a word for each index.
    var memory: Int { bytes.count + sorted.count * 4 + (ranks?.count ?? 0) * 4 }
}

/// The lists shipped in `Resources/Names`: Wikidata's given names and family names (CC0), and the
/// 50,000 commonest words of Mozilla Common Voice's German sentences (CC0). See `LICENCES.txt`.
public final class NameKnowledge: NameKnowing, @unchecked Sendable {
    public static let shared = NameKnowledge()

    private let lock = NSLock()
    private var loaded = false
    private var first: PackedWords?
    private var last: PackedWords?
    private let load: (String) -> Data?

    /// How many times the name sets were unpacked, and what the last took: printed by the tests.
    public private(set) var loads = 0
    public private(set) var loadSeconds: Double = 0
    public private(set) var bytesHeld = 0

    /// `load`: a list's packed bytes by name; the app's own files by default. A test passes one
    /// that fails, to see what a list that cannot be read does.
    public init(load: @escaping (String) -> Data? = NameKnowledge.bundled) {
        self.load = load
    }

    public static func bundled(_ name: String) -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "lzfse", subdirectory: "Names")
            ?? Bundle.module.url(forResource: name, withExtension: "lzfse") else { return nil }
        // Mapped, not read: the packed bytes are the file's pages, not a copy on the heap.
        return try? Data(contentsOf: url, options: .alwaysMapped)
    }

    /// Unpacked straight into one block: room for six times the packed size is asked for, and only
    /// the pages the words fill are ever touched, so memory is the words' size, with no growing copy.
    static func unpack(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        var room = data.count * 6
        while room <= 64 << 20 {
            guard let out = malloc(room)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let used = data.withUnsafeBytes { raw in
                compression_decode_buffer(out, room, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
            if used > 0, used < room { return Data(bytesNoCopy: out, count: used, deallocator: .free) }
            free(out)
            if used == 0 { return nil }
            room *= 2
        }
        return nil
    }

    /// Folded as the disguise folds a word: `Pseudonymizer.key`.
    static func fold(_ word: String) -> String { Pseudonymizer.key(word) }

    /// The two name sets, on first need, once for the process.
    private func names() -> (PackedWords?, PackedWords?) {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            let start = Date()
            first = Self.unpack(load("first-names")).flatMap { PackedWords(data: $0, ranked: false) }
            last = Self.unpack(load("surnames")).flatMap { PackedWords(data: $0, ranked: false) }
            loadSeconds = Date().timeIntervalSince(start)
            bytesHeld = (first?.memory ?? 0) + (last?.memory ?? 0)
            loads += 1
            loaded = true
        }
        return (first, last)
    }

    public var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }

    public func isFirstName(_ word: String) -> Bool? { names().0.map { $0.contains(word) } }
    public func isSurname(_ word: String) -> Bool? { names().1.map { $0.contains(word) } }

    public var counts: (first: Int, last: Int) { let n = names(); return (n.0?.count ?? 0, n.1?.count ?? 0) }

    /// The ordinary words, for the review only: unpacked when it runs and let go when it ends.
    public func ordinaryWords() -> any WordRanking {
        OrdinaryWords(Self.unpack(load("words")).flatMap { PackedWords(data: $0, ranked: true) })
    }
}

struct OrdinaryWords: WordRanking, @unchecked Sendable {
    let words: PackedWords?
    init(_ words: PackedWords?) { self.words = words }
    var readable: Bool { words != nil }
    func rank(_ word: String) -> Int? { words?.rank(word) }
}
