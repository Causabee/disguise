import Foundation
import Testing
@testable import Disguise

/// 1.0.1's own `Codable` shapes of the list, frozen here as they were at that tag (b164096): what an
/// older build on another device decodes. No new kind of entity and no new switch state may reach it.
enum Older {
    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case person, place, organization, email, phone, iban, street, postalCity, reference }
        var kind: Kind
        var original: String
        var standIn: String
        var partOf: String?
        enum CodingKeys: String, CodingKey { case kind, original, standIn = "stand_in", partOf = "part_of" }
    }

    struct Mapping: Codable {
        var version: Int
        var placeholder: [Entry]
        var standin: [Entry]
        var cleaned: Cleaned?
        var level: Int?
        var fresh: Date?
        var switches: [String: Switch]?

        struct Switch: Codable {
            enum State: String, Codable { case on, off, gone }
            var state: State
            var at: Date
        }

        struct Cleaned: Codable {
            var id: UUID
            var at: Date
            var dropped: [String]
        }
    }
}

/// F027: one switch for every way of writing (AC-7), a new way of an off person (AC-8), and an
/// older build beside this one (AC-14). Every name here is made up.
@Suite("F027 · Switches over ways of writing")
struct SwitchWaysTests {
    /// A list of this build: a row, its ways, its parts, every kind, every switch state, with and without `ways`.
    static func thisBuildsList() -> Pseudonymizer.Mapping {
        var mapping = Pseudonymizer.Mapping()
        mapping.joined = 1
        mapping.placeholder = [
            .init(kind: .person, original: "Patrick Schüßler", standIn: "[Person A]"),
            .init(kind: .person, original: "Patrick Schuessler", standIn: "[Person A]", formOf: "Patrick Schüßler"),
            .init(kind: .person, original: "Herrn Patrick Schüßler", standIn: "Herrn [Person A]", formOf: "Patrick Schüßler"),
            .init(kind: .person, original: "Patrick", standIn: "[Person A]", partOf: "Patrick Schüßler"),
            .init(kind: .person, original: "Schüßler", standIn: "[Person A]", partOf: "Patrick Schüßler"),
            .init(kind: .organization, original: "Radwerk Berlin GmbH", standIn: "[Company A]"),
            .init(kind: .organization, original: "'Radwerk Berlin GmbH'", standIn: "[Company A]", formOf: "Radwerk Berlin GmbH"),
            .init(kind: .place, original: "Göttingen", standIn: "[Place A]"),
            .init(kind: .email, original: "p.schuessler@radwerk-berlin.example", standIn: "[Email A]"),
            .init(kind: .phone, original: "030 5550 1234", standIn: "[Phone A]"),
            .init(kind: .iban, original: "DE00 1111 2222 3333 4444 55", standIn: "[IBAN A]"),
            .init(kind: .street, original: "Lindenstraße 4", standIn: "[Street A]"),
            .init(kind: .postalCity, original: "37073 Göttingen", standIn: "[Postcode A] [Place A]"),
            .init(kind: .reference, original: "AZ 4471-26", standIn: "[Nummer A]"),
        ]
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        mapping.switches = [
            Pseudonymizer.Mapping.hashed("Patrick Schüßler"): .init(.off, at: at, ways: true),
            Pseudonymizer.Mapping.hashed("Herrn Patrick Schüßler"): .init(.on, at: at),
            Pseudonymizer.Mapping.hashed("Radwerk Berlin GmbH"): .init(.gone, at: at, ways: true),
            Pseudonymizer.Mapping.hashed("Göttingen"): .init(.off, at: at),
        ]
        return mapping
    }

    @Test("F027 AC-14 · read with 1.0.1's shapes, this list keeps every entry, kind and state")
    func olderShapes() throws {
        let mapping = Self.thisBuildsList()
        let data = try JSONEncoder().encode(mapping)
        let older = try JSONDecoder().decode(Older.Mapping.self, from: data)
        #expect(older.version == mapping.version)
        #expect(older.placeholder.count == mapping.placeholder.count)
        for (old, new) in zip(older.placeholder, mapping.placeholder) {
            #expect(old.kind.rawValue == new.kind.rawValue && old.original == new.original && old.standIn == new.standIn && old.partOf == new.partOf)
        }
        // A way of writing has no part_of: to 1.0.1 it is a whole of its own, taken over and hidden.
        #expect(older.placeholder.filter { $0.partOf == nil }.count == mapping.placeholder.filter { $0.partOf == nil }.count)
        #expect(Set((older.switches ?? [:]).keys) == Set((mapping.switches ?? [:]).keys))
        for (key, value) in mapping.switches ?? [:] { #expect(older.switches?[key]?.state.rawValue == value.state.rawValue) }
    }
}
