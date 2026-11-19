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

    // MARK: Learned by this build

    static func entity(_ kind: Entity.Kind, _ text: String) -> Entity {
        Entity(kind: kind, text: text, field: .body, start: 0, length: (text as NSString).length, source: .rule)
    }

    static let patricksWays = ["Patrick Schüßler", "Herrn Patrick Schüßler", "SCHÜSSLER Patrick", "Patrick Schuessler", "Dr. Patrick Schüßler",
                               "Schüßler, Patrick"]

    /// Patrick Schüßler written several ways and a via name, learned as the doors learn; Patrick Ahlers beside him, or not.
    static func learned(ways: [String] = Array(patricksWays.dropFirst()), ahlers: Bool = true) -> Pseudonymizer.Mapping {
        var p = Pseudonymizer(mode: .placeholder)
        p.learnAdmitted((["Patrick Schüßler"] + (ahlers ? ["Patrick Ahlers"] : [])).map { entity(.person, $0) })
        p.learnAdmitted((ways + ["Patrick Schüßler via Doodle"]).map { entity(.person, $0) })
        var mapping = Pseudonymizer.Mapping()
        mapping.placeholder = p.entries
        mapping.switches = [:]
        return mapping
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func set(_ mapping: inout Pseudonymizer.Mapping, _ name: String, _ state: Pseudonymizer.Mapping.Switch.State, at: Date, ways: Bool = true) {
        var switches = mapping.switches ?? [:]
        switches[Pseudonymizer.Mapping.hashed(name)] = .init(state, at: at, ways: ways)
        mapping.switches = switches
    }

    static func out(_ mapping: Pseudonymizer.Mapping, _ text: String) -> String {
        Pseudonymizer(mapping).disguiser.apply(text).text
    }

    @Test("F027 AC-7 · off lets every way out, on hides them again with the row's stand-in, delete takes every way")
    func oneSwitch() throws {
        // Off: every way goes out as written, his first name and surname with it.
        var alone = Self.learned(ahlers: false)
        Self.set(&alone, "Patrick Schüßler", .off, at: Self.t0)
        for way in Self.patricksWays + ["Patrick", "Schüßler", "Herr Schüßler kommt"] {
            #expect(Self.out(alone, way) == way, "\(way) went out as \(Self.out(alone, way))")
        }
        // „Patrick“, which Patrick Ahlers still has, stays hidden; nothing of his own tag is left.
        var mapping = Self.learned()
        let tag = try #require(Pseudonymizer(mapping).standIn(for: "Patrick Schüßler"))
        let shared = try #require(Pseudonymizer(mapping).standIn(for: "Patrick"))
        Self.set(&mapping, "Patrick Schüßler", .off, at: Self.t0)
        for way in Self.patricksWays {
            let out = Self.out(mapping, way)
            #expect(out == way.replacingOccurrences(of: "Patrick", with: shared), "\(way) went out as \(out)")
        }
        #expect(Self.out(mapping, "Patrick Ahlers") != "Patrick Ahlers")
        // On again: every way hidden with the row's stand-in.
        Self.set(&mapping, "Patrick Schüßler", .on, at: Self.t0 + 60)
        for way in Self.patricksWays { #expect(Pseudonymizer.tags(in: Self.out(mapping, way)) == [tag], "\(way)") }
        #expect(Self.out(mapping, "Herrn Patrick Schüßler") == "Herrn \(tag)")
        // The switch turned on another device, whose row has another own name (one device's row is another's way).
        var other = Pseudonymizer.Mapping()
        other.placeholder = [.init(kind: .person, original: "Patrick Schuessler", standIn: "[Person C]"),
                             .init(kind: .person, original: "Patrick Schüßler", standIn: "[Person C]", formOf: "Patrick Schuessler"),
                             .init(kind: .person, original: "Herr Schuessler", standIn: "Herr [Person C]", formOf: "Patrick Schuessler")]
        other.switches = [:]
        Self.set(&mapping, "Patrick Schüßler", .off, at: Self.t0 + 120)
        other.switches = Pseudonymizer.Mapping.merged([other.switches, mapping.switches])
        #expect(Self.out(other, "Herr Schuessler") == "Herr Schuessler")
        #expect(Self.out(other, "Patrick Schuessler") == "Patrick Schuessler")
        // Delete: the row and every way leave the list; each way keeps its own `gone`, so no older copy brings it back.
        var deleted = Self.learned()
        let rowAndWays = deleted.placeholder.filter { $0.original == "Patrick Schüßler" || $0.formOf == "Patrick Schüßler" }.map(\.original)
        Self.set(&deleted, "Patrick Schüßler", .gone, at: Self.t0)
        for way in rowAndWays where way != "Patrick Schüßler" { Self.set(&deleted, way, .gone, at: Self.t0, ways: false) }
        deleted = deleted.settled()
        #expect(!deleted.placeholder.contains { rowAndWays.contains($0.original) })
        #expect(rowAndWays.allSatisfy { deleted.gone.contains(Pseudonymizer.Mapping.hashed($0)) })
        #expect(Self.out(deleted, "Schüßler") == "Schüßler")
        // Learned again, it is on and hidden.
        var again = Pseudonymizer(deleted)
        again.learnAdmitted([Self.entity(.person, "Patrick Schuessler")])
        #expect(again.disguiser.apply("Patrick Schuessler").text != "Patrick Schuessler")
    }

    @Test("F027 AC-7 · a via name's service stays hidden while the person is off, and after he is deleted")
    func viaService() throws {
        var mapping = Self.learned(ahlers: false)
        let doodle = try #require(Pseudonymizer(mapping).standIn(for: "Doodle"))
        Self.set(&mapping, "Patrick Schüßler", .off, at: Self.t0)
        #expect(Self.out(mapping, "Patrick Schüßler via Doodle") == "Patrick Schüßler via \(doodle)")
        #expect(Self.out(mapping, "Doodle") == doodle)
        // Deleted: the service is no way of him and gets no `gone`; it stays hidden, a company row of its own.
        var deleted = Self.learned()
        Self.set(&deleted, "Patrick Schüßler", .gone, at: Self.t0)
        for way in deleted.placeholder where way.formOf == "Patrick Schüßler" { Self.set(&deleted, way.original, .gone, at: Self.t0, ways: false) }
        deleted = deleted.settled()
        let service = try #require(deleted.placeholder.first { $0.original == "Doodle" })
        #expect(service.partOf == nil && service.formOf == nil && service.kind == .organization && service.standIn == doodle)
        #expect(Self.out(deleted, "Doodle") == doodle)
    }

    @Test("F027 AC-8 · a new way of an off person comes in on")
    func newWayComesInOn() throws {
        var before = Self.learned(ways: ["Herrn Patrick Schüßler", "Dr. Patrick Schüßler"], ahlers: false)
        Self.set(&before, "Patrick Schüßler", .off, at: Self.t0)
        // A send learns a way the list did not hold: hidden in that send, the set of what goes out made before it existed.
        var send = Pseudonymizer(before)
        send.learnAdmitted([Self.entity(.person, "PATRICK SCHUESSLER")])
        #expect(send.entries.first { $0.original == "PATRICK SCHUESSLER" }?.formOf == "Patrick Schüßler")
        #expect(send.disguiser.apply("PATRICK SCHUESSLER").text != "PATRICK SCHUESSLER")
        var after = before
        after.placeholder = send.entries
        after.settleNewWays(base: before, now: Self.t0 + 60)
        // It comes in on: hidden with his stand-in until the owner turns it off too; the others stay off.
        #expect(after.switches?[Pseudonymizer.Mapping.hashed("PATRICK SCHUESSLER")] == .init(.on, at: Self.t0 + 60))
        #expect(Self.out(after, "PATRICK SCHUESSLER") == send.standIn(for: "Patrick Schüßler"))
        // The others stay off: let go, as the owner turned them (a word the new way holds stays hidden with it).
        let hidden = Set(Pseudonymizer(after).hidden.map(\.original))
        for way in ["Patrick Schüßler", "Herrn Patrick Schüßler", "Dr. Patrick Schüßler"] { #expect(!hidden.contains(way), "\(way) is hidden") }
        #expect(Self.out(after, "Herr Schüßler") == "Herr Schüßler")
        #expect(after.hiddenWays(of: "Patrick Schüßler") == ["PATRICK SCHUESSLER"])
        // A second settle changes nothing; the owner's one tap turns it off with the others.
        var twice = after
        twice.settleNewWays(base: before, now: Self.t0 + 90)
        #expect(twice == after)
        Self.set(&after, "Patrick Schüßler", .off, at: Self.t0 + 120)
        #expect(Self.out(after, "PATRICK SCHUESSLER") == "PATRICK SCHUESSLER")
        #expect(after.hiddenWays(of: "Patrick Schüßler").isEmpty)
        // An off from before this build (no `ways`) spoke for that one name: it stays a row of its own, off,
        // and a way that folds like it is hidden.
        var older = Self.learned()
        older.placeholder = older.placeholder.map { var e = $0; e.formOf = nil; return e }
        Self.set(&older, "Patrick Schüßler", .off, at: Self.t0, ways: false)
        older = older.settled()
        let row = older.placeholder.first { $0.original == "Patrick Schüßler" }
        #expect(row?.formOf == nil && row?.partOf == nil)
        #expect(Self.out(older, "Patrick Schüßler") == "Patrick Schüßler")
        #expect(Self.out(older, "Patrick Schuessler") != "Patrick Schuessler")
    }

    @Test("F027 AC-14 · every word a part holds reaches an older build inside a whole")
    func partsInsideWholes() {
        var p = Pseudonymizer(mode: .placeholder)
        p.learnAdmitted(["Patrick Schüßler", "Mirela Ottilie Brankovan", "Lotta Schüßler", "Monsieur Garrigou"].map { Self.entity(.person, $0) })
        p.learnAdmitted([Self.entity(.organization, "Ostwind Reiseschutz AG"), Self.entity(.place, "Göttingen")])
        p.learnAdmitted(["Mirela Ottilie", "Patrick Schüßler via Doodle", "SCHÜSSLER Patrick", "Patrick Schuessler", "#3 Patrick Schüßler",
                         "P. Schüßler", "Schüßler, Patrick (Radwerk Berlin GmbH)", "Herr Schüßler", "Mme Lestrade"].map { Self.entity(.person, $0) })
        p.learnAdmitted([Self.entity(.organization, "P7 Ostwind Reiseschutz AG"), Self.entity(.place, "Goettingen"),
                         Self.entity(.postalCity, "37073 Göttingen"), Self.entity(.street, "Lindenstraße 4")])
        // What an older build takes over: every entry without part_of, a way of writing included.
        let wholes = p.entries.filter { $0.partOf == nil }.map { " " + Pseudonymizer.words(Pseudonymizer.key($0.original)).joined(separator: " ") + " " }
        let parts = p.entries.filter { $0.partOf != nil }
        #expect(!parts.isEmpty)
        for part in parts {
            let word = " " + Pseudonymizer.words(Pseudonymizer.key(part.original)).joined(separator: " ") + " "
            #expect(wholes.contains { $0.contains(word) }, "\(part.original) reaches an older build in no whole")
        }
    }

    @Test("F027 AC-14 · a switch from an older build stays as narrow as it was turned")
    func olderSwitchIsNarrow() throws {
        // An older build turns off one way it holds as a whole of its own: only that way is let go (its words
        // stay hidden where his row, still on, holds them); here it leaves its row, a row of its own, off.
        var mapping = Self.learned(ahlers: false)
        let tag = try #require(Pseudonymizer(mapping).standIn(for: "Patrick Schüßler"))
        Self.set(&mapping, "Patrick Schuessler", .off, at: Self.t0, ways: false)
        let hidden = Set(Pseudonymizer(mapping).hidden.map(\.original))
        #expect(!hidden.contains("Patrick Schuessler"))
        for way in Self.patricksWays where way != "Patrick Schuessler" {
            #expect(hidden.contains(way), "\(way) was let go")
            #expect(Pseudonymizer.tags(in: Self.out(mapping, way)) == [tag], "\(way)")
        }
        #expect(Self.out(mapping, "Schüßler") == tag)
        mapping = mapping.settled()
        let way = try #require(mapping.placeholder.first { $0.original == "Patrick Schuessler" })
        #expect(way.formOf == nil && way.partOf == nil && way.standIn == tag)
        // It turns off the row's own name: only that name; the plainest other way becomes the row.
        var own = Self.learned(ahlers: false)
        Self.set(&own, "Patrick Schüßler", .off, at: Self.t0, ways: false)
        #expect(!Pseudonymizer(own).hidden.contains { $0.original == "Patrick Schüßler" })
        #expect(Self.out(own, "Herrn Patrick Schüßler") == "Herrn \(tag)")
        own = own.settled()
        let newRow = try #require(own.placeholder.first { $0.original == "Patrick Schuessler" })
        #expect(newRow.formOf == nil && newRow.partOf == nil)
        #expect(own.placeholder.filter { $0.formOf != nil }.allSatisfy { $0.formOf == "Patrick Schuessler" })
        #expect(own.placeholder.first { $0.original == "Patrick Schüßler" }.map { $0.formOf == nil && $0.partOf == nil } == true)
        #expect(own.placeholder.filter { $0.partOf == "Patrick Schüßler" }.isEmpty)
        #expect(Self.out(own, "Schüßler") == tag)
        // It deletes one way: only that way leaves the list.
        var gone = Self.learned(ahlers: false)
        Self.set(&gone, "Dr. Patrick Schüßler", .gone, at: Self.t0, ways: false)
        gone = gone.settled()
        #expect(!gone.placeholder.contains { $0.original == "Dr. Patrick Schüßler" })
        #expect(gone.placeholder.filter { $0.formOf == "Patrick Schüßler" }.count
                == Self.learned(ahlers: false).placeholder.filter { $0.formOf == "Patrick Schüßler" }.count - 1)
        // A row's off from here is, to an older build, off for that one name: no switch for its other ways.
        var here = Self.learned()
        Self.set(&here, "Patrick Schüßler", .off, at: Self.t0)
        let older = try JSONDecoder().decode(Older.Mapping.self, from: JSONEncoder().encode(here))
        #expect(older.switches?.count == 1 && older.switches?[Pseudonymizer.Mapping.hashed("Patrick Schüßler")]?.state == .off)
        // An older build's copy of the same switch lost the word `ways` when it wrote its own file: on a tie, `ways` is kept.
        let with = Pseudonymizer.Mapping.Switch(.off, at: Self.t0, ways: true), without = Pseudonymizer.Mapping.Switch(.off, at: Self.t0)
        for lists in [[["k": with], ["k": without]], [["k": without], ["k": with]]] {
            #expect(Pseudonymizer.Mapping.merged(lists)["k"] == with)
        }
    }
}
