import Foundation
import Testing
@testable import Disguise

/// Fix, 28 Nov 2026 (the backlog's line from CAU-205's review and CAU-268): three ways something
/// left the device as written, on every source — what comes in (mail, screenshots, photos, files and
/// scans), notes, the chat, and tasks and dates added by hand.
/// 1. A role with a bare surname: `Arzt Sternwald hat geschrieben`, `Our neighbour Sternwald called`.
///    The spell checker knows `Sternwald` as written (it reads it as `Stern` and `Wald`), so no rule
///    took it. A role followed by a capitalised word reads as a name when the word is a first name,
///    on the surname list, or not on the shipped everyday list (the same on every device). An everyday
///    noun no list holds as a name stays after a role that is no title (`Arzt Termin`); a role that is
///    a title (`Nachbarin`, `Pfleger`) still guards whatever follows, as in 1.1.7. Nothing 1.1.7 hid
///    goes out now (the regression test against 1.1.7's own output).
/// 2. `Unterschrift: Pfleger Ilka`: `Pfleger` is a role here (`Pseudonymizer.roles`), so only the name
///    is hidden — right as it is, kept by a guard.
/// 3. `Postfach 4120` went out, and a made-up town (`Feldau`) in an address line: the PO box is an
///    address part now, and the town after `in` or `aus`, or after the street, on a line with an
///    address is a place. Every name is made up.
@Suite("Fix 28 Nov · A role with a bare surname, a PO box, a town in an address", .serialized)
@MainActor
struct RoleSurnamePlaceRulesTests {
    func run(_ text: String, typed: Bool) -> (found: [String], sent: String, list: Pseudonymizer) {
        Detection.$override.withValue(.new) {
            var finder = RuleFinder()
            finder.typed = typed
            let entities = finder.entities(in: text, field: .body)
            var list = Pseudonymizer(Pseudonymizer.Mapping())
            Detection.learn(entities, into: &list)
            return (entities.map(\.text), list.disguiser.apply(text).text, list)
        }
    }

    static let germanRoles = ["Arzt", "Ärztin", "Hausarzt", "Nachbarin", "Nachbar", "Pfleger", "Steuerberater", "Physiotherapeutin"]
    static let surnames = ["Sternwald", "Quellbach", "Tannhauf"]

    @Test("A German role with a bare surname: the role stays visible, the surname is hidden")
    func germanRoleBareSurname() {
        for typed in [true, false] {
            for role in Self.germanRoles {
                for name in Self.surnames {
                    for frame in ["%@ hat geschrieben.", "Gestern hat %@ angerufen.", "Die Nummer von %@ suchen."] {
                        let text = String(format: frame, "\(role) \(name)")
                        let (found, sent, list) = run(text, typed: typed)
                        #expect(sent.contains(role), "typed \(typed): \(text) ⇒ \(sent)")
                        #expect(!sent.contains(name), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
                        #expect(!list.entries.contains { $0.original.contains(role) }, "typed \(typed): \(text) → \(list.entries.map(\.original))")
                    }
                }
            }
        }
    }

    @Test("An English role with a bare surname: the role stays visible, the surname is hidden")
    func englishRoleBareSurname() {
        for typed in [true, false] {
            for role in ["neighbour", "lawyer", "dentist", "nurse"] {
                for name in Self.surnames {
                    let capital = role.prefix(1).uppercased() + role.dropFirst()
                    for (text, shown) in [("Our \(role) \(name) called.", role), ("Ask the \(role) \(name) tomorrow.", role),
                                          ("\(capital) \(name) called.", capital)] {
                        let (found, sent, _) = run(text, typed: typed)
                        #expect(sent.contains(shown), "typed \(typed): \(text) ⇒ \(sent)")
                        #expect(!sent.contains(name), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
                    }
                }
            }
        }
    }

    @Test("Guard: an everyday noun after a role goes as written, and so does the role")
    func everydayNounAfterRole() {
        let texts = ["Arzt Termin am Montag.", "Hausarzt Rezept abholen.", "Ärztin Befund besprechen.", "Zahnarzt Rechnung bezahlen.",
                     "Physiotherapeutin Unterlagen schicken.",
                     // CAU-258, the owner's choice a: written small, an ordinary word goes as written.
                     "arzt termin morgen", "nachbarin garten gießen"]
        for typed in [true, false] {
            for text in texts {
                let (found, sent, _) = run(text, typed: typed)
                #expect(sent == text, "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
            }
        }
    }

    /// The reviewer's surnames that are words too: 1.1.7 hid them after `Nachbar`; they stay hidden,
    /// and after `Arzt` and `Our neighbour` they are hidden now too. The surname list wins over the everyday
    /// words. Two of the reviewer's eighteen are not written here: F024 AC-2 marks them as old details.
    static let surnameWords = ["Bauer", "Schäfer", "Krüger", "Groß", "Weiß", "König", "Hahn", "Maurer", "Zimmermann",
                               "Schuster", "Herbst", "Bär", "Hase", "Specht", "Wald", "Busch"]

    @Test("A surname that is a word too, after Nachbar, Arzt or Our neighbour, is hidden")
    func surnameWordsAfterRole() {
        for typed in [true, false] {
            for name in Self.surnameWords {
                for (text, role) in [("Nachbar \(name) kommt morgen.", "Nachbar"), ("Arzt \(name) kommt morgen.", "Arzt"),
                                     ("Our neighbour \(name) called.", "neighbour")] {
                    let (found, sent, _) = run(text, typed: typed)
                    #expect(sent.contains(role), "typed \(typed): \(text) ⇒ \(sent)")
                    #expect(!sent.contains(name), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
                }
            }
        }
    }

    @Test("A role that is a title guards whatever follows, as in 1.1.7")
    func titleRoleGuardsAsBefore() {
        for typed in [true, false] {
            for (text, name) in [("Nachbarin Garten gießen.", "Garten"), ("Pfleger Schlüssel zurückgeben.", "Schlüssel"),
                                 ("Nachbar Hecke schneiden.", "Hecke")] {
                let (_, sent, _) = run(text, typed: typed)
                #expect(!sent.contains(name), "typed \(typed): \(text) ⇒ \(sent)")
            }
        }
    }

    @Test("The everyday list gives the same answers on every device, and the text sent is the same")
    func everydaySameEverywhere() {
        let answers: [(String, Bool)] = [("Termin", true), ("Garten", true), ("Ordnung", true), ("Versehen", true),
                                         ("Berlin", false), ("Sternwald", false), ("Feldau", false)]
        for (word, everyday) in answers {
            #expect(NameKnowledge.shared.isEveryday(word) == everyday, "\(word): \(String(describing: NameKnowledge.shared.isEveryday(word)))")
        }
        for typed in [true, false] {
            #expect(run("Lindenweg 4, Berlin", typed: typed).sent == "[Street A], [Place A]")
            #expect(run("Arzt Termin am Montag.", typed: typed).sent == "Arzt Termin am Montag.")
            #expect(run("Arzt Sternwald hat geschrieben.", typed: typed).sent == "Arzt [Person A] hat geschrieben.")
        }
    }

    struct Probe: Codable { var text: String; var typed: Bool; var sent: String }

    static func words(_ text: String) -> Set<String> { Set(text.matches(of: /[\p{L}]+/).map { String($0.output) }) }

    @Test("Nothing 1.1.7 hid goes out now: every word it hid is hidden still, but a role word (CAU-205)")
    func nothingLessHiddenThan117() throws {
        let file = F024GoldenTests.fixtures.appendingPathComponent("role-place-1.1.7.json")
        let probes = try JSONDecoder().decode([Probe].self, from: Data(contentsOf: file))
        #expect(probes.count > 1000)
        for probe in probes {
            let now = run(probe.text, typed: probe.typed).sent
            let all = Self.words(probe.text)
            let hiddenThen = all.subtracting(Self.words(probe.sent)).filter { !Ordinary.isRole($0) }
            let hiddenNow = all.subtracting(Self.words(now))
            #expect(hiddenThen.isSubset(of: hiddenNow), "typed \(probe.typed): \(probe.text) ⇒ 1.1.7 \(probe.sent), now \(now)")
        }
    }

    @Test("Guard: a title after a role still guards an everyday word, which is a name there")
    func titleStillGuards() {
        for typed in [true, false] {
            for (text, role, name) in [("Nachbarin Frau Garten anrufen.", "Nachbarin", "Garten"), ("Arzt Dr. Hecke hat geschrieben.", "Arzt", "Hecke"),
                                       ("Pfleger Herr Termin kommt.", "Pfleger", "Termin")] {
                let (_, sent, _) = run(text, typed: typed)
                #expect(sent.contains(role), "typed \(typed): \(text) ⇒ \(sent)")
                #expect(!sent.contains(name), "typed \(typed): \(text) ⇒ \(sent)")
            }
        }
    }

    @Test("Pfleger is a role here: only the name after it is hidden, and Pfleger stays visible")
    func pflegerIsARole() {
        for typed in [true, false] {
            for (text, hidden) in [("Unterschrift: Pfleger Ilka", ["Ilka"]), ("Unterschrift: Pfleger Ilka Sternwald", ["Ilka", "Sternwald"]),
                                   ("Unterschrift: Pfleger Quellbach", ["Quellbach"])] {
                let (_, sent, list) = run(text, typed: typed)
                #expect(sent.hasPrefix("Unterschrift: Pfleger "), "typed \(typed): \(text) ⇒ \(sent)")
                for word in hidden { #expect(!sent.contains(word), "typed \(typed): \(text) ⇒ \(sent)") }
                #expect(!list.entries.contains { $0.original.contains("Pfleger") }, "\(list.entries.map(\.original))")
            }
        }
    }

    @Test("A PO box is an address part and is hidden, with its number")
    func poBox() {
        let cases = ["Postfach 4120, 79098 Feldau", "Bitte an Postfach 4120 schicken.", "PO Box 4120, Feldau", "Please write to P.O. Box 4120.",
                     "Anschrift: postfach 4120", "Postfach: 4120"]
        for typed in [true, false] {
            for text in cases {
                let (found, sent, _) = run(text, typed: typed)
                #expect(!sent.contains("4120"), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
                #expect(!sent.contains("Feldau"), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
            }
        }
    }

    @Test("Guard: the word Postfach alone, with no number, goes as written")
    func postfachWithoutNumber() {
        for typed in [true, false] {
            for text in ["Ihre Bescheinigung liegt im Postfach.", "Postfach leeren", "Das Postfach ist voll."] {
                let (_, sent, _) = run(text, typed: typed)
                #expect(sent == text, "typed \(typed): \(text) ⇒ \(sent)")
            }
        }
    }

    @Test("A made-up town after a postcode, or after in or aus or the street in an address line, is hidden")
    func townInAddress() {
        let cases = ["79098 Feldau", "Anschrift: Lindenweg 4, 79098 Feldau", "Wir wohnen in Feldau, Lindenweg 4.", "Lindenweg 4 in Feldau",
                     "Sie kommt aus Feldau, Am Markt 3.", "Lindenweg 4, Feldau", "PO Box 4120, Feldau", "Postfach 4120 in Feldau",
                     "We live at 12 Hollybush Lane in Feldau."]
        for typed in [true, false] {
            for text in cases {
                let (found, sent, _) = run(text, typed: typed)
                #expect(!sent.contains("Feldau"), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
            }
        }
    }

    @Test("Guard: an everyday word after in or aus in an address line goes as written")
    func everydayWordInAddress() {
        for typed in [true, false] {
            for (text, kept) in [("Die Karte kam aus Versehen an Lindenweg 4.", "aus Versehen"), ("Alles in Ordnung, Lindenweg 4.", "in Ordnung")] {
                let (_, sent, _) = run(text, typed: typed)
                #expect(sent.contains(kept), "typed \(typed): \(text) ⇒ \(sent)")
            }
        }
    }

    @Test("The chat's whole path: a role and a bare surname, a PO box and its town come back as written")
    func chatRoundTrip() {
        let question = "Arzt Sternwald hat geschrieben, Antwort an Postfach 4120, 79098 Feldau"
        for typed in [true, false] {
            let (_, asked, mapping) = run(question, typed: typed)
            #expect(asked.hasPrefix("Arzt "), "\(asked)")
            #expect(!asked.contains("Sternwald") && !asked.contains("4120") && !asked.contains("Feldau"), "\(asked)")
            #expect(mapping.restore(asked) == question, "\(mapping.restore(asked))")
        }
    }
}
