import CryptoKit
import Foundation

/// Step 4 of the spike: replace everything identifiable before any of it is sent, and keep the
/// way back on the device.
///
/// Two modes, because question three of the plan is which one costs the model less accuracy:
///
/// - `placeholder` writes `[Person A]`, `[Company B]`. Nothing about the original survives, and
///   nothing about the stand-in can be mistaken for a real person.
/// - `standin` writes a realistic replacement of the same shape: a full name for a full name,
///   `Frau` kept in front of a surname, a legal form kept on a company, a house number on a
///   street. A model reads it as ordinary mail.
///
/// Two things make this more than a find-and-replace of what step 3 found.
///
/// **Everything learned is replaced everywhere.** The tagger finds a name in one sentence and
/// misses it in the next; a disguise that only covers what was found in *this* mail leaks the
/// rest. So a folder is learned first, and every mail is then disguised with the whole mapping.
///
/// **A name is learned in parts.** `Patrick Schüßler` also teaches `Schüßler` and `Patrick`;
/// `Honigtauer Str. 14` teaches `Honigtauer`; `10437 Berlin` teaches `Berlin`. That is how
/// a bare surname in a greeting, or the street written without its dot, is still covered — and
/// in `standin` mode it keeps relationships readable: `Frau Seeger` and `Hausverwaltung Seeger
/// GmbH` become the same new surname, because they were the same surname.
public struct Pseudonymizer: Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case placeholder, standin
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var kind: Entity.Kind
        public var original: String
        public var standIn: String
        /// Set when the entry was made from part of another — the surname out of a full name, the
        /// street out of an address — so the mapping says where every line came from.
        public var partOf: String?
        /// F027: set when the entry is a way of writing a row (`Herrn Patrick Schüßler` of `Patrick
        /// Schüßler`): the row's original. It has the row's stand-in, and no `partOf`, so an older build,
        /// which ignores this key, takes it over as a whole of its own and hides it.
        public var formOf: String?

        // F024: the memberwise init, public now that the type lives in its own package.
        public init(kind: Entity.Kind, original: String, standIn: String, partOf: String? = nil, formOf: String? = nil) {
            self.kind = kind
            self.original = original
            self.standIn = standIn
            self.partOf = partOf
            self.formOf = formOf
        }

        enum CodingKeys: String, CodingKey { case kind, original, standIn = "stand_in", partOf = "part_of", formOf = "form_of" }
    }

    /// `mapping.json`: both modes, so a comparison run of one does not throw away the other.
    /// Made from real mail, gitignored, and never sent anywhere.
    public struct Mapping: Codable, Equatable, Sendable {
        public var version = Self.current
        public var placeholder: [Entry] = []
        public var standin: [Entry] = []
        /// F020: the owner replaced the list — on this device or another — and what they let go, as
        /// hashes only (`Mapping.hashed`). A key of the list's own JSON, not of the store: an older
        /// build ignores it, and drops it when it writes its own file.
        public var cleaned: Cleaned?
        /// F020: written by every build that knows `cleaned`, at its first start and with every write
        /// of a list (`MappingFile.write`). A list without it was last written by an older build.
        public var level: Int? = Self.level
        public static let level = 1
        /// F021 AC-19: when this device's list was started fresh, built only by the new rules. A key
        /// of the list's own JSON, not of the store: an older build ignores it and drops it when it
        /// writes, so a list without it was built by the old rules — never adopted, and on this
        /// build started fresh once (`NameFresh`).
        public var fresh: Date?
        /// F022 (the owner, 18 November 2026: „Ich kann ihn doch ausschalten und dann kann ich ihn
        /// irgendwann wieder anschalten“): the owner's switch on a whole of the list, by the hash of its
        /// folded original (`hashed`, as `dropped`), with when it was set. `on`, `off`, or `gone` (deleted:
        /// the tombstone). The newest wins between devices. A key of the list's own JSON, not of the
        /// store: an older build ignores it and drops it when it writes. Every write of this build sets
        /// it, `{}` at least, so a list with the key was written by this build. Nil: everything on.
        public var switches: [String: Switch]?
        /// F027: written by every write of this build (`MappingFile.write`): this list's ways of writing
        /// were joined under their rows. A list without it was last written by an earlier build, or
        /// copied and written again by one, and is joined when read. An older build ignores it and
        /// drops it when it writes its own file.
        public var joined: Int? = Self.joinedLevel
        public static let joinedLevel = 1

        public struct Switch: Codable, Equatable, Sendable {
            public enum State: String, Codable, Sendable { case on, off, gone }
            public var state: State
            public var at: Date
            /// F027: `true` when this switch speaks for a row and every way of writing it; absent when it
            /// speaks for the one name whose hash it is (an older build's, one set before this build, or
            /// a way's own `on`). An older build ignores it: there the switch is for that one name.
            public var ways: Bool?
            public init(_ state: State, at: Date, ways: Bool? = nil) {
                self.state = state
                self.at = at
                self.ways = ways == true ? true : nil
            }

            /// It speaks for the row and every way of writing it.
            public var coversWays: Bool { ways == true }

            /// Of two set at the same instant: hidden more, never less — `on`, then `gone`, then `off`.
            var rank: Int { switch state { case .on: 2; case .gone: 1; case .off: 0 } }
            /// The newer of two; on a tie, the one that hides more. F027: on a tie of time and state, the one
            /// with `ways` — an older build's copy of the same switch lost the word when it wrote its own file.
            func beats(_ other: Switch) -> Bool {
                if at != other.at { return at > other.at }
                if rank != other.rank { return rank > other.rank }
                return coversWays && !other.coversWays
            }
        }

        /// A `gone` lasts this long: then it is dropped at the next write, and in every merge.
        public static let goneLasts: TimeInterval = 90 * 86_400

        /// The hashes of the wholes switched off.
        public var off: Set<String> { Set((switches ?? [:]).filter { $0.value.state == .off }.keys) }
        /// The hashes of the wholes deleted (newest word on them, under 90 days).
        public var gone: Set<String> { Set((switches ?? [:]).filter { $0.value.state == .gone }.keys) }

        /// The owner's word on a whole: on, unless it was switched off or deleted.
        public func state(of original: String) -> Switch.State { switches?[Self.hashed(original)]?.state ?? .on }
        public func isOn(_ original: String) -> Bool { state(of: original) == .on }

        /// Every switch of these lists, the newest of each key (on a tie, the one that hides more); a
        /// `gone` older than 90 days is left out. A list without the key adds nothing: an older build's
        /// record never counts as a turn on.
        public static func merged(_ lists: [[String: Switch]?], now: Date = Date()) -> [String: Switch] {
            var out: [String: Switch] = [:]
            for list in lists.compactMap({ $0 }) {
                for (key, value) in list where out[key].map({ value.beats($0) }) ?? true { out[key] = value }
            }
            return out.filter { !($0.value.state == .gone && now.timeIntervalSince($0.value.at) > goneLasts) }
        }

        /// F020: one replace — chosen once, on one device — and the wholes it let go, cumulative over
        /// earlier replaces, as the SHA-256 of each folded original. Nothing of a dropped word travels.
        public struct Cleaned: Codable, Equatable, Sendable {
            public var id: UUID
            public var at: Date
            public var dropped: [String]
            public init(id: UUID, at: Date, dropped: [String]) {
                self.id = id
                self.at = at
                self.dropped = dropped
            }
        }

        /// The SHA-256 of a name as the list folds it: how a dropped name is recognised, never said.
        public static func hashed(_ original: String) -> String {
            SHA256.hash(data: Data(Pseudonymizer.key(original).utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// The entries that are names of their own, not parts of another.
        public var wholes: [Entry] { placeholder.filter { $0.partOf == nil } }

        /// F020 AC-9, the invariant: a list's own `dropped` never holds the hash of a whole it holds.
        public mutating func keepInvariant() {
            guard var cleaned else { return }
            let held = Set(wholes.map { Self.hashed($0.original) })
            cleaned.dropped = cleaned.dropped.filter { !held.contains($0) }
            self.cleaned = cleaned
        }

        /// 2: in placeholder mode, people who share only a first or a last name no longer share a tag.
        /// 3: a role in front of a name — `Hausmeister Bittner` — is a title, not a first name.
        /// 4: an ordinary word the tagger took for a name, or for the start of one, is no entry.
        /// 7: one row and one stand-in for each name, however it is written: ways of writing name their row (F027).
        public static let current = 7

        public init() {}

        /// Brings a mapping from an earlier version up to this one, and says how many people it
        /// had to tell apart. The people are learned again, full names first; nothing else changes.
        @discardableResult
        public mutating func upgrade() -> Int {
            guard version < Self.current || joined == nil else { return 0 }
            var changed = 0
            if version < 2 {
                let before = Set(placeholder.filter { $0.kind == .person }.compactMap { Pseudonymizer.personTag($0.standIn) }).count
                placeholder = Pseudonymizer.relearningPeople(placeholder)
                changed += Set(placeholder.filter { $0.kind == .person }.compactMap { Pseudonymizer.personTag($0.standIn) }).count - before
            }
            if version < 3 {
                // Only the entries with a role in them, so every other tag keeps its letter and the
                // model's answers for mail that never mentioned one stay in the cache.
                let before = placeholder
                placeholder = Pseudonymizer.rolesAsTitles(placeholder)
                let after = Set(placeholder.map { $0.original + "\u{0}" + $0.standIn })
                changed += before.filter { !after.contains($0.original + "\u{0}" + $0.standIn) }.count
            }
            if version < 4 {
                // What the owner typed to the assistant taught words that are no names: "Schreibe Bertram"
                // as one person, "Alle" as another. They are forgotten; the name beside them has its own entry.
                let before = placeholder.count
                placeholder = Pseudonymizer.withoutMisreadWords(placeholder)
                standin = Pseudonymizer.withoutMisreadWords(standin)
                changed += before - placeholder.count
            }
            if version < 5 {
                // A product read as a person lent its last word to every text: "Design" stood for
                // "Claude Design". Such an entry is forgotten, and the word with it.
                let before = placeholder.count
                placeholder = Pseudonymizer.withoutWordsAtTheEnd(placeholder)
                standin = Pseudonymizer.withoutWordsAtTheEnd(standin)
                changed += before - placeholder.count
            }
            if version < 6 {
                // A single common word read as a company — "For" at the start of a title — stood for
                // a company in every text, and came back capitalised (9 November). Forgotten.
                func common(_ entry: Entry) -> Bool {
                    entry.kind == .organization && !entry.original.contains(" ") && Pseudonymizer.commonWords.contains(Pseudonymizer.key(entry.original))
                }
                let before = placeholder.count
                placeholder.removeAll(where: common)
                standin.removeAll(where: common)
                changed += before - placeholder.count
            }
            if version < 7 || joined == nil {
                // F027: the ways of writing one name joined under one row with one stand-in, once; then
                // checked word by word, and every word that would go out is put back. Counted for the log.
                changed += joinWays()
            }
            version = Self.current
            joined = Self.joinedLevel
            return changed
        }

        public subscript(mode: Mode) -> [Entry] {
            get { mode == .placeholder ? placeholder : standin }
            set { if mode == .placeholder { placeholder = newValue } else { standin = newValue } }
        }
    }

    public let mode: Mode
    public private(set) var entries: [Entry] = []
    private var index: [String: Int] = [:]
    /// Placeholder mode: each full name's tag, by first and last name, so `Ahlers, Patrick`
    /// finds `Patrick Ahlers`.
    private var fullNames: [String: String] = [:]
    /// The tags `fullNames` hands out, and every tag in use, by what comes before its letters
    /// (`[Person `): kept as entries come in, so a new tag is not counted out of all of them again —
    /// taking over another device's list of thousands of names took minutes that way.
    private var fullNameTags: Set<String> = []
    private var usedTags: [String: Set<String>] = [:]
    /// Every original, and every word of one. A stand-in is never picked from here, or restoring
    /// would have two answers for the same word.
    private var forbidden: Set<String> = []
    /// Only while learning: whether the entity being learned came from a rule, and the parts that
    /// were not learned because they are ordinary words.
    private var trusted = true
    /// F021: while learning what the new rules' gate admitted (`learnAdmitted`). Read by `recordPart` (P1).
    private var admitted = false
    private var skippedParts: [Skip] = []
    /// F027, placeholder mode: the first entry of each kind and folded spelling (`foldKey`), so
    /// `Schüßler`, `Schuessler` and `SCHÜSSLER` are found as one name while learning, not as three.
    private var foldIndex: [String: Int] = [:]
    /// F027: the same, for the wholes only (rows and ways of writing): a person is joined to a whole.
    private var foldWhole: [String: Int] = [:]
    /// F027: the tags a word two people share was given (`recordSharedPart`): no single person's.
    private var sharedTags: Set<String> = []
    /// F027, placeholder mode: each full name's tag and the row it was first given to — the row its
    /// other ways of writing (`Herrn Patrick Schüßler`, `Schüßler, Patrick`) go under.
    private var rowOfTag: [String: String] = [:]
    /// F027 rule 8: an initial and a surname (`P. Schüßler`) is no full name: its tag, by initial and
    /// surname, kept apart from `fullNames`.
    private var initialNames: [String: String] = [:]
    /// F027 rule 5: the words of every full name, folded and without titles, by its first two words,
    /// with its tag — for `Mirela Ottilie` out of `Mirela Ottilie Brankovan`.
    private var fullNameWords: [String: [(tag: String, words: [String])]] = [:]

    /// F022: the hashes of the wholes the owner switched off (`Mapping.switches`). They stay in the
    /// list, so they are not learned again and a send already out is still put back; the disguise —
    /// and so the check before a send — skips them and their parts: they go out as written.
    public var off: Set<String> = []

    public init(mode: Mode, entries: [Entry] = [], off: Set<String> = []) {
        self.mode = mode
        self.off = off
        for entry in entries { add(entry) }
    }

    /// F022: a list's own entries, with the owner's switches. Every send builds from this.
    /// F027: what goes out as written is read over ways of writing (`Mapping.outAsWritten`).
    public init(_ mapping: Mapping, mode: Mode = .placeholder) {
        self.init(mode: mode, entries: mapping[mode], off: mapping.outAsWritten(mode))
    }

    /// The entries the disguise uses: all but the wholes switched off and their parts — a part a whole
    /// that stays on holds too stays hidden (`NameLists.shed`).
    public var hidden: [Entry] {
        guard !off.isEmpty else { return entries }
        return Self.shed(entries, dropped: off)
    }

    public func standIn(for original: String) -> String? {
        index[Self.key(original)].map { entries[$0].standIn }
    }

    /// F019: a word the second pass found, learned in a copy for one send only — never in the list
    /// that is kept and synced. A person's tag, as it may be anyone.
    public mutating func learnTransient(_ word: String) -> String? {
        if let known = standIn(for: word) { return known }
        let tag = placeholder(.person)
        return record(.person, word, tag, partOf: nil)
    }

    /// Months and weekdays where they are a date — `5. Jan 2027`, `Mai 2026`, `Sonntag, 3.` — taken
    /// out of a text before it is looked at for names: there `Jan` is a month, whoever else is called Jan.
    static func withoutDates(_ text: String) -> String {
        guard let regex = datedCalendarWord else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    /// Is the calendar word at `range` part of a date: a day number before it, or a year after it?
    static func isDated(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<range.lowerBound].suffix(6)
        let after = text[range.upperBound...].prefix(7)
        if before.range(of: #"\d{1,2}\.?\s*$"#, options: .regularExpression) != nil { return true }
        if after.range(of: #"^\.?,?\s*\d{1,4}\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    static let datedCalendarWord: NSRegularExpression? = {
        let months = "januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember|january|february|march|may|june|july|october|december|jan|feb|mär|mar|apr|jun|jul|aug|sep|sept|okt|oct|nov|dez|dec"
        let days = "montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        return try? NSRegularExpression(pattern: #"(?i)(?<=\d\.|\d\. |\d )(?:"# + months + "|" + days + #")(?![\p{L}])|(?<![\p{L}])(?:"# + months + "|" + days + #")(?=\.?,?\s*\d)"#)
    }()

    // MARK: Learning

    /// What the detector found that the disguise left alone, and why. A false positive from the
    /// tagger — `Sie`, `Mit`, `IBAN` — replaced in every mail would ruin the text for nothing,
    /// but a skipped word is exactly where a missed name would hide, so every one is reported.
    public struct Skip: Codable, Equatable, Sendable {
        public var text: String
        public var reason: String
    }

    /// Learns everything in `entities`, all items at once: what the rules' one gate admitted
    /// (F021). The old admission — the skip reasons, the trimming of the tagger's spans and the
    /// frequency test — went with the old rules (AC-9); the gate asks once, before. `vocabulary` is
    /// no longer read.
    @discardableResult
    public mutating func learn(_ entities: [Entity], vocabulary: Vocabulary = Vocabulary([])) -> [Skip] {
        learnAdmitted(entities)
    }

    /// F021: what the new rules' gate admitted (`Gate.admit`), learned as it stands. The gate asked
    /// once, so the old skip reasons, the trimming and the frequency test are not asked again; the
    /// list's own mechanics — the order, the stand-ins, the parts — are the same as `learn`'s. Only
    /// `Detection` calls it, and only while the new rules decide (or a test sets them).
    @discardableResult
    public mutating func learnAdmitted(_ entities: [Entity]) -> [Skip] {
        skippedParts = []
        var skipped: [Skip] = []
        var usable: [Entity] = []
        for entity in entities {
            if [.organization, .person, .place].contains(entity.kind), PublicNames.covers(entity.text) {
                skipped.append(.init(text: entity.text, reason: "public, as you marked it"))
                continue
            }
            usable.append(entity)
        }
        for entity in usable {
            forbidden.insert(Self.key(entity.text))
            for word in Self.words(entity.text) { forbidden.insert(Self.key(word)) }
        }
        let sorted = usable.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if Self.priority(x.kind) != Self.priority(y.kind) { return Self.priority(x.kind) < Self.priority(y.kind) }
            if Self.fullness(x.kind, x.text) != Self.fullness(y.kind, y.text) { return Self.fullness(x.kind, x.text) > Self.fullness(y.kind, y.text) }
            if Self.words(x.text).count != Self.words(y.text).count { return Self.words(x.text).count > Self.words(y.text).count }
            return a.offset < b.offset
        }.map(\.element)
        // F027: of the ways one person is written in this batch, the plainest is learned first, so it is the row.
        let ordered = mode == .placeholder ? Self.plainestFirst(sorted) : sorted
        admitted = true
        defer { admitted = false }
        for entity in ordered {
            // A word the gate admitted as a name of its own (`Eisenhut` of `Kanzlei Eisenhut &
            // Partner`) is no longer only a part of another (P2 then leaves it alone).
            if [.person, .organization].contains(entity.kind), Self.words(entity.text).count == 1,
               let at = index[Self.key(entity.text)], let whole = entries[at].partOf, entries[at].kind == .person,
               // F022 AC-5: a part of a whole the owner switched off goes with it; it is not made a whole.
               !off.contains(Mapping.hashed(whole)) {
                entries[at].partOf = nil
                // F027: a word of one person, admitted on its own, is a way of writing that person's row;
                // a word two people share keeps a stand-in of its own and is a row of its own (AC-4).
                if mode == .placeholder, let tag = Self.personTag(entries[at].standIn), entries[at].standIn == tag,
                   fullNameTags.contains(tag), let row = rowOfTag[tag], index[Self.key(row)] != nil,
                   Self.key(row) != Self.key(entries[at].original) {
                    entries[at].formOf = root(of: row)
                }
            }
            // F027 rule 3: a via name's service that also came in on its own is a company row of its own.
            if mode == .placeholder, entity.kind == .organization, let at = index[Self.key(entity.text)], entries[at].kind == .organization,
               let whole = entries[at].partOf, let w = index[Self.key(whole)], entries[w].kind == .person {
                entries[at].partOf = nil
            }
            learn(entity.kind, entity.text)
        }
        var seen: Set<String> = []
        return (skipped + skippedParts).filter { seen.insert($0.text).inserted }
    }

    /// A small word read as a place: „der“ out of a scan's „10119 DER“. Only articles, prepositions,
    /// pronouns and the like — a town that is a noun, Haus in Austria, stays a place (the owner,
    /// 17 November: "Yes, small words"). A town named „Die“ goes out as written; that is accepted.
    static func isCommonPlace(_ word: String) -> Bool {
        !word.contains(" ") && smallWords.contains(key(word))
    }

    static let smallWords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "und", "oder", "aber", "zu", "zur", "zum", "mit", "für", "an", "am", "auf", "aus", "bei", "beim",
        "bis", "in", "im", "ins", "um", "von", "vom", "nach", "seit", "über", "unter", "vor", "durch",
        "gegen", "ohne", "ich", "du", "er", "sie", "es", "wir", "ihr", "ihm", "ihn", "ihnen", "uns", "euch",
        "mir", "mich", "dir", "dich", "sich", "sein", "seine", "ihre", "ihren", "ihrer", "mein", "meine",
        "dein", "deine", "unser", "unsere",
        "the", "a", "an", "and", "or", "of", "to", "for", "on", "at", "by", "with", "from", "it", "is", "are",
    ]

    public static func isListed(_ word: String) -> Bool {
        let key = key(word)
        return commonWords.contains(key) || greetings.contains(key) || calendarWords.contains(key) || Pseudonymizer.isTitle(key)
    }

    /// The entries without those a name or a place was never in: only words on the lists, or one of
    /// them in front of a name — and without the parts made of such an entry.
    static func withoutMisreadWords(_ entries: [Entry]) -> [Entry] {
        var dropped = Set<String>()
        for entry in entries where entry.kind == .person || entry.kind == .place {
            let tokens = words(entry.original)
            guard let first = tokens.first else { continue }
            func ordinary(_ token: String) -> Bool {
                let key = key(token)
                return !Pseudonymizer.isTitle(key) && !particles.contains(key) && isListed(token)
            }
            if tokens.allSatisfy(ordinary) || (tokens.count > 1 && ordinary(first)) { dropped.insert(entry.original) }
        }
        return entries.filter { !dropped.contains($0.original) && !($0.partOf.map(dropped.contains) ?? false) }
    }

    /// The entries without a name or a place that ends in a word of the common list, and without a
    /// part that is such a word by itself. "Claude Design" is a product, and was read as a first
    /// name and a surname — and "Design" alone then stood for that person in every text, so that
    /// "Head of Design System" came back as "Head of Claude Design System". By the common words
    /// only, not the calendar's: "Jan" is a month and a man.
    static func withoutWordsAtTheEnd(_ entries: [Entry]) -> [Entry] {
        func common(_ token: String) -> Bool { commonWords.contains(key(token)) }
        var dropped = Set<String>()
        for entry in entries where entry.kind == .person || entry.kind == .place {
            let tokens = words(entry.original)
            if entry.partOf != nil ? tokens.allSatisfy(common) : (tokens.allSatisfy(common) || (tokens.count > 1 && tokens.last.map(common) == true)) {
                dropped.insert(entry.original + "\u{0}" + (entry.partOf ?? ""))
            }
        }
        let whole = Set(entries.filter { $0.partOf == nil && dropped.contains($0.original + "\u{0}") }.map(\.original))
        return entries.filter { !dropped.contains($0.original + "\u{0}" + ($0.partOf ?? "")) && !($0.partOf.map(whole.contains) ?? false) }
    }

    /// A part of a name is learned unless it is on the word lists — `Liebe Frau` never teaches
    /// `Frau`, `info Hummelhaus` never teaches `info`. The folder-frequency test is not asked
    /// here: a surname the tagger rarely finds on its own is still a surname when it arrives
    /// attached to a first name, and leaving it out is exactly how a bare `Bittner` leaks.
    mutating func recordPart(_ kind: Entity.Kind, _ part: String, _ standIn: String, of original: String) {
        guard part.count >= 3, part != original else { return }
        // F021 P1: what the gate admitted keeps every part of a person but a title or a small word,
        // whatever the dictionary says of it; and none of a company's ordinary words.
        if admitted {
            let key = Self.key(part)
            let ordinaryPart = kind == .person
                ? Self.isTitle(key) || Self.smallWords.contains(key)
                : Self.words(part).count == 1 && (Ordinary.neverAlone(part) || Ordinary.knowsLower(part, words: SystemWords.shared) == true)
            if ordinaryPart {
                skippedParts.append(.init(text: part, reason: "part of \(original), but a common word"))
                return
            }
            record(kind, part, standIn, partOf: original)
            return
        }
        // F019 AC-5: a month or a day in a full name a rule or a header found — `Jan Spengler`, `Mai
        // Thi Pham` — is that person's name. It is disguised where it is no date (`Replacer`).
        let name = Self.nameParts(original)
        let calendarName = trusted && kind == .person && name.given != nil && name.family != nil
            && Self.calendarWords.contains(Self.key(part)) && !Self.commonWords.contains(Self.key(part))
        if Self.isListed(part), !calendarName {
            skippedParts.append(.init(text: part, reason: "part of \(original), but a common word"))
            return
        }
        record(kind, part, standIn, partOf: original)
    }

    /// A full name before a name in one part, so that `Patrick Ahlers` and `Patrick Schüßler` are
    /// both known as people before a bare `Patrick` or `Herr Ahlers` has to be placed.
    static func fullness(_ kind: Entity.Kind, _ text: String) -> Int {
        guard kind == .person else { return 0 }
        let name = nameParts(text)
        return name.given != nil && name.family != nil ? 2 : 1
    }

    static func priority(_ kind: Entity.Kind) -> Int {
        switch kind {
        case .person: 0
        case .organization: 1
        case .email: 2
        case .street, .postalCity: 3
        case .place: 4
        case .phone, .iban, .reference: 5
        }
    }

    @discardableResult
    public mutating func learn(_ kind: Entity.Kind, _ text: String, partOf: String? = nil) -> String? {
        let original = text.trimmed
        guard original.count >= 2 else { return nil }
        if let known = self.standIn(for: original) { return known }
        // F027 rule 1: a company, a place, a street or a postcode written another way — `Goettingen`,
        // `'Radwerk Berlin GmbH'` — is the name already known: its stand-in, and a way of its row.
        // A person is joined in `person`, after the via and the brackets are read.
        if mode == .placeholder, kind != .person, let known = spelling(kind, original) { return known }
        // F027 rule 6: a row's label in front of a name — `P7 Ostwind Reiseschutz AG` out of a table — is
        // no part of it. The name is learned as itself, and the whole, label and all, is a way of its row
        // with the row's stand-in, so the label is hidden inside it. When what follows is no name on its
        // own, the whole is learned as written, as before.
        if mode == .placeholder, [.person, .organization].contains(kind), let name = Self.withoutRowLabel(original),
           let standIn = learn(kind, name) {
            let row = joinedRow(of: name, standIn: standIn)
            record(kind, original, standIn, partOf: partOf, formOf: row)
            // What 1.0.1 hid of the labelled whole stays hidden: its name without the legal form, label and all.
            if kind == .organization, let tag = Self.tags(in: standIn).first, let bare = Self.companyName(original, admitted: admitted),
               bare.count >= 4 { recordPart(.organization, bare, tag, of: original) }
            return standIn
        }

        // `Schüßler, Patrick (Radwerk Berlin GmbH)` is a person and a company, and each half is
        // learned as what it is. F027 rule 4: the whole is a way of writing the person; the company
        // keeps a row of its own.
        if let open = original.firstIndex(of: "("), let close = original.lastIndex(of: ")"), open < close {
            let outer = (String(original[..<open]) + String(original[original.index(after: close)...])).trimmed
            let inner = String(original[original.index(after: open)..<close]).trimmed
            guard let outerStandIn = learn(kind, outer), let innerStandIn = learn(.organization, inner)
            else { return nil }
            let row = mode == .placeholder && kind == .person ? joinedRow(of: outer, standIn: outerStandIn) : nil
            return record(kind, original, "\(outerStandIn) (\(innerStandIn))", partOf: partOf, formOf: row)
        }
        if original.contains("@"), kind != .email { return learn(.email, original, partOf: partOf) }

        // `Jan Spengler via TestFlight` is a person and the service that sent on their behalf.
        if kind == .person, let via = original.range(of: " via ", options: .caseInsensitive) {
            let person = String(original[..<via.lowerBound]).trimmed
            let service = String(original[via.upperBound...]).trimmed
            guard let personStandIn = learn(.person, person) else { return nil }
            guard mode == .placeholder else {
                let serviceStandIn = learn(.organization, service) ?? service
                return record(kind, original, "\(personStandIn) via \(serviceStandIn)", partOf: partOf)
            }
            // F027 rule 3: the via name is a way of writing the person. The service is hidden, kept under the
            // person's row (no row of its own unless it also came in on its own), and the person's switch
            // never lets it out (`shed`).
            let row = joinedRow(of: person, standIn: personStandIn)
            let serviceStandIn = learn(.organization, service, partOf: row ?? original) ?? service
            return record(kind, original, "\(personStandIn) via \(serviceStandIn)", partOf: partOf, formOf: row)
        }

        switch kind {
        case .person: return person(original, partOf: partOf)
        // A single common word is no company, whatever the tagger read: "For" at the start of a title (9 November).
        case .organization:
            if !original.contains(" "), Self.commonWords.contains(Self.key(original)) { return nil }
            return organization(original, partOf: partOf)
        // A small word is no place: a scan read „10119 BERLIN“ as „10119 DER“ (17 November).
        case .place:
            if Self.isCommonPlace(original) { return nil }
            return record(.place, original, pickName(.place), partOf: partOf)
        case .email: return email(original, partOf: partOf)
        case .street: return street(original, partOf: partOf)
        case .postalCity: return postalCity(original, partOf: partOf)
        case .phone:
            return record(.phone, original, mode == .placeholder ? placeholder(.phone) : Self.phone(original), partOf: partOf)
        case .iban:
            return record(.iban, original, mode == .placeholder ? placeholder(.iban) : Self.iban(original), partOf: partOf)
        case .reference:
            return record(.reference, original, placeholder(.reference), partOf: partOf)
        }
    }

    // MARK: People

    mutating func person(_ original: String, partOf: String?) -> String? {
        let name = Self.nameParts(original)
        guard name.family != nil || name.given != nil else { return nil }

        let standIn: String
        if mode == .placeholder {
            // F027 rule 1: the same person written another way — `Patrick Schuessler`, `'Patrick
            // Schüßler'`, `Schuessler` — is the one already known: a way of its row, or a part of it.
            if let at = Self.foldKey(.person, original).flatMap({ foldWhole[$0] }) {
                let match = entries[at]
                let standIn = Self.titled(name.title, match.standIn)
                record(.person, original, standIn, partOf: partOf, formOf: match.original)
                if let given = name.given, let family = name.family, let tag = Self.personTag(match.standIn) {
                    for part in [given, family] { recordSharedPart(part, tag, of: original) }
                }
                return standIn
            }
            // One tag for the person however they are written; a `Frau` stays readable. A full
            // name is one person, and only the same first and last name are the same person:
            // `Patrick Schüßler` is not `Patrick Ahlers`, and `Lotta Spengler` is not `Jan Spengler`.
            // Sharing a tag through one shared word made the way back give the wrong name.
            let tag: String
            if let given = name.given, let family = name.family, Self.isInitial(given) {
                // F027 rule 8: an initial and a surname — `P. Schüßler` — is a row of its own with a stand-in
                // of its own, the initial hidden in it; the same initial and surname written another way is a
                // way of it. It is never a full name: the surname alone is the initial's only while no full
                // name has it, and it never takes it from one.
                let known = initialNames[Self.personKey(given, family)]
                tag = known ?? placeholder(.person)
                standIn = [name.title, tag].compactMap { $0 }.joined(separator: " ")
                record(.person, original, standIn, partOf: partOf, formOf: known.flatMap { rowOfTag[$0] })
                if index[Self.key(family)] == nil, Self.foldKey(.person, family).flatMap({ foldIndex[$0] }) == nil {
                    recordPart(.person, family, tag, of: original)
                }
            } else if let given = name.given, let family = name.family {
                // F027 rule 2: the same first name and surname (`fold`), however ordered, titled or quoted: a way
                // of that row. Rule 5: the first words of exactly one known full name (`Mirela Ottilie`) are
                // that person, and the words of it the row lacks are parts of the row.
                let same = fullNames[Self.personKey(given, family)]
                let known = same ?? knownFullName(startingWith: original)
                tag = known ?? placeholder(.person)
                standIn = [name.title, tag].compactMap { $0 }.joined(separator: " ")
                record(.person, original, standIn, partOf: partOf, formOf: known.flatMap { rowOfTag[$0] })
                let parts = same == nil && known != nil ? Self.wordsOf(original) : [given, family]
                for part in parts { recordSharedPart(part, tag, of: original) }
            } else {
                let part = name.given ?? name.family ?? original
                let known = self.standIn(for: part).flatMap(Self.personTag)
                    ?? Self.foldKey(.person, part).flatMap { foldIndex[$0] }.flatMap { Self.personTag(entries[$0].standIn) }
                tag = known ?? placeholder(.person)
                standIn = [name.title, tag].compactMap { $0 }.joined(separator: " ")
                // F027 rule 7: a word of the one full name that has it, with a title or none — `Herr
                // Schüßler` — is a way of that row. A word two full names share has a tag of its own,
                // and a name with it is a row of its own.
                let row = known.flatMap { fullNameTags.contains($0) ? rowOfTag[$0] : nil }
                record(.person, original, standIn, partOf: partOf, formOf: row)
                recordPart(.person, part, tag, of: original)
            }
            return standIn
        }

        let given = name.given.map { self.standIn(for: $0) ?? pickName(.givenName) }
        let family = name.family.map { self.standIn(for: $0) ?? pickName(.person) }
        switch (given, family) {
        case let (given?, family?):
            // F027: a surname in capitals written first stays first, in capitals.
            standIn = name.commaFirst ? "\(family), \(given)" : name.familyFirst ? "\(family.uppercased()) \(given)" : "\(given) \(family)"
        case let (given?, nil): standIn = given
        case let (nil, family?): standIn = family
        default: return nil
        }
        let titled = [name.title, standIn].compactMap { $0 }.joined(separator: " ")
        record(.person, original, titled, partOf: partOf)
        if let part = name.given, let new = given { recordPart(.person, part, new, of: original) }
        if let part = name.family, let new = family { recordPart(.person, part, new, of: original) }
        return titled
    }

    /// A part of a full name, in placeholder mode. The first person to have it lends it their
    /// tag, so a bare `Bittner` is known to be Herr Bittner. When a second person has the same
    /// word — two Patricks, a mother and a son both called Spengler — the word alone can no
    /// longer say which of them is meant, and it gets a tag of its own. It is still disguised;
    /// it just no longer comes back as the wrong person.
    mutating func recordSharedPart(_ part: String, _ tag: String, of original: String) {
        // F027: the word as written, or another spelling of it (`fold`): a spelling never counts as a second person.
        let exact = index[Self.key(part)]
        let at = exact ?? (mode == .placeholder ? Self.foldKey(.person, part).flatMap { foldIndex[$0] } : nil)
        guard let at else { return recordPart(.person, part, tag, of: original) }
        guard entries[at].kind == .person, let old = Self.personTag(entries[at].standIn) else { return }
        if old != tag, !fullNameTags.contains(old), !sharedTags.contains(old) {
            // F027 rule 8: a surname an initial held alone goes to the full name when it comes, and the
            // names made of it alone — `Herr Schüßler` — with it, as ways of that row. So does a word a name
            // of one word held alone (rule 7, whichever came first), as the upgrade reads it.
            let row = root(of: original)
            let folded = Self.fold(part)
            for i in entries.indices where entries[i].kind == .person && Self.personTag(entries[i].standIn) == old {
                let name = Self.nameParts(entries[i].original)
                let single = name.given == nil ? name.family : (name.family == nil ? name.given : nil)
                guard i == at || single.map(Self.fold) == folded else { continue }
                entries[i].standIn = entries[i].standIn.replacingOccurrences(of: old, with: tag)
                if entries[i].partOf != nil { entries[i].partOf = row } else if Self.key(entries[i].original) != Self.key(row) { entries[i].formOf = row }
            }
            if exact == nil { recordPart(.person, part, tag, of: original) }
            return
        }
        guard old != tag, fullNameTags.contains(old) else {
            // The same person, or a word no full name lent its tag: this spelling of it goes with it, hidden.
            if exact == nil { recordPart(.person, part, old, of: original) }
            return
        }
        let own = placeholder(.person)
        use(own)
        sharedTags.insert(own)
        let folded = Self.fold(part)
        for i in entries.indices where entries[i].kind == .person && Self.personTag(entries[i].standIn) == old {
            let name = Self.nameParts(entries[i].original)
            let single = name.given == nil ? name.family : (name.family == nil ? name.given : nil)
            guard i == at || single.map(Self.fold) == folded else { continue }
            entries[i].standIn = entries[i].standIn.replacingOccurrences(of: old, with: own)
            // F027 (AC-4): no row holds a way of writing another person: a way that held the word leaves its row.
            entries[i].formOf = nil
        }
        if exact == nil { recordPart(.person, part, own, of: original) }
    }

    /// `[Person F]` out of `Frau [Person F]`.
    static func personTag(_ standIn: String) -> String? {
        tags(in: standIn).first { $0.hasPrefix("[Person ") }
    }

    /// Every tag in a stand-in — `[Person F]`, `[Company AB]`: a bracket, letters, one space, capitals,
    /// a bracket. Read by hand, not by a pattern: asked for each of thousands of names whenever a
    /// question is disguised, the pattern alone took a third of a second.
    static func tags(in standIn: String) -> [String] {
        guard standIn.contains("[") else { return [] }
        var out: [String] = []
        let chars = Array(standIn.unicodeScalars)
        var i = 0
        while i < chars.count {
            guard chars[i] == "[" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, (65...90).contains(chars[j].value) || (97...122).contains(chars[j].value) { j += 1 }
            guard j > i + 1, j < chars.count, chars[j] == " " else { i += 1; continue }
            var k = j + 1
            while k < chars.count, (65...90).contains(chars[k].value) { k += 1 }
            guard k > j + 1, k < chars.count, chars[k] == "]" else { i += 1; continue }
            var tag = String.UnicodeScalarView()
            tag.append(contentsOf: chars[i...k])
            out.append(String(tag))
            i = k + 1
        }
        return out
    }

    /// F027: by `fold`, so `Patrick Schuessler` is the same first name and surname as `Patrick Schüßler`.
    static func personKey(_ given: String, _ family: String) -> String { fold(given) + "|" + fold(family) }

    struct NameParts {
        var title: String?
        var given: String?
        var family: String?
        var commaFirst = false
        /// F027: `SCHÜSSLER Patrick` — the surname in capitals, written first.
        var familyFirst = false
    }

    /// `Sibylle Seeger`, `Moreno, Valentina`, `Frau Seeger`, `Martin`. A single word is read as a
    /// first name, because that is how a bare name turns up in what comes in — `Hallo Martin` — and
    /// a surname on its own almost always has `Frau` or `Herr` in front of it.
    ///
    /// F027, for the list: the French titles are titles too (`isListTitle`), and one word in capitals
    /// among words that are not, written first, is the surname (`SCHÜSSLER Patrick`). `legacy` reads
    /// as 1.0.1 did, for the disguise's own rule P2, which must find exactly what it found.
    static func nameParts(_ text: String, legacy: Bool = false) -> NameParts {
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: "'\"‘’‚“”„ "))
        var parts = NameParts()
        if let comma = text.firstIndex(of: ",") {
            parts.family = String(text[..<comma]).trimmed.nilIfEmpty
            parts.given = words(String(text[text.index(after: comma)...])).first
            parts.commaFirst = true
            return parts
        }
        // `'Jan Spengler'`, as some mail clients write the display name, is Jan Spengler.
        var tokens = words(text).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"‘’‚“”„")) }.filter { !$0.isEmpty }
        // `Jan Spengler via TestFlight` is Jan Spengler.
        if let via = tokens.firstIndex(where: { $0.lowercased() == "via" }), via > 0 { tokens = Array(tokens[..<via]) }
        var titles: [String] = []
        while let first = tokens.first {
            if legacy ? Pseudonymizer.isTitle(first) : Pseudonymizer.isListTitle(first) { titles.append(first); tokens.removeFirst() }
            else if let glued = gluedTitle(first) { titles.append(glued.title); tokens[0] = glued.rest }
            else { break }
        }
        parts.title = titles.isEmpty ? nil : titles.joined(separator: " ")
        if !legacy, tokens.count >= 2, isShouted(tokens[0]), tokens.dropFirst().allSatisfy({ !isShouted($0) }) {
            parts.family = tokens[0]
            parts.given = tokens[1]
            parts.familyFirst = true
            return parts
        }
        switch tokens.count {
        case 0: break
        case 1: if parts.title == nil { parts.given = tokens[0] } else { parts.family = tokens[0] }
        default: parts.given = tokens.first; parts.family = tokens.last
        }
        return parts
    }

    /// F027: a word written all in capitals, two letters at least: `SCHÜSSLER`, `MÜLLER-LÜDENSCHEID`.
    static func isShouted(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
            && letters == letters.uppercased() && letters != letters.lowercased()
    }

    /// F027: a person's tag with this name's own title in front, where the known stand-in is that tag
    /// with or without a title (`Herr [Person A]`); any other stand-in (`[Person A] via [Company B]`) as it is.
    static func titled(_ title: String?, _ standIn: String) -> String {
        guard let tag = personTag(standIn), tags(in: standIn) == [tag], standIn.hasSuffix(tag) else { return standIn }
        return [title, tag].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Companies

    /// The legal form and the words that only say what kind of business it is are kept —
    /// `Hausverwaltung … GmbH` tells the model what a party *is*, and identifies nobody. The
    /// rest is the name, and the name is replaced.
    /// A company's name without its legal form and the words that say what kind of business it is:
    /// `Thermotec Kubiak` of `Thermotec Kubiak GmbH`. Nil when nothing is left.
    static func companyName(_ original: String, admitted: Bool) -> String? {
        let tokens = original.split(separator: " ").map(String.init)
        let isGeneric = tokens.map { companyWords.contains(key($0)) || admitted && Ordinary.isKindWord($0) }
        guard isGeneric.contains(false) else { return nil }
        return zip(tokens, isGeneric).filter { !$0.1 }.map(\.0).joined(separator: " ")
    }

    mutating func organization(_ original: String, partOf: String?) -> String? {
        let tokens = original.split(separator: " ").map(String.init)
        // F021 N6: under the new rules, the words that say what a business is are generic too.
        let isGeneric = tokens.map { Self.companyWords.contains(Self.key($0)) || admitted && Ordinary.isKindWord($0) }
        guard isGeneric.contains(false) else { return nil }  // `Hausverwaltung` alone names nobody

        if mode == .placeholder {
            // The name without its legal form is learned too — `Thermotec Kubiak` turns up in the
            // prose without the `GmbH`, and it names the company just as well.
            let tag = placeholder(.organization)
            record(.organization, original, tag, partOf: partOf)
            let name = zip(tokens, isGeneric).filter { !$0.1 }.map(\.0).joined(separator: " ")
            if name.count >= 4 { recordPart(.organization, name, tag, of: original) }
            return tag
        }

        var out: [String] = []
        var run: [String] = []
        var runs: [(String, String)] = []
        func endRun() {
            guard !run.isEmpty else { return }
            let text = run.joined(separator: " ")
            let new = self.standIn(for: text) ?? (run.count == 1 ? self.standIn(for: run[0]) : nil) ?? pickName(.organization)
            out.append(new)
            runs.append((text, new))
            run = []
        }
        for (token, generic) in zip(tokens, isGeneric) {
            if generic { endRun(); out.append(token) } else { run.append(token) }
        }
        endRun()
        let standIn = record(.organization, original, out.joined(separator: " "), partOf: partOf)
        for (text, new) in runs where text.count >= 4 { recordPart(.organization, text, new, of: original) }
        return standIn
    }

    // MARK: Addresses

    mutating func email(_ original: String, partOf: String?) -> String? {
        let parts = original.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return record(.email, original, placeholder(.email), partOf: partOf) }
        let domain = parts[1]
        let isFreeMail = Self.freeMail.contains(Self.key(domain))

        if mode == .placeholder {
            // The domain is learned too: `www.seeger-hv.example` in a signature names the company
            // as surely as the address does.
            if !isFreeMail, self.standIn(for: domain) == nil { record(.email, domain, placeholder("Domain"), partOf: original) }
            return record(.email, original, placeholder(.email), partOf: partOf)
        }

        let newDomain: String
        if isFreeMail {
            newDomain = domain
        } else {
            newDomain = self.standIn(for: domain) ?? (Self.ascii(pickName(.organization)).lowercased() + ".example")
            record(.email, domain, newDomain, partOf: original)
        }
        // Two names from the pools, never one that is a real name somewhere in this folder.
        var count = entries.filter { $0.kind == .email && $0.partOf == nil }.count
        func usable(_ name: String) -> Bool { !forbidden.contains(Self.key(name)) }
        var given = Pool.givenNames[count % Pool.givenNames.count]
        var family = Pool.surnames[(count * 7 + 3) % Pool.surnames.count]
        while !usable(given) || !usable(family) {
            count += 1
            given = Pool.givenNames[count % Pool.givenNames.count]
            family = Pool.surnames[(count * 7 + 3) % Pool.surnames.count]
        }
        let local = Self.ascii(given).lowercased() + "." + Self.ascii(family).lowercased()
        return record(.email, original, "\(local)@\(newDomain)", partOf: partOf)
    }

    /// `Honigtauer Str. 14`, `Honigwabenallee 47`, `14 Hivemead Road`. The street's own name is
    /// learned separately, because it turns up without the number — `WEG Honigtauer` — and
    /// in a matter about a building, that word is the matter.
    mutating func street(_ original: String, partOf: String?) -> String? {
        guard let street = Self.streetParts(original) else {
            return record(.street, original, mode == .placeholder ? placeholder(.street) : pickName(.street) + " 1", partOf: partOf)
        }
        // Two words (`Honigtauer Str.`) teach the first one on its own, because that is how the
        // street gets written in a hurry. One word (`Honigwabenallee`) teaches only the whole
        // word: its front half on its own is `Honigwaben`, which is honeycombs.
        let named = street.stem + street.separator + street.suffix
        let learnsStem = !street.separator.isEmpty && street.stem.count >= 4
        let stemTag = (learnsStem ? self.standIn(for: street.stem) : nil)
            ?? (mode == .placeholder ? self.standIn(for: named) : nil)
            ?? (mode == .placeholder ? placeholder(.street) : pickName(.street))
        if learnsStem { recordPart(.street, street.stem, stemTag, of: original) }

        var suffix = street.suffix
        if street.separator.isEmpty, let first = suffix.first { suffix = first.uppercased() + suffix.dropFirst() }
        let name = mode == .placeholder ? stemTag : "\(stemTag) \(suffix)"
        if named != original { record(.street, named, self.standIn(for: named) ?? name, partOf: original) }
        if mode == .placeholder {
            return record(.street, original, stemTag, partOf: partOf)
        }
        let number = street.number.map { Self.houseNumber(for: original, not: $0) }
        let standIn = street.numberFirst ? "\(number ?? "1") \(name)" : [name, number].compactMap { $0 }.joined(separator: " ")
        return record(.street, original, standIn, partOf: partOf)
    }

    struct StreetParts {
        var stem: String
        var separator: String
        var suffix: String
        var number: String?
        var numberFirst = false
    }

    static func streetParts(_ text: String) -> StreetParts? {
        var name = text.trimmed
        var number: String?
        var numberFirst = false
        if let match = name.firstMatch(of: /^(\d{1,4}\s?[a-zA-Z]?)\s+(.+)$/) {
            number = String(match.1); name = String(match.2); numberFirst = true
        } else if let match = name.firstMatch(of: /^(.+?)\s+(\d{1,4}(?:\s?[a-zA-Z])?)$/) {
            name = String(match.1); number = String(match.2)
        }
        let suffixes = /(?i)^(.*?)(\s*)(straße|strasse|str\.|allee|weg|platz|gasse|damm|ufer|ring|chaussee|steig|road|rd\.|street|st\.|avenue|ave\.|lane|drive|close|square|court|gardens)$/
        guard let match = name.firstMatch(of: suffixes), !match.1.isEmpty else { return nil }
        return StreetParts(stem: String(match.1), separator: String(match.2), suffix: String(match.3),
                           number: number, numberFirst: numberFirst)
    }

    /// The town is learned as a place, so a bare `Berlin` in the prose gets the same stand-in as
    /// the one in the address block.
    mutating func postalCity(_ original: String, partOf: String?) -> String? {
        // F019 AC-7: an Austrian or Swiss code has four digits, and may carry its country: `A-1010 Wien`.
        guard let match = original.firstMatch(of: /^(?:(?:A|CH|D)-)?(\d{4,5})\s+(.+)$/) else {
            return record(.postalCity, original, placeholder(.postalCity), partOf: partOf)
        }
        let code = String(match.1)
        // A town that is a small word is no town — „10119 DER“ out of a scan: the code is learned, the word is not.
        let town = String(match.2)
        let city: String
        if Self.isCommonPlace(town) { city = town } else {
            guard let learned = learn(.place, town, partOf: original) else { return nil }
            city = learned
        }
        let newCode = self.standIn(for: code) ?? (mode == .placeholder ? placeholder(.postalCity) : Self.digits(code.count, from: code))
        record(.postalCity, code, newCode, partOf: original)
        return record(.postalCity, original, "\(newCode) \(city)", partOf: partOf)
    }

    // MARK: Numbers

    /// The shape kept — spaces, a `+49`, a leading `0` and the digit after it — and the rest
    /// replaced, so a mobile number still reads as one.
    static func phone(_ original: String) -> String {
        // `+49`, or `0` and the next digit. Never more: `+493001234567` has no spaces, and taking
        // every leading digit as the country code kept the whole number.
        var kept = original.hasPrefix("+") ? 3 : 2
        var out = ""
        var fresh = Array(digits(original.filter(\.isNumber).count, from: original))
        for character in original {
            if kept > 0 { out.append(character); kept -= 1; continue }
            if character.isNumber, !fresh.isEmpty { out.append(fresh.removeFirst()) } else { out.append(character) }
        }
        guard out == original, let last = out.lastIndex(where: \.isNumber), let digit = out[last].wholeNumberValue
        else { return out }
        out.replaceSubrange(last...last, with: String((digit + 1) % 10))
        return out
    }

    static func iban(_ original: String) -> String {
        var fresh = Array(digits(original.count, from: original))
        var out = String(original.prefix(2))
        for character in original.dropFirst(2) {
            out.append(character == " " ? " " : fresh.removeFirst())
        }
        return out
    }

    static func houseNumber(for seed: String, not original: String) -> String {
        var number = 1 + (Int(digits(3, from: seed)) ?? 0) % 120
        if String(number) == original { number += 1 }
        return String(number)
    }

    /// Digits that are the same every run for the same original, so two runs of one folder give
    /// two logs that can be diffed.
    static func digits(_ count: Int, from seed: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 { hash ^= UInt64(byte); hash &*= 0x0100_0000_01b3 }
        var out = ""
        for _ in 0..<count {
            hash = hash &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out.append(Character(String((hash >> 33) % 10)))
        }
        return out
    }

    // MARK: Picking stand-ins

    enum Pick { case person, givenName, organization, place, street }

    /// The first name in the pool that is neither in use nor anywhere among the originals. When a
    /// pool runs out, a number goes on the end: unrealistic, and still never a real name.
    mutating func pickName(_ kind: Pick) -> String {
        if mode == .placeholder {
            switch kind {
            case .person, .givenName: return placeholder(.person)
            case .organization: return placeholder(.organization)
            case .place: return placeholder(.place)
            case .street: return placeholder(.street)
            }
        }
        let pool: [String] = switch kind {
        case .person: Pool.surnames
        case .givenName: Pool.givenNames
        case .organization: Pool.companies
        case .place: Pool.places
        case .street: Pool.streets
        }
        // A domain made from a stem (`aurelis.example`) uses up that stem too.
        let used = Set(entries.flatMap { entry -> [String] in
            let key = Self.key(entry.standIn)
            return key.hasSuffix(".example") ? [key, String(key.dropLast(".example".count))] : [key]
        })
        var round = 0
        while true {
            for name in pool {
                let candidate = round == 0 ? name : "\(name)\(round + 1)"
                if !used.contains(Self.key(candidate)), !forbidden.contains(Self.key(candidate)) { return candidate }
            }
            round += 1
        }
    }

    public func placeholder(_ kind: Entity.Kind) -> String {
        placeholder(Self.label(kind))
    }

    /// What a tag of this kind is called: `Person`, `Company`, `Nummer`.
    static func label(_ kind: Entity.Kind) -> String {
        switch kind {
        case .person: "Person"
        case .organization: "Company"
        case .place: "Place"
        case .email: "Email"
        case .phone: "Phone"
        case .iban: "IBAN"
        case .reference: "Nummer"
        case .street: "Street"
        case .postalCity: "Postcode"
        }
    }

    /// `[Person A]` … `[Person Z]`, `[Person AA]`. Counted from the tags already handed out, so a
    /// mapping loaded from an earlier run carries on where it stopped.
    func placeholder(_ label: String) -> String {
        let prefix = "[\(label) "
        // Wherever a tag stands in a stand-in — `Frau [Person A]` holds one too. Counting only those
        // that begin with it handed `[Person A]` to Frau Kurz, Herr Li and Frau Post alike.
        let used = usedTags[prefix] ?? []
        var number = used.count
        while true {
            var letters = ""
            var n = number
            repeat { letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters; n = n / 26 - 1 } while n >= 0
            let tag = "\(prefix)\(letters)]"
            if !used.contains(tag) { return tag }
            number += 1
        }
    }

    @discardableResult
    public mutating func record(_ kind: Entity.Kind, _ original: String, _ standIn: String, partOf: String?, formOf: String? = nil) -> String {
        if let known = self.standIn(for: original) { return known }
        // F027: a part and a way of writing point at the row, never at another part or way, so a
        // switch on the row reaches each of them in one step (`shed`).
        let key = Self.key(original)
        func row(_ name: String?) -> String? { name.map { root(of: $0) }.flatMap { Self.key($0) == key ? nil : $0 } }
        let part = row(partOf)
        add(Entry(kind: kind, original: original, standIn: standIn, partOf: part, formOf: part == nil ? row(formOf) : nil))
        return standIn
    }

    /// F027: the row an entry belongs to: itself, or the row its `formOf` or `partOf` names. A name not
    /// in the list is its own row.
    public func root(of original: String) -> String {
        var current = original
        var seen: Set<String> = [Self.key(original)]
        while let at = index[Self.key(current)], let up = entries[at].formOf ?? entries[at].partOf,
              index[Self.key(up)] != nil, seen.insert(Self.key(up)).inserted {
            current = up
        }
        return current
    }

    /// F027 rule 1: the same kind and the same `fold` as a known name: its stand-in; a way of its row,
    /// or, when the known name is a part, a part of the same row. Never an email, a phone, a bank
    /// account or a reference: they are matched as written (`foldKey`).
    mutating func spelling(_ kind: Entity.Kind, _ original: String) -> String? {
        guard let at = Self.foldKey(kind, original).flatMap({ foldWhole[$0] ?? foldIndex[$0] }) else { return nil }
        let match = entries[at]
        if let row = match.partOf { return record(kind, original, match.standIn, partOf: row) }
        return record(kind, original, match.standIn, partOf: nil, formOf: match.original)
    }

    /// F027: the kinds whose ways of writing are joined by their `fold`; a number or an address is matched as written.
    static func foldKey(_ kind: Entity.Kind, _ text: String) -> String? {
        guard [.person, .organization, .place, .street, .postalCity].contains(kind) else { return nil }
        let folded = fold(text)
        return folded.isEmpty ? nil : kind.rawValue + "|" + folded
    }

    /// `[Person AB]` is taken.
    private mutating func use(_ tag: String) {
        guard let space = tag.firstIndex(of: " ") else { return }
        usedTags[String(tag[...space]), default: []].insert(tag)
    }

    private mutating func add(_ entry: Entry) {
        let key = Self.key(entry.original)
        guard index[key] == nil else { return }
        index[key] = entries.count
        if mode == .placeholder, let fold = Self.foldKey(entry.kind, entry.original) {
            if foldIndex[fold] == nil { foldIndex[fold] = entries.count }
            if entry.partOf == nil, foldWhole[fold] == nil { foldWhole[fold] = entries.count }
        }
        if mode == .placeholder, entry.kind == .person, let whole = entry.partOf, let at = index[Self.key(whole)],
           let tag = Self.personTag(entry.standIn), Self.personTag(entries[at].standIn) != tag {
            sharedTags.insert(tag)
        }
        entries.append(entry)
        forbidden.insert(key)
        for tag in Self.tags(in: entry.standIn) { use(tag) }
        if mode == .placeholder, entry.kind == .person, entry.partOf == nil,
           case let name = Self.nameParts(entry.original), let given = name.given, let family = name.family,
           let tag = Self.personTag(entry.standIn) {
            let person = Self.personKey(given, family)
            if Self.isInitial(given) {
                initialNames[person] = initialNames[person] ?? tag
            } else {
                fullNames[person] = fullNames[person] ?? tag
                fullNameTags.insert(fullNames[person]!)
                fullNameTags.insert(tag)
                if let words = Self.nameWords(entry.original), words.count >= 2 {
                    fullNameWords[words[0] + " " + words[1], default: []].append((tag, words))
                }
            }
            if entry.formOf == nil, rowOfTag[tag] == nil { rowOfTag[tag] = entry.original }
        }
    }

    /// F027 rule 5: the tag of the one full name whose first words these are (two at least, titles
    /// aside): `Mirela Ottilie` of `Mirela Ottilie Brankovan`. Nil when none, or more than one, has them.
    func knownFullName(startingWith text: String) -> String? {
        guard let words = Self.nameWords(text), words.count >= 2 else { return nil }
        let tags = Set((fullNameWords[words[0] + " " + words[1]] ?? [])
            .filter { $0.words.count > words.count && Array($0.words.prefix(words.count)) == words }.map(\.tag))
        return tags.count == 1 ? tags.first : nil
    }

    /// F027: a person's name as its words in reading order, folded, titles off — nil for a name
    /// written another way (comma order, surname first in capitals, via, brackets, a label).
    static func nameWords(_ text: String) -> [String]? {
        let name = nameParts(text)
        guard !name.commaFirst, !name.familyFirst, !text.contains("("), text.range(of: " via ", options: .caseInsensitive) == nil,
              withoutRowLabel(text) == nil else { return nil }
        let words = words(fold(text)).filter { !isListTitle($0) }
        return words.isEmpty ? nil : words
    }

    /// F027 rule 5: a name's own words as written, quote marks and titles off: `Mirela`, `Ottilie`.
    static func wordsOf(_ text: String) -> [String] {
        words(text).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"‘’‚“”„")) }.filter { !$0.isEmpty && !isListTitle($0) }
    }

    /// F027 rule 8: `P.`, `P`, `H.-J.`: an initial, not a first name.
    static func isInitial(_ word: String) -> Bool {
        // `\p{Lu}\.?(-\p{Lu}\.?)?`, read by hand: asked for every name of a list of thousands.
        var rest = Substring(word)
        func capital() -> Bool {
            guard let first = rest.first, first.isLetter, first.isUppercase else { return false }
            rest = rest.dropFirst()
            if rest.first == "." { rest = rest.dropFirst() }
            return true
        }
        guard capital() else { return false }
        if rest.first == "-" { rest = rest.dropFirst(); guard capital() else { return false } }
        return rest.isEmpty
    }

    /// F027 rule 6: the name after a row's label — `Ostwind Reiseschutz AG` of `P7 Ostwind Reiseschutz
    /// AG`, `Patrick Schüßler` of `#3 Patrick Schüßler`: a capital and one to three digits, or `#` and
    /// digits, then perhaps `.`, `)` or `:`, before a capital. Nil when there is none.
    static func withoutRowLabel(_ text: String) -> String? {
        // `(\p{Lu}\d{1,3}|#\d{1,4})[.):]?\s+(?=\p{Lu})`, read by hand: asked for every name of a list of thousands.
        var rest = Substring(text)
        guard let first = rest.first, first == "#" || first.isLetter && first.isUppercase else { return nil }
        rest = rest.dropFirst()
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...(first == "#" ? 4 : 3)).contains(digits.count) else { return nil }
        rest = rest.dropFirst(digits.count)
        if let mark = rest.first, ".):".contains(mark) { rest = rest.dropFirst() }
        let space = rest.prefix { $0.isWhitespace }
        guard !space.isEmpty else { return nil }
        rest = rest.dropFirst(space.count)
        guard let next = rest.first, next.isLetter, next.isUppercase else { return nil }
        let name = String(rest).trimmed
        return name.count >= 2 ? name : nil
    }

    /// F027: the row a whole joins through the name inside it — the person of a via name, the person
    /// outside brackets, the name after a label: that name's row, when the stand-in carries that row's
    /// own tag. Nil otherwise: a word two people share, say, joins neither.
    func joinedRow(of name: String, standIn: String) -> String? {
        let row = root(of: name)
        guard let at = index[Self.key(row)], let tag = Self.tags(in: standIn).first,
              Self.tags(in: entries[at].standIn).first == tag else { return nil }
        return row
    }

    /// F027: of the ways one person is written in one batch, the plainest first — `Patrick Schüßler`
    /// before `Dr. Patrick Schüßler`, `Schüßler, Patrick` and `SCHÜSSLER Patrick` — so it is the row the
    /// others go under. Each person keeps the places their ways had, so no other tag's letter moves.
    static func plainestFirst(_ entities: [Entity]) -> [Entity] {
        func person(_ entity: Entity) -> String? {
            guard entity.kind == .person else { return nil }
            let text = entity.text.trimmed
            let name = nameParts(withoutRowLabel(text) ?? text)
            guard let given = name.given, let family = name.family else { return nil }
            return personKey(given, family)
        }
        var groups: [String: [Int]] = [:]
        for (i, entity) in entities.enumerated() { if let key = person(entity) { groups[key, default: []].append(i) } }
        var out = entities
        for positions in groups.values where positions.count > 1 {
            // Plainest first; among the plain, the longest (`Mirela Ottilie Brankovan`); then as they came.
            let members = positions.map { entities[$0] }.enumerated().sorted { a, b in
                let (x, y) = (decoration(a.element.text), decoration(b.element.text))
                if x != y { return x < y }
                let (m, n) = (words(a.element.text).count, words(b.element.text).count)
                return m != n ? m > n : a.offset < b.offset
            }.map(\.element)
            for (position, member) in zip(positions, members) { out[position] = member }
        }
        return out
    }

    /// F027: how far a way of writing is from the plainest — each of a title, comma order, a surname in
    /// capitals, all in capitals, quote marks, a "via", brackets, a word written twice counts one.
    static func decoration(_ text: String) -> Int {
        let text = text.trimmed
        let name = nameParts(text)
        let folded = words(fold(text))
        let letters = text.filter(\.isLetter)
        return (name.title != nil ? 1 : 0) + (name.commaFirst ? 1 : 0) + (name.familyFirst ? 1 : 0)
            + (letters == letters.uppercased() && letters != letters.lowercased() ? 1 : 0)
            + (text.first.map { "'\"‘’‚“”„".contains($0) } == true ? 1 : 0)
            + (text.range(of: " via ", options: .caseInsensitive) != nil ? 1 : 0) + (text.contains("(") ? 1 : 0)
            + (Set(folded).count < folded.count ? 1 : 0) + (withoutRowLabel(text) != nil ? 1 : 0)
    }

    /// Every person in `entries` learned again, as if for the first time: full names before names
    /// in one part, then in the order they were first learned. Everything else is kept as it was.
    static func relearningPeople(_ entries: [Entry]) -> [Entry] {
        var fresh = Pseudonymizer(mode: .placeholder, entries: entries.filter { $0.kind != .person })
        let people = entries.enumerated().filter { $0.element.kind == .person && $0.element.partOf == nil }
        let ordered = people.sorted { a, b in
            let (x, y) = (fullness(.person, a.element.original), fullness(.person, b.element.original))
            if x != y { return x > y }
            return a.offset < b.offset
        }
        for (_, entry) in ordered { fresh.learn(.person, entry.original) }
        return fresh.entries
    }

    /// A role learned as a name is taken out, and a name with a role in front keeps the role in
    /// the clear: `Hausmeister` alone is no longer a person, and `Hausmeister Bittner` goes out as
    /// `Hausmeister [Person AS]`. Tags keep their letters.
    static func rolesAsTitles(_ entries: [Entry]) -> [Entry] {
        entries.compactMap { entry in
            guard entry.kind == .person else { return entry }
            let words = Self.words(entry.original)
            let leading = words.prefix { roles.contains(key($0)) }
            if leading.count == words.count { return nil }
            guard !leading.isEmpty, let tag = personTag(entry.standIn), !entry.standIn.lowercased().contains(leading[0].lowercased()) else {
                return entry
            }
            var fixed = entry
            fixed.standIn = entry.standIn.replacingOccurrences(of: tag, with: leading.joined(separator: " ") + " " + tag)
            return fixed
        }
    }

    // MARK: Disguising and restoring

    /// Everything the mapping knows, replaced in one pass, longest first, whole words only — and
    /// in every way it is spelled. German is typed without its umlauts as often as with them:
    /// the mapping knew `Schüßler` and `Hüttenberger`, and `Herrn Schüssler` and `Herr Huettenberger` went out in
    /// the clear.
    public var disguiser: Replacer {
        // Made once for a list, not again for every send and its check: the last one is kept.
        var hasher = Hasher()
        for entry in entries { hasher.combine(entry.original); hasher.combine(entry.standIn); hasher.combine(entry.kind.rawValue); hasher.combine(entry.partOf); hasher.combine(entry.formOf) }
        hasher.combine(off.sorted())
        hasher.combine(PublicNames.current.sorted())
        hasher.combine(Detection.active.rawValue)
        let print = hasher.finalize()
        Self.disguiserLock.lock()
        if let last = Self.lastDisguiser, last.print == print { Self.disguiserLock.unlock(); return last.replacer }
        Self.disguiserLock.unlock()
        let replacer = makeDisguiser()
        Self.disguiserLock.lock(); Self.lastDisguiser = (print, replacer); Self.disguiserLock.unlock()
        return replacer
    }

    nonisolated(unsafe) private static var lastDisguiser: (print: Int, replacer: Replacer)?
    private static let disguiserLock = NSLock()

    private func makeDisguiser() -> Replacer {
        // What the owner marked as public is left as it is: a big company, a brand — and every
        // entry learned from it, "Expedia" out of "Expedia Inc.".
        // F019, found at Proof: a date is never a number to hide. `20261113` read as a code out of a
        // file's name held every question about a matter with a date on 13 November. Such an entry is
        // disguised where it stands, as one run of eight digits, like any word wrongly in the list —
        // `Ruf 12031990 an` may be a phone — and never out of a written date (`NumberRuns` leaves it out).
        // F022 AC-4: what the owner switched off goes out as written.
        let entries = hidden.filter { !PublicNames.covers($0.original) && !($0.partOf.map(PublicNames.covers) ?? false) }
            // A place that is a small word, learned before the rule above: „DER“ out of „10119 DER“ took
            // every „der“ (17 November). It stays in the list and is never disguised.
            .filter { !($0.kind == .place && Self.isCommonPlace($0.original)) }
        let exact = entries.map { ($0.original, $0.standIn) }
        let variants = entries.filter { [.person, .organization, .street, .place, .postalCity].contains($0.kind) }
            .flatMap { entry in Self.spellings(of: entry.original).map { ($0, entry.standIn) } }
        var replacer = Replacer(exact + variants)
        // A name learned in capitals — "BERLIN SONNE" from a shouted line — is a name where
        // the text has a capital, not the word "alles" in the owner's own sentence.
        let shouted = entries.filter { [.person, .organization].contains($0.kind) }.map(\.original)
            .filter { name in name.contains { $0.isLetter } && name == name.uppercased() && name.filter(\.isLetter).count >= 3 }
            .map(Self.key)
        replacer.capitalOnly = Self.lowercaseWords.union(shouted)
        // A number is written with its spaces and dots or without: DE123 456 789, DE123456789.
        replacer.numbers = NumberRuns(entries)
        replacer.skipsStandIns = true
        // F021 P2, behind the switch: a part of a person that is an ordinary word (`Sonntag` of
        // `Sonja Sonntag`) is hidden where its first name or a title stands beside it, and not alone.
        if Detection.active == .new {
            for entry in entries where entry.kind == .person {
                // The surname only: a first name alone is still that person (`Hallo Lotta,`).
                guard let whole = entry.partOf, Self.words(entry.original).count == 1, SecondOpinion.isOrdinarySurname(entry.original),
                      let family = Self.nameParts(whole, legacy: true).family, Self.key(family) == Self.key(entry.original) else { continue }
                let given = Self.nameParts(whole, legacy: true).given.map(Self.key)
                replacer.needsName[Self.key(entry.original), default: []].formUnion([given].compactMap { $0 })
            }
        }
        return replacer
    }

    /// Surnames that are also ordinary German words other than nouns — "weil", "kurz", "neu". A
    /// noun is written with a capital anyway; these are not, so `Frau Kurz` is a name and "kurz
    /// er fragt" is not. Only the capitalised one is disguised; at the start of a sentence that
    /// hides one "Weil" too many, which is the safe side.
    static let lowercaseWords: Set<String> = [
        "weil", "kurz", "lang", "klein", "groß", "gross", "schwarz", "weiß", "weiss", "braun", "grün", "gruen",
        "roth", "neu", "alt", "jung", "fromm", "frei", "froh", "stark", "stolz", "ernst", "lieb", "gut", "bald",
        "recht", "wild", "hell", "klug", "reich", "schön", "schoen", "still", "fest", "voll", "bloß", "noch",
    ]

    /// The other ways a name is typed: `ß` as `ss`, `ü` as `ue`, and `ue` as `ü`. Never `ss` as
    /// `ß` — a Herr Gross must not disguise every "groß".
    static func spellings(of original: String) -> [String] {
        var out: Set<String> = []
        let spelledOut = original.replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe").replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "Ä", with: "Ae").replacingOccurrences(of: "Ö", with: "Oe").replacingOccurrences(of: "Ü", with: "Ue")
        out.insert(spelledOut)
        // F019: the other accents typed without — `Çetin` as `Cetin`, `José` as `Jose`. Never `ä` as `a`:
        // `Fälle` is not `Falle`, `schön` not `schon`.
        if let plain = spelledOut.applyingTransform(.stripDiacritics, reverse: false) { out.insert(plain) }
        out.insert(original.replacingOccurrences(of: "ß", with: "ss"))
        let withUmlauts = original.replacingOccurrences(of: "ae", with: "ä").replacingOccurrences(of: "oe", with: "ö")
            .replacingOccurrences(of: "ue", with: "ü").replacingOccurrences(of: "Ae", with: "Ä")
            .replacingOccurrences(of: "Oe", with: "Ö").replacingOccurrences(of: "Ue", with: "Ü")
        out.insert(withUmlauts)
        // `'Kurz, Hella'` was learned with its quote marks, and a bare Kurz never matched it.
        let quotes = CharacterSet(charactersIn: "'\"‘’‚“”„")
        for form in Array(out) + [original] { out.insert(form.trimmingCharacters(in: quotes)) }
        out.remove(original)
        return out.filter { $0.count >= 3 }.sorted()
    }

    /// The way back, for step 6. Where several originals share a tag — `[Person A]` for
    /// `Sibylle Seeger`, `Seeger`, `Frau Seeger` and `Sibylle Seeger via Doodle` — the way back
    /// cannot know which was written, and brings the plainest full name: two words or as few as
    /// possible above one, no title in front, and the one learned first when that still ties.
    /// Longest-wins brought back `Jan Spengler via TestFlight` as a neighbour.
    public var restorer: Replacer {
        // A name without a title before one with, and a name in full before a part of one — but a
        // word with a tag of its own, `Maria`, comes back as that word, not as `Dr. Maria`.
        // One that ran on into a signature's "Tel" comes back last of all.
        func plainness(_ entry: Entry) -> (Int, Int, Int, Int, Int) {
            let words = Self.words(entry.original)
            let titles = words.prefix { Pseudonymizer.isTitle($0) }.count
            return (Self.endsOnContactWord(entry.original) ? 1 : 0,
                    words.count - titles < 2 ? 1 : 0, titles > 0 ? 1 : 0, entry.partOf != nil ? 1 : 0, words.count)
        }
        // Worked out once for each name, not again in every comparison.
        let plain = entries.map(plainness)
        var best: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let key = Self.key(entry.standIn)
            if let current = best[key], plain[current] <= plain[index] { continue }
            best[key] = index
        }
        // "Lechner, Martina", as an insurer's mail writes it, comes back as "Martina Lechner": beside
        // her surname's own tag it is then one name, written once.
        func natural(_ entry: Entry) -> String {
            guard entry.kind == .person, entry.original.contains(",") else { return entry.original }
            // `Family, Given` or `Family, Given Middle`: letters and hyphens only, read by hand.
            func isName(_ word: Substring) -> Bool { !word.isEmpty && word.allSatisfy { $0.isLetter || $0 == "-" } }
            let halves = entry.original.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2, isName(halves[0]), halves[1].first?.isWhitespace == true else { return entry.original }
            let given = halves[1].drop { $0.isWhitespace }
            let words = given.split(separator: " ", omittingEmptySubsequences: false)
            guard (1...2).contains(words.count), words.allSatisfy(isName) else { return entry.original }
            return "\(given) \(halves[0])"
        }
        var replacer = Replacer(best.values.sorted().map { (entries[$0].standIn, natural(entries[$0])) })
        replacer.joinsNames = true
        return replacer
    }

    public func disguise(_ email: Email, with replacer: Replacer? = nil) -> Disguise {
        let replacer = replacer ?? disguiser
        var count = 0
        func apply(_ text: String) -> String {
            let (out, made) = replacer.apply(text)
            count += made
            return out
        }
        return Disguise(mode: mode,
                        subject: apply(email.subject),
                        from: apply(email.from),
                        to: email.to.map(apply),
                        cc: email.cc.map(apply),
                        body: apply(email.body),
                        attachmentNames: email.attachments.map { apply($0.filename) },
                        replacements: count)
    }

    public func restore(_ text: String) -> String { restorer.apply(text).text }

    // MARK: Words

    public static func key(_ text: String) -> String {
        text.trimmed.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// F027: how two ways of writing a name are compared while learning, to find the row it belongs
    /// to: as `key`, each word's quote marks off, `ß` as `ss`, `ä`, `ö`, `ü` as `ae`, `oe`, `ue`, other
    /// accents off, single spaces. `Schüßler`, `Schuessler`, `SCHÜSSLER` and `'Schüßler'` are one.
    /// Only to join: never stored (the list keeps each way as written, and a switch's hash is by `key`),
    /// and never used to find a word in a text, so `Fälle` is not `Falle`.
    public static func fold(_ text: String) -> String {
        let quotes = CharacterSet(charactersIn: "'\"‘’‚“”„`´")
        let spelled = key(text).replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe").replacingOccurrences(of: "ü", with: "ue")
        // The other accents off — asked only where there is one left: the transform is slow, and names are many.
        let plain = spelled.unicodeScalars.allSatisfy(\.isASCII) ? spelled : spelled.applyingTransform(.stripDiacritics, reverse: false) ?? spelled
        return words(plain).map { $0.trimmingCharacters(in: quotes) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func ascii(_ text: String) -> String {
        text.replacingOccurrences(of: "ß", with: "ss")
            .applyingTransform(.stripDiacritics, reverse: false)?
            .replacingOccurrences(of: " ", with: "-") ?? text
    }

    /// What a signature writes right after a name — "Frau Seeger Tel.: 0331 …" — and is no part of it.
    static let contactWords: Set<String> = ["tel", "tel.", "telefon", "fax", "mobil", "handy", "mail", "email", "e-mail", "durchwahl", "zimmer"]

    /// A name that ends on one of those: the detector once took "Frau Seeger Tel" for a name.
    static func endsOnContactWord(_ text: String) -> Bool {
        words(text).last.map { contactWords.contains($0.lowercased()) } ?? false
    }

    public static let honorifics = Set(["frau", "herr", "herrn", "dr.", "dr", "doktor", "prof.", "prof", "professor", "mr", "mr.", "mrs", "mrs.", "ms", "ms."])
        .union(roles).union(academic)

    /// A title as a word, written spaced or glued: `Dr.`, `med.`, and `Dr.med.`, `Dr.med.dent.`, `Prof.Dr.`, `Dipl.-Ing.` —
    /// German writes them both ways (found at Proof, 17 November: „Dr.med. Hollenbach“ went out in the clear).
    public static func isTitle(_ word: String) -> Bool {
        let word = key(word)
        if honorifics.contains(word) { return true }
        guard word.hasSuffix("."), word.dropLast().contains(".") else { return false }
        // Split after every dot, and see whether the pieces join into titles: `dipl.` + `-ing.` is `dipl.-ing.`.
        var pieces: [String] = []
        var current = ""
        for character in word { current.append(character); if character == "." { pieces.append(current); current = "" } }
        var reachable = [true] + Array(repeating: false, count: pieces.count)
        for start in 0..<pieces.count where reachable[start] {
            for end in (start + 1)...pieces.count where honorifics.contains(pieces[start..<end].joined()) { reachable[end] = true }
        }
        return reachable[pieces.count]
    }

    /// F027: the titles the list reads in front of a name — today's (`isTitle`) and the French ones
    /// (the owner's yes at F027's question 4). A title here is never learned as a first name or a part,
    /// and stays in front of the stand-in, as Herr does. For the list only: the rules that find names
    /// (`Ordinary.isTitle`, read by every rule of `Detection`) keep 1.0.1's titles.
    public static func isListTitle(_ word: String) -> Bool {
        isTitle(word) || frenchTitles.contains(key(word))
    }

    static let frenchTitles: Set<String> = ["monsieur", "madame", "mademoiselle", "mme", "mme.", "mlle", "mlle."]

    /// A title glued to the name after it: `Dr.med.Hollenbach` is `Dr.med.` and `Hollenbach`.
    static func gluedTitle(_ word: String) -> (title: String, rest: String)? {
        var best: String.Index?
        for index in word.indices where word[index] == "." {
            let end = word.index(after: index)
            if end < word.endIndex, isTitle(String(word[..<end])) { best = end }
        }
        guard let best, word[best].isUppercase else { return nil }
        return (String(word[..<best]), String(word[best...]))
    }

    /// F019 AC-5: what stands between a title and a name, and is no name: `Dr. med.`, `Dipl.-Ing.`,
    /// `Freiherr von`. Read whole as title; never learned as a person or a company.
    static let academic: Set<String> = [
        "med.", "med", "dent.", "vet.", "rer.", "nat.", "phil.", "jur.", "habil.", "dipl.", "dipl.-ing.", "dipl.-kfm.", "dipl.-kffr.",
        "dipl.-psych.", "ing.", "mag.", "freiherr", "freifrau", "freiin", "graf", "gräfin", "baron", "baronin", "miss", "sir", "dame",
    ]

    /// What someone is, written in front of their name like a title: `Hausmeister Bittner`.
    /// Kept in the text like `Herr`, because it says who a party is and names nobody — and never
    /// learned as a first name, or every caretaker in every mail would be disguised as a person.
    static let roles: Set<String> = [
        "hausmeister", "hausmeisterin", "hausverwalter", "hausverwalterin", "verwalter", "verwalterin",
        "rechtsanwalt", "rechtsanwältin", "anwalt", "anwältin", "notar", "notarin", "architekt", "architektin",
        "makler", "maklerin", "steuerberater", "steuerberaterin", "beirat", "beirätin", "kollege", "kollegin",
        "nachbar", "nachbarin", "sachbearbeiter", "sachbearbeiterin", "schwester", "pfleger", "pflegerin",
    ]

    static let companyWords: Set<String> = [
        "gmbh", "mbh", "ag", "ug", "kg", "ohg", "gbr", "se", "e.v.", "e.", "v.", "ltd", "ltd.", "inc", "inc.",
        "llc", "&", "co.", "co", "und", "hausverwaltung", "verwaltung", "immobilien", "kanzlei",
        "rechtsanwalt", "rechtsanwälte", "notar", "praxis", "versicherung", "bank", "sparkasse", "team",
        "service", "support", "studio", "studios", "söhne", "baumarkt", "design",
    ]

    public static let greetings: Set<String> = [
        "liebe", "lieber", "liebes", "hallo", "guten", "abend", "morgen", "tag", "moin", "servus",
        "herzliche", "herzlichen", "viele", "beste", "besten", "grüße", "gruß", "danke", "dear", "hello",
    ]

    static let calendarWords: Set<String> = [
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
        "januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober",
        "november", "dezember", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "june", "july", "october", "december", "uhr",
        "mon", "tue", "wed", "thu", "fri", "sat", "sun", "jan", "feb", "mär", "mar", "apr", "jun", "jul",
        "aug", "sep", "sept", "okt", "oct", "nov", "dez", "dec",
    ]

    /// Lowercase words that do belong inside a name: `Ludwig van Beethoven`, `Gudula von der Leyen`.
    static let particles: Set<String> = ["von", "van", "de", "der", "den", "zu", "da", "di", "del", "la", "le", "du", "ten", "ter"]

    public static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "web.de", "gmx.de", "gmx.net", "t-online.de", "icloud.com",
        "me.com", "mac.com", "arcor.de", "mailbox.org", "posteo.de", "outlook.com", "outlook.de",
        "hotmail.com", "hotmail.de", "yahoo.com", "yahoo.de", "freenet.de", "aol.com",
    ]

    /// Words the tagger has been seen calling a name. Kept short and specific: every word here is
    /// one that will never be disguised, so a real surname that happens to be a German word —
    /// `Fleischer`, `Weber` — must not end up on it.
    static let commonWords: Set<String> = [
        "sie", "ihr", "ihre", "ich", "wir", "mit", "und", "oder", "aber", "viele", "liebe", "lieber",
        "hallo", "danke", "gruß", "grüße", "beste", "tel", "fax", "mail", "email", "iban", "bic", "weg",
        "bescheid", "betreff", "anbei", "bitte", "termin", "montag", "dienstag", "mittwoch",
        "donnerstag", "freitag", "samstag", "sonntag", "hi", "hey", "thanks", "best", "regards",
        "cheers", "dear", "the", "and", "with", "re", "aw", "fwd", "wg",
        // English words that are no one's name, read as one at the start of a title ("For", 9 November).
        "for", "of", "to", "from", "your", "our", "my", "at", "by", "in", "is", "are", "this", "that", "it", "you", "please", "new", "about", "euch", "dein", "deine", "mein",
        "meine", "ihnen", "ihren", "ihrer", "uns", "das", "die", "der", "ein", "eine", "von", "bei",
        "on", "als", "am", "im", "um", "für", "bis", "nach", "zum", "zur", "vom", "ab", "seit", "info", "mobil", "handy", "telefon", "fon", "kurz", "kurze",
        "gute", "namen", "post", "sitz", "haus", "privat", "wenn", "ihre", "ihr", "antwort",
        // Words of work that stand beside a name in a title or a product — "Head of Design System",
        // "Claude Design" — and are no one's surname.
        "design", "system", "systems", "product", "team", "portfolio", "strategy", "review", "memo",
        "quality", "platform", "engineering", "marketing",
        // What the owner types to the assistant in front of a name, or at the start of a sentence.
        "schreibe", "schreib", "antworte", "frage", "erinnere", "alle", "alles", "sachen", "write", "tell", "ask", "reply", "remind",
    ]
}

/// How often each word of a folder was written with a capital — the denominator for telling a
/// noun the tagger ignores from a name it finds. Addresses and links are left out, because they
/// write names too, and would count a name every time a signature repeats.
public struct Vocabulary: Sendable {
    public private(set) var capitalised: [String: Int] = [:]

    public init(_ texts: [String]) {
        for text in texts {
            let prose = text.precomposedStringWithCanonicalMapping
                .replacing(/\S+@\S+|https?:\/\/\S+|www\.\S+/, with: " ")
            for match in prose.matches(of: /\p{L}[\p{L}\p{M}'’\-]*/) {
                let word = String(match.output)
                if let first = word.first, first.isUppercase { capitalised[Pseudonymizer.key(word), default: 0] += 1 }
            }
        }
    }
}

/// One mail as it would be sent. Kept in the decision log so a leak can be seen, not inferred.
public struct Disguise: Codable, Equatable, Sendable {
    public var mode: Pseudonymizer.Mode
    public var subject: String
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var body: String
    public var attachmentNames: [String]
    public var replacements: Int

    // F024: the memberwise init, public now that the type lives in its own package.
    public init(mode: Pseudonymizer.Mode, subject: String, from: String, to: [String], cc: [String], body: String,
                attachmentNames: [String], replacements: Int) {
        self.mode = mode
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.body = body
        self.attachmentNames = attachmentNames
        self.replacements = replacements
    }

    enum CodingKeys: String, CodingKey {
        case mode, subject, from, to, cc, body, replacements
        case attachmentNames = "attachment_names"
    }
}

/// Replaces a set of strings with others in one pass: longest first, so `Sibylle Seeger` is
/// never half-replaced as `Sibylle` and `Seeger`; whole words only, so `Seeger` does not bite a
/// piece out of `Seegerstraße`'s neighbour; and without regard to case or to how an umlaut was
/// encoded, because mail arrives both ways.
public struct Replacer: Sendable {
    private let table: [String: String]
    private let expression: NSRegularExpression?
    /// For the way back only: two replacements side by side that are one name are written once.
    /// A first name two people share has a tag of its own, so `Dr. Martina Lechner` can go out as
    /// `Dr. [Person BT] [Person B]` — and must not come back as `Dr. Maria Martina Lechner`.
    var joinsNames = false
    /// Keys matched only where the text has a capital: `Kurz` the name, not "kurz" the word.
    var capitalOnly: Set<String> = []
    /// F021 P2: keys that are a person's part and an ordinary word, each with the first names it
    /// belongs to; matched only beside one of them or a title. Empty under the old rules.
    var needsName: [String: Set<String>] = [:]

    /// P2: the word before `range` is a title or one of `given`, on the same line; or, written
    /// surname first, the word after it, behind a comma, is one of `given`.
    static func standsBeside(_ range: Range<String.Index>, in text: String, given: Set<String>) -> Bool {
        let before = text[..<range.lowerBound]
        // A space or a tab between, or, in a file's name, `-` or `_` (`scan-lotta-lemke.jpg`).
        let joins: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "-" || $0 == "_" }
        if let separator = before.last, joins(separator), let last = before.split(whereSeparator: { joins($0) || $0.isNewline }).last,
           !before.dropLast().hasSuffix("\n") {
            let word = String(last)
            if Pseudonymizer.isTitle(word) || given.contains(Pseudonymizer.key(word)) { return true }
            // The first name already went as its stand-in — an earlier turn's own words, `[Person A] Montag`:
            // a person stands beside it, and the calendar word is that person's name (TestFlight 272).
            let head = before.dropLast()
            if head.hasSuffix("]"), let open = head.lastIndex(of: "["), head[open...].hasPrefix("[Person"),
               !Self.standIns(in: String(head[open...])).isEmpty { return true }
        }
        let after = text[range.upperBound...]
        if after.hasPrefix(","), let next = after.dropFirst().split(whereSeparator: \.isWhitespace).first {
            return given.contains(Pseudonymizer.key(String(next).trimmingCharacters(in: .punctuationCharacters)))
        }
        return false
    }
    /// F019: the list's phones, IBANs and references, found as whole written numbers.
    var numbers: NumberRuns?
    /// F019: the disguise looks at the owner's words only, never inside a stand-in it or another
    /// pass put there. Off for a way back, whose keys are the stand-ins.
    var skipsStandIns = false

    /// What a stand-in looks like, so nothing inside one is taken for a name: `[Person A]`,
    /// `[Company 3]`, `[Person A·first]`, `[Link 1]`, `[IBAN B]`.
    static let standIn = try! NSRegularExpression(pattern: #"\[(?:\p{Lu}\p{Ll}+|IBAN) [A-Z0-9]{1,6}(?:·\p{Ll}+)?\]"#)

    static func standIns(in text: String) -> [Range<String.Index>] {
        standIn.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// A person's stand-in with the title the disguise writes in front of it (`name.title`): `Dr. med. [Person B]`
    /// for `Dr. med. Hollenbach`. The title's words are the disguise's own output, not words of the owner's
    /// that went past it — TestFlight 264 held „med“ (junk in the list) in exactly that `Dr. med.`.
    static func titledStandIns(in text: String) -> [Range<String.Index>] {
        standIns(in: text).map { tag in
            guard text[tag].hasPrefix("[Person") else { return tag }
            var start = tag.lowerBound
            // Over any whitespace — a line's start, a tab, two spaces — but never across a word that is no title.
            while start > text.startIndex, text[text.index(before: start)].isWhitespace {
                var space = text.index(before: start)
                while space > text.startIndex, text[text.index(before: space)].isWhitespace { space = text.index(before: space) }
                let wordStart = text[..<space].lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
                guard wordStart < space, Pseudonymizer.isTitle(String(text[wordStart..<space])) else { break }
                start = wordStart
            }
            return start..<tag.upperBound
        }
    }

    public init(_ pairs: [(String, String)]) {
        var table: [String: String] = [:]
        for (from, to) in pairs where !from.trimmed.isEmpty {
            let key = Pseudonymizer.key(from)
            if table[key] == nil { table[key] = to }
        }
        self.table = table
        let alternatives = table.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
        // A table that cannot become an expression stops here: without it `apply` would hand the
        // text back unchanged, and the names in it would leave as they are.
        if alternatives.isEmpty {
            expression = nil
        } else {
            do {
                // F019 AC-8: an ending does not let a name out — `Seegers`, `Divya's` — and comes back
                // with it. Only after the whole original: `Berg` is never found in `Seeger`.
                // F019, the reviewer of 4c45bff: a name written in a file's name, `Hartmuth_Mielitz.pdf`, is the
                // name — its words joined by `_`; and a name glued to an address, `Selighttps://…`, ends
                // where the address starts (the address becomes `[link]` after the disguise).
                expression = try NSRegularExpression(
                    pattern: #"(?<![\p{L}\p{N}])(?:"# + alternatives.map { $0.replacingOccurrences(of: " ", with: "[ _]") }.joined(separator: "|")
                        + #")((?:['’])?s)?(?:(?![\p{L}\p{N}])|(?=https?://|www\.))"#,
                    options: [.caseInsensitive])
            } catch {
                fatalError("The disguise could not be built from \(table.count) names; nothing may be sent.")
            }
        }
    }

    public func apply(_ text: String) -> (text: String, count: Int) {
        let text = text.precomposedStringWithCanonicalMapping
        let found = found(in: text)
        var out = text
        for item in found.reversed() { out.replaceSubrange(item.range, with: item.with) }
        return (out, found.count)
    }

    /// F019 AC-9: the check before every send is this matcher run again over the exact text that
    /// leaves — one definition of a match, used twice. The words of the first match still in it, or nil.
    /// `ownWords`: the words of the request's own fixed text (`SendGate.promptWords`) — Causabee's,
    /// never the owner's — are not held for: „Appointments already on file“ when the list wrongly holds „Appointment“.
    public func firstMatch(in text: String, ownWords: Set<String> = []) -> String? {
        let text = text.precomposedStringWithCanonicalMapping
        return found(in: text).first { item in
            let words = String(text[item.range]).lowercased().split { !$0.isLetter }.map(String.init)
            return words.isEmpty || !words.allSatisfy { ownWords.contains($0) }
        }.map { String(text[$0.range]) }
    }

    /// Everything to replace in an NFC text, in order, none overlapping.
    public func found(in text: String) -> [(range: Range<String.Index>, with: String)] {
        let whole = NSRange(text.startIndex..., in: text)
        // The way back replaces stand-ins; the disguise never looks inside one.
        let tags = skipsStandIns ? Self.standIns(in: text) : []
        // Nothing the disguise wrote is looked inside: a stand-in, and the title it keeps in front of a person's.
        let written = skipsStandIns ? Self.titledStandIns(in: text) : []
        func inTag(_ range: Range<String.Index>) -> Bool { written.contains { $0.overlaps(range) } }
        var found: [(range: Range<String.Index>, with: String)] = []
        var dates: [Range<String.Index>]?
        if let expression {
            for match in expression.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                let ending = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
                let core = ending.isEmpty ? range : range.lowerBound..<text.index(range.upperBound, offsetBy: -ending.count)
                let written = Pseudonymizer.key(String(text[core]))
                let key = table[written] != nil ? written : written.replacingOccurrences(of: "_", with: " ")
                guard let replacement = table[key] else { continue }
                if capitalOnly.contains(key), text[core].first?.isLowercase == true { continue }
                if let given = needsName[key], !Self.standsBeside(core, in: text, given: given) { continue }
                if skipsStandIns {
                    if inTag(range) { continue }
                    // Glued to a stand-in, a word is what is left of a longer one the disguise cut —
                    // `Juli[Nummer A]` of `Juli2026` — not a word of the text: the check finds what the disguise found.
                    // Only a real stand-in: `Mielitz[1]` and `x]Selig` are the owner's words, and go under theirs (the reviewer, 17 November).
                    if tags.contains(where: { $0.upperBound == range.lowerBound || $0.lowerBound == range.upperBound }) { continue }
                }
                if !joinsNames {
                    // A month or a day that is a name too — `Jan`, `Mai` — stays where it is a date: `5. Jan 2027`.
                    if Pseudonymizer.calendarWords.contains(key), Pseudonymizer.isDated(core, in: text) { continue }
                    // Nothing out of the middle of a date: `2026` of `2026-11-13`.
                    if text[core].contains(where: \.isNumber) {
                        if dates == nil { dates = NumberRuns.dates(in: text) }
                        if dates!.contains(where: { $0.contains(core.lowerBound) && $0 != core && core.upperBound <= $0.upperBound }) { continue }
                    }
                }
                found.append((range, replacement + ending))
            }
        }
        if joinsNames { return Self.joined(found, in: text).map { Self.swallowingNumber($0, in: text) } }
        found = Self.oneTagAcross(found, in: text)
        if let numbers, !numbers.isEmpty {
            // A whole number before a part of it the table knows: `VN 2026 448812`, not its `2026`.
            let more = numbers.found(in: text).filter { !inTag($0.range) }
            if !more.isEmpty {
                found = (found.filter { item in !more.contains { $0.range.overlaps(item.range) } } + more)
                    .sorted { $0.range.lowerBound < $1.range.lowerBound }
            }
        }
        return found
    }

    /// A street comes back with its house number, and the model sometimes wrote the number after
    /// the tag as well: `[Street A] 51` is `Honigtauer Str. 14`, not `… 51 51`.
    static func swallowingNumber(_ item: (range: Range<String.Index>, with: String), in text: String) -> (range: Range<String.Index>, with: String) {
        guard let number = item.with.split(separator: " ").last, number.first?.isNumber == true else { return item }
        let rest = text[item.range.upperBound...]
        guard rest.hasPrefix(" " + number) else { return item }
        let end = text.index(item.range.upperBound, offsetBy: number.count + 1)
        if end < text.endIndex, text[end].isLetter || text[end].isNumber { return item }
        return (item.range.lowerBound..<end, item.with)
    }

    /// Where a surname alone was disguised right after another first name — "Herta Kloss", whose
    /// "Kloss" is known as part of "Ella Kloss" and goes out under her tag: "Herta [Person B]" is
    /// then Herta Kloss, not "Herta Ella Kloss" (9 November). Read from the text before it is
    /// disguised, so the way back knows exactly what stood there. German nouns are capitalised
    /// too — "Meine Mutter Lotta Spengler" — so a capital alone could not tell.
    public func surnameNotes(in text: String) -> [String: String] {
        let text = text.precomposedStringWithCanonicalMapping
        guard let expression else { return [:] }
        // Each tag's name in full: the longest original it stands for.
        var full: [String: String] = [:]
        for (key, tag) in table where key.split(separator: " ").count > (full[tag]?.split(separator: " ").count ?? 0) { full[tag] = key }
        var notes: [String: String] = [:]
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            // Without an ending: `Kloss` of `Kloss's`.
            let range = Range(match.range(at: 1), in: text).map { whole.lowerBound..<$0.lowerBound } ?? whole
            let written = String(text[range])
            guard let tag = table[Pseudonymizer.key(written)], let name = full[tag], !written.contains(" "),
                  case let words = name.split(separator: " ").map(String.init), words.count >= 2,
                  words.last == Pseudonymizer.key(written) else { continue }
            let before = text[..<range.lowerBound]
            guard before.hasSuffix(" "), let word = before.dropLast().split(separator: " ").last.map(String.init),
                  word.first?.isUppercase == true, word.allSatisfy({ $0.isLetter || $0 == "-" }) else { continue }
            let plain = Pseudonymizer.key(word)
            // Her own first name — or another word with a tag of its own — is not another person's.
            guard plain != words.first, table[plain] == nil, !Pseudonymizer.isTitle(plain),
                  !Pseudonymizer.commonWords.contains(plain) else { continue }
            notes[word + " " + tag] = word + " " + written
        }
        return notes
    }

    /// F019 AC-7: one person's parts side by side in a file's name — `Arztbrief_Simone_Hollenbach` —
    /// are one tag, so the name stays recognisable: `Arztbrief_[Person A]_2026.pdf`.
    static func oneTagAcross(_ found: [(range: Range<String.Index>, with: String)], in text: String) -> [(range: Range<String.Index>, with: String)] {
        var out: [(range: Range<String.Index>, with: String)] = []
        for item in found {
            if let last = out.last, last.with == item.with, ["_", "-", "."].contains(text[last.range.upperBound..<item.range.lowerBound]) {
                out[out.count - 1] = (last.range.lowerBound..<item.range.upperBound, item.with)
                continue
            }
            out.append(item)
        }
        return out
    }

    /// `Dr. Maria` is `Dr. ` and `Maria`.
    static func untitled(_ name: String) -> (title: String, core: String) {
        let words = Pseudonymizer.words(name)
        let titles = words.prefix { Pseudonymizer.isTitle($0) }
        guard !titles.isEmpty, titles.count < words.count else { return ("", name) }
        return (titles.joined(separator: " ") + " ", words.dropFirst(titles.count).joined(separator: " "))
    }

    /// `Maria` then `Martina Lechner`, or `Martina Lechner` then `Lechner`, with one space between:
    /// one name, written once.
    static func joined(_ found: [(range: Range<String.Index>, with: String)], in text: String) -> [(range: Range<String.Index>, with: String)] {
        var out: [(range: Range<String.Index>, with: String)] = []
        for item in found {
            if let last = out.last, text[last.range.upperBound..<item.range.lowerBound] == " " {
                let (title, core) = untitled(last.with)
                var name: String?
                if item.with == last.with || last.with.hasSuffix(" " + item.with) { name = last.with }
                else if item.with.hasPrefix(core + " ") { name = title + item.with }
                if let name {
                    out[out.count - 1] = (last.range.lowerBound..<item.range.upperBound, name)
                    continue
                }
            }
            out.append(item)
        }
        return out
    }
}

extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Stand-ins. Ordinary, plausible, and chosen to be unremarkable: a stand-in that reads as a
/// joke — or as `Tanja5` — changes what the model thinks the mail is.
///
/// A real folder has hundreds of people in it, far more than any hand-written list, so most of
/// each pool is made from German name parts: `Lind` and `ner`, `Berg` and `heim`. Every result
/// reads like a name and is checked against the folder's own originals before it is used.
enum Pool {
    static let givenNames = [
        "Birgit", "Jonas", "Heike", "Lukas", "Sabine", "Felix", "Anja", "Moritz", "Claudia", "Tobias",
        "Katrin", "Florian", "Nadine", "Jan", "Stefanie", "Matthias", "Julia", "Daniel", "Petra",
        "Christian", "Miriam", "Sven", "Ines", "Philipp", "Doris", "Kai", "Lena", "Marco", "Silke",
        "Oliver", "Tanja", "Henrik", "Ute", "Niklas", "Carola", "Benedikt", "Ronja", "Dirk", "Jana", "Emil",
        "Andrea", "Bernd", "Christina", "Dieter", "Elke", "Frank", "Gabriele", "Günter", "Hannah", "Holger",
        "Iris", "Jens", "Karin", "Klaus", "Laura", "Lars", "Monika", "Martin", "Nina", "Norbert", "Olga",
        "Peter", "Renate", "Ralph", "Sandra", "Stefan", "Theresa", "Thomas", "Ulla", "Uwe", "Vera",
        "Volker", "Wiebke", "Werner", "Yvonne", "Axel", "Anke", "Björn", "Beate", "Carsten", "Dagmar",
        "Detlef", "Edith", "Erik", "Franziska", "Fabian", "Gesa", "Gerd", "Helga", "Hendrik", "Ilse",
        "Ingo", "Judith", "Jörg", "Kerstin", "Konrad", "Lisa", "Lothar", "Maren", "Markus", "Nele",
        "Nils", "Paula", "Paul", "Regina", "Rainer", "Svenja", "Simon", "Tina", "Timo", "Ulrike",
        "Ulf", "Verena", "Wolfgang", "Antje", "Achim", "Bettina", "Boris", "Corinna", "Clemens", "Dörte",
        "David", "Eva", "Egon", "Friederike", "Friedrich", "Gudrun", "Georg", "Hanna", "Hans", "Imke",
        "Ivo", "Johanna", "Johannes", "Katja", "Karl", "Luise", "Leon", "Merle", "Max", "Nora", "Noah",
        "Ottilie", "Otto", "Pia", "Pascal", "Rieke", "Robert", "Susanne", "Sebastian", "Tabea", "Till",
        "Ursula", "Ulrich", "Viola", "Viktor", "Wilma", "Wilhelm", "Xenia", "Yannick", "Zoe", "Anton",
        "Agnes", "Bruno", "Britta", "Christoph", "Cornelia", "Dominik", "Diana", "Elias", "Emma", "Finn",
        "Frieda", "Gregor", "Greta", "Harald", "Heidi", "Ingrid", "Isabel", "Jakob", "Jutta", "Kurt",
        "Klara", "Ludwig", "Lotte", "Manfred", "Marie", "Nikolaus", "Nathalie", "Oskar", "Olivia",
        "Rudolf", "Rosa", "Siegfried", "Sophie", "Torsten", "Tamara", "Valentin", "Waltraud", "Walter",
        "Albert", "Alma", "Benno", "Berit", "Carl", "Cilly", "Dennis", "Dana", "Eberhard", "Esther",
        "Ferdinand", "Fenja", "Gustav", "Gisela", "Heinz", "Hedwig", "Ida", "Igor", "Jasper", "Jette",
        "Knut", "Kirsten", "Leo", "Liesel", "Malte", "Mia", "Nico", "Nadja", "Ole", "Oda", "Piet", "Rita",
        "Rolf", "Saskia", "Silas", "Thea", "Theo", "Ulli", "Vincent", "Wanda", "Wim",
        "Adele", "Arne", "Bianca", "Bastian", "Chiara", "Cem", "Denise", "Deniz", "Elif", "Emre", "Fatma",
        "Farid", "Gülay", "Goran", "Hatice", "Hakan", "Irina", "Ilias", "Jelena", "Jonte", "Kübra", "Kemal",
        "Leyla", "Luca", "Mira", "Milan", "Nesrin", "Nikola", "Oksana", "Omar", "Patrizia", "Pavel",
        "Raphaela", "Raul", "Selin", "Sami", "Tijana", "Tarek", "Vesna", "Vasco", "Yasmin", "Yusuf",
        "Zeynep", "Zoran", "Alina", "Aaron", "Bente", "Bjarne", "Cosima", "Cornelius", "Delia", "Darius",
        "Elena", "Emilian", "Fiona", "Fritz", "Gloria", "Gideon", "Helene", "Hugo", "Isolde", "Ilja",
        "Josefine", "Joscha", "Kira", "Korbinian", "Lina", "Linus", "Magdalena", "Mats", "Nadine",
        "Nepomuk", "Orla", "Otmar", "Philippa", "Quirin", "Rebekka", "Rasmus", "Selma", "Severin",
        "Theda", "Tjark", "Uta", "Urs", "Vivien", "Veit", "Wencke", "Wendelin", "Adrian", "Annika",
        "Benjamin", "Bärbel", "Cedric", "Constanze", "Dietmar", "Dorothea", "Enno", "Erika", "Frederik",
        "Frauke", "Gernot", "Gerda", "Henning", "Hildegard", "Ingmar", "Ivana", "Janosch", "Jolanda",
        "Kilian", "Kornelia", "Lennart", "Leonie", "Mathis", "Melanie", "Nikolai", "Nicole", "Olaf",
        "Pauline", "Reinhard", "Ricarda", "Sönke", "Sigrid", "Thorben", "Tilda", "Udo", "Ulrika",
        "Wieland", "Wilhelmine", "Arvid", "Amelie", "Birger", "Bella", "Colin", "Carla", "Dario", "Dina",
    ]

    static let surnames = [
        "Albers", "Brandt", "Dietz", "Ebert", "Falk", "Gerlach", "Hesse", "Jansen", "Kessler", "Lorenz",
        "Marx", "Nolte", "Ott", "Pohl", "Quast", "Ritter", "Seidel", "Thiel", "Voigt", "Winkler",
        "Beck", "Claasen", "Dreyer", "Engel", "Frey", "Gottschalk", "Haas", "Imhoff", "Jäger", "Kuhn",
        "Lang", "Mertens", "Nagel", "Oswald", "Pauli", "Reuter", "Stark", "Tews", "Ulrich", "Vogel",
        "Wendt", "Zander", "Busch", "Conrad", "Dorn", "Eckert", "Fiedler", "Grimm", "Horn", "Janke",
    ] + combined(stems, ["ner", "mann", "meier", "huber", "bach", "berg", "feld", "hoff", "rath",
                         "wald", "inger", "ke", "sen", "er", "hauser", "städter"])

    static let companies = [
        "Lindner", "Hoffmeister", "Aurelis", "Sonntag", "Brenner", "Nordwind", "Kaiser", "Stellwerk",
        "Ahrens", "Weidemann", "Merkur", "Falkenberg", "Rosenthal", "Linde", "Greif", "Heimdall",
        "Kranich", "Lotsen", "Achter", "Dreieck", "Seeberg", "Uhland", "Wachholz", "Zeisig",
    ] + combined(stems, ["tec", "plan", "werk", "bau", "haus", "data", "form", "line", "kontor", "concept"])

    static let places = [
        "Friedrichshain", "Kassel", "Lüneburg", "Göttingen", "Weißensee", "Erfurt", "Bamberg", "Rostock",
        "Oldenburg", "Pankow", "Jena", "Siegen", "Konstanz", "Wismar", "Coburg", "Tempelhof", "Gießen",
        "Hameln", "Passau", "Celle", "Stralsund", "Moabit", "Fulda", "Landshut",
    ] + generatedPlaces

    static let streets = [
        "Lindauer", "Gothaer", "Weimarer", "Kolberger", "Ansbacher", "Detmolder", "Hildesheimer",
        "Eisenacher", "Rudolstädter", "Wittenberger", "Marburger", "Bayreuther", "Zwickauer",
        "Plauener", "Coswiger", "Eschweger", "Tübinger", "Mindener", "Schweriner", "Harzer",
    ] + generatedPlaces.map { $0 + "er" }

    static let generatedPlaces = combined(stems, ["au", "heim", "hausen", "dorf", "rode", "stedt", "felde", "hagen", "burg", "beck"])

    static let stems = [
        "Lind", "Berg", "Hof", "Wald", "Stein", "Brun", "Eich", "Hart", "Kron", "Ross", "Wies", "Mohr",
        "Feld", "Hag", "Neu", "Alt", "Stroh", "Gold", "Sand", "Holz", "Ried", "Moos", "Esch", "Tann",
        "Hahn", "Roth", "Wend", "Kirch", "Mühl", "Brück",
    ]

    /// Every stem with every ending, ending by ending — so the first thirty are one family of
    /// names and not thirty variations of `Lind`.
    static func combined(_ stems: [String], _ endings: [String]) -> [String] {
        endings.flatMap { ending in
            stems.map { stem in
                // `Hahn` and `ner` would be `Hahnner`; one consonant where two would double.
                if let last = stem.last, ending.first == last { return stem + ending.dropFirst() }
                return stem + ending
            }
        }
    }
}

// MARK: F027 · One switch for every way of writing

extension Pseudonymizer.Mapping {
    public typealias Entry = Pseudonymizer.Entry

    /// The rows of a list, each with the names it speaks for: its own first, then its ways of writing,
    /// as indices into `entries`, in the list's order. A way whose row is not in the list, or is no row,
    /// is read as a row of its own.
    static func rows(_ entries: [Entry]) -> [[Int]] {
        var rowAt: [String: Int] = [:]
        for (i, entry) in entries.enumerated() where entry.partOf == nil && entry.formOf == nil {
            rowAt[Pseudonymizer.key(entry.original)] = rowAt[Pseudonymizer.key(entry.original)] ?? i
        }
        var order: [Int] = [], names: [Int: [Int]] = [:]
        for (i, entry) in entries.enumerated() where entry.partOf == nil {
            let row = entry.formOf.flatMap { rowAt[Pseudonymizer.key($0)] } ?? i
            if names[row] == nil { order.append(row); names[row] = [row] }
            if row != i { names[row]!.append(i) }
        }
        return order.map { names[$0]! }
    }

    /// The names a row speaks for: its own and its ways of writing.
    func names(of row: String) -> [String] {
        let entries = placeholder
        return Self.rows(entries).first { entries[$0[0]].original == row || Pseudonymizer.key(entries[$0[0]].original) == Pseudonymizer.key(row) }?
            .map { entries[$0].original } ?? []
    }

    /// F027: a row's own state: the newest switch with `ways` on its own name or any of its ways (one
    /// device's row may be another's way of writing). Nil when none was turned with `ways`.
    static func rowSwitch(_ names: [String], in switches: [String: Switch]) -> Switch? {
        names.compactMap { switches[hashed($0)] }.filter(\.coversWays).reduce(nil) { best, next in
            best.map { next.beats($0) ? next : $0 } ?? next
        }
    }

    /// F027: the switch of one name only — without `ways` — or nil.
    static func own(_ name: String, in switches: [String: Switch]) -> Switch? {
        switches[hashed(name)].flatMap { $0.coversWays ? nil : $0 }
    }

    /// F027: the hashes of what goes out as written, for `Pseudonymizer.init(_ mapping:)`: each name turned
    /// off on its own (a switch without `ways`: an older build's, one from before this build, as F022
    /// read it), and every name of a row turned off with `ways` — but a way whose own `on` is newer than
    /// that off (AC-8). A `gone` is not here: the name leaves the list (`settled`, `shed`), hidden till then.
    public func outAsWritten(_ mode: Pseudonymizer.Mode = .placeholder) -> Set<String> {
        guard let switches, !switches.isEmpty else { return [] }
        var out = Set(switches.filter { !$0.value.coversWays && $0.value.state == .off }.keys)
        guard switches.values.contains(where: \.coversWays) else { return out }
        let entries = self[mode]
        for row in Self.rows(entries) {
            let originals = row.map { entries[$0].original }
            guard let state = Self.rowSwitch(originals, in: switches), state.state == .off else { continue }
            for name in originals {
                if let own = Self.own(name, in: switches), own.state == .on, own.at > state.at { continue }
                out.insert(Self.hashed(name))
            }
        }
        return out
    }

    /// F027 (AC-8): the ways of writing a row the owner turned off that are still hidden — each came in
    /// after the off, with an `on` of its own, until the owner turns it off too.
    public func hiddenWays(of row: String) -> [String] {
        guard let switches else { return [] }
        let names = names(of: row)
        guard let state = Self.rowSwitch(names, in: switches), state.state == .off else { return [] }
        return names.filter { name in Self.own(name, in: switches).map { $0.state == .on && $0.at > state.at } ?? false }
    }

    /// F027 (AC-8, Q2): a way of writing learned since `base` under a row the owner turned off comes in
    /// on: an `on` of its own, without `ways`, at `now`, so it stays hidden until the owner turns it off too.
    /// A name with a switch of its own that is off, or newer than the row's, keeps it.
    public mutating func settleNewWays(base: Self, now: Date = Date()) {
        guard var switches, switches.values.contains(where: \.coversWays) else { return }
        let had = Set(base.placeholder.map { Pseudonymizer.key($0.original) })
        let entries = placeholder
        for row in Self.rows(entries) {
            let originals = row.map { entries[$0].original }
            guard let state = Self.rowSwitch(originals, in: switches), state.state == .off else { continue }
            for name in originals where !had.contains(Pseudonymizer.key(name)) {
                let hash = Self.hashed(name)
                if let mine = switches[hash], mine.coversWays || mine.state == .off || mine.at > state.at { continue }
                switches[hash] = .init(.on, at: now)
            }
        }
        self.switches = switches
    }

    /// F027: the list as its switches say, after every merge and in the upgrade (`adopt`, `current`,
    /// `upgrade`), so the list and the page say what the switches say:
    /// - a row deleted with `ways`: it, its ways and its parts leave the list — but a via name's service,
    ///   which becomes a company row of its own, and a name learned again since, with its own newer `on`;
    /// - a way turned off on its own (no `ways`) leaves its row: a row of its own, off, with its stand-in;
    ///   a way deleted on its own leaves the list;
    /// - the row's own name turned off or deleted on its own: the plainest other way becomes the row, and
    ///   only the old name is off, or gone.
    public func settled() -> Self {
        guard let switches, !switches.isEmpty else { return self }
        var entries = placeholder
        var removed: Set<String> = []
        func rehome(_ names: [Int], from old: Int) {
            guard let next = names.min(by: { Self.plainness(entries[$0].original, $0).lexicographicallyPrecedes(Self.plainness(entries[$1].original, $1)) })
            else { return }
            let oldKey = Pseudonymizer.key(entries[old].original), new = entries[next].original
            entries[next].formOf = nil
            for i in names where i != next { entries[i].formOf = new }
            for i in entries.indices where entries[i].partOf.map(Pseudonymizer.key) == oldKey { entries[i].partOf = new }
        }
        for row in Self.rows(entries) {
            let originals = row.map { entries[$0].original }
            if let state = Self.rowSwitch(originals, in: switches), state.state == .gone {
                let again = row.filter { Self.own(entries[$0].original, in: switches).map { $0.state == .on && $0.at > state.at } ?? false }
                for i in row where !again.contains(i) { removed.insert(Self.hashed(entries[i].original)) }
                if !again.isEmpty { rehome(again, from: row[0]) }
                continue
            }
            var staying: [Int] = []
            for i in row.dropFirst() {
                switch Self.own(entries[i].original, in: switches)?.state {
                case .off?: entries[i].formOf = nil
                case .gone?: removed.insert(Self.hashed(entries[i].original))
                default: staying.append(i)
                }
            }
            if let mine = Self.own(originals[0], in: switches), mine.state != .on {
                rehome(staying, from: row[0])
                if mine.state == .gone { removed.insert(Self.hashed(originals[0])) }
            }
        }
        var mapping = self
        mapping.placeholder = removed.isEmpty ? entries : Pseudonymizer.shed(entries, dropped: removed)
        return mapping
    }

    /// F027: one row of the list as a page shows it — a person, a company, a place, an address or a
    /// number — with the ways it was written. Read the list `settled()` first.
    public struct Identity: Sendable, Equatable {
        /// The row's own entry: what its switch and a delete act on.
        public var row: Entry
        /// The row's own name and its ways of writing, as written, in the list's order. Parts are no ways.
        public var ways: [String]
        /// The plainest way, with what is no part of the name taken off: a title in front, a row's label,
        /// quote marks; comma order read first name first (`Schüßler, Patrick` → `Patrick Schüßler`).
        public var name: String
        /// The owner's word on the row: its newest switch with `ways`, else its own name's.
        public var state: Switch.State
        /// The ways still hidden while the row is off: each came in after the off (AC-8).
        public var hidden: [String]
    }

    /// F027: the rows of the list, each with its ways, in the list's order.
    public func identities(_ mode: Pseudonymizer.Mode = .placeholder) -> [Identity] {
        let entries = self[mode], switches = switches ?? [:]
        return Self.rows(entries).map { row in
            let names = row.map { entries[$0].original }
            let plainest = row.min { Self.plainness(entries[$0].original, $0).lexicographicallyPrecedes(Self.plainness(entries[$1].original, $1)) } ?? row[0]
            let state = Self.rowSwitch(names, in: switches)?.state ?? Self.own(names[0], in: switches)?.state ?? .on
            return Identity(row: entries[row[0]], ways: names, name: Self.plainName(entries[plainest].original, kind: entries[row[0]].kind),
                            state: state, hidden: state == .off ? hiddenWays(of: names[0]) : [])
        }
    }

    /// F027: a way of writing as a row is named by it: label, quote marks and a title in front taken
    /// off, comma order read first name first. The words themselves are never changed.
    public static func plainName(_ original: String, kind: Entity.Kind) -> String {
        var name = original.trimmingCharacters(in: .whitespaces)
        name = Pseudonymizer.withoutRowLabel(name) ?? name
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\"‘’‚“”„ "))
        guard kind == .person else { return name }
        let words = name.split(separator: " ", omittingEmptySubsequences: true)
        let titles = words.prefix { Pseudonymizer.isListTitle(String($0)) }.count
        if titles > 0, titles < words.count { name = words.dropFirst(titles).joined(separator: " ") }
        return SendRecord.natural(name)
    }

    /// F027: how plain a way of writing is, to name a row: a name of two words or more before one word, then
    /// the fewest marks on it (a title, comma order, capitals, quote marks, a label, via, brackets), then the
    /// fewest words, then the first in the list.
    static func plainness(_ original: String, _ at: Int) -> [Int] {
        [Pseudonymizer.words(original).count < 2 ? 1 : 0, Pseudonymizer.decoration(original), Pseudonymizer.words(original).count, at]
    }
}

// MARK: F027 · The upgrade: a list from before brought up once

extension Pseudonymizer.Mapping {
    /// F027, version 7 (AC-12): the ways of writing one name joined under one row with one stand-in, by
    /// the rules of `Pseudonymizer.learn`. Nothing is learned anew: each entry is kept and pointed at its
    /// row, so no part the list hides can be lost to a rule that would read it differently today.
    /// 1. Each name whose own switch is off or gone is kept as it is, with its parts.
    /// 2. An entry that is only Monsieur, Madame, Mademoiselle, Mme or Mlle goes; a name that starts with one
    ///    keeps it in front of its stand-in (the owner's one exception to "never less hidden").
    /// 3. A company, a place, a street or a postcode that folds like an earlier one is its way of writing.
    /// 4. The people, full names first, then as they were learned, the plainest way of one person first:
    ///    each keeps its stand-in and is a row, unless a rule joins it to a row before it.
    /// 5. Each part points at its row: a first name or a surname takes the stand-in of the one full name
    ///    that holds it; held by two or more, a stand-in of its own.
    /// 6. Checked word by word (`putBack`). Rows keep their stand-ins; a joined way and a part that changed
    ///    hands change their letter once. The words put back are returned, for the device's log.
    mutating func joinWays() -> Int {
        let before = self
        var join = Join(placeholder, switches: switches ?? [:])
        join.titles()
        join.others()
        join.people()
        join.parts()
        placeholder = join.result()
        self = settled()
        return putBack(before: before)
    }

    /// F027 (AC-13): the check, word by word: every original of `before`, disguised with the list before
    /// and with this one. A word hidden before that this one lets out as written — Monsieur, Madame,
    /// Mademoiselle, Mme and Mlle aside — is a loss: its entry is put back as a row of its own, with a
    /// stand-in no one else has. Returns how many were put back.
    @discardableResult
    public mutating func putBack(before: Self) -> Int {
        let lost = Self.losses(before, self)
        guard !lost.isEmpty else { return 0 }
        var used = Set(placeholder.flatMap { Pseudonymizer.tags(in: $0.standIn) })
        for entry in lost {
            let tag = Self.freshTag(entry.kind, used: &used)
            if let at = placeholder.firstIndex(where: { Pseudonymizer.key($0.original) == Pseudonymizer.key(entry.original) }) {
                placeholder[at].partOf = nil
                placeholder[at].formOf = nil
                placeholder[at].standIn = tag
            } else {
                placeholder.append(.init(kind: entry.kind, original: entry.original, standIn: tag))
            }
        }
        return lost.count
    }

    /// The entries of `before` with a word hidden there that `after` lets out as written, the French titles aside.
    static func losses(_ before: Self, _ after: Self) -> [Entry] {
        func hiding(_ m: Self) -> Replacer {
            Pseudonymizer(mode: .placeholder, entries: Pseudonymizer.shed(m.placeholder, dropped: m.gone), off: m.outAsWritten()).disguiser
        }
        func written(_ text: Substring) -> Set<String> {
            var plain = String(text)
            for range in Replacer.standIns(in: plain).reversed() { plain.replaceSubrange(range, with: " ") }
            return Set(plain.split { !$0.isLetter && !$0.isNumber }.map { Pseudonymizer.key(String($0)) })
        }
        var seen: Set<String> = []
        let originals = before.placeholder.filter { seen.insert(Pseudonymizer.key($0.original)).inserted && !$0.original.contains("\n") }
        guard !originals.isEmpty else { return [] }
        // One pass over all of them, each on a line of its own, a line between that no rule reads across.
        let gap = "\n¶\n"
        let text = originals.map(\.original).joined(separator: gap)
        let (was, now) = (hiding(before).apply(text).text, hiding(after).apply(text).text)
        let wasLines = was.components(separatedBy: gap), nowLines = now.components(separatedBy: gap)
        guard wasLines.count == originals.count, nowLines.count == originals.count else {
            // Never guessed: each one alone.
            let (b, a) = (hiding(before), hiding(after))
            return originals.filter { entry in
                let words = written(Substring(entry.original))
                return !words.subtracting(written(Substring(b.apply(entry.original).text))).intersection(written(Substring(a.apply(entry.original).text)))
                    .subtracting(Pseudonymizer.frenchTitles).isEmpty
            }
        }
        return originals.indices.filter { i in
            let words = written(Substring(originals[i].original))
            let lost = words.subtracting(written(Substring(wasLines[i]))).intersection(written(Substring(nowLines[i])))
            return !lost.subtracting(Pseudonymizer.frenchTitles).isEmpty
        }.map { originals[$0] }
    }

    /// A tag of this kind that is no one's: `[Person AB]`, counted as `placeholder` counts.
    static func freshTag(_ kind: Entity.Kind, used: inout Set<String>) -> String {
        let prefix = "[" + Pseudonymizer.label(kind) + " "
        var number = used.filter { $0.hasPrefix(prefix) }.count
        while true {
            var letters = "", n = number
            repeat { letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters; n = n / 26 - 1 } while n >= 0
            let tag = prefix + letters + "]"
            if used.insert(tag).inserted { return tag }
            number += 1
        }
    }

    /// The join of `joinWays`, over one list's entries, in place: their order is kept.
    struct Join {
        var entries: [Entry]
        let switches: [String: Switch]
        /// Kept as they are: each whole the owner turned off or deleted, and its parts.
        var kept: [Bool]
        var used: Set<String>
        /// The rows made for a labelled name, each before the whole it was made for.
        var made: [(before: Int, entry: Entry)] = []
        var row: [Int?]
        /// By `foldKey`, the row of each row and way of writing so far.
        var byFold: [String: Int] = [:]
        /// By `personKey`, the row of each full name so far; the same for an initial and a surname.
        var fullRow: [String: Int] = [:], initialRow: [String: Int] = [:]
        /// Rule 5: the words of each full name so far, by its first two, with its row.
        var starts: [String: [(row: Int, words: [String])]] = [:]
        /// Rule 7: the rows of the full names that hold each word (folded), and the words the kept full names hold.
        var holders: [String: Set<Int>] = [:], keptHolders: [String: Set<String>] = [:]
        /// The tags of every row that is a full name: no word's own.
        var fullTags: Set<String> = []
        /// Each entry by its `key`, the first of it.
        var at: [String: Int] = [:]

        init(_ entries: [Entry], switches: [String: Switch]) {
            self.entries = entries
            self.switches = switches
            let off = Set(entries.filter { $0.partOf == nil && (switches[hashed($0.original)].map { $0.state != .on } ?? false) }
                .map { Pseudonymizer.key($0.original) })
            kept = entries.map { off.contains(Pseudonymizer.key($0.original)) || ($0.partOf.map { off.contains(Pseudonymizer.key($0)) } ?? false) }
            used = Set(entries.flatMap { Pseudonymizer.tags(in: $0.standIn) })
            row = Array(repeating: nil, count: entries.count)
            for (i, entry) in entries.enumerated() { at[Pseudonymizer.key(entry.original)] = at[Pseudonymizer.key(entry.original)] ?? i }
            for i in entries.indices where !kept[i] { self.entries[i].formOf = nil }
            for (i, entry) in entries.enumerated() where kept[i] && entry.kind == .person && entry.partOf == nil {
                let name = Pseudonymizer.nameParts(entry.original)
                guard let given = name.given, let family = name.family, !Pseudonymizer.isInitial(given) else { continue }
                for word in [given, family] { keptHolders[Pseudonymizer.fold(word), default: []].insert(Pseudonymizer.key(entry.original)) }
            }
        }

        /// Step 2: the French titles.
        mutating func titles() {
            for i in entries.indices where !kept[i] && entries[i].kind == .person {
                let words = Pseudonymizer.words(entries[i].original)
                let leading = words.prefix { Pseudonymizer.frenchTitles.contains(Pseudonymizer.key($0)) }
                guard !leading.isEmpty else { continue }
                if leading.count == words.count {  // only a title: it goes
                    at[Pseudonymizer.key(entries[i].original)] = nil
                    kept[i] = true
                    entries[i].original = ""
                    continue
                }
                guard entries[i].partOf == nil, let tag = Pseudonymizer.personTag(entries[i].standIn) else { continue }
                let title = leading.joined(separator: " ")
                if !entries[i].standIn.hasPrefix(title + " ") {
                    entries[i].standIn = entries[i].standIn.replacingOccurrences(of: tag, with: title + " " + tag)
                }
            }
        }

        func isWhole(_ i: Int) -> Bool { !kept[i] && entries[i].partOf == nil && !entries[i].original.isEmpty }

        /// Joins whole `i` to row `r`: a way of writing it, with its stand-in's tags.
        mutating func joinTo(_ i: Int, _ r: Int) -> [String: String] {
            entries[i].formOf = entries[r].original
            row[i] = r
            let mine = Pseudonymizer.tags(in: entries[i].standIn), theirs = Pseudonymizer.tags(in: entries[r].standIn)
            var moved: [String: String] = [:]
            for (k, tag) in mine.enumerated() where k < theirs.count && tag != theirs[k] && Self.label(tag) == Self.label(theirs[k]) {
                moved[tag] = theirs[k]
            }
            for (old, new) in moved { entries[i].standIn = entries[i].standIn.replacingOccurrences(of: old, with: new) }
            return moved
        }

        static func label(_ tag: String) -> Substring { tag.prefix { $0 != " " } }

        /// Step 3: companies, places, streets and postcodes.
        mutating func others() {
            let kinds: Set<Entity.Kind> = [.organization, .place, .street, .postalCity]
            let wholes = entries.indices.filter { isWhole($0) && kinds.contains(entries[$0].kind) }
            var moved: [Int: [String: String]] = [:]
            // A part of this kind, by its fold: `Göttingen` of `37073 Göttingen`.
            var parts: [String: Int] = [:]
            for i in entries.indices where !kept[i] && entries[i].partOf != nil && kinds.contains(entries[i].kind) {
                if let fold = Pseudonymizer.foldKey(entries[i].kind, entries[i].original), parts[fold] == nil { parts[fold] = i }
            }
            // The unlabelled first, so a labelled name finds its row wherever it stands.
            for i in wholes where Pseudonymizer.withoutRowLabel(entries[i].original) == nil {
                guard let fold = Pseudonymizer.foldKey(entries[i].kind, entries[i].original) else { continue }
                if let r = byFold[fold] { moved[i] = joinTo(i, r); continue }
                if let p = parts[fold], let whole = entries[p].partOf, let w = index(of: whole), !kept[w] {
                    // Written another way than a part of a row: a part of that row, with its stand-in, as learning makes it.
                    var map: [String: String] = [:]
                    for (old, new) in zip(Pseudonymizer.tags(in: entries[i].standIn), Pseudonymizer.tags(in: entries[p].standIn))
                    where old != new && Self.label(old) == Self.label(new) { map[old] = new }
                    for (old, new) in map { entries[i].standIn = entries[i].standIn.replacingOccurrences(of: old, with: new) }
                    entries[i].partOf = whole
                    row[i] = w
                    moved[i] = map
                    continue
                }
                byFold[fold] = i
                row[i] = i
            }
            for i in wholes {
                guard let name = Pseudonymizer.withoutRowLabel(entries[i].original),
                      entries[i].kind != .organization || Pseudonymizer.companyName(name, admitted: true) != nil,
                      let fold = Pseudonymizer.foldKey(entries[i].kind, name) else {
                    if row[i] == nil { row[i] = i }
                    continue
                }
                if let r = byFold[fold] { moved[i] = joinTo(i, r); continue }
                made.append((i, .init(kind: entries[i].kind, original: name, standIn: entries[i].standIn)))
                entries[i].formOf = name
                row[i] = i
            }
            // Their parts follow them.
            for i in entries.indices where !kept[i] && kinds.contains(entries[i].kind) {
                guard let whole = entries[i].partOf, let w = index(of: whole), let map = moved[w] else { continue }
                for (old, new) in map { entries[i].standIn = entries[i].standIn.replacingOccurrences(of: old, with: new) }
                entries[i].partOf = entries[row[w] ?? w].original
            }
        }

        func index(of original: String) -> Int? { at[Pseudonymizer.key(original)] }

        /// The person a whole names, without its label, its brackets and its service.
        static func core(_ text: String) -> String {
            var text = Pseudonymizer.withoutRowLabel(text) ?? text
            if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
                text = (String(text[..<open]) + String(text[text.index(after: close)...])).trimmed
            }
            if let via = text.range(of: " via ", options: .caseInsensitive) { text = String(text[..<via.lowerBound]).trimmed }
            return text
        }

        /// Step 4: the people.
        mutating func people() {
            let wholes = entries.indices.filter { isWhole($0) && entries[$0].kind == .person }
            var cores: [Int: String] = [:], fullness: [Int: Int] = [:]
            for i in wholes {
                cores[i] = Self.core(entries[i].original)
                fullness[i] = Pseudonymizer.fullness(.person, cores[i]!)
            }
            // Full names first, then as they were learned; of the ways of one person, the plainest first.
            let sorted = wholes.enumerated().sorted { a, b in
                let (x, y) = (fullness[a.element]!, fullness[b.element]!)
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
            var groups: [String: [Int]] = [:]
            for (n, i) in sorted.enumerated() {
                let name = Pseudonymizer.nameParts(cores[i]!)
                if let given = name.given, let family = name.family { groups[Pseudonymizer.personKey(given, family), default: []].append(n) }
            }
            var order = sorted
            for positions in groups.values where positions.count > 1 {
                let plain = positions.map { n in
                    (sorted[n], Pseudonymizer.decoration(entries[sorted[n]].original), Pseudonymizer.words(entries[sorted[n]].original).count)
                }
                let members = plain.enumerated().sorted { a, b in
                    if a.element.1 != b.element.1 { return a.element.1 < b.element.1 }
                    return a.element.2 != b.element.2 ? a.element.2 > b.element.2 : a.offset < b.offset
                }.map(\.element.0)
                for (position, member) in zip(positions, members) { order[position] = member }
            }
            for i in order {
                let core = cores[i]!
                if let r = resolve(core) {
                    _ = joinTo(i, r)
                    register(i, as: r)
                } else if Pseudonymizer.withoutRowLabel(entries[i].original) != nil, core != entries[i].original,
                          Pseudonymizer.nameParts(core).given != nil || Pseudonymizer.nameParts(core).family != nil, index(of: core) == nil {
                    // A labelled name whose name is no row yet: a row is made for it, with the labelled whole's stand-in.
                    made.append((i, .init(kind: .person, original: core, standIn: entries[i].standIn)))
                    entries[i].formOf = core
                    row[i] = i
                    register(i, as: i)
                } else {
                    row[i] = i
                    register(i, as: i)
                }
            }
        }

        /// The row a person's name joins, by the rules of `learn`: one row, or none.
        func resolve(_ text: String) -> Int? {
            if let r = Pseudonymizer.foldKey(.person, text).flatMap({ byFold[$0] }) { return r }
            let name = Pseudonymizer.nameParts(text)
            if let given = name.given, let family = name.family {
                let key = Pseudonymizer.personKey(given, family)
                if Pseudonymizer.isInitial(given) { return initialRow[key] }
                if let r = fullRow[key] { return r }
                guard let words = Pseudonymizer.nameWords(text), words.count >= 2 else { return nil }
                let rows = Set((starts[words[0] + " " + words[1]] ?? []).filter { $0.words.count > words.count && Array($0.words.prefix(words.count)) == words }.map(\.row))
                return rows.count == 1 ? rows.first : nil
            }
            guard let word = name.given ?? name.family else { return nil }
            let fold = Pseudonymizer.fold(word), rows = holders[fold] ?? []
            return rows.count == 1 && (keptHolders[fold] ?? []).isEmpty ? rows.first : nil
        }

        /// What a row or a way of writing tells the rules that come after it.
        mutating func register(_ i: Int, as r: Int) {
            if let fold = Pseudonymizer.foldKey(.person, entries[i].original), byFold[fold] == nil { byFold[fold] = r }
            let core = Self.core(entries[i].original)
            if core != entries[i].original, let fold = Pseudonymizer.foldKey(.person, core), byFold[fold] == nil, entries[i].original.contains("(") == false,
               entries[i].original.range(of: " via ", options: .caseInsensitive) == nil { byFold[fold] = r }
            let name = Pseudonymizer.nameParts(core)
            guard let given = name.given, let family = name.family else { return }
            let key = Pseudonymizer.personKey(given, family)
            if Pseudonymizer.isInitial(given) {
                if initialRow[key] == nil { initialRow[key] = r }
                return
            }
            if fullRow[key] == nil { fullRow[key] = r }
            if let tag = Pseudonymizer.personTag(entries[r].standIn) { fullTags.insert(tag) }
            for word in [given, family] { holders[Pseudonymizer.fold(word), default: []].insert(r) }
            if let words = Pseudonymizer.nameWords(core), words.count >= 2 { starts[words[0] + " " + words[1], default: []].append((r, words)) }
        }

        /// Step 5: each part points at its row; a first name or a surname alone takes the stand-in of the one
        /// full name that holds it, and a word two or more hold a stand-in of its own.
        mutating func parts() {
            var own: [String: String] = [:]
            // A word's own stand-in: the first one a part or a name of that word alone already has that is no full name's.
            func single(_ i: Int) -> String? {
                let name = Pseudonymizer.nameParts(entries[i].original)
                return name.given == nil ? name.family : (name.family == nil ? name.given : nil)
            }
            for i in entries.indices where !kept[i] && !entries[i].original.isEmpty && entries[i].kind == .person && (entries[i].partOf != nil || row[i] == i) {
                guard let word = single(i), let tag = Pseudonymizer.personTag(entries[i].standIn) else { continue }
                let fold = Pseudonymizer.fold(word)
                if own[fold] == nil, !fullTags.contains(tag), (holders[fold] ?? []).count + (keptHolders[fold] ?? []).count >= 2 { own[fold] = tag }
            }
            for i in entries.indices where !kept[i] && !entries[i].original.isEmpty && entries[i].kind == .person {
                let isPart = entries[i].partOf != nil
                guard isPart || row[i] == i, let word = single(i), let tag = Pseudonymizer.personTag(entries[i].standIn) else {
                    if isPart { repoint(i) }
                    continue
                }
                let fold = Pseudonymizer.fold(word), rows = holders[fold] ?? [], all = rows.count + (keptHolders[fold] ?? []).count
                if all >= 2 {
                    let shared = own[fold] ?? Self.fresh(&used)
                    own[fold] = shared
                    entries[i].standIn = entries[i].standIn.replacingOccurrences(of: tag, with: shared)
                    if isPart { repoint(i) }
                } else if rows.count == 1, let r = rows.first, let theirs = Pseudonymizer.personTag(entries[r].standIn), isPart {
                    entries[i].standIn = entries[i].standIn.replacingOccurrences(of: tag, with: theirs)
                    entries[i].partOf = entries[r].original
                } else if isPart {
                    repoint(i)
                }
            }
            for i in entries.indices where !kept[i] && !entries[i].original.isEmpty && entries[i].kind != .person && entries[i].partOf != nil { repoint(i) }
        }

        static func fresh(_ used: inout Set<String>) -> String { Pseudonymizer.Mapping.freshTag(.person, used: &used) }

        /// A part points at the row its whole belongs to.
        mutating func repoint(_ i: Int) {
            guard let whole = entries[i].partOf, let w = index(of: whole) else { return }
            var r = w, seen: Set<Int> = [w]
            while let up = row[r], up != r, seen.insert(up).inserted { r = up }
            if let up = entries[r].formOf, let u = index(of: up), u != r, entries[u].formOf == nil, entries[u].partOf == nil { r = u }
            entries[i].partOf = entries[r].original
        }

        /// The entries, the rows made for labelled names each before its labelled whole, a title alone left out.
        func result() -> [Entry] {
            var out: [Entry] = []
            let made = Dictionary(grouping: self.made, by: \.before)
            for (i, entry) in entries.enumerated() {
                for row in made[i] ?? [] { out.append(row.entry) }
                if !entry.original.isEmpty { out.append(entry) }
            }
            return out
        }
    }
}

