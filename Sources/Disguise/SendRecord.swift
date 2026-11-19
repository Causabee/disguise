import Foundation

/// F027: the record of one send — what each stand-in replaced in it, word for word, as it stood in the
/// text. The answer to that send is put back from this record and from nothing else: a stand-in comes
/// back as the words it replaced in that send, never as a fuller name, another spelling the list holds,
/// or another person's surname (principle 11, "What I wrote comes back").
///
/// It lives in memory with its send, and is on purpose not `Codable`: it is never written into the list,
/// a file, the store, the log or a request. It ends with the answer it puts back.
public struct SendRecord: Sendable, Equatable {
    /// One stand-in written into the send.
    public struct Note: Sendable, Equatable {
        /// The stand-in as written: `Herrn [Person A]`.
        public var standIn: String
        /// The words it replaced, as they stood in the text, without an ending (the "s" of `Schüßlers`).
        public var words: String
        /// Which text of the send it stands in — a field, a piece — and from where to where in that text
        /// once disguised, in UTF-16 offsets.
        public var source: String
        public var range: Range<Int>
        /// It stood in the owner's question (the chat's only).
        public var question: Bool
        /// For each tag of the stand-in, the words that tag replaced: `[Person A]` → `Patrick Schüßler` of
        /// `Herrn [Person A]` for `Herrn Patrick Schüßler`. Empty where they do not line up: then the note
        /// stands for the whole stand-in only. Empty too for a surname after another first name.
        public var tags: [String: String]

        public init(standIn: String, words: String, source: String = "", range: Range<Int> = 0..<0, question: Bool = false,
                    tags: [String: String]? = nil) {
            self.standIn = standIn
            self.words = words
            self.source = source
            self.range = range
            self.question = question
            self.tags = tags ?? SendRecord.align(standIn, words)
        }
    }

    public var notes: [Note]

    public init(notes: [Note] = []) {
        self.notes = notes
    }

    /// A note the disguise did not make: a word the second pass found and hid for this send only.
    public mutating func note(_ standIn: String, as words: String, in source: String = "", question: Bool = false) {
        notes.append(Note(standIn: standIn, words: words, source: source, question: question))
    }

    /// Another record's notes, after these: the pieces of one send.
    public mutating func add(_ other: SendRecord) {
        notes += other.notes
    }

    /// Cut to the exact text that leaves: only the notes whose stand-in stands in it. A stand-in the send
    /// did not carry is in no record, so it keeps its brackets wherever it comes back.
    public func cut(to text: String) -> SendRecord {
        let text = text.precomposedStringWithCanonicalMapping
        return SendRecord(notes: notes.filter { note in
            note.tags.isEmpty ? text.contains(note.standIn) : note.tags.keys.contains { text.contains($0) }
        })
    }

    // MARK: The way back

    /// The way back for this send's answer:
    /// 1. each stand-in as written in this send comes back as the words it replaced (`Herrn [Person A]` →
    ///    `Herrn Patrick Schüßler`);
    /// 2. each tag on its own as one of the ways this send held for it: the owner's question's first (the
    ///    first written there), else the plainest of the rest, else the first written; comma order in
    ///    reading order, the same words;
    /// 3. a surname disguised after another first name (`Herta [Person B]` → `Herta Kloss`) wins, longer;
    /// 4. `[Person A·first]` and `[Person A·last]` from the ways this send held: the first name of the chosen
    ///    one; the surname of the first held way that has one; else the words it did hold;
    /// 5. as before: an ending (`[Person A]s` → `Schüßlers`), a street's number written twice, two stand-ins
    ///    side by side that are one name.
    /// A stand-in this send did not hold is not in it, and keeps its brackets.
    public var restorer: Replacer {
        var pairs: [(String, String)] = []
        // 3: the surname notes, longest.
        for note in notes where note.tags.isEmpty && Pseudonymizer.tags(in: note.standIn).count == 1 && !note.standIn.hasPrefix("[") {
            pairs.append((note.standIn, note.words))
        }
        // 1: each stand-in with words of its own around its tags.
        let written = Dictionary(grouping: notes.indices.filter { !isBareTag(notes[$0].standIn) }, by: { Pseudonymizer.key(notes[$0].standIn) })
        for indices in written.values {
            guard let best = chosen(indices.map { (notes[$0].words, notes[$0].question, $0) }) else { continue }
            pairs.append((notes[indices[0]].standIn, best))
        }
        // 2 and 4: each tag on its own, and its first and last name.
        var held: [String: [(String, Bool, Int)]] = [:]
        for (n, note) in notes.enumerated() {
            for (tag, words) in note.tags { held[tag, default: []].append((words, note.question, n)) }
        }
        for (tag, ways) in held {
            let order = ordered(ways)
            guard let best = order.first.map(Self.natural) else { continue }
            pairs.append((tag, best))
            guard tag.hasPrefix("[Person ") else { continue }
            let first = Pseudonymizer.nameParts(best).given ?? best
            let last = order.lazy.compactMap { way -> String? in
                let name = Pseudonymizer.nameParts(way)
                return name.given != nil ? name.family : nil
            }.first ?? best
            pairs.append((String(tag.dropLast()) + "·first]", first))
            pairs.append((String(tag.dropLast()) + "·last]", last))
        }
        var replacer = Replacer(pairs)
        replacer.joinsNames = true
        return replacer
    }

    /// This send's answer, put back.
    public func restore(_ text: String) -> String { restorer.apply(text).text }

    func isBareTag(_ standIn: String) -> Bool { Pseudonymizer.tags(in: standIn) == [standIn] }

    /// The ways held for one stand-in or tag, in the order they come back: the owner's question's first,
    /// as written there; then the plainest; then the first written in the send.
    func ordered(_ ways: [(words: String, question: Bool, at: Int)]) -> [String] {
        ways.sorted { a, b in
            if a.question != b.question { return a.question }
            if a.question { return a.at < b.at }
            let (x, y) = (Self.plainness(a.words), Self.plainness(b.words))
            return x != y ? x.lexicographicallyPrecedes(y) : a.at < b.at
        }.map(\.words)
    }

    func chosen(_ ways: [(words: String, question: Bool, at: Int)]) -> String? { ordered(ways).first }

    /// How plain a way of writing is, in the order the row's name uses: not ending on a contact word; a first
    /// name and a surname before one word; the fewest marks (a title, comma order, capitals, quote marks, a
    /// label, via, brackets); the fewest words.
    static func plainness(_ words: String) -> [Int] {
        let count = Pseudonymizer.words(words).count
        let titles = Pseudonymizer.words(words).prefix { Pseudonymizer.isListTitle($0) }.count
        return [Pseudonymizer.endsOnContactWord(words) ? 1 : 0, count - titles < 2 ? 1 : 0, Pseudonymizer.decoration(words), count]
    }

    /// `Lechner, Martina` as `Martina Lechner`: the same words, in reading order.
    static func natural(_ words: String) -> String {
        guard words.contains(",") else { return words }
        func isName(_ word: Substring) -> Bool { !word.isEmpty && word.allSatisfy { $0.isLetter || $0 == "-" } }
        let halves = words.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2, isName(halves[0]), halves[1].first?.isWhitespace == true else { return words }
        let given = halves[1].drop { $0.isWhitespace }
        let parts = given.split(separator: " ", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy(isName) else { return words }
        return "\(given) \(halves[0])"
    }

    // MARK: Noting

    /// For each tag in a stand-in, the words it replaced: the stand-in's own words — a title in front,
    /// " via ", brackets, the space between a code and a town — taken off the replaced words in order.
    /// Empty when they do not line up.
    static func align(_ standIn: String, _ words: String) -> [String: String] {
        let tags = Pseudonymizer.tags(in: standIn)
        guard !tags.isEmpty else { return [:] }
        // The stand-in in pieces: its own words, and its tags.
        var pieces: [(literal: String, tag: String?)] = []
        var rest = Substring(standIn)
        for tag in tags {
            guard let range = rest.range(of: tag) else { return [:] }
            if range.lowerBound > rest.startIndex { pieces.append((String(rest[..<range.lowerBound]), nil)) }
            pieces.append(("", tag))
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { pieces.append((String(rest), nil)) }
        var out: [String: String] = [:]
        var at = words.startIndex
        for (n, piece) in pieces.enumerated() {
            if let tag = piece.tag {
                // Up to the next piece of the stand-in's own words, or to the end.
                let end: String.Index
                if n + 1 < pieces.count, let next = words.range(of: pieces[n + 1].literal, options: [.caseInsensitive], range: at..<words.endIndex) {
                    end = next.lowerBound
                } else if n + 1 < pieces.count {
                    return [:]
                } else {
                    end = words.endIndex
                }
                let held = words[at..<end].trimmingCharacters(in: .whitespaces)
                guard !held.isEmpty else { return [:] }
                if let other = out[tag], other != held { return [:] }
                out[tag] = held
                at = end
            } else {
                guard let range = words.range(of: piece.literal, options: [.caseInsensitive, .anchored], range: at..<words.endIndex) else { return [:] }
                at = range.upperBound
            }
        }
        return at == words.endIndex ? out : [:]
    }

    /// The ending a replacement kept from the text: the "s" of `[Person A]s`.
    static func ending(of replacement: String) -> String {
        guard let close = replacement.lastIndex(of: "]") else { return "" }
        let tail = String(replacement[replacement.index(after: close)...])
        return ["s", "'s", "’s"].contains(tail) ? tail : ""
    }
}

extension Replacer {
    /// F027: `apply`, and each replacement noted as it is made, from the matcher's own finds: exactly the
    /// bytes and the count `apply` gives. A spelling the disguise found is noted as it stood (`Herr
    /// Schuessler`, not the list's `Schüßler`), and a surname after another first name (`surnameNotes`) too.
    public func apply(_ text: String, noting record: inout SendRecord, in source: String = "", question: Bool = false) -> (text: String, count: Int) {
        let text = text.precomposedStringWithCanonicalMapping
        let found = found(in: text)
        var out = text
        for item in found.reversed() { out.replaceSubrange(item.range, with: item.with) }
        var shift = 0
        for item in found {
            let written = String(text[item.range])
            let ending = SendRecord.ending(of: item.with)
            let standIn = String(item.with.dropLast(ending.count))
            let words = written.hasSuffix(ending) ? String(written.dropLast(ending.count)) : written
            let start = text.utf16.distance(from: text.startIndex, to: item.range.lowerBound) + shift
            record.notes.append(.init(standIn: standIn, words: words, source: source, range: start..<(start + standIn.utf16.count), question: question))
            shift += item.with.utf16.count - written.utf16.count
        }
        for (standIn, words) in surnameNotes(in: text).sorted(by: { $0.key < $1.key }) {
            let start = (out as NSString).range(of: standIn)
            let range = start.location == NSNotFound ? 0..<0 : start.location..<(start.location + start.length)
            record.notes.append(.init(standIn: standIn, words: words, source: source, range: range, question: question, tags: [:]))
        }
        return (out, found.count)
    }
}

extension Pseudonymizer {
    /// F027: `disguise`, each field noted in the send's record, by its name (`subject`, `from`, `body` …).
    public func disguise(_ email: Email, with replacer: Replacer? = nil, noting record: inout SendRecord) -> Disguise {
        let replacer = replacer ?? disguiser
        var count = 0
        func apply(_ text: String, _ field: Entity.Field) -> String {
            let (out, made) = replacer.apply(text, noting: &record, in: field.rawValue)
            count += made
            return out
        }
        return Disguise(mode: mode,
                        subject: apply(email.subject, .subject),
                        from: apply(email.from, .from),
                        to: email.to.map { apply($0, .to) },
                        cc: email.cc.map { apply($0, .cc) },
                        body: apply(email.body, .body),
                        attachmentNames: email.attachments.map { apply($0.filename, .attachmentName) },
                        replacements: count)
    }
}
