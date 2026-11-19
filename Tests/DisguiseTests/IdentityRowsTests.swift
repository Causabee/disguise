import Foundation
import Testing
import Disguise

/// F027: the rows of a list as an app's page shows them, through the public interface only (no
/// `@testable`): one row for each person, company and place, named plainly, its ways behind it.
/// Every name here is made up.
@Suite("F027 · The rows of a list, public")
struct IdentityRowsTests {
    static func list(_ names: [(Entity.Kind, String)]) -> Pseudonymizer.Mapping {
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        for (kind, name) in names { _ = pseudonymizer.learn(kind, name) }
        var mapping = Pseudonymizer.Mapping()
        mapping.placeholder = pseudonymizer.entries
        mapping.switches = [:]
        return mapping
    }

    @Test("F027 AC-5 · one row for each person and company, named plainly, with every way it was written")
    func rows() throws {
        let mapping = Self.list([(.person, "Dr. Patrick Schüßler"), (.person, "Schüßler, Patrick"), (.person, "Patrick Schuessler"),
                                 (.person, "Patrick Ahlers"), (.organization, "Radwerk Berlin GmbH"), (.organization, "RADWERK BERLIN GMBH"),
                                 (.organization, "P7 Ostwind Reiseschutz AG")])
        let rows = mapping.settled().identities()
        let patrick = try #require(rows.first { $0.ways.contains("Schüßler, Patrick") })
        #expect(Set(patrick.ways) == ["Dr. Patrick Schüßler", "Schüßler, Patrick", "Patrick Schuessler"])
        #expect(patrick.name == "Patrick Schuessler", "the plainest way, with nothing taken off but what is no name")
        #expect(patrick.state == .on && patrick.hidden.isEmpty)
        #expect(rows.filter { $0.row.kind == .person }.count == 2, "a stranger is a row of his own; no part is a row")
        // Written in capitals, it is the same row: the matcher finds it as it is, so it is no way of its own.
        #expect(rows.filter { $0.row.kind == .organization && $0.name == "Radwerk Berlin GmbH" }.count == 1)
        #expect(rows.contains { $0.name == "Ostwind Reiseschutz AG" }, "a row's label is no part of its name")
        #expect(Pseudonymizer.Mapping.plainName("Herrn Patrick Schüßler", kind: .person) == "Patrick Schüßler")
        #expect(Pseudonymizer.Mapping.plainName("'Schüßler, Patrick'", kind: .person) == "Patrick Schüßler")
        #expect(Pseudonymizer.Mapping.plainName("Monsieur Garrigou", kind: .person) == "Garrigou")
    }

    @Test("F027 AC-8 · a row turned off with its ways, and a way that came in after, still hidden")
    func offAndHidden() throws {
        var mapping = Self.list([(.person, "Patrick Schüßler"), (.person, "Patrick Schuessler")])
        let base = mapping
        mapping.switches = [Pseudonymizer.Mapping.hashed("Patrick Schüßler"): .init(.off, at: Date(timeIntervalSince1970: 1_800_000_000), ways: true)]
        var pseudonymizer = Pseudonymizer(mapping)
        _ = pseudonymizer.learn(.person, "SCHÜSSLER Patrick")
        let before = mapping
        mapping.placeholder = pseudonymizer.entries
        mapping.settleNewWays(base: before, now: Date(timeIntervalSince1970: 1_800_000_100))
        let row = try #require(mapping.settled().identities().first { $0.ways.contains("Patrick Schüßler") })
        #expect(row.state == .off)
        #expect(row.hidden == ["SCHÜSSLER Patrick"])
        #expect(base.settled().identities().first?.state == .on)
    }
}
