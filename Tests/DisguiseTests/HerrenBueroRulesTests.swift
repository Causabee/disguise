import Testing
import NaturalLanguage
@testable import Disguise

/// Fix, 24 Nov 2026: "Herren" in "Sehr geehrte Damen und Herren" was taken for a person, and the
/// label "Büro" too, with an id written before it ("X1 Büro"). Who is greeted as a group, and what
/// says what a business is, is no one alone; an id of letters and digits is no part of a name.
@Suite("Herren, Damen and Büro are no one alone")
struct HerrenBueroRulesTests {
    func people(_ text: String, typed: Bool = false, language: NLLanguage? = nil) -> [String] {
        var finder = RuleFinder(language: language)
        finder.typed = typed
        let out = finder.entities(in: text, field: .body).filter { $0.kind == .person }.map(\.text)
        return out
    }

    @Test("“Sehr geehrte Damen und Herren” has no person in it, typed or not, in any language")
    func greetingToAll() {
        for typed in [false, true] {
            for language in [nil, NLLanguage.german, .english] as [NLLanguage?] {
                #expect(people("Sehr geehrte Damen und Herren,\n\nanbei die Unterlagen.", typed: typed, language: language).isEmpty)
                #expect(people("Sehr geehrte Damen und Herren, bitte rufen Sie zurück.", typed: typed, language: language).isEmpty)
                #expect(people("Dear Ladies and Gentlemen, please find attached the forms.", typed: typed, language: language).isEmpty)
            }
        }
        // A name after them is still a name.
        #expect(people("Sehr geehrte Damen und Herren, sehr geehrter Herr Quellbrunn,").contains { $0.contains("Quellbrunn") })
    }

    @Test("“Büro” alone, and with an id before it, is no one; Büro with a name is the name's")
    func office() {
        for text in ["Details the owner keeps here, values not shown (the owner sees them under Details): X1 Büro",
                     "Details the owner keeps here, values not shown (the owner sees them under Details): Büro; Mobil",
                     "Details: X1 Büro; X2 Kundennummer"] {
            #expect(people(text).isEmpty, "\(text)")
        }
        #expect(people("Bitte ruf im Büro von Frau Quellbrunn an.").contains { $0.contains("Quellbrunn") })
    }

    /// The reviewer, 24 Nov: what 1.1.0 hid must stay hidden. A title in front keeps a word a name,
    /// even one that is a greeting or a word for everyone; "Herren" before a name works as a title.
    @Test("Herr Sehr, Herr Herren, Frau Damen and die Herren Weber stay hidden, in any language")
    func titleKeepsTheName() {
        for typed in [false, true] {
            for language in [nil, NLLanguage.german, .english] as [NLLanguage?] {
                #expect(people("Herr Sehr rief an.", typed: typed, language: language).contains { $0.contains("Sehr") }, "\(String(describing: language))")
                #expect(people("Herr Herren rief an.", typed: typed, language: language).contains { $0.contains("Herren") }, "\(String(describing: language))")
                #expect(people("Frau Damen rief an.", typed: typed, language: language).contains { $0.contains("Damen") }, "\(String(describing: language))")
                #expect(people("Die Herren Weber und Kurz kommen morgen.", typed: typed, language: language).contains { $0.contains("Weber") }, "\(String(describing: language))")
                // And the greeting to all still has no one in it.
                #expect(people("Sehr geehrte Damen und Herren,\n\nanbei die Unterlagen.", typed: typed, language: language).isEmpty)
            }
        }
    }

    /// The reviewer, 24 Nov: `Familie` and `Fräulein` are titles too, so a surname after them stays hidden.
    @Test("Familie Herren, Fräulein Damen and Familie Sehr stay hidden, in any language")
    func familyAndMiss() {
        for typed in [false, true] {
            for language in [nil, NLLanguage.german, .english] as [NLLanguage?] {
                for (text, name) in [("Von: Familie Herren", "Herren"), ("Kontakt: Familie Damen, Tel. 0301234567", "Damen"),
                                     ("Fräulein Herren rief an.", "Herren"), ("Fräulein Damen rief an.", "Damen"), ("Familie Sehr kommt.", "Sehr")] {
                    #expect(people(text, typed: typed, language: language).contains { $0.contains(name) }, "\(text) \(String(describing: language))")
                }
            }
        }
    }
}
