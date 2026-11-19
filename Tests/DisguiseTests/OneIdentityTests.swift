import Foundation
import Testing
@testable import Disguise

/// What a rule or a door found, made by hand here, so the joining is tested on what it is given.
private func found(_ kind: Entity.Kind, _ text: String) -> Entity {
    Entity(kind: kind, text: text, field: .body, start: 0, length: (text as NSString).length, source: .rule)
}

/// Learned as the doors learn (what the gate admitted, Auto on) or as the owner's own words are (by hand, Auto off).
enum Path: CaseIterable { case admitted, byHand }

private func learn(_ texts: [(Entity.Kind, String)], into p: inout Pseudonymizer, by path: Path) {
    switch path {
    case .admitted: p.learnAdmitted(texts.map { found($0.0, $0.1) })
    case .byHand: for (kind, text) in texts { p.learn(kind, text) }
    }
}

private func people(_ texts: [String]) -> [(Entity.Kind, String)] { texts.map { (.person, $0) } }

/// F027 AC-1 to AC-4: one person, company or place, however written, is one row and one stand-in;
/// when it is not clear, they stay apart. Every name here is made up.
@Suite("F027 · One identity, one stand-in")
struct OneIdentityTests {
    /// AC-1's ways of writing Patrick Schüßler, and what each goes out as.
    static let ways: [(written: String, out: String?)] = [
        ("Herrn Patrick Schüßler", "Herrn [Person A]"),
        ("Patrick", "[Person A]"),
        ("SCHÜSSLER Patrick", "[Person A]"),
        ("Schuessler", "[Person A]"),
        ("Schüßler, Patrick", "[Person A]"),
        ("Patrick Schuessler", "[Person A]"),
        ("'Patrick Schüßler'", nil),
        ("Dr. Patrick Schüßler", "Dr. [Person A]"),
    ]

    /// Every way goes out as his one stand-in, and the list holds one row for him.
    static func expectOne(_ p: Pseudonymizer, row: String? = "Patrick Schüßler", _ comment: String) {
        let tag = p.standIn(for: "Patrick Schüßler").flatMap(Pseudonymizer.personTag)
        for way in ways {
            let out = p.disguiser.apply(way.written).text
            if let expected = way.out?.replacingOccurrences(of: "[Person A]", with: tag ?? "?") {
                #expect(out == expected, "\(comment): \(way.written) went out as \(out)")
            }
            #expect(Pseudonymizer.tags(in: out) == [tag ?? "?"], "\(comment): \(way.written) went out as \(out)")
            for word in ["Patrick", "Schüßler", "Schuessler", "SCHÜSSLER"] { #expect(!out.contains(word), "\(comment): \(out)") }
        }
        let rows = p.entries.filter { $0.kind == .person && $0.partOf == nil && $0.formOf == nil }.map(\.original)
        #expect(rows.count == 1, "\(comment): rows \(rows)")
        if let row { #expect(rows == [row], "\(comment): rows \(rows)") }
        let root = rows.first ?? ""
        for entry in p.entries where entry.kind == .person && entry.original != root {
            #expect(entry.formOf == root || entry.partOf == root, "\(comment): \(entry.original) is not under \(root)")
            #expect(entry.partOf == nil || entry.formOf == nil)
        }
    }

    @Test("F027 AC-1 · one person, however written, is one stand-in: in one batch, and send by send in any order", arguments: Path.allCases)
    func onePerson(path: Path) {
        let written = Self.ways.map(\.written)
        let orders = [written, Array(written.reversed()), Array(written[3...] + written[..<3]), Array(written[5...] + written[..<5])]
        for (n, order) in orders.enumerated() {
            // The list knows him; then every way, in one batch.
            var batch = Pseudonymizer(mode: .placeholder)
            learn(people(["Patrick Schüßler"]), into: &batch, by: path)
            learn(people(order), into: &batch, by: path)
            Self.expectOne(batch, "\(path), one batch, order \(n)")
            // Send by send.
            var sends = Pseudonymizer(mode: .placeholder)
            learn(people(["Patrick Schüßler"]), into: &sends, by: path)
            for text in order { learn(people([text]), into: &sends, by: path) }
            Self.expectOne(sends, "\(path), send by send, order \(n)")
        }
        // All nine in one batch, the list knowing none: still one person; a plain way is the row.
        var fresh = Pseudonymizer(mode: .placeholder)
        learn(people(Array(written.reversed()) + ["Patrick Schüßler"]), into: &fresh, by: .admitted)
        Self.expectOne(fresh, row: nil, "nine in one batch")
        let row = fresh.entries.first { $0.kind == .person && $0.partOf == nil && $0.formOf == nil }?.original
        #expect(row == "Patrick Schüßler" || row == "Patrick Schuessler", "the row is \(row ?? "none")")
    }

    @Test("F027 AC-1 · a later spelling never splits him: Herr Schüßler stays his", arguments: Path.allCases)
    func laterSpelling(path: Path) {
        var p = Pseudonymizer(mode: .placeholder)
        for text in ["Patrick Schüßler", "Herr Schüßler", "Patrick Schuessler", "SCHÜSSLER Patrick", "Schüßler, Patrick"] {
            learn(people([text]), into: &p, by: path)
        }
        let tag = p.standIn(for: "Patrick Schüßler") ?? "?"
        #expect(p.disguiser.apply("Herr Schüßler").text == "Herr \(tag)")
        #expect(p.disguiser.apply("Schüßler").text == tag)
        #expect(p.disguiser.apply("Schuessler").text == tag)
        #expect(p.disguiser.apply("Patrick").text == tag)
        #expect(p.disguiser.apply("Hallo Patrick Schuessler").text == "Hallo \(tag)")
        #expect(p.entries.first { $0.original == "Herr Schüßler" }?.formOf == "Patrick Schüßler")
        #expect(Set(p.entries.filter { $0.kind == .person }.compactMap { Pseudonymizer.personTag($0.standIn) }) == [tag])
    }

    @Test("F027 AC-1 · folded only to join: a list holding Falle leaves Fälle as written")
    func foldedOnlyToJoin() {
        var p = Pseudonymizer(mode: .placeholder)
        p.learnAdmitted([found(.person, "Frau Falle"), found(.person, "Patrick Schüßler"), found(.person, "Patrick Schuessler")])
        #expect(p.standIn(for: "Falle") != nil)
        #expect(p.disguiser.apply("Die Fälle sind klar.").text == "Die Fälle sind klar.")
        #expect(p.disguiser.apply("Frau Falle kommt.").text != "Frau Falle kommt.")
        #expect(Pseudonymizer.fold("Fälle") != Pseudonymizer.fold("Falle"))
        #expect(Pseudonymizer.fold("'SCHÜSSLER'") == Pseudonymizer.fold("Schuessler"))
        #expect(Pseudonymizer.fold("Schüßler") == Pseudonymizer.fold("Schuessler"))
        // Never stored: the list keeps each way as it was written, and a switch's hash is by `key`.
        #expect(p.entries.contains { $0.original == "Patrick Schuessler" })
        #expect(Pseudonymizer.Mapping.hashed("Patrick Schuessler") != Pseudonymizer.Mapping.hashed("Patrick Schüßler"))
    }

    @Test("F027 AC-2 · a company, a place and a street written another way go out as their row's stand-in", arguments: Path.allCases)
    func companyPlaceStreet(path: Path) {
        var p = Pseudonymizer(mode: .placeholder)
        learn([(.organization, "Radwerk Berlin GmbH"), (.place, "Göttingen"), (.street, "Lindenstraße 4")], into: &p, by: path)
        let company = p.standIn(for: "Radwerk Berlin GmbH"), place = p.standIn(for: "Göttingen"), street = p.standIn(for: "Lindenstraße 4")
        learn([(.organization, "RADWERK BERLIN GMBH"), (.organization, "'Radwerk Berlin GmbH'"), (.place, "Goettingen"),
               (.street, "LINDENSTRASSE 4"), (.street, "Lindenstrasse 4")], into: &p, by: path)
        for (written, row, standIn) in [("RADWERK BERLIN GMBH", "Radwerk Berlin GmbH", company), ("'Radwerk Berlin GmbH'", "Radwerk Berlin GmbH", company),
                                         ("Goettingen", "Göttingen", place), ("LINDENSTRASSE 4", "Lindenstraße 4", street),
                                         ("Lindenstrasse 4", "Lindenstraße 4", street)] {
            #expect(p.standIn(for: written) == standIn, "\(path): \(written) is \(p.standIn(for: written) ?? "nothing")")
            #expect(p.disguiser.apply(written).text == standIn, "\(path): \(written) went out as \(p.disguiser.apply(written).text)")
            if let entry = p.entries.first(where: { $0.original == written }) {
                #expect(entry.formOf == row && entry.partOf == nil, "\(path): \(written) is no way of \(row)")
            }
        }
        #expect(p.entries.filter { $0.partOf == nil && $0.formOf == nil }.count == 3)
    }

    @Test("F027 AC-2 · Radwerk GmbH is not Radwerk Berlin GmbH; an email, a phone, a bank account and a reference are never folded", arguments: Path.allCases)
    func neverFolded(path: Path) {
        let pairs: [(Entity.Kind, String, String)] = [
            (.organization, "Radwerk Berlin GmbH", "Radwerk GmbH"),
            (.email, "p.schuessler@radwerk-berlin.example", "p.schüßler@radwerk-berlin.example"),
            (.phone, "030 5550 1234", "030  5550 1234"),
            (.iban, "DE00 1111 2222 3333 4444 55", "DE00  1111 2222 3333 4444 55"),
            (.reference, "Kd-Nr. ÄB 4471", "Kd-Nr. AEB 4471"),
        ]
        for (kind, first, second) in pairs {
            var p = Pseudonymizer(mode: .placeholder)
            learn([(kind, first)], into: &p, by: path)
            learn([(kind, second)], into: &p, by: path)
            #expect(p.standIn(for: first) != nil && p.standIn(for: second) != nil)
            #expect(p.standIn(for: first) != p.standIn(for: second), "\(path): \(second) took \(first)'s stand-in")
            #expect(p.entries.allSatisfy { $0.formOf == nil }, "\(path): \(second) was joined")
        }
    }

    enum FurtherWay: String, CaseIterable { case frenchTitles }

    @Test("F027 AC-3 · the further ways, as the owner picked them", arguments: FurtherWay.allCases, Path.allCases)
    func furtherWays(way: FurtherWay, path: Path) {
        var p = Pseudonymizer(mode: .placeholder)
        switch way {
        case .frenchTitles:
            // Monsieur, Madame, Mademoiselle, Mme and Mlle are titles, like Herr and Frau: kept in front, never learned.
            learn(people(["Monsieur Garrigou", "Mme Lestrade", "Madame Brankovan", "Mlle. Kolbeck", "Mademoiselle"]), into: &p, by: path)
            let garrigou = p.standIn(for: "Garrigou") ?? "?", lestrade = p.standIn(for: "Lestrade") ?? "?"
            #expect(garrigou != lestrade)
            #expect(p.disguiser.apply("Monsieur Garrigou").text == "Monsieur \(garrigou)")
            #expect(p.disguiser.apply("Mme Lestrade").text == "Mme \(lestrade)")
            #expect(p.disguiser.apply("Mlle. Kolbeck").text.hasPrefix("Mlle. [Person "))
            #expect(p.disguiser.apply("Merci, Madame.").text == "Merci, Madame.")
            for title in ["Monsieur", "Madame", "Mademoiselle", "Mme", "Mme.", "Mlle", "Mlle."] {
                #expect(p.standIn(for: title) == nil, "\(path): \(title) was learned")
            }
        }
    }

    @Test("F027 AC-3 · the rules that find names keep 1.0.1's titles: none of the five in Ordinary.isTitle")
    func findingKeepsItsTitles() throws {
        for title in ["Monsieur", "Madame", "Mademoiselle", "Mme", "Mme.", "Mlle", "Mlle."] {
            #expect(!Ordinary.isTitle(title), "\(title) is a title for the rules that find names")
            #expect(!Pseudonymizer.isTitle(title))
            #expect(Pseudonymizer.isListTitle(title), "\(title) is no title for the list")
        }
        for title in ["Herr", "Frau", "Dr.", "Dr.med."] { #expect(Ordinary.isTitle(title) && Pseudonymizer.isListTitle(title)) }
        // The source: `Ordinary.isTitle` reads 1.0.1's titles, and `honorifics` holds none of the five.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Disguise")
        let ordinary = try String(contentsOf: sources.appendingPathComponent("Detection/Ordinary.swift"), encoding: .utf8)
        #expect(ordinary.contains("static func isTitle(_ word: String) -> Bool { Pseudonymizer.isTitle(word) }"))
        #expect(!ordinary.contains("isListTitle"))
        let pseudonymizer = try String(contentsOf: sources.appendingPathComponent("Pseudonymizer.swift"), encoding: .utf8)
        let honorifics = try #require(pseudonymizer.components(separatedBy: "public static let honorifics").dropFirst().first?
            .components(separatedBy: ".union(roles)").first)
        for title in ["monsieur", "madame", "mademoiselle", "mme", "mlle"] { #expect(!honorifics.contains(title)) }
    }
}
