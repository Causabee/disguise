import Foundation
import Testing
@testable import Disguise

/// CAU-269: "Die Kaution von Wohnbau Sternhagen ist noch nicht zurück" — said in the chat, with no
/// names known yet — went out as it was said (the dictation measurement of 27 November, mh04). The
/// tagger read nothing in the line, "Wohnbau" was no word that says what a business is, and the
/// dictionary knows "Sternhagen" as written (it is a place too), so no rule proposed it. A housing
/// company's kind word anchors its name, as `Kanzlei` and `Hausverwaltung` do. Every name is made up.
@Suite("CAU-269 · A housing company's name is hidden", .serialized)
@MainActor
struct HousingCompanyRulesTests {
    func companies(_ text: String, typed: Bool) -> [String] {
        Detection.$override.withValue(.new) {
            var finder = RuleFinder()
            finder.typed = typed
            return finder.entities(in: text, field: .body).filter { $0.kind == .organization }.map(\.text)
        }
    }

    @Test("CAU-269: Wohnbau, Immobilien, Baugenossenschaft before a name the dictionary knows: the whole company is found")
    func kindWordAnchors() {
        let cases = [
            ("Die Kaution von Wohnbau Sternhagen ist noch nicht zurück, ich muss malen.", "Wohnbau Sternhagen"),
            ("Die Abrechnung von Immobilien Sternhagen kam gestern.", "Immobilien Sternhagen"),
            ("Bei der Baugenossenschaft Sternhagen anrufen wegen der Kaution.", "Baugenossenschaft Sternhagen"),
            ("Die Wohnungsbaugesellschaft Sternhagen hat die Miete erhöht.", "Wohnungsbaugesellschaft Sternhagen"),
        ]
        for typed in [true, false] {
            for (text, company) in cases {
                #expect(companies(text, typed: typed).contains(company), "\(text) → \(companies(text, typed: typed))")
            }
        }
    }

    @Test("CAU-269: the chat's whole path sends no Sternhagen, and keeps Kaution")
    func chatSendsNoName() throws {
        let question = "Die Kaution von Wohnbau Sternhagen ist noch nicht zurück, ich muss malen."
        let sent = Detection.$override.withValue(.new) { () -> String in
            var finder = RuleFinder()
            finder.typed = true
            var list = Pseudonymizer(Pseudonymizer.Mapping())
            Detection.learn(finder.entities(in: question, field: .body), into: &list)
            return list.disguiser.apply(question).text
        }
        #expect(!sent.contains("Sternhagen"), "\(sent)")
        #expect(sent.contains("Kaution"), "\(sent)")
    }

    @Test("CAU-269: the kind word alone, or before an ordinary small word, is no one")
    func kindWordAlone() {
        for text in ["Der Wohnbau in der Stadt geht voran.", "Immobilien sind teuer geworden.", "Die Baugenossenschaft hat geschrieben."] {
            for typed in [true, false] {
                #expect(companies(text, typed: typed).isEmpty, "\(text) → \(companies(text, typed: typed))")
            }
        }
    }
}
