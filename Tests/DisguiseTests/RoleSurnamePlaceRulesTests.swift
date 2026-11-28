import Foundation
import Testing
@testable import Disguise

/// Fix, 28 Nov 2026 (the backlog's line from CAU-205's review and CAU-268): three ways something
/// left the device as written, on every source — what comes in (mail, screenshots, photos, files and
/// scans), notes, the chat, and tasks and dates added by hand.
/// 1. A role with a bare surname: `Arzt Sternwald hat geschrieben`, `Our neighbour Sternwald called`.
///    The spell checker knows `Sternwald` as written (it reads it as `Stern` and `Wald`), so no rule
///    took it. A role followed by a capitalised word that is not an everyday word reads as a name;
///    an everyday noun after a role stays (`Arzt Termin`, `Nachbarin Garten`), and a title always guards.
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
        let texts = ["Arzt Termin am Montag.", "Nachbarin Garten gießen.", "Hausarzt Rezept abholen.", "Pfleger Schlüssel zurückgeben.",
                     "Nachbar Hecke schneiden.", "Ärztin Befund besprechen.", "Steuerberater Rechnung bezahlen.",
                     // CAU-258, the owner's choice a: written small, an ordinary word goes as written.
                     "arzt termin morgen", "nachbarin garten gießen"]
        for typed in [true, false] {
            for text in texts {
                let (found, sent, _) = run(text, typed: typed)
                #expect(sent == text, "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
            }
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
