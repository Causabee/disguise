import Foundation
import Testing
@testable import Disguise

/// CAU-205: a role word before a name — what someone does, `Ergotherapeutin`, `Steuerberater`,
/// `lawyer` — was taken as part of the name. `Steuerberater Torvak` became one person, and
/// `Gestern hat Ergotherapeutin Dr. Ilka Sternwald geschrieben` went out as `Gestern hat [Person A]
/// geschrieben`: the role was hidden with the name, and the contact that came back had no role.
/// The role stays visible and outside the name; only the name is hidden. A title (`Frau`, `Herr`,
/// `Dr.`) still guards the name and stays in it, as today. Every name is made up.
@Suite("CAU-205 · A role word before a name stays visible", .serialized)
@MainActor
struct RoleBeforeNameRulesTests {
    /// The people and companies found, and the text as it goes out.
    func run(_ text: String, typed: Bool) -> (found: [String], sent: String, list: Pseudonymizer) {
        Detection.$override.withValue(.new) {
            var finder = RuleFinder()
            finder.typed = typed
            let entities = finder.entities(in: text, field: .body)
            var list = Pseudonymizer(Pseudonymizer.Mapping())
            Detection.learn(entities, into: &list)
            let found = entities.filter { [.person, .organization].contains($0.kind) }.map(\.text)
            return (found, list.disguiser.apply(text).text, list)
        }
    }

    static let germanRoles = ["Ergotherapeutin", "Physiotherapeut", "Hausärztin", "Steuerberater", "Rechtsanwältin", "Logopädin",
                              "Hausmeister", "Nachbarin", "Pflegerin"]
    /// The name, and the word of it that must not go out.
    static let germanNames = [("Frau Rosa Quellbach", "Quellbach"), ("Herr Tannhauf", "Tannhauf"), ("Dr. Ilka Sternwald", "Sternwald"),
                              ("Frau Quellbach", "Quellbach"), ("Rosa Quellbach", "Quellbach"), ("Torvak", "Torvak")]
    static let germanFrames = ["Die Nummer der %@ ist 0421 5550123.", "%@ anrufen.", "Gestern hat %@ geschrieben, alles gut."]

    func check(_ text: String, role: String, hidden: String, typed: Bool) {
        let (found, sent, _) = run(text, typed: typed)
        let roleWords = Pseudonymizer.words(role).map { $0.lowercased() }
        for name in found {
            let words = Pseudonymizer.words(name).map { $0.lowercased() }
            #expect(!words.contains(where: roleWords.contains), "typed \(typed): \(text) → the name \(name) holds the role")
        }
        #expect(sent.contains(role), "typed \(typed): \(text) ⇒ \(sent)")
        #expect(!sent.contains(hidden), "typed \(typed): \(text) ⇒ \(sent)")
    }

    @Test("CAU-205: a German role before Frau, Herr, Dr. or a bare name stays visible, and only the name is hidden")
    func germanRoleStaysVisible() {
        for typed in [true, false] {
            for role in Self.germanRoles {
                for (name, hidden) in Self.germanNames {
                    for frame in Self.germanFrames {
                        check(String(format: frame, "\(role) \(name)"), role: role, hidden: hidden, typed: typed)
                    }
                }
            }
        }
    }

    @Test("CAU-205: an English role before Mrs, Mr, Dr. or a bare name stays visible, and only the name is hidden")
    func englishRoleStaysVisible() {
        let roles = ["occupational therapist", "lawyer", "physiotherapist", "tax advisor", "family doctor", "neighbour"]
        let names = [("Mrs. Rosa Quellbach", "Quellbach"), ("Dr. Torvak", "Torvak"), ("Rosa Quellbach", "Quellbach"),
                     ("Ilka Sternwald", "Sternwald"), ("Mr Tannhauf", "Tannhauf")]
        for typed in [true, false] {
            for role in roles {
                for (name, hidden) in names {
                    for frame in ["Call the %@ tomorrow.", "Our %@ wrote back."] {
                        check(String(format: frame, "\(role) \(name)"), role: role, hidden: hidden, typed: typed)
                    }
                    let capital = role.prefix(1).uppercased() + role.dropFirst()
                    check("\(capital) \(name) called.", role: capital, hidden: hidden, typed: typed)
                }
            }
        }
    }

    @Test("CAU-205: the chat's whole path keeps the role, and the stand-in comes back as the name alone")
    func chatKeepsTheRole() {
        let question = "Das sind infos zur Ergotherapeutin Dr. Ilka Sternwald, Telefon 0421 5550123"
        for typed in [true, false] {
            let (_, sent, list) = run("Gestern hat Ergotherapeutin Dr. Ilka Sternwald geschrieben, alles gut.", typed: typed)
            #expect(sent.contains("Ergotherapeutin Dr. "), "\(sent)")
            #expect(!list.entries.contains { $0.original.contains("Ergotherapeutin") }, "\(list.entries.map(\.original))")
            let (_, asked, mapping) = run(question, typed: typed)
            #expect(asked.contains("Ergotherapeutin Dr. "), "\(asked)")
            #expect(!asked.contains("Sternwald") && !asked.contains("5550123"), "\(asked)")
            #expect(mapping.restore(asked) == question, "\(mapping.restore(asked))")
        }
        let (_, sent, list) = run("Steuerberater Torvak braucht die Belege.", typed: true)
        #expect(sent == "Steuerberater [Person A] braucht die Belege.", "\(sent)")
        #expect(list.entries.map(\.original) == ["Torvak"], "\(list.entries.map(\.original))")
    }

    @Test("CAU-205: a role before a name is a person's; with a firm's sign after it, still a company")
    func roleOrFirm() {
        for typed in [true, false] {
            let (found, sent, _) = run("Notar Torvak schickt den Entwurf.", typed: typed)
            #expect(found == ["Torvak"], "\(found)")
            #expect(sent == "Notar [Person A] schickt den Entwurf.", "\(sent)")
            let (firms, firmSent, _) = run("Die Rechnung von Steuerberater Torvak & Partner kam gestern.", typed: typed)
            #expect(firms.contains("Steuerberater Torvak & Partner"), "\(firms)")
            #expect(!firmSent.contains("Torvak"), "\(firmSent)")
        }
    }

    @Test("CAU-205: a title still guards the name and stays in it, as today")
    func titleStillGuards() {
        let cases = [
            ("Frau Quellbach anrufen.", "Frau Quellbach"),
            ("Herr Tannhauf kommt am Montag.", "Herr Tannhauf"),
            ("Gestern hat Dr. Ilka Sternwald geschrieben.", "Dr. Ilka Sternwald"),
            // A word the dictionary knows, after a title, is a name: the title guards it.
            ("Ergotherapeutin Frau Sommer anrufen.", "Frau Sommer"),
            ("Steuerberater Herr Winter braucht die Belege.", "Herr Winter"),
        ]
        for typed in [true, false] {
            for (text, name) in cases {
                let (found, sent, _) = run(text, typed: typed)
                #expect(found.contains(name), "typed \(typed): \(text) → \(found)")
                let surname = Pseudonymizer.words(name).last!
                #expect(!sent.contains(surname), "typed \(typed): \(text) ⇒ \(sent)")
            }
        }
    }

    @Test("CAU-205: a name made of a role-like word is still hidden")
    func roleLikeNamesStayHidden() {
        let cases = [
            ("Frau Richter anrufen.", "Richter", nil),
            ("Herr Gärtner kommt am Montag.", "Gärtner", nil),
            ("Gestern hat Rosa Schneider geschrieben.", "Schneider", nil),
            ("Steuerberater Frau Richter braucht die Belege.", "Richter", "Steuerberater"),
            ("Gestern hat Hausärztin Dr. Gärtner geschrieben.", "Gärtner", "Hausärztin"),
            ("Our lawyer Mrs. Fischer wrote back.", "Fischer", "lawyer"),
        ]
        for typed in [true, false] {
            for (text, name, role) in cases {
                let (_, sent, _) = run(text, typed: typed)
                #expect(!sent.contains(name), "typed \(typed): \(text) ⇒ \(sent)")
                if let role { #expect(sent.contains(role), "typed \(typed): \(text) ⇒ \(sent)") }
            }
        }
    }
}
