import Foundation
import Testing
@testable import Disguise

@Suite("Names hidden and put back, in the owner's own sentences")
struct NameRestoreTests {
    @Test("A name learned in capitals does not take the ordinary word")
    func shouted() {
        let pseudonymizer = Pseudonymizer(mode: .placeholder, entries: [
            .init(kind: .person, original: "BERLIN SONNE", standIn: "[Person A]"),
            .init(kind: .person, original: "SONNE", standIn: "[Person A]", partOf: "BERLIN SONNE"),
        ])
        let out = pseudonymizer.disguiser.apply("Die sonne scheint, SONNE steht im Briefkopf.").text
        #expect(out == "Die sonne scheint, [Person A] steht im Briefkopf.")
    }

    /// 17 November, F020 Proof: a scan read „10119 BERLIN“ as „10119 DER L/N“. The postal-city rule
    /// learned „DER“ as a place, and every „der“ in every send went out as `[Place A]` — on a list
    /// rebuilt with today's rules too. A small word — an article, a preposition, a pronoun — is no place.
    @Test("Fix · a place that is a small word does not take every „der“, in a list that already has it")
    func commonWordPlaceInTheList() {
        let pseudonymizer = Pseudonymizer(mode: .placeholder, entries: [
            .init(kind: .postalCity, original: "10119 DER", standIn: "[PLZ A] [Place A]"),
            .init(kind: .place, original: "DER", standIn: "[Place A]", partOf: "10119 DER"),
            .init(kind: .postalCity, original: "10119", standIn: "[PLZ A]", partOf: "10119 DER"),
            .init(kind: .postalCity, original: "10115 Berlin", standIn: "[PLZ B] [Place B]"),
            .init(kind: .place, original: "Berlin", standIn: "[Place B]", partOf: "10115 Berlin"),
            .init(kind: .place, original: "Haus", standIn: "[Place C]", partOf: "8967 Haus"),
        ])
        let out = pseudonymizer.disguiser.apply("Der Fahrdienst muss bei der Krankenkasse in Berlin gemeldet werden, DER Kunst.").text
        #expect(out == "Der Fahrdienst muss bei der Krankenkasse in [Place B] gemeldet werden, DER Kunst.")
        #expect(pseudonymizer.disguiser.apply("Urlaub in Haus im Ennstal").text == "Urlaub in [Place C] im Ennstal")
        #expect(pseudonymizer.disguiser.apply("WEG Fehrbelliner Str. 51, 10119 DER L/N").text.contains("[PLZ A]"), "the code is still hidden")
    }

    @Test("Fix · a postal city whose town is a small word teaches the code, not the word")
    func commonWordPlaceLearned() {
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        _ = pseudonymizer.learn([Entity(kind: .postalCity, text: "10119 DER", field: .body, start: 0, length: 9, source: .rule)])
        #expect(!pseudonymizer.entries.contains { $0.kind == .place && Pseudonymizer.key($0.original) == "der" })
        #expect(pseudonymizer.standIn(for: "10119") != nil)
        #expect(pseudonymizer.disguiser.apply("und der Fahrdienst").text == "und der Fahrdienst")
        var berlin = Pseudonymizer(mode: .placeholder)
        _ = berlin.learn([Entity(kind: .postalCity, text: "10115 Berlin", field: .body, start: 0, length: 12, source: .rule)])
        #expect(berlin.standIn(for: "Berlin") != nil, "a real town is still a place")
        // The owner, 17 November: "Yes, small words" — only articles, prepositions and pronouns.
        var den = Pseudonymizer(mode: .placeholder)
        _ = den.learn([Entity(kind: .postalCity, text: "10119 DEN", field: .body, start: 0, length: 9, source: .rule)])
        #expect(den.disguiser.apply("mit den Unterlagen").text == "mit den Unterlagen")
        var haus = Pseudonymizer(mode: .placeholder)
        _ = haus.learn([Entity(kind: .postalCity, text: "8967 Haus", field: .body, start: 0, length: 9, source: .rule)])
        #expect(haus.standIn(for: "Haus") != nil, "a town that is a noun, Haus in Austria, is still a place")
    }

    @Test("Last name first comes back as first name first, and beside the surname tag it is one name")
    func surnameFirst() {
        let pseudonymizer = Pseudonymizer(mode: .placeholder, entries: [
            .init(kind: .person, original: "Lindner, Petra", standIn: "[Person A]"),
            .init(kind: .person, original: "Petra", standIn: "[Person A]", partOf: "Lindner, Petra"),
            .init(kind: .person, original: "Lindner", standIn: "[Person B]", partOf: "Lindner, Petra"),
        ])
        #expect(pseudonymizer.restorer.apply("Sehr geehrte Frau [Person A] [Person B],").text == "Sehr geehrte Frau Petra Lindner,")
        #expect(pseudonymizer.restorer.apply("Grüße an [Person A].").text == "Grüße an Petra Lindner.")
    }


    @Test("A name that ran on into a signature's Tel comes back without it")
    func signatureLabel() {
        let pseudonymizer = Pseudonymizer(mode: .placeholder, entries: [
            .init(kind: .person, original: "Frau Berger", standIn: "Frau [Person A]"),
            .init(kind: .person, original: "Frau Berger Tel", standIn: "Frau [Person A]"),
        ])
        #expect(pseudonymizer.restorer.apply("Guten Tag Frau [Person A],").text == "Guten Tag Frau Berger,")
        let found = Detection.finder(runsTagger: false).entities(in: "Ihre Frau Berger Tel.: 0331 1234567", field: .body)
        #expect(found.contains { $0.kind == .person && $0.text == "Frau Berger" })
        #expect(!found.contains { $0.text.hasSuffix("Tel") })
    }

    static func learned(_ names: [String]) -> Pseudonymizer {
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        pseudonymizer.learn(names.map { Entity(kind: .person, text: $0, field: .body, start: 0, length: $0.utf16.count, source: .rule) })
        return pseudonymizer
    }

    @Test("F019 AC-8 · Bergers Anwalt meldet sich, Annegrets Sohn, Priya's mother are disguised and come back as written")
    func endings() {
        let pseudonymizer = Self.learned(["Annegret Berger", "Priya Raman"])
        let text = "Bergers Anwalt meldet sich. Annegrets Sohn kommt. Priya's mother called, and Priya’s brother."
        let out = pseudonymizer.disguiser.apply(text).text
        for name in ["Berger", "Annegret", "Priya"] { #expect(!out.contains(name), "\(out)") }
        #expect(out.contains("]s Anwalt") && out.contains("]s Sohn") && out.contains("]'s mother") && out.contains("]’s brother"), "\(out)")
        let back = pseudonymizer.restorer.apply(out).text
        #expect(back.contains("Bergers Anwalt") && back.contains("Annegret") && back.contains("s Sohn") && back.contains("Priya") && back.contains("'s mother"), "\(back)")
        // Only after the whole original: `Berg` is no part of `Berger`.
        let berg = Self.learned(["Lena Berg"]).disguiser.apply("Herr Berger kommt, Bergs Hund auch.").text
        #expect(berg.contains("Berger") && !berg.contains("Bergs"), "\(berg)")
    }

    @Test("F019 AC-8 · [Person A]s the model wrote comes back as Bergers")
    func endingWrittenByTheModel() {
        let pseudonymizer = Self.learned(["Berger"])
        let tag = pseudonymizer.disguiser.apply("Berger").text
        let back = pseudonymizer.restorer.apply("\(tag)s Anwalt meldet sich.").text
        #expect(back == "Bergers Anwalt meldet sich.", "\(back)")
    }
}
