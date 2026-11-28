import Foundation
import NaturalLanguage

/// F021: the new rules, in the owner's order — A names, B places and numbers, C dates of birth —
/// on every source: what comes in (mail, screenshots, photos, files and scans), notes, the chat,
/// and tasks and dates added by hand. Each rule proposes candidates with their evidence; only the
/// gate (`Gate.admit`) decides what is learned. Reached only through `Detection`, and only while the
/// new rules decide or a test sets them.
public struct RuleFinder: NameFinding {
    public var language: NLLanguage?
    public var runsTagger: Bool
    /// The owner's own question to the chat (2b): N5's lone-word test is skipped.
    public var typed = false
    var words: any WordKnowledge = SystemWords.shared
    var opinion = SecondOpinion()

    public init(language: NLLanguage? = nil, runsTagger: Bool = true) {
        self.language = language
        self.runsTagger = runsTagger
    }

    public func entities(in email: Email) -> [Entity] {
        var found: [Entity] = []
        found += entities(in: email.subject, field: .subject)
        found += entities(in: email.body, field: .body)
        found += sender(email.from, field: .from).map(\.entity)
        for address in email.to { found += sender(address, field: .to).map(\.entity) }
        for address in email.cc { found += sender(address, field: .cc).map(\.entity) }
        for attachment in email.attachments { found += entities(in: attachment.filename, field: .attachmentName) }
        return found
    }

    public func entities(in text: String, field: Entity.Field) -> [Entity] {
        found(in: text, field: field).map(\.entity)
    }

    /// What the gate admitted from one text, each with the rule that found it.
    func found(in text: String, field: Entity.Field) -> [Gate.Admitted] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let read = Reading(text: text, finder: self)
        var candidates: [Gate.Candidate] = []
        candidates += titled(read, field: field)
        candidates += pairs(read, field: field)
        candidates += taggedPeople(read, field: field)
        candidates += companies(read, field: field)
        candidates += unknownWords(read, field: field)
        candidates += lowercaseFirstNames(read, field: field)
        candidates += taggedPlaces(read, field: field)
        candidates += Shapes.candidates(in: text, field: field)
        candidates += fileNames(in: text, field: field)
        let admitted = candidates.compactMap { Gate.admit($0, typed: typed, words: words) }
        return Self.resolvingOverlaps(admitted)
    }

    // MARK: Reading a text

    /// A word of the text, with what stands before it.
    struct Token {
        var range: Range<String.Index>
        var text: String
        /// The text between the word before and this one.
        var gap: Substring
        /// A full stop right after it: `Dr.`, `G.`, or a sentence's end.
        var dot: Bool
        var capital: Bool { text.first?.isUppercase == true }
        var withDot: String { dot ? text + "." : text }
    }

    /// A text cut into words, with the tagger's people where the tagger runs.
    struct Reading {
        var text: String
        var tokens: [Token] = []
        /// What the tagger read, and the ranges it read as a person.
        var tagged: [Tagged] = []
        var people: [Range<String.Index>] = []
        /// N8: each run of the text with the language it is read in.
        var languages: [(Range<String.Index>, NLLanguage)] = []

        /// The words of a file's name, read as a line: no word opens a sentence there.
        var fileLine = false

        init(text: String, finder: RuleFinder, fileLine: Bool = false) {
            self.text = text
            self.fileLine = fileLine
            var last = text.startIndex
            for match in text.matches(of: /[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*/) {
                let range = match.range
                let dot = range.upperBound < text.endIndex && text[range.upperBound] == "."
                tokens.append(Token(range: range, text: String(text[range]), gap: text[last..<range.lowerBound], dot: dot))
                last = range.upperBound
            }
            languages = RuleFinder.runs(of: text, main: finder.language ?? RuleFinder.language(of: text), forced: finder.language != nil)
            if finder.runsTagger {
                tagged = finder.tagged(text)
                people = tagged.filter { $0.kind == .person }.map(\.range)
            }
        }

        /// Only spaces or tabs between this word and the one before: the same run of words.
        func joined(_ i: Int) -> Bool {
            i > 0 && !tokens[i].gap.isEmpty && tokens[i].gap.allSatisfy { $0 == " " || $0 == "\t" }
        }

        /// The word opens a line or a sentence: nothing before it, a line break, or a sentence's end
        /// that is no title's or initial's dot.
        func opens(_ i: Int) -> Bool {
            if fileLine { return false }
            guard i > 0 else { return true }
            let gap = tokens[i].gap
            if gap.contains(where: \.isNewline) { return true }
            let before = tokens[i - 1]
            if gap.contains(where: { "!?".contains($0) }) { return true }
            if gap.hasPrefix(".") && before.dot {
                return !(Ordinary.isTitle(before.withDot) || before.text.count == 1)
            }
            return false
        }

        static let articles: Set<String> = [
            "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "kein", "keine",
            "mein", "meine", "meinen", "meinem", "meiner", "dein", "deine", "sein", "seine", "seinen", "ihr", "ihre", "ihren",
            "ihrem", "unser", "unsere", "unseren", "euer", "eure", "am", "im", "beim", "zum", "zur", "vom", "ins",
            "the", "my", "your", "his", "her", "our", "their",
        ]

        /// Right after an article or a pronoun that stands before a noun: `der Krankenkasse`, `am Sonntag`.
        func afterArticle(_ i: Int) -> Bool {
            joined(i) && Self.articles.contains(tokens[i - 1].text.lowercased())
        }

        /// The language the word at `index` is read in: `de` or `en`.
        func language(_ index: String.Index) -> String {
            (languages.first { $0.0.contains(index) }?.1 ?? languages.last?.1) == .english ? "en" : "de"
        }

        /// The word is glued to a digit: part of a code (`DEUTDEFF500`, `kd4471`), never a name.
        func inCode(_ i: Int) -> Bool {
            let range = tokens[i].range
            if range.upperBound < text.endIndex, text[range.upperBound].isNumber { return true }
            if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)].isNumber { return true }
            return false
        }

        /// The tagger read this word as (part of) a person.
        func taggedPerson(_ i: Int) -> Bool {
            people.contains { $0.overlaps(tokens[i].range) }
        }

        func offset(_ range: Range<String.Index>) -> (start: Int, length: Int) {
            let ns = NSRange(range, in: text)
            return (ns.location, ns.length)
        }
    }

    /// A first name: the tagger read it as a person, or the list of first names has it (second opinion).
    func isFirstName(_ i: Int, in read: Reading) -> Bool {
        let token = read.tokens[i]
        guard token.capital, !Ordinary.neverAlone(token.text), !Self.labels.contains(token.text.lowercased()) else { return false }
        return read.taggedPerson(i) || opinion.isFirstName(token.text)
    }

    // MARK: N2 · a title or a label

    /// The words after which a name stands, whatever word it is: a form's label, a greeting.
    static let labels: Set<String> = [
        "versicherungsnehmer", "versicherungsnehmerin", "versicherte", "versicherter", "patient", "patientin", "mieter", "mieterin",
        "vermieter", "vermieterin", "kunde", "kundin", "inhaber", "inhaberin", "inh", "empfänger", "empfängerin", "absender", "absenderin",
        "antragsteller", "antragstellerin", "ansprechpartner", "ansprechpartnerin", "kontoinhaber", "kontoinhaberin", "name",
        "policyholder", "passenger", "tenant", "landlord", "customer", "recipient", "applicant", "holder", "willkommen", "welcome",
    ]
    static let greetingLabels: Set<String> = ["hallo", "hi", "hey", "liebe", "lieber", "moin", "servus", "dear"]

    /// What a title never stands before as a name: a pronoun, a group of people. Not `Damen` or
    /// `Herren`: right after a title they are a surname (`Herr Herren`, 24 Nov 2026).
    static let notAfterTitle: Set<String> = [
        "sie", "ihr", "ihre", "ihnen", "du", "dich", "dir", "euch", "wir", "uns", "ich", "mich", "mir", "the", "and", "und",
        "grüße", "gruß", "leute", "alle", "zusammen", "team", "kollegen", "kolleginnen", "angehörige",
        "angehörigen", "mitglieder", "beiratsmitglieder", "nachbarn", "eigentümer", "eigentümerinnen", "freunde", "freundinnen",
        "eltern", "kinder", "familie", "beirat", "beiräte", "doktor",
    ]

    func titled(_ read: Reading, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        let tokens = read.tokens
        for i in tokens.indices {
            let word = tokens[i]
            let key = word.text.lowercased()
            // `med.`, `dent.`, `phil.` stand between a title and a name, never in front alone: `med. Beträge` is no person.
            let between: Set<String> = ["med", "dent", "vet", "rer", "nat", "phil", "jur", "habil", "ing", "mag"]
            // `Inh.`, `Inhaber`: a title as the old rules read it, kept in the name: `Inh. Martina Baume`.
            let owner = ["inh", "inhaber", "inhaberin"].contains(key)
            // `Herren`, `Damen` before a name work as a title: `die Herren Weber und Kurz` (24 Nov 2026).
            let isTitle = (Ordinary.isTitle(word.withDot) || Ordinary.isTitle(word.text) || owner || Ordinary.isEveryone(word.text)
                           || Ordinary.anchorsLikeTitle(word.text) || Ordinary.anchorsLikeTitle(word.withDot)) && !between.contains(key)
            let isLabel = Self.labels.contains(key) || (Self.greetingLabels.contains(key) && word.capital)
            guard isTitle || isLabel else { continue }
            // Further titles and particles: `Dr. med.`, `Freiherr von`.
            var j = i + 1
            while j < tokens.count, read.joined(j) || [".", ".-"].contains(tokens[j].gap.trimmingCharacters(in: .whitespaces)) && tokens[j - 1].dot,
                  Ordinary.isTitle(tokens[j].withDot) || Ordinary.isTitle(tokens[j].text) || Ordinary.particles.contains(tokens[j].text.lowercased()) && tokens[j].text.first?.isLowercase == true {
                j += 1
            }
            guard j < tokens.count else { continue }
            let first = tokens[j]
            let gap = first.gap.trimmingCharacters(in: .whitespaces)
            // A label may have its colon or comma: `Versicherungsnehmer: Gerwin Schiefbein`, `Hallo Bertram,`.
            let allowed = isLabel && !isTitle ? ["", ":", ",", "."] : ["", "."]
            guard !first.gap.contains(where: \.isNewline) || (isLabel && gap == ":"), allowed.contains(gap) || gap.isEmpty else { continue }
            let firstKey = first.text.lowercased()
            // After a title a greeting word is a name: `Herr Sehr` (24 Nov 2026); after a label it is not.
            if Ordinary.isSmall(first.text) || Ordinary.isTitle(first.withDot) || Ordinary.isGreeting(first.text) && !isTitle || Self.notAfterTitle.contains(firstKey) { continue }
            if first.capital {
                // A label is weaker than a title: the word after it is a name, not a common word.
                if !isTitle, Ordinary.neverAlone(first.text) { continue }
                if !isTitle, Self.greetingLabels.contains(key), !isFirstName(j, in: read), Ordinary.knowsLower(first.text, words: words) == true { continue }
            } else {
                // `frau wojciechowski`: lowercase after a title, only where the dictionary does not know it.
                guard isTitle, first.text.count >= 3, !Ordinary.isCommon(first.text), Ordinary.knowsLower(first.text, words: words) == false else { continue }
            }
            var end = j
            // An initial and the surname after it: `Mrs D. Whittington`.
            let initial = first.text.count == 1 && first.dot && first.capital
            if initial {
                guard j + 1 < tokens.count, tokens[j + 1].capital, tokens[j + 1].gap == ". " else { continue }
                end = j + 1
            } else if j + 1 < tokens.count, read.joined(j + 1), tokens[j + 1].capital, first.capital {
                // A second word joins only if the first is a first name, or the second is no word the
                // dictionary knows in lowercase.
                let second = tokens[j + 1].text
                let ordinary = Ordinary.isSmall(second) || Ordinary.isTitle(second) || Ordinary.isGreeting(second)
                if !ordinary, isFirstName(j, in: read) || (!Ordinary.isCommon(second) && !Ordinary.isKindWord(second) && Ordinary.knowsLower(second, words: words) != true) {
                    end = j + 1
                }
            }
            // A label is not part of the name; a title is, and stays readable in the disguise.
            // `Familie`, `Herren` anchor the name like a title but stay outside it: `Familie [Person A]`.
            let keptOutside = Ordinary.anchorsLikeTitle(word.text) || Ordinary.anchorsLikeTitle(word.withDot) || Ordinary.isEveryone(word.text)
            // CAU-205: a role guards the name like a title but stays outside it, and visible:
            // `Steuerberater [Person A]`, `Steuerberater Frau [Person A]`. The title after it stays in the name.
            var titleAt = i
            while titleAt < j, Ordinary.isRole(tokens[titleAt].text) { titleAt += 1 }
            let start = isTitle && !keptOutside ? tokens[titleAt].range.lowerBound : first.range.lowerBound
            let range = start..<tokens[end].range.upperBound
            let at = read.offset(range)
            out.append(Gate.Candidate(kind: .person, text: String(read.text[range]), field: field, start: at.start, length: at.length,
                                      evidence: [isTitle ? .title : .label], rule: .N2))
        }
        return out
    }

    // MARK: N3 · a pair

    /// A first name beside a capitalised word is a person, the second word the surname whatever the
    /// dictionary says of it (`Sonja Sonntag`). At the start of a line or a sentence, where any word
    /// is capitalised, a first name from the list alone needs a second word no dictionary knows
    /// (`Gesche Mühlenhoff wegen …`).
    func pairs(_ read: Reading, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        let tokens = read.tokens
        for i in tokens.indices.dropLast() {
            let first = tokens[i], second = tokens[i + 1]
            guard read.joined(i + 1), !first.dot, second.capital, second.text.count >= 2, !read.inCode(i), !read.inCode(i + 1) else { continue }
            guard !read.afterArticle(i), isFirstName(i, in: read) else { continue }
            if Ordinary.isSmall(second.text) || Ordinary.isTitle(second.withDot) || Ordinary.isGreeting(second.text) || Ordinary.isKindWord(second.text)
                || Ordinary.isKin(second.text) { continue }
            if Ordinary.isCommon(second.text), !Ordinary.isCalendar(second.text) { continue }
            // A code, not a surname: `M-RW`, `KFZ`.
            if !second.text.contains(where: \.isLowercase), second.text.count <= 4 { continue }
            // A first name that is an ordinary word too (`Miete`, `Kay`), or a word of a file's name, needs
            // a second word that is no ordinary one: on the list of surnames, unknown to the dictionary,
            // or read by the tagger with it.
            let taggedBoth = read.people.contains { $0.contains(first.range.lowerBound) && $0.upperBound >= second.range.upperBound }
            let language = read.language(first.range.lowerBound)
            let secondOrdinary = Ordinary.isCalendar(second.text) || Ordinary.knowsLower(second.text, words: words, language: language) == true && !opinion.holdsSurname(second.text)
            if read.fileLine || Ordinary.knowsLower(first.text, words: words, language: language) == true, secondOrdinary, !taggedBoth { continue }
            // At the start of a line, the list alone needs a second word no dictionary knows, or the
            // tagger's reading of both as one name (`Alfons Rosenhagen`, read as a place). A day or a
            // month beside a first name is that person's surname there too (N3, F021 AC-11): „<First>
            // Mittwoch ist meine Schwester“ went out with the day and came back with a stranger's surname.
            if read.opens(i), !read.taggedPerson(i), !Ordinary.isCalendar(second.text), Ordinary.knows(second.text, words: words) == true,
               !read.tagged.contains(where: { $0.range.contains(first.range.lowerBound) && $0.range.upperBound >= second.range.upperBound }) { continue }
            let range = first.range.lowerBound..<second.range.upperBound
            let at = read.offset(range)
            out.append(Gate.Candidate(kind: .person, text: String(read.text[range]), field: field, start: at.start, length: at.length,
                                      evidence: [.firstName], rule: .N3))
        }
        return out
    }

    // MARK: N5 · the tagger's guess

    /// The span rule: a person is one to four words, each capitalised or a particle (`von`, `van`,
    /// `de`, `zu`); a small word inside it ends the span (`Kasse den Fahrdienst` is two pieces, and
    /// no name). Particles only between two capitalised words.
    static func span(of text: String) -> [[String]] {
        pieces(of: text.split(whereSeparator: \.isWhitespace).map(String.init)) { $0 }
    }

    static func pieces<T>(of items: [T], _ word: (T) -> String) -> [[T]] {
        var out: [[T]] = [], current: [T] = []
        func end() {
            while let last = current.last, word(last).first?.isLowercase == true { current.removeLast() }
            if !current.isEmpty { out.append(current) }
            current = []
        }
        for item in items {
            let text = word(item)
            let previous = current.last.map(word)
            // `von`, `van`, `de`, `zu` after a capitalised word; `der`, `den` only after `von`, `van`.
            let particle = previous.map { ["von", "van", "de", "zu"].contains(text) && $0.first?.isUppercase == true
                || ["der", "den"].contains(text) && ["von", "van"].contains($0) } ?? false
            if text.first?.isUppercase == true, !Ordinary.isSmall(text) {
                if current.count == 4 { end() }
                current.append(item)
            } else if particle {
                current.append(item)
            } else {
                end()
            }
        }
        end()
        return out
    }

    /// N5: the tagger's people, cut by the span rule, with the words before the first name taken
    /// off that the dictionary knows as written (`Vater Arnulf Hufnagel`, `Patientin Rosemarie
    /// Ossenkamp`) — what someone is, not who.
    func taggedPeople(_ read: Reading, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        for tag in read.tagged where tag.kind == .person {
            let inside = read.tokens.indices.filter { tag.range.overlaps(read.tokens[$0].range) }
            for var piece in Self.pieces(of: inside, { read.tokens[$0].text }) {
                // What someone is, before or after the name: `Oma Gretl Furtkamp`, `Aunt Winifred`.
                // An id before a word (`X1 Büro`) and everyone greeted at once (`Damen`, `Herren`) are no part of a name.
                while let first = piece.first, piece.count > 1, Ordinary.isID(read.tokens[first].text) || Ordinary.isEveryone(read.tokens[first].text) { piece.removeFirst() }
                // `Damen und Herren` at the end, never after a title: `Herr Herren` is a name.
                while let last = piece.last, piece.count > 1, Ordinary.isEveryone(read.tokens[last].text),
                      !Ordinary.isTitle(read.tokens[piece[piece.count - 2]].withDot) { piece.removeLast() }
                while let first = piece.first, piece.count > 1, Ordinary.isKin(read.tokens[first].text) { piece.removeFirst() }
                while let last = piece.last, piece.count > 1, Ordinary.isKin(read.tokens[last].text) { piece.removeLast() }
                // CAU-205: what someone does, before the name, is no part of it: `Ergotherapeutin Dr. Ilka Sternwald`.
                // Only in front: a surname may be a role word (`Ilka Pfleger`).
                while let first = piece.first, piece.count > 1, Ordinary.isRole(read.tokens[first].text) { piece.removeFirst() }
                // A lone word right after an article is a noun: `Ihr Tarif`, `die Nachbarn` (N5's lone-word test).
                if piece.count == 1, !typed, read.afterArticle(piece[0]) { continue }
                // L1 with N5 (the lead's reading of 6b): a lone word the tagger read as a person and
                // the first-name list holds is kept, though the dictionary knows it in lowercase
                // (`Gernot`, `Ada`). Never a small word, a title, a calendar or a kinship word; never
                // by the surname list.
                // Greetings and common words at either end are no part of a name: `Liebe Frau Stein`.
                while let first = piece.first, piece.count > 1, Ordinary.isGreeting(read.tokens[first].text) || Ordinary.isCommon(read.tokens[first].text) && !Ordinary.isCalendar(read.tokens[first].text) { piece.removeFirst() }
                while let last = piece.last, piece.count > 1, Ordinary.isGreeting(read.tokens[last].text) || Ordinary.isCommon(read.tokens[last].text) && !Ordinary.isCalendar(read.tokens[last].text) { piece.removeLast() }
                // The first name's token, taken before the piece is cut: its place in the piece moves (TestFlight 276).
                if let at = piece.firstIndex(where: { opinion.isFirstName(read.tokens[$0].text) }), at > 0 {
                    let anchor = piece[at]
                    while piece.count > 1, let first = piece.first, first != anchor, !opinion.isFirstName(read.tokens[first].text),
                          !Ordinary.isTitle(read.tokens[first].withDot), Ordinary.knows(read.tokens[first].text, words: words) == true {
                        piece.removeFirst()
                    }
                }
                guard let first = piece.first, let last = piece.last else { continue }
                let range = read.tokens[first].range.lowerBound..<read.tokens[last].range.upperBound
                let at = read.offset(range)
                let word = read.tokens[first].text
                let listed = piece.count == 1 && (opinion.isFirstName(word) || opinion.cannotTell(word))
                out.append(Gate.Candidate(kind: .person, text: String(read.text[range]), field: field, start: at.start, length: at.length,
                                          evidence: listed ? [.tagger, .secondOpinion] : [.tagger], rule: listed ? .L1 : .N5,
                                          language: read.language(range.lowerBound)))
            }
        }
        return out
    }

    // MARK: N4 · a word no dictionary knows

    static var streetEnds: [String] { Ordinary.streetEnds }

    /// A capitalised word in running text that neither the German nor the English dictionary knows,
    /// as written or small, that is not on a list of ordinary words and does not look like a
    /// company, a street or a word made of two known ones, is a person. Not at the start of a
    /// sentence, not after an article.
    func unknownWords(_ read: Reading, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        let tokens = read.tokens
        for i in tokens.indices {
            let token = tokens[i], text = token.text
            guard token.capital, text.count >= 3, !read.opens(i), !read.afterArticle(i), !Ordinary.neverAlone(text), !read.inCode(i) else { continue }
            // An abbreviation: `AOK`, `TÜV`.
            if text == text.uppercased(), text.count <= 4 { continue }
            let lower = text.lowercased()
            if Self.streetEnds.contains(where: { lower.hasSuffix($0) }) || Self.labels.contains(lower) { continue }
            if i + 1 < tokens.count, Self.legalForms.contains(tokens[i + 1].text.lowercased()) { continue }
            let asked = text == text.uppercased() ? text.prefix(1) + text.dropFirst().lowercased() : Substring(text)
            guard Ordinary.knows(String(asked), words: words) == false, Ordinary.knowsLower(text, words: words) == false else { continue }
            // `Kuendigung` is `Kündigung`; `Badewannensitz` is two words the dictionary knows.
            let umlauts = LookAlikeNames.withUmlauts(String(asked))
            if umlauts != String(asked), words.knows(umlauts) == true { continue }
            if isCompound(String(asked)) { continue }
            if text.contains("-"), text.split(separator: "-").contains(where: { words.knows(String($0)) == true && !opinion.isName(String($0)) }) { continue }
            let at = read.offset(token.range)
            out.append(Gate.Candidate(kind: .person, text: text, field: field, start: at.start, length: at.length,
                                      evidence: [.unknownWord], rule: .N4))
        }
        return out
    }

    /// `Badewannensitz`, `Anhörungsbogen`: two words the dictionary knows, with `s`, `n`, `es` or `en`
    /// between. Not when the end is a name the list holds (`Kottmeier` is no `Brink` and `Meier`):
    /// the list raises, it never lowers.
    func isCompound(_ word: String) -> Bool {
        let letters = Array(word)
        guard letters.count >= 7 else { return false }
        for cut in 3...(letters.count - 3) {
            let rest = String(letters[cut...])
            let right = rest.prefix(1).uppercased() + rest.dropFirst()
            guard words.knows(right) == true, !opinion.isName(right) else { continue }
            let left = String(letters[..<cut])
            for link in ["", "s", "n", "es", "en", "e"] where left.hasSuffix(link) {
                let stem = String(left.dropLast(link.count))
                if stem.count >= 3, words.knows(stem) == true || words.knows(stem.lowercased()) == true { return true }
            }
        }
        return false
    }

    // MARK: A file's name

    static let fileName = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])[\p{L}\p{N}][\p{L}\p{N}_\-.]*\.(?i:pdf|jpe?g|png|heic|tiff?|gif|docx?|xlsx?|txt|eml|emlx|pages|numbers|odt|rtf)(?![\p{L}\p{N}])"#)

    /// `Arztbrief_Simone_Hollenbach_2026` → Arztbrief, Simone, Hollenbach, 2026; `ScanLottaLemke` too.
    static func pieces(ofStem stem: String) -> [String] {
        var out: [String] = []
        for part in stem.split(whereSeparator: { "_-. ".contains($0) }) {
            var current = ""
            for character in part {
                if character.isUppercase, let last = current.last, last.isLowercase { out.append(current); current = "" }
                current.append(character)
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    /// A file's name is cut where its words meet, and its words read as a line by the same rules:
    /// `Kuendigung_Casper_Hermanns.pdf` teaches Casper Hermanns, `scan-lotta-lemke.jpg` lotta lemke,
    /// learned as written in the name.
    func fileNames(in text: String, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        let ns = NSRange(text.startIndex..., in: text)
        for match in Self.fileName.matches(in: text, range: ns) {
            guard let range = Range(match.range, in: text) else { continue }
            let written = String(text[range])
            let stem = URL(fileURLWithPath: written).deletingPathExtension().lastPathComponent
            // A plain word with an extension is no file's name in running text (`Rechnung.pdf` is one).
            guard field == .attachmentName || stem.contains(where: { "_-".contains($0) }) || stem.contains(where: \.isUppercase) && stem.dropFirst().contains(where: \.isUppercase) else { continue }
            let pieces = Self.pieces(ofStem: stem).filter { $0.count >= 2 && !$0.contains(where: \.isNumber) }
            guard !pieces.isEmpty else { continue }
            let line = pieces.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            let read = Reading(text: line, finder: self, fileLine: true)
            var candidates = titled(read, field: field) + pairs(read, field: field) + taggedPeople(read, field: field)
                + companies(read, field: field) + unknownWords(read, field: field)
            candidates = candidates.filter { $0.kind == .person || $0.kind == .organization }
            // The line's capitals are the reader's, not the writer's: a company there needs a name
            // word that is no ordinary one (`bank_details.pdf` names no company).
            candidates = candidates.filter { candidate in
                candidate.kind != .organization || Pseudonymizer.words(candidate.text).contains { word in
                    !Ordinary.isKindWord(word) && Ordinary.knowsLower(word, words: words) != true
                }
            }
            for candidate in candidates {
                let words = candidate.text.split(separator: " ").map { word in pieces.first { $0.lowercased() == word.lowercased() } ?? String(word) }
                var named = candidate
                named.text = words.joined(separator: " ")
                named.start = match.range.location
                named.length = 0
                out.append(named)
            }
        }
        return out
    }

    // MARK: L1 · a first name written small

    /// The words that stand before a person: prepositions, and asking, telling, calling.
    static var beforePerson: Set<String> { Ordinary.beforePerson }

    /// What the owner types in a chat or a note is often all in lowercase (`frag tobias …`, `anruf bei
    /// ulrike`). A lowercase word the list holds as a first name is a person where the word before
    /// it stands before a person, or where it owns something (`sina's idea`): the list raises a
    /// word another rule's anchor doubts (L1), whatever this device's dictionary knows of it. Never
    /// a small word, a title, a calendar or kinship word, or a word of the common list.
    func lowercaseFirstNames(_ read: Reading, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        let tokens = read.tokens
        for i in tokens.indices {
            let token = tokens[i]
            guard token.text.count >= 3, token.text == token.text.lowercased(), !token.text.contains("-"), !Ordinary.neverAlone(token.text) else { continue }
            var word = token.text, range = token.range
            // `sina's`: the name, without its ending.
            let owns = word.hasSuffix("'s") || word.hasSuffix("’s")
            if owns { word = String(word.dropLast(2)); range = range.lowerBound..<read.text.index(range.upperBound, offsetBy: -2) }
            let anchored = owns || (read.joined(i) && Self.beforePerson.contains(tokens[i - 1].text.lowercased()))
            guard anchored, !token.dot || range.upperBound < token.range.upperBound,
                  opinion.isFirstName(word.prefix(1).uppercased() + word.dropFirst()) else { continue }
            // `bei max. 20`: an abbreviation, not a name.
            if token.dot && !owns { continue }
            let at = read.offset(range)
            out.append(Gate.Candidate(kind: .person, text: word, field: field, start: at.start, length: at.length,
                                      evidence: [.secondOpinion, .label], rule: .L1))
        }
        return out
    }

    // MARK: S4 · a place the tagger reads

    /// A town alone only if the tagger read it as a place, the dictionary does not know it in
    /// lowercase (in the text's language), and it is not a small word; the vetoes as for a person.
    func taggedPlaces(_ read: Reading, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        for tag in read.tagged where tag.kind == .place {
            let inside = read.tokens.indices.filter { tag.range.overlaps(read.tokens[$0].range) }
            for var piece in Self.pieces(of: inside, { read.tokens[$0].text }) {
                // CAU-205: a role before a name read as a place (`Nachbarin Herr Tannhauf anrufen`): the role
                // stays visible, and a title after it makes the rest a person's, which N2 finds.
                if let lead = piece.first, Ordinary.isRole(read.tokens[lead].text) {
                    while let first = piece.first, piece.count > 1, Ordinary.isRole(read.tokens[first].text) { piece.removeFirst() }
                    if let first = piece.first, Ordinary.isTitle(read.tokens[first].withDot) || Ordinary.isTitle(read.tokens[first].text) { continue }
                }
                guard let first = piece.first, let last = piece.last else { continue }
                if piece.count == 1, read.afterArticle(first) { continue }
                let range = read.tokens[first].range.lowerBound..<read.tokens[last].range.upperBound
                let at = read.offset(range)
                out.append(Gate.Candidate(kind: .place, text: String(read.text[range]), field: field, start: at.start, length: at.length,
                                          evidence: [.tagger], rule: .S4, language: read.language(range.lowerBound)))
            }
        }
        return out
    }

    // MARK: N6 · a company

    static let legalForms: Set<String> = ["gmbh", "mbh", "ag", "ug", "kg", "ohg", "gbr", "se", "kgaa", "ltd", "inc", "llc", "plc", "partg", "e.v"]

    /// The words that name a business when they stand after its name: `Weserland BKK`.
    static let kindsAfter: Set<String> = ["bkk", "ikk", "aok", "hkk", "versicherung", "bank", "apotheke", "werkstatt", "lettings", "ltd"]

    /// A legal form (`GmbH`, `AG`, `e. V.`) after one to four capitalised words, or a word that says
    /// what a business is (`Kanzlei`, `Praxis`, `Werkstatt`, `Krankenkasse`) beside a capitalised
    /// name; and the tagger's organisations. The gate keeps a company of one ordinary word out.
    func companies(_ read: Reading, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        let tokens = read.tokens
        func key(_ i: Int) -> String { tokens[i].text.lowercased() }
        func isName(_ i: Int) -> Bool {
            tokens[i].capital && !Ordinary.isSmall(tokens[i].text) && !Ordinary.isGreeting(tokens[i].text) && !Ordinary.isCalendar(tokens[i].text)
                && !(Ordinary.isCommon(tokens[i].text) && !Ordinary.isKindWord(tokens[i].text))
        }
        func near(_ i: Int) -> Bool { read.joined(i) || tokens[i].gap.trimmingCharacters(in: .whitespaces) == "&" }
        func add(_ from: Int, _ to: Int, _ evidence: Gate.Evidence) {
            // N6 (the lead, 17 November, at Build): the whole company is hidden, its kind word too —
            // `[Company A]` for `Sanitätshaus Krull KG` — as the old rules do. The kind word alone is
            // still no one, and is never learned as a part (`Pseudonymizer.organization`).
            guard (from...to).contains(where: { !Ordinary.isKindWord(tokens[$0].text) }) else { return }
            // `e. V.`, `Ltd.`, `Inc.`: the legal form's own full stop belongs to it.
            let dotted = tokens[to].dot && ["v", "ltd", "inc", "co"].contains(key(to))
            let range = tokens[from].range.lowerBound..<(dotted ? read.text.index(after: tokens[to].range.upperBound) : tokens[to].range.upperBound)
            let at = read.offset(range)
            out.append(Gate.Candidate(kind: .organization, text: String(read.text[range]), field: field, start: at.start, length: at.length,
                                      evidence: [evidence], rule: .N6))
        }
        for i in tokens.indices {
            let k = key(i)
            // `e. V.`: two tokens.
            let isLegal = Self.legalForms.contains(k) || k == "v" && i > 0 && tokens[i - 1].text.lowercased() == "e" && tokens[i - 1].dot
            if isLegal, i > 0, near(i) || tokens[i].gap == ". " {
                var start = i - (k == "v" ? 1 : 0)
                var from = start
                while from > 0, from - 1 >= 0, near(from), isName(from - 1), start - from < 4 { from -= 1 }
                // What stands before the kind word and the dictionary knows is no part of the name: `Rückruf Sanitätshaus Krull KG`.
                if let kind = (from..<start).first(where: { Ordinary.isKindWord(tokens[$0].text) }) {
                    while from < kind, Ordinary.knows(tokens[from].text, words: words) == true { from += 1 }
                }
                start = from
                if start < i - (k == "v" ? 1 : 0) { add(start, i, .legalForm) }
                continue
            }
            guard Ordinary.isKindWord(tokens[i].text), tokens[i].capital || Self.kindsAfter.contains(k) else { continue }
            // The kind word, then its name: `Werkstatt Sadowski`, `Kanzlei Eisenhut & Partner`, `BKK Hafenwerk`.
            var end = i
            while end + 1 < tokens.count, near(end + 1), isName(end + 1), end - i < 3, !Self.legalForms.contains(key(end + 1)) { end += 1 }
            // CAU-205: a role before a name is a person's (`Steuerberater Frau Quellbach`, `Notar Torvak`): the role
            // stays visible (N2). Only with a firm's sign after it is it a company: `Steuerberater Torvak & Partner`.
            let firm = end > i && (i + 1...end).contains { tokens[$0].gap.contains("&") || Ordinary.isKindWord(tokens[$0].text) && !Ordinary.isRole(tokens[$0].text) }
            if Ordinary.isRole(tokens[i].text), !firm { continue }
            if end > i { add(i, end, .kindWord) }
            // The name, then its kind: `Weserland BKK`.
            if Self.kindsAfter.contains(k), i > 0, near(i), isName(i - 1), !Ordinary.isKindWord(tokens[i - 1].text) { add(i - 1, i, .kindWord) }
        }
        for tag in read.tagged where tag.kind == .organization {
            let inside = read.tokens.indices.filter { tag.range.overlaps(read.tokens[$0].range) }
            for piece in Self.pieces(of: inside, { read.tokens[$0].text }) {
                guard let first = piece.first, let last = piece.last else { continue }
                let range = read.tokens[first].range.lowerBound..<read.tokens[last].range.upperBound
                let at = read.offset(range)
                out.append(Gate.Candidate(kind: .organization, text: String(read.text[range]), field: field, start: at.start, length: at.length,
                                          evidence: [.tagger], rule: .N6))
            }
        }
        return out
    }

    // MARK: N7 · a sender

    /// The shown name of a sender is a name when it is two words or more, or has a legal form, or
    /// the list knows it as a name and the dictionary does not know it in lowercase, or the address
    /// carries it. A one-word shown name the dictionary knows is no person (`Krankenkasse <…>`); the
    /// address is found by its own rule (S1).
    func sender(_ line: String, field: Entity.Field) -> [Gate.Admitted] {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var candidates = Shapes.candidates(in: line, field: field)
        if let name = Email.displayName(in: line) {
            let at = (line as NSString).range(of: name)
            let parts = Pseudonymizer.words(name)
            let legal = CompanyForm.looksIncorporated(name) && !(parts.count == 1 && Ordinary.isKindWord(name))
            let kind = parts.count >= 2 && parts.contains(where: Ordinary.isKindWord)
            var person = parts.count >= 2 || legal
            // One word: the cheap tests first, the list last, so a list is loaded only for a word
            // that passes every other (F020 AC-17).
            // N7 is the sender's: a recipient's shown name is learned as before (F020 AC-13).
            if !person, field != .from { person = true }
            if !person {
                person = CompanyForm.addressParts(of: line).contains(Pseudonymizer.key(name))
                    || Ordinary.knows(name, words: words) != true
                    || Ordinary.knowsLower(name, words: words) != true && opinion.mayBeName(name)
            }
            if person, at.location != NSNotFound {
                let company = legal || kind
                candidates.append(Gate.Candidate(kind: company ? .organization : .person, text: name, field: field, start: at.location,
                                                 length: at.length, evidence: legal ? [.legalForm] : kind ? [.kindWord] : [.sender], rule: .N7))
            }
        }
        return Self.resolvingOverlaps(candidates.compactMap { Gate.admit($0, typed: false, words: words) })
    }

    // MARK: The tagger

    struct Tagged { var kind: Entity.Kind; var range: Range<String.Index> }

    /// On iPhone, Apple's name tagger stays empty for the whole process when it is used before its
    /// language models are asked for. No error, just no names (probes on an iPhone 15 Pro, iOS 27.0.1,
    /// 19 November 2026). So the models of the languages it reads (N8: German and English) are asked
    /// for once, before the first tagging, and waited for, at most three seconds. If they don't answer
    /// in time, tagging goes on as before.
    static let modelsAsked: Bool = {
        let languages: [NLLanguage] = [.german, .english]
        askedLock.lock(); askedLanguages = languages; askedLock.unlock()
        let group = DispatchGroup()
        for language in languages {
            group.enter()
            NLTagger.requestAssets(for: language, tagScheme: .nameType) { _, _ in group.leave() }
        }
        return group.wait(timeout: .now() + 3) == .success
    }()

    /// The languages whose models were asked for, in the one-time setup above.
    static var asked: [NLLanguage] { askedLock.lock(); defer { askedLock.unlock() }; return askedLanguages }
    private static let askedLock = NSLock()
    nonisolated(unsafe) private static var askedLanguages: [NLLanguage] = []

    /// N8: each paragraph in its own language when German or English is clear, German when it is
    /// not; paragraphs of one language read together, as the tagger reads that run alone.
    func tagged(_ text: String) -> [Tagged] {
        _ = Self.modelsAsked
        var out: [Tagged] = []
        for (range, language) in Self.runs(of: text, main: language ?? Self.language(of: text), forced: language != nil) {
            let part = String(text[range])
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = part
            tagger.setLanguage(language, range: part.startIndex..<part.endIndex)
            tagger.enumerateTags(in: part.startIndex..<part.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]) { tag, found in
                let kind: Entity.Kind? = switch tag {
                case .personalName?: .person
                case .placeName?: .place
                case .organizationName?: .organization
                default: nil
                }
                guard let kind else { return true }
                let lower = text.index(range.lowerBound, offsetBy: part.distance(from: part.startIndex, to: found.lowerBound))
                let upper = text.index(lower, offsetBy: part.distance(from: found.lowerBound, to: found.upperBound))
                out.append(Tagged(kind: kind, range: lower..<upper))
                return true
            }
            // German read once more by the English tagger, for people only, and only one word right
            // after the words that stand before a person: `bei Manuela`, `dann zu Gretl`.
            guard language == .german else { continue }
            let english = NLTagger(tagSchemes: [.nameType])
            english.string = part
            english.setLanguage(.english, range: part.startIndex..<part.endIndex)
            english.enumerateTags(in: part.startIndex..<part.endIndex, unit: .word, scheme: .nameType,
                                  options: [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]) { tag, found in
                guard tag == .personalName else { return true }
                var found = found
                if let space = part[found].lastIndex(of: " ") { found = part.index(after: space)..<found.upperBound }
                let before = part[..<found.lowerBound].split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
                guard part[found].first?.isUppercase == true, ["bei", "zu", "mit", "an", "von", "für", "und"].contains(before) else { return true }
                let lower = text.index(range.lowerBound, offsetBy: part.distance(from: part.startIndex, to: found.lowerBound))
                let upper = text.index(lower, offsetBy: part.distance(from: found.lowerBound, to: found.upperBound))
                if !out.contains(where: { $0.range.overlaps(lower..<upper) && $0.kind == .person }) { out.append(Tagged(kind: .person, range: lower..<upper)) }
                return true
            }
        }
        return out
    }

    /// German or English when the recognizer is more than half sure; German otherwise.
    static func language(of text: String) -> NLLanguage {
        clearLanguage(of: text) ?? .german
    }

    static func clearLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.dominantLanguage, best == .german || best == .english,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[best], confidence > 0.5 else { return nil }
        return best
    }

    /// The paragraphs, each with its language (its own when clear and at least 20 letters long, else
    /// the text's), joined into runs of one language.
    static func runs(of text: String, main: NLLanguage, forced: Bool) -> [(Range<String.Index>, NLLanguage)] {
        if forced { return [(text.startIndex..<text.endIndex, main)] }
        var out: [(Range<String.Index>, NLLanguage)] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let paragraph = text[start..<end]
            var language = main
            if paragraph.filter(\.isLetter).count >= 20, let clear = clearLanguage(of: String(paragraph)) { language = clear }
            let upper = end < text.endIndex ? text.index(after: end) : end
            if let last = out.last, last.1 == language { out[out.count - 1] = (last.0.lowerBound..<upper, language) }
            else { out.append((start..<upper, language)) }
            start = upper
        }
        return out.isEmpty ? [(text.startIndex..<text.endIndex, main)] : out
    }

    // MARK: Overlaps

    /// The longest span wins; at the same length, the rule that comes first in How's table.
    static func resolvingOverlaps(_ found: [Gate.Admitted]) -> [Gate.Admitted] {
        let order = Gate.Rule.allCases
        let sorted = found.sorted {
            if $0.entity.length != $1.entity.length { return $0.entity.length > $1.entity.length }
            // A shape is never a name: at the same length, `COBADEFFXXX` after `BIC` is S1's, not N4's.
            let shapes: Set<Gate.Rule> = [.S1, .S2, .S3, .S4, .C1]
            if shapes.contains($0.rule) != shapes.contains($1.rule) { return shapes.contains($0.rule) }
            // The same digits after `Kontonummer:` are the account's, not a phone's: a shape loses to a label.
            if ($0.entity.kind == .phone) != ($1.entity.kind == .phone) { return $1.entity.kind == .phone }
            if $0.rule != $1.rule { return order.firstIndex(of: $0.rule)! < order.firstIndex(of: $1.rule)! }
            return $0.entity.start < $1.entity.start
        }
        var kept: [Gate.Admitted] = []
        for item in sorted {
            // A name read out of a file's name has no length of its own and overlaps nothing.
            if item.entity.length > 0, kept.contains(where: { $0.entity.field == item.entity.field && $0.entity.length > 0 && $0.entity.range.overlaps(item.entity.range) }) { continue }
            kept.append(item)
        }
        return kept.sorted { $0.entity.start < $1.entity.start }
    }
}
