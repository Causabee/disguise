import Foundation
import Testing
@testable import Disguise

/// Entities are made by hand here rather than by the detector, so these tests hold the disguise
/// to what it does with what it is given — not to what the tagger happens to find on this OS.
private func found(_ kind: Entity.Kind, _ text: String, by source: Entity.Source = .rule) -> Entity {
    Entity(kind: kind, text: text, field: .body, start: 0, length: (text as NSString).length, source: source)
}

private func learned(_ mode: Pseudonymizer.Mode, _ entities: [Entity]) -> Pseudonymizer {
    var pseudonymizer = Pseudonymizer(mode: mode)
    pseudonymizer.learn(entities)
    return pseudonymizer
}

@Suite("Disguising a mail before it leaves the device")
struct PseudonymizerTests {
    let hausverwaltung = [
        found(.person, "Sibylle Ferber", by: .onDevice),
        found(.organization, "Hausverwaltung Ferber GmbH"),
        found(.street, "Honigtauer Str. 14"),
        found(.postalCity, "10437 Berlin"),
        found(.email, "a.ferber@ferber-hv.example"),
        found(.phone, "030 0471 2288"),
        found(.iban, "DE89 3704 0044 0532 0130 00"),
    ]

    let letter = """
    Sehr geehrte Frau Ferber,
    die Begehung in der Honigtauer Str 51 ist am 9. Oktober. WEG Honigtauer, 10437 Berlin.
    Rückfragen an a.ferber@ferber-hv.example oder 030 0471 2288, IBAN DE89 3704 0044 0532 0130 00.
    Berlin, im September. Sibylle Ferber, Hausverwaltung Ferber GmbH
    """

    @Test("Nothing that was learned survives, in either mode", arguments: Pseudonymizer.Mode.allCases)
    func nothingSurvives(mode: Pseudonymizer.Mode) {
        let out = learned(mode, hausverwaltung).disguiser.apply(letter).text
        for word in ["Ferber", "Sibylle", "Honigtauer", "Berlin", "10437", "ferber-hv", "0471", "0532"] {
            #expect(!out.contains(word), "\(word) reached the disguised text: \(out)")
        }
    }

    @Test("A product read as a person does not lend its last word to every title: “Head of Design System” comes back as it went")
    func aProductIsNotAPerson() {
        // Learned now, "Design" is no one's surname.
        var fresh = Pseudonymizer(mode: .placeholder, entries: [])
        fresh.learn(.person, "Claude Design")
        let title = "I'm interviewing for the Head of Design System role."
        #expect(fresh.restore(fresh.disguiser.apply(title).text) == title)
        // Learned before, as it stands in a name list made by an earlier version: dropped when the list is read.
        let old = [Pseudonymizer.Entry(kind: .person, original: "Claude Design", standIn: "[Person SH]"),
                   Pseudonymizer.Entry(kind: .person, original: "Design", standIn: "[Person SH]", partOf: "Claude Design"),
                   Pseudonymizer.Entry(kind: .person, original: "Sibylle Ferber", standIn: "[Person A]"),
                   Pseudonymizer.Entry(kind: .person, original: "Ferber", standIn: "[Person A]", partOf: "Sibylle Ferber")]
        #expect(Pseudonymizer.withoutWordsAtTheEnd(old + [Pseudonymizer.Entry(kind: .person, original: "Jan Philipp Bossmann", standIn: "[Person B]")])
            .map(\.original) == ["Sibylle Ferber", "Ferber", "Jan Philipp Bossmann"])
    }

    @Test("Stand-ins: what comes back is exactly what went in")
    func roundTrip() {
        let pseudonymizer = learned(.standin, hausverwaltung)
        let disguised = pseudonymizer.disguiser.apply(letter).text
        #expect(disguised != letter)
        #expect(pseudonymizer.restore(disguised) == letter.precomposedStringWithCanonicalMapping)
    }

    /// `[Person A]` stood for `Sibylle Ferber` and for `Ferber`, so the way back cannot know
    /// which was written. It brings the fullest one, which is what a fact about a party wants.
    @Test("Placeholders: every tag comes back, as the fullest name it stood for")
    func placeholderRoundTrip() {
        let pseudonymizer = learned(.placeholder, hausverwaltung)
        let restored = pseudonymizer.restore(pseudonymizer.disguiser.apply(letter).text)
        #expect(!restored.contains("["))
        #expect(pseudonymizer.restore("[Person A] schreibt") == "Sibylle Ferber schreibt")
    }

    @Test("Placeholders: one tag for one person, and a Frau stays readable")
    func placeholderPerson() {
        let pseudonymizer = learned(.placeholder, hausverwaltung)
        let out = pseudonymizer.disguiser.apply("Sibylle Ferber. Frau Ferber. Ferber. Sibylle.").text
        #expect(out == "[Person A]. Frau [Person A]. [Person A]. [Person A].")
    }

    @Test("Three people known only with a title get three tags, not one")
    func titledPeopleApart() {
        // "Kurz" and "Post" are ordinary words and "Li" is short, so none is learned on its own;
        // the tag then stands only inside "Frau [Person A]" — and must still count as handed out.
        let pseudonymizer = learned(.placeholder, [found(.person, "Frau Kurz"), found(.person, "Herr Li"), found(.person, "Frau Post")])
        let tags = ["Frau Kurz", "Herr Li", "Frau Post"].map { pseudonymizer.disguiser.apply($0).text }
        #expect(Set(tags).count == 3, "\(tags)")
        #expect(pseudonymizer.restorer.apply(tags[0]).text == "Frau Kurz")
        #expect(pseudonymizer.restorer.apply(tags[2]).text == "Frau Post")
    }

    @Test("A shared tag comes back as the plainest full name, not the longest")
    func plainestNameComesBack() {
        let pseudonymizer = learned(.placeholder, [
            found(.person, "Jan Spengler via TestFlight"),
            found(.person, "Frau Spengler"),
            found(.person, "Jan Spengler"),
            found(.person, "Rubin Keller Contractor"),
            found(.person, "Rubin Keller"),
        ])
        let me = pseudonymizer.standIn(for: "Jan Spengler") ?? ""
        let ronnie = pseudonymizer.standIn(for: "Rubin Keller") ?? ""
        #expect(pseudonymizer.restore(me) == "Jan Spengler")
        #expect(pseudonymizer.restore(ronnie) == "Rubin Keller")
        #expect(pseudonymizer.standIn(for: "Jan Spengler via TestFlight") == "\(me) via [Company A]")
    }

    @Test("A company's name is learned without its legal form")
    func companyWithoutLegalForm() {
        let entities = [found(.organization, "Thermotec Kubiak GmbH")]
        for mode in Pseudonymizer.Mode.allCases {
            let out = learned(mode, entities).disguiser.apply("das Angebot von Thermotec Kubiak").text
            #expect(!out.contains("Thermotec"), "\(mode): \(out)")
        }
    }

    @Test("Stand-ins keep the shape: the title, the legal form, the kind of business, the house number")
    func standInShape() throws {
        let pseudonymizer = learned(.standin, hausverwaltung + [found(.person, "Moreno, Valentina")])

        let frau = try #require(pseudonymizer.disguiser.apply("Frau Ferber").text.split(separator: " ").map(String.init))
        #expect(frau.count == 2 && frau[0] == "Frau")

        let company = try #require(pseudonymizer.standIn(for: "Hausverwaltung Ferber GmbH"))
        #expect(company.hasPrefix("Hausverwaltung ") && company.hasSuffix(" GmbH"))
        // The company was named after the person, and in disguise it still is.
        #expect(company.split(separator: " ")[1] == frau[1])

        let street = try #require(pseudonymizer.standIn(for: "Honigtauer Str. 14"))
        #expect(street.contains(" Str. ") && street.last?.isNumber == true && !street.hasSuffix(" 51"))

        #expect(pseudonymizer.standIn(for: "Moreno, Valentina")?.contains(", ") == true)
    }

    @Test("A stand-in is never one of the originals, even when the original is in the pool")
    func standInIsNeverAnOriginal() {
        let entities = [found(.person, "Sigrun Ahlers"), found(.person, "Julian Brandt"), found(.person, "Ina Goetz")]
        let pseudonymizer = learned(.standin, entities)
        let originals = Set(entities.flatMap { $0.text.split(separator: " ").map(String.init) })
        for entry in pseudonymizer.entries {
            for word in entry.standIn.split(separator: " ") {
                #expect(!originals.contains(String(word)), "\(entry.original) became \(entry.standIn)")
            }
        }
    }

    @Test("Numbers keep their shape and lose their digits")
    func numbers() throws {
        let pseudonymizer = learned(.standin, hausverwaltung + [found(.phone, "+49 30 09778110")])
        let phone = try #require(pseudonymizer.standIn(for: "030 0471 2288"))
        #expect(phone.hasPrefix("03") && phone.count == "030 0471 2288".count && phone != "030 0471 2288")
        #expect(try #require(pseudonymizer.standIn(for: "+49 30 09778110")).hasPrefix("+49 "))
        // Written without a space, it once kept every digit and never came back.
        let unspaced = learned(.standin, [found(.phone, "+493009778110")]).standIn(for: "+493009778110")
        #expect(unspaced?.hasPrefix("+49") == true && unspaced != "+493009778110")
        let iban = try #require(pseudonymizer.standIn(for: "DE89 3704 0044 0532 0130 00"))
        #expect(iban.hasPrefix("DE") && iban.count == 27 && iban != "DE89 3704 0044 0532 0130 00")
    }

    @Test("A lowercase surname or a `von` does not make a name a sentence")
    func lowercaseInsideAName() {
        let pseudonymizer = learned(.placeholder, [
            found(.person, "Elisa ueckerhof", by: .onDevice),
            found(.person, "Julian von Elmhorst", by: .onDevice),
            found(.person, "wendgard kurtz"),
        ])
        #expect(pseudonymizer.standIn(for: "Elisa ueckerhof") != nil)
        #expect(pseudonymizer.standIn(for: "Julian von Elmhorst") != nil)
        #expect(pseudonymizer.disguiser.apply("Herr Kurtz").text == "Herr [Person C]")
    }

    @Test("A surname the tagger rarely finds alone is still learned from a full name")
    func partsAreNotOutvoted() {
        let prose = String(repeating: "Hausmeister Bittner kommt. Bittner sagt. ", count: 10)
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        pseudonymizer.learn([found(.person, "Alfred Bittner", by: .onDevice)], vocabulary: Vocabulary([prose]))
        #expect(pseudonymizer.standIn(for: "Bittner") != nil)
    }

    @Test("A title is never learned as a name, not even out of a company's")
    func titleIsNeverAName() {
        let pseudonymizer = learned(.placeholder, [found(.organization, "Frau e.V."), found(.person, "Abend Frau", by: .onDevice)])
        #expect(pseudonymizer.standIn(for: "Frau e.V.") != nil)
        #expect(pseudonymizer.disguiser.apply("Liebe Frau Weber").text == "Liebe Frau Weber")
    }

    @Test("What a rule found is trusted however rarely the tagger agrees")
    func rulesAreNotOutvoted() {
        let prose = String(repeating: "WEG Honigtauer. ", count: 20)
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        pseudonymizer.learn([found(.street, "Honigtauer Str. 14")], vocabulary: Vocabulary([prose]))
        #expect(pseudonymizer.standIn(for: "Honigtauer") != nil)
    }

    @Test("A rule's find is never skipped, however short")
    func rulesAreTrusted() {
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        #expect(pseudonymizer.learn([found(.organization, "WEG AG")]).isEmpty)
        #expect(pseudonymizer.standIn(for: "WEG AG") != nil)
    }

    @Test("Whole words only, whatever the case, however the umlaut was encoded")
    func matching() {
        let pseudonymizer = learned(.placeholder, [found(.person, "Patrick Schüßler")])
        let decomposed = "Herr Schu\u{0308}ßler, SCHÜßLER und die Ferberstraße"
        #expect(pseudonymizer.disguiser.apply(decomposed).text == "Herr [Person A], [Person A] und die Ferberstraße")
    }

    @Test("A mapping read back carries on where it stopped")
    func mappingCarriesOn() throws {
        let first = learned(.placeholder, [found(.person, "Sibylle Ferber")])
        let data = try JSONEncoder().encode(first.entries)
        var second = Pseudonymizer(mode: .placeholder, entries: try JSONDecoder().decode([Pseudonymizer.Entry].self, from: data))
        second.learn([found(.person, "Krzysztof Warnecki"), found(.person, "Sibylle Ferber")])
        #expect(second.standIn(for: "Sibylle Ferber") == "[Person A]")
        #expect(second.standIn(for: "Krzysztof Warnecki") == "[Person B]")
    }

    @Test("The same folder gives the same stand-ins every time")
    func deterministic() {
        #expect(learned(.standin, hausverwaltung).entries == learned(.standin, hausverwaltung).entries)
    }

    @Test("A person and their company in one display name are learned as each")
    func displayNameWithCompany() {
        let pseudonymizer = learned(.placeholder, [found(.person, "Schüßler, Patrick (Radwerk Berlin GmbH)")])
        let out = pseudonymizer.disguiser.apply("Schüßler, Patrick (Radwerk Berlin GmbH) und Radwerk Berlin").text
        #expect(!out.contains("Schüßler") && !out.contains("Radwerk"))
    }
}

@Suite("The pipeline with a disguise in it")
struct DisguisedSpikeTests {
}

@Suite("Two people with one name in common are still two people")
struct SharedNameTests {
    let people = [
        found(.person, "Patrick Ahlers"),
        found(.person, "Patrick Schüßler"),
        found(.person, "Jan Spengler"),
        found(.person, "Lotta Spengler"),
        found(.person, "Herr Ahlers"),
        found(.person, "Ahlers, Patrick"),
    ]

    @Test("Each full name has its own tag; the same first and last name share one")
    func ownTags() throws {
        let p = learned(.placeholder, people)
        let ahlers = try #require(p.standIn(for: "Patrick Ahlers"))
        #expect(p.standIn(for: "Patrick Schüßler") != ahlers)
        #expect(p.standIn(for: "Lotta Spengler") != p.standIn(for: "Jan Spengler"))
        #expect(p.standIn(for: "Ahlers, Patrick") == ahlers)
        #expect(p.standIn(for: "Herr Ahlers") == "Herr \(ahlers)")
        #expect(learned(.placeholder, people + [found(.person, "'Jan Spengler'")]).standIn(for: "'Jan Spengler'")
                == p.standIn(for: "Jan Spengler"))
    }

    @Test("Each one comes back as who they were, and a shared word alone comes back as itself")
    func wayBack() {
        let p = learned(.placeholder, people)
        let text = "Patrick Schüßler und Patrick Ahlers. Meine Mutter Lotta Spengler, ich Jan Spengler. Hallo Patrick, Familie Spengler"
        let disguised = p.disguiser.apply(text).text
        for word in ["Patrick", "Schüßler", "Ahlers", "Lotta", "Spengler", "Jan"] {
            #expect(!disguised.contains(word), "\(word) reached the disguised text: \(disguised)")
        }
        #expect(p.restore(disguised) == text)
    }

    @Test("A shared first name next to the full name comes back once, not twice")
    func noDoubleName() {
        let p = learned(.placeholder, [found(.person, "Martina Lechner"), found(.person, "Martina Hiller"),
                                       found(.person, "Dr. Martina")])
        let disguised = p.disguiser.apply("Dr. Martina\u{00A0}Lechner").text
        #expect(!disguised.contains("Martina"))
        let cornelia = p.standIn(for: "Martina") ?? "", harz = p.standIn(for: "Martina Lechner") ?? ""
        #expect(p.restore("Dr. \(cornelia) \(harz)") == "Dr. Martina Lechner")
        #expect(p.restore("\(harz) \(p.standIn(for: "Lechner") ?? "")") == "Martina Lechner")
        #expect(p.restore("\(cornelia) und \(harz)") == "Martina und Martina Lechner")
    }

    @Test("A caretaker is a role, not a first name: the word stays readable and the name comes back alone")
    func roleIsNotAName() {
        let p = learned(.placeholder, [found(.person, "Hausmeister Bittner"), found(.street, "Honigtauer Str. 14")])
        let out = p.disguiser.apply("Der Hausmeister kommt. Herr Bittner und Hausmeister Bittner.").text
        #expect(out.hasPrefix("Der Hausmeister kommt."))
        #expect(!out.contains("Bittner"))
        let tag = p.standIn(for: "Bittner") ?? "?"
        #expect(p.restore("Herr \(tag)") == "Herr Bittner")
        let street = p.standIn(for: "Honigtauer Str. 14") ?? "?"
        #expect(p.restore("Treffen in der \(street) 14, 10437") == "Treffen in der Honigtauer Str. 14, 10437")
        #expect(p.restore("\(street) 142") == "Honigtauer Str. 14 142")
    }

    @Test("A name typed without its umlaut or its ß is still disguised")
    func otherSpellings() {
        let p = learned(.placeholder, [found(.person, "Patrick Schüßler"), found(.person, "Alf Hüttenberger"), found(.person, "Egbert Gross")])
        let out = p.disguiser.apply("bei Herrn Schüssler, Herr Huettenberger und Herr Schuessler. Das ist groß.").text
        for word in ["Schüssler", "Huettenberger", "Schuessler"] { #expect(!out.contains(word), "\(word): \(out)") }
        #expect(out.hasSuffix("Das ist groß."))
        #expect(p.restore(p.disguiser.apply("Herrn Schüssler").text) == "Herrn Patrick Schüßler")
    }

    @Test("A name learned with quote marks is disguised without them; kurz the word stays")
    func quotedAndLowercase() {
        let p = Pseudonymizer(mode: .placeholder, entries: [
            .init(kind: .person, original: "'Kurz, Hella'", standIn: "[Person A]"),
            .init(kind: .person, original: "'Kurz", standIn: "[Person A]", partOf: "'Kurz, Hella'"),
        ])
        let out = p.disguiser.apply("Sehr geehrte Frau Kurz, ich frage kurz nach.").text
        #expect(out == "Sehr geehrte Frau [Person A], ich frage kurz nach.")
    }

    @Test("An old mapping that merged them is repaired when it is read")
    func upgrade() {
        var mapping = Pseudonymizer.Mapping()
        mapping.version = 1
        mapping.placeholder = [
            .init(kind: .person, original: "Patrick Ahlers", standIn: "[Person A]"),
            .init(kind: .person, original: "Patrick", standIn: "[Person A]", partOf: "Patrick Ahlers"),
            .init(kind: .person, original: "Ahlers", standIn: "[Person A]", partOf: "Patrick Ahlers"),
            .init(kind: .person, original: "Patrick Schüßler", standIn: "[Person A]"),
            .init(kind: .person, original: "Schüßler", standIn: "[Person A]", partOf: "Patrick Schüßler"),
            .init(kind: .place, original: "Berlin", standIn: "[Place A]"),
        ]
        #expect(mapping.upgrade() > 0)
        #expect(mapping.version == Pseudonymizer.Mapping.current)
        let p = Pseudonymizer(mode: .placeholder, entries: mapping.placeholder)
        #expect(p.standIn(for: "Patrick Ahlers") != p.standIn(for: "Patrick Schüßler"))
        #expect(p.standIn(for: "Berlin") == "[Place A]")
        #expect(p.restore(p.disguiser.apply("Patrick Schüßler").text) == "Patrick Schüßler")
        #expect(mapping.upgrade() == 0)
    }

    @Test("Version 2 to 3 changes only the entries with a role in them")
    func rolesUpgrade() {
        var mapping = Pseudonymizer.Mapping()
        mapping.version = 2
        mapping.placeholder = [
            .init(kind: .person, original: "Patrick Schüßler", standIn: "[Person A]"),
            .init(kind: .person, original: "Hausmeister Bittner", standIn: "[Person B]"),
            .init(kind: .person, original: "Hausmeister", standIn: "[Person B]", partOf: "Hausmeister Bittner"),
            .init(kind: .person, original: "Bittner", standIn: "[Person B]", partOf: "Hausmeister Bittner"),
        ]
        #expect(mapping.upgrade() == 2)
        let p = Pseudonymizer(mode: .placeholder, entries: mapping.placeholder)
        #expect(p.standIn(for: "Patrick Schüßler") == "[Person A]")
        #expect(p.standIn(for: "Hausmeister") == nil)
        #expect(p.disguiser.apply("Hausmeister Bittner").text == "Hausmeister [Person B]")
        #expect(p.restore("Herr [Person B]") == "Herr Bittner")
    }
}
