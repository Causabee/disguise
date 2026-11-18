import Foundation
import NaturalLanguage
import Testing
@testable import Disguise

/// A dictionary that knows exactly these words — or nothing at all (`nil`).
struct StubWords: WordKnowledge {
    var known: Set<String>?
    func knows(_ word: String) -> Bool? { known.map { $0.contains(word) || $0.contains(word.lowercased()) } }
}

/// Name lists that hold exactly these words; `nil`: the list cannot be read.
struct StubNames: NameKnowing {
    var first: Set<String>? = []
    var last: Set<String>? = []
    func isFirstName(_ word: String) -> Bool? { first.map { $0.contains(Pseudonymizer.key(word)) } }
    func isSurname(_ word: String) -> Bool? { last.map { $0.contains(Pseudonymizer.key(word)) } }
}

/// Counts how often it is asked, to see that a mail that needs no list never loads one.
final class CountingNames: NameKnowing, @unchecked Sendable {
    let inner = NameKnowledge()
    private(set) var asked = 0
    func isFirstName(_ word: String) -> Bool? { asked += 1; return inner.isFirstName(word) }
    func isSurname(_ word: String) -> Bool? { asked += 1; return inner.isSurname(word) }
}

@Suite("F020 · The sender fix and the shipped lists")
struct CleanListRulesTests {
    static let ordinary = StubWords(known: ["Krankenkasse", "Fahrdienst", "Sonntag", "Apple", "Wolf", "Hirsch"])

    func detector(_ words: any WordKnowledge = Self.ordinary, _ names: any NameKnowing = StubNames(last: ["sonntag", "berger"])) -> RuleFinder {
        var detector = RuleFinder(runsTagger: false)
        detector.words = words
        detector.opinion = SecondOpinion(lists: names)
        return detector
    }


    func names(_ email: Email, _ detector: RuleFinder, field: Entity.Field = .from) -> [String] {
        detector.entities(in: email).filter { $0.field == field && $0.kind != .email }.map(\.text)
    }



}

extension CleanListRulesTests {
    #if DEBUG
    static let build = "debug"
    #else
    static let build = "release"
    #endif
}

/// F020 AC-18, AC-19: the rule fixes (3) and (4) of 3-spec.md. The real tagger, stub dictionaries
/// and lists, made-up text.
@Suite("F020 · A lone ordinary word, and each paragraph in its own language")
struct LoneWordAndLanguageTests {
    static let words = StubWords(known: ["fragen", "kessel", "sonntag", "wolf", "graf", "verfügung", "kasse", "fahrdienst"])
    static let names = StubNames(first: ["anja", "mehmet"], last: ["sonntag", "berger"])

    func detector(_ words: any WordKnowledge = Self.words, _ names: any NameKnowing = Self.names, drops: Bool = true,
                  language: NLLanguage? = nil) -> RuleFinder {
        var detector = RuleFinder(language: language)
        detector.words = words
        detector.opinion = SecondOpinion(lists: names)
        detector.typed = !drops
        return detector
    }

    func people(_ text: String, _ detector: RuleFinder) -> [String] {
        detector.entities(in: text, field: .body).filter { $0.kind == .person }.map(\.text)
    }

    static let closing = "Guten Tag,\nanbei die Unterlagen. Bei Fragen stehe ich gern zur Verfügung.\nMit freundlichen Grüßen"

    @Test("F020 AC-18 · „Bei Fragen stehe ich gern zur Verfügung“: the tagger's lone „Fragen“ is not learned")
    func fragen() {
        #expect(people(Self.closing, detector(drops: false)).contains("Fragen"), "the tagger takes it for a person today")
        #expect(!people(Self.closing, detector()).contains("Fragen"))
    }

    @Test("F020 AC-18 · learned as before: two words, a listed word, a word after a title, a word the dictionary does not know small")
    func asBefore() {
        for text in ["Morgen kommt Anja Sonntag vorbei.", "Das Paket liegt bei Sonntag im Flur.", "Bitte Frau Graf anrufen.",
                     "Bitte Frau Kessel anrufen.", "Heute kam Mehmet vorbei, wegen der Heizung."] {
            #expect(people(text, detector()) == people(text, detector(drops: false)), "\(text)")
        }
    }

    @Test("F020 AC-18 · no dictionary, or a list that cannot be read: „Fragen“ is learned as today")
    func failsTowardHiding() {
        let today = people(Self.closing, detector(drops: false))
        #expect(people(Self.closing, detector(StubWords(known: nil))) == today)
        #expect(people(Self.closing, detector(Self.words, StubNames(first: nil, last: nil))) == today)
    }

    @Test("F020 AC-18 · the filter only removes: what it keeps is what the tagger found")
    func onlyRemoves() {
        for text in [Self.closing, "Morgen kommt Anja Sonntag vorbei.", "Bei Fragen zu Herrn Wolf bitte melden."] {
            let all = detector(drops: false).entities(in: text, field: .body)
            let kept = detector().entities(in: text, field: .body)
            #expect(kept.allSatisfy { k in all.contains { $0.text == k.text && $0.start == k.start && $0.kind == k.kind } }, "\(text)")
        }
    }



    // AC-19. "Clearly German or English" reuses the > 0.5 of `EntityDetector.language(of:)`, with
    // at least 20 letters; any other reading keeps the whole text's language.

    static let note = "In diesen Fällen zahlt die Kasse den Fahrdienst."
    /// An English question over a matter's German notes and to-dos, as `prepare` joins them (the fixture's).
    static let notes = [
        "2026-11-12: Almuth Milde, geb. 04.09.57, braucht ab Dezember einen Fahrdienst zur Dialyse.",
        "2026-11-13: Erstattung des Betrages bei der Krankenkasse beantragen. In diesen Fällen zahlt die Kasse den Fahrdienst.",
        "Widerspruch gegen den Bescheid der Pflegekasse einlegen, Frist beachten",
        "Fahrdienst bei der Krankenkasse beantragen",
        "Geburtsdatum und Versichertennummer an den Fahrdienst schicken",
        "Rechnung des Sanitätshauses über den Rollator prüfen",
    ]

    @Test("F020 AC-19 · an English question over German notes: each German note learns what the German tagger learns of it alone; no „Kasse den Fahrdienst“")
    func germanNote() {
        let text = (["Draft an email to the insurance about the payment of 13 November."] + Self.notes).joined(separator: "\n")
        let all = detector(drops: false).entities(in: text, field: .body)
        #expect(!all.contains { $0.kind == .person && ($0.text.contains("Fahrdienst") || $0.text.contains("Kasse")) }, "\(all.map(\.text))")
        for note in Self.notes where note.filter(\.isLetter).count >= 20 {
            let at = (text as NSString).range(of: note)
            let inNote = all.filter { $0.start >= at.location && $0.start < at.location + at.length && $0.source == .onDevice }.map(\.text)
            let alone = detector(drops: false, language: .german).entities(in: note, field: .body).filter { $0.source == .onDevice }.map(\.text)
            #expect(Set(inNote) == Set(alone), "\(note): in the text \(inNote), alone \(alone)")
        }
    }

    @Test("F020 AC-19 · a German text with a line of names and numbers stays German; a text in one language is read as today")
    func oneLanguage() {
        let german = "Sehr geehrte Frau Berger,\nAnja Sonntag 0171 1234567 Mehmet Yilmaz\nwir melden uns wegen der Heizung am Montag bei Ihnen."
        #expect(people(german, detector(drops: false)) == people(german, detector(drops: false, language: .german)))
        #expect(people(Self.note, detector(drops: false)) == people(Self.note, detector(drops: false, language: .german)))
        let english = "Hi Ralf,\nthe meeting with Jonathan Pryce moved to Tuesday. Margaret will send the notes afterwards."
        #expect(people(english, detector(drops: false)) == people(english, detector(drops: false, language: .english)))
    }
}

extension LoneWordAndLanguageTests {
    @Test("F020 AC-18 · with the real lists: „Bei“ is a first name somewhere, but a word on today's lists before „Fragen“ is no first name")
    func realLists() {
        var real = RuleFinder()
        real.opinion = SecondOpinion(lists: NameKnowledge())
        #expect(NameKnowledge().isFirstName("Bei") == true, "the world-wide list holds it")
        #expect(!people(Self.closing, real).contains("Fragen") || SystemWords.shared.knows("fragen") != true)
        #expect(people("Morgen kommt Anja Sonntag vorbei.", real) == people("Morgen kommt Anja Sonntag vorbei.", { var d = real; d.typed = true; return d }()))
    }
}
