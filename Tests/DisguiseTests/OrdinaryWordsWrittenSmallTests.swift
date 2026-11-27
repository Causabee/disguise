import Foundation
import Testing
@testable import Disguise

/// CAU-258 (the test bench, 27 November 2026): the second pass took ordinary words written small, and
/// typos of them, for names — in a chat screenshot, a typed line, a note, anything that comes in. The
/// ask could not be read, and the words came back as people. A word written small that is an ordinary
/// word, or one letter off one, is no name, unless a name list holds it or the text shows it as one.
/// Every name here is invented.
@Suite("CAU-258 · Ordinary words written small are no names", .serialized)
struct OrdinaryWordsWrittenSmallTests {
    static let words = SystemWords.shared

    @Test("CAU-258 · a chat full of typos: kanst, morgn, schlüssel, abhohlen go as written; the name after frau is still found")
    func typosInAChat() {
        let found = LookAlikeNames.find(in: "kanst du morgn bis 12 die schlüssel bei frau quellbrunn abhohlen?? sie is ab mittag weg", words: Self.words)
        for word in ["kanst", "morgn", "schlüssel", "abhohlen"] { #expect(!found.contains(word), "\(word) in \(found)") }
        #expect(found.contains("quellbrunn"), "\(found)")
    }

    @Test("CAU-258 · a title before a stand-in anchors no word after it: frau [Person C] abhohlen")
    func titleBeforeAStandIn() {
        let found = LookAlikeNames.find(in: "kanst du die schlüssel bei frau [Person C] abhohlen??", words: Self.words)
        #expect(found.isEmpty, "\(found)")
    }

    @Test("CAU-258 · a typed first line: umzug and dne go as written")
    func typoInAFirstLine() {
        let found = LookAlikeNames.find(in: "Der umzug ist für dne 3.4.2027 geplant", words: Self.words)
        #expect(found.isEmpty, "\(found)")
    }

    @Test("CAU-258 · names written small are still hidden: on a name list, read as a place, a street, or a word no dictionary knows")
    func namesWrittenSmallStay() {
        let cases: [(text: String, name: String)] = [
            ("kannst du morgen mit julian reden?", "julian"),
            ("ruf bitte müller wegen der rechnung an", "müller"),
            ("wir treffen uns am freitag in bremen", "bremen"),
            ("termin mit hollenbach morgen um 10", "hollenbach"),
            ("gruß an gesine", "gesine"),
            ("wegen der wohnung in der birkenstraße 4", "birkenstraße"),
            ("wir wohnen jetzt am schlehenweg", "schlehenweg"),
        ]
        for item in cases {
            let found = LookAlikeNames.find(in: item.text, words: Self.words)
            #expect(found.contains(item.name), "\(item.text) → \(found)")
        }
    }

    /// A dictionary in a table, with its guesses: the rule judged without the machine's own.
    struct Guessing: WordKnowledge {
        var known: Set<String>
        var offered: [String: [String]] = [:]
        func knows(_ word: String) -> Bool? { known.contains(word) }
        func guesses(_ word: String, language: String) -> [String] { offered[word] ?? [] }
    }

    @Test("CAU-258 · by a dictionary in a table: a typo goes; a name list that holds it, or cannot be read, keeps it hidden; after bei only a small word's typo goes")
    func byTable() {
        let words = Guessing(known: ["morgen", "den", "Umzug", "kurz", "bei", "für", "ist", "frag"],
                             offered: ["morgn": ["morgen", "Morgan"], "dne": ["den"], "kurtz": ["kurz"], "linnea": ["Linnen"]])
        let none = StubNames(first: [], last: [])
        #expect(LookAlikeNames.find(in: "morgn ist der umzug", words: words, names: none).isEmpty)
        // On a list: hidden, written small or not.
        #expect(LookAlikeNames.find(in: "morgn ist der umzug", words: words, names: StubNames(first: ["umzug"], last: [])) == ["umzug"])
        // A list that cannot be read says nothing: hidden (fails toward hiding).
        #expect(LookAlikeNames.find(in: "morgn ist der umzug", words: words, names: StubNames(first: nil, last: [])) == ["morgn", "umzug"])
        // After a word that stands before a person, the text shows a name; a small word's typo is still a typo.
        #expect(LookAlikeNames.find(in: "frag kurtz", words: words, names: none) == ["kurtz"])
        #expect(LookAlikeNames.find(in: "ist kurtz", words: words, names: none).isEmpty)
        #expect(LookAlikeNames.find(in: "für dne", words: words, names: none).isEmpty)
        // A guess with a capital, or more than one letter off, makes no typo.
        #expect(LookAlikeNames.find(in: "ist linnea", words: words, names: none) == ["linnea"])
        // Written with its capital, a word the dictionary does not know is the second pass's, as before.
        #expect(LookAlikeNames.find(in: "ist Kurtz", words: words, names: none) == ["Kurtz"])
    }

    @Test("CAU-258 · one letter off: added, left out, changed, or two swapped")
    func oneOff() {
        for (a, b) in [("morgn", "morgen"), ("kanst", "kannst"), ("abhohlen", "abholen"), ("dne", "den"), ("hsut", "hust")] {
            #expect(LookAlikeNames.oneOff(a, b), "\(a) \(b)")
        }
        for (a, b) in [("dne", "dne"), ("morgn", "morgan1"), ("ab", "ba1"), ("schule", "scheul")] {
            #expect(!LookAlikeNames.oneOff(a, b), "\(a) \(b)")
        }
    }

    /// The price of the rule, chosen openly (the owner's "a", 27 November 2026): a name written small that
    /// no list holds and that is one letter off an ordinary word goes out as written, unless a guard
    /// stands right before it. Pinned here so that a change to it is a conscious one. Invented names.
    static let leaks = Guessing(
        known: ["sehn", "sein", "marke", "kommst", "treffe", "morgen", "sagt", "frag", "bei", "mit", "für", "herr", "frau", "hallo", "und"],
        offered: ["sevn": ["sein", "Sven", "sehn"], "marle": ["Marke", "marke"]])

    @Test("CAU-258 · known leaks, by a dictionary in a table: an unlisted name one letter off a word goes out unless a guard stands right before it")
    func knownLeaks() {
        let none = StubNames(first: [], last: [])
        let rows: [(text: String, found: [String])] = [
            // Out as written: no guard before it. `hallo`, `an`, `und`, a quote, a colon, `@`, a chat line's time are no guards.
            ("hallo sevn, kommst du?", []),
            ("ich treffe marle morgen", []),
            ("gruß an marle", []),
            ("und sevn kommst", []),
            ("\"marle\" sagt ja", []),
            ("marle: kommst du", []),
            ("@marle kommst du", []),
            ("[12:01] marle: kommst du", []),
            // Hidden: a title or a word that stands before a person, right before it.
            ("frag marle", ["marle"]),
            ("bei marle", ["marle"]),
            ("mit marle", ["marle"]),
            ("frau marle", ["marle"]),
            ("herr marle", ["marle"]),
            // After a title, never excused, whatever it is one letter off.
            ("herr sevn", ["sevn"]),
            ("frau sevn", ["sevn"]),
            ("dr. sevn", ["sevn"]),
            ("prof. sevn", ["sevn"]),
            ("mrs sevn", ["sevn"]),
            ("mr sevn", ["sevn"]),
            // Out after a word that stands before a person: one letter off a small word (`sevn` → `sein`), as `für dne` is `für den`.
            ("bei sevn", []),
            ("für sevn", []),
        ]
        for row in rows {
            #expect(LookAlikeNames.find(in: row.text, words: Self.leaks, names: none) == row.found, "\(row.text)")
        }
        // On a list, the same names are hidden wherever they stand.
        let listed = StubNames(first: ["sevn", "marle"], last: [])
        #expect(LookAlikeNames.find(in: "hallo sevn, ich treffe marle morgen", words: Self.leaks, names: listed) == ["sevn", "marle"])
    }

    @Test("CAU-258 · the guards are exactly the titles and the words that stand before a person")
    func guards() {
        #expect(Ordinary.beforePerson == ["bei", "mit", "von", "für", "zu", "frag", "frage", "fragt", "sag", "sage", "sagt", "ruf", "rufe",
                                          "schreib", "schreibe", "grüß", "grüße", "hat", "hast", "meint", "ask", "tell", "call", "ring", "text"])
        for word in ["an", "und", "hallo", "and", "hi"] { #expect(!Ordinary.beforePerson.contains(word) && !Ordinary.isTitle(word), "\(word)") }
    }
}
