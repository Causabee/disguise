import Foundation
import Testing
@testable import Disguise

/// F027: a list from before is brought up once (AC-12), nothing hidden before goes out after
/// (AC-13), and the list's JSON only gains optional keys (AC-15). Every name here is made up.
@Suite("F027 · The list brought up once")
struct IdentityUpgradeTests {
    @Test("F027 AC-15 · the new keys are optional: a list without them decodes, and they encode as joined, form_of and ways")
    func optionalKeys() throws {
        // A list as 1.0.1 writes it: none of the new keys.
        let older = """
        {"version":6,"level":1,"switches":{},"standin":[],
         "placeholder":[
          {"kind":"person","original":"Patrick Schüßler","stand_in":"[Person A]"},
          {"kind":"person","original":"Schüßler","stand_in":"[Person A]","part_of":"Patrick Schüßler"}]}
        """
        let decoded = try JSONDecoder().decode(Pseudonymizer.Mapping.self, from: Data(older.utf8))
        #expect(decoded.joined == nil)
        #expect(decoded.placeholder.allSatisfy { $0.formOf == nil })
        #expect(decoded.placeholder.count == 2)

        var mapping = Pseudonymizer.Mapping()
        mapping.joined = 1
        mapping.placeholder = [
            .init(kind: .person, original: "Patrick Schüßler", standIn: "[Person A]"),
            .init(kind: .person, original: "Patrick Schuessler", standIn: "[Person A]", formOf: "Patrick Schüßler"),
        ]
        mapping.switches = [Pseudonymizer.Mapping.hashed("Patrick Schüßler"): .init(.off, at: Date(timeIntervalSince1970: 0), ways: true),
                            Pseudonymizer.Mapping.hashed("Patrick Schuessler"): .init(.on, at: Date(timeIntervalSince1970: 0))]
        let json = String(decoding: try JSONEncoder().encode(mapping), as: UTF8.self)
        #expect(json.contains("\"joined\":1"))
        #expect(json.contains("\"form_of\":\"Patrick Schüßler\""))
        #expect(json.contains("\"ways\":true"))
        // Absent where nothing is said: a row has no form_of, a switch for one name no ways.
        #expect(json.components(separatedBy: "\"form_of\"").count == 2)
        #expect(json.components(separatedBy: "\"ways\"").count == 2)
        #expect(try JSONDecoder().decode(Pseudonymizer.Mapping.self, from: Data(json.utf8)) == mapping)
    }
}
