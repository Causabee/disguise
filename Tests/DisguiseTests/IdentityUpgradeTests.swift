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

    // MARK: A list from before

    static let fixtures: URL = {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        if FileManager.default.fileExists(atPath: here.path) { return here }
        return Bundle.module.url(forResource: "Fixtures", withExtension: nil) ?? here
    }()

    /// A version 6 list as 1.0.1 wrote it, its placeholder list learned send by send by 1.0.1's own code
    /// (b164096) from made-up names: Patrick Schüßler written many ways, companies, places, a street,
    /// numbers, two rows the owner turned off (F022), one deleted, junk, and every key. Its stand-in mode
    /// list is three made-up lines: the stand-in pool's own names would trip `F024NamesTests`.
    static func olderList() throws -> Pseudonymizer.Mapping {
        try JSONDecoder().decode(Pseudonymizer.Mapping.self, from: Data(contentsOf: fixtures.appendingPathComponent("f027-list-v6.json")))
    }

    static func entry(_ m: Pseudonymizer.Mapping, _ original: String) -> Pseudonymizer.Entry? {
        m.placeholder.first { $0.original == original }
    }

    static func tag(_ m: Pseudonymizer.Mapping, _ original: String) -> String? {
        entry(m, original).flatMap { Pseudonymizer.tags(in: $0.standIn).first }
    }

    /// What an older build writes when it copies this build's list: no `joined`, no `form_of`, no `ways`.
    static func copiedByAnOlderBuild(_ m: Pseudonymizer.Mapping) -> Pseudonymizer.Mapping {
        var copy = m
        copy.joined = nil
        copy.placeholder = copy.placeholder.map { var e = $0; e.formOf = nil; return e }
        copy.switches = copy.switches?.mapValues { .init($0.state, at: $0.at) }
        return copy
    }

    @Test("F027 AC-12 · a version 6 list is joined once: every key, off row and deleted entry kept, junk left")
    func joinedOnce() throws {
        let before = try Self.olderList()
        #expect(before.version == 6 && before.joined == nil)
        var after = before
        #expect(after.upgrade() == 0, "a word would have gone out")
        #expect(after.version == Pseudonymizer.Mapping.current && after.version == 7 && after.joined == 1)
        // Every key kept as it was; the stand-in mode's list untouched.
        #expect(after.cleaned == before.cleaned && after.level == before.level && after.fresh == before.fresh)
        #expect(after.switches == before.switches && after.standin == before.standin)
        // The rows the owner turned off stay as they are: their own row, off, with their parts.
        for off in ["Patrick Schuessler", "Tamsin Harlander"] {
            #expect(Self.entry(after, off) == Self.entry(before, off), "\(off) changed")
            for part in before.placeholder where part.partOf == off { #expect(Self.entry(after, part.original) == part) }
        }
        // The deleted entry does not come back; junk stays.
        #expect(Self.entry(after, "Lotta Kloss") == nil)
        for junk in ["Kontoauszug Seite", "Anlage Drei"] { #expect(Self.entry(after, junk) == Self.entry(before, junk)) }
        // The ways of writing Patrick Schüßler are ways of his row, with his stand-in.
        let patrick = try #require(Self.tag(after, "Patrick Schüßler"))
        #expect(patrick == Self.tag(before, "Patrick Schüßler"), "a row keeps its stand-in")
        for way in ["Herrn Patrick Schüßler", "SCHÜSSLER Patrick", "Schüßler, Patrick", "'Patrick Schüßler'", "Dr. Patrick Schüßler",
                    "Schüßler, Patrick (Radwerk Berlin GmbH)", "Patrick Schüßler via Doodle", "#3 Patrick Schüßler"] {
            #expect(Self.entry(after, way)?.formOf == "Patrick Schüßler", "\(way) is no way of his row")
            #expect(Self.tag(after, way) == patrick, "\(way): \(Self.entry(after, way)?.standIn ?? "gone")")
        }
        let p = Pseudonymizer(after)
        #expect(p.disguiser.apply("Herrn Patrick Schüßler, SCHÜSSLER Patrick").text == "Herrn \(patrick), \(patrick)")
        // Companies, places and streets written another way: ways of their rows, with their stand-ins.
        for (way, row) in [("'Radwerk Berlin GmbH'", "Radwerk Berlin GmbH"), ("P7 Ostwind Reiseschutz AG", "Ostwind Reiseschutz AG"),
                           ("LINDENSTRASSE 4", "Lindenstraße 4")] {
            #expect(Self.entry(after, way)?.formOf == row, "\(way) is no way of \(row)")
            #expect(Self.entry(after, way)?.standIn == Self.entry(after, row)?.standIn)
        }
        #expect(p.disguiser.apply("Goettingen").text == Self.tag(after, "Göttingen"))
        #expect(Self.entry(after, "Doodle").map { $0.partOf == nil && $0.formOf == nil } == true, "a service 1.0.1 learned stays a company row")
        // The first words of one full name; its middle name and first name go back to her.
        let mirela = try #require(Self.tag(after, "Mirela Ottilie Brankovan"))
        #expect(Self.entry(after, "Mirela Ottilie")?.formOf == "Mirela Ottilie Brankovan")
        #expect(Self.tag(after, "Ottilie") == mirela && Self.tag(after, "Mirela") == mirela)
        // Apart: the initial, the surname two share, the first words of two names, the stranger.
        #expect(Self.entry(after, "P. Schüßler").map { $0.formOf == nil && $0.partOf == nil } == true)
        let shared = try #require(Self.tag(after, "Schüßler"))
        #expect(![patrick, Self.tag(after, "Lotta Schüßler"), Self.tag(after, "P. Schüßler")].contains(shared))
        #expect(Self.tag(after, "Herr Schüßler") == shared && Self.entry(after, "Herr Schüßler")?.formOf == nil)
        #expect(Self.entry(after, "Tamsin Liv")?.formOf == nil && Self.tag(after, "Patrick Ahlers") != patrick)
        // The French titles go out as written, in front of the stand-in; none is an entry.
        #expect(Self.entry(after, "Monsieur Garrigou")?.standIn.hasPrefix("Monsieur [Person ") == true)
        #expect(Self.entry(after, "Mme Lestrade")?.standIn.hasPrefix("Mme [Person ") == true)
        #expect(Self.entry(after, "Monsieur") == nil && Self.entry(after, "Mme") == nil)
        // Every row that was a whole before keeps its stand-in.
        let rows = after.placeholder.filter { $0.partOf == nil && $0.formOf == nil }
        for row in rows where !Pseudonymizer.frenchTitles.contains(Pseudonymizer.key(Pseudonymizer.words(row.original).first ?? "")) {
            if let old = Self.entry(before, row.original), old.partOf == nil { #expect(row.standIn == old.standIn, "\(row.original)") }
        }
    }

    @Test("F027 AC-12 · a second run, and a list this build learned, change nothing")
    func secondRun() throws {
        var once = try Self.olderList()
        once.upgrade()
        var twice = once
        #expect(twice.upgrade() == 0)
        #expect(twice == once)
        // Copied and written again by an older build, it is joined again when read: the same list.
        var copied = Self.copiedByAnOlderBuild(once)
        copied.upgrade()
        #expect(copied.placeholder == once.placeholder)
        #expect(copied.version == 7 && copied.joined == 1)
        // A list this build learned: nothing to do, and joined again after an older build copied it, no letter moves.
        var p = Pseudonymizer(mode: .placeholder)
        func found(_ kind: Entity.Kind, _ text: String) -> Entity { Entity(kind: kind, text: text, field: .body, start: 0, length: 0, source: .rule) }
        for batch: [(Entity.Kind, String)] in [
            [(.person, "Herr Schüßler"), (.organization, "Radwerk Berlin GmbH"), (.postalCity, "37073 Göttingen")],
            [(.person, "Patrick Schüßler"), (.person, "Patrick Ahlers"), (.place, "Goettingen")],
            [(.person, "SCHÜSSLER Patrick"), (.person, "Schuessler"), (.organization, "'Radwerk Berlin GmbH'"), (.person, "Patrick")],
            [(.person, "Mirela Ottilie Brankovan"), (.person, "Patrick Schüßler via Doodle"), (.organization, "B12 Ostwind Reiseschutz AG")],
            [(.person, "Mirela Ottilie"), (.person, "P. Schüßler"), (.person, "Lotta Schüßler"), (.person, "Monsieur Garrigou")],
        ] { p.learnAdmitted(batch.map { found($0.0, $0.1) }) }
        var learned = Pseudonymizer.Mapping()
        learned.placeholder = p.entries
        learned.switches = [:]
        var same = learned
        #expect(same.upgrade() == 0 && same == learned)
        var rejoined = Self.copiedByAnOlderBuild(learned)
        rejoined.upgrade()
        #expect(rejoined.placeholder.map(\.original).sorted() == learned.placeholder.map(\.original).sorted())
        for entry in learned.placeholder {
            #expect(Self.entry(rejoined, entry.original)?.standIn == entry.standIn, "\(entry.original): \(entry.standIn) became \(Self.entry(rejoined, entry.original)?.standIn ?? "nothing")")
        }
    }

    /// The words of a text that went out as written: its letters and digits, the stand-ins taken out.
    static func written(_ text: String) -> Set<String> {
        var plain = text
        for range in Replacer.standIns(in: text).reversed() { plain.replaceSubrange(range, with: " ") }
        return Set(plain.split { !$0.isLetter && !$0.isNumber }.map { Pseudonymizer.key(String($0)) })
    }

    /// Every original of the list before, disguised with the list before and the list after: the words hidden
    /// before that go out as written after.
    static func lost(_ before: Pseudonymizer.Mapping, _ after: Pseudonymizer.Mapping) -> [String: Set<String>] {
        func hiding(_ m: Pseudonymizer.Mapping) -> Pseudonymizer {
            Pseudonymizer(mode: .placeholder, entries: Pseudonymizer.shed(m.placeholder, dropped: m.gone), off: m.outAsWritten())
        }
        let (b, a) = (hiding(before).disguiser, hiding(after).disguiser)
        var out: [String: Set<String>] = [:]
        for original in Set(before.placeholder.map(\.original)) {
            let words = written(original)
            let lost = words.subtracting(written(b.apply(original).text)).intersection(written(a.apply(original).text))
            if !lost.isEmpty { out[original] = lost }
        }
        return out
    }

    /// A grown list of thousands of made-up names, shaped as 1.0.1 learned them: a tag of its own for each
    /// spelling and order, a word two people share split off with a tag of its own.
    static func grownList(people count: Int) -> Pseudonymizer.Mapping {
        let first = ["Ka", "Lo", "Mi", "Ru", "Ta", "We", "Jo", "Fe", "Ha", "Ni", "Sö", "Gü"], middle = ["ri", "na", "le", "mo", "ta", "su", "ve"]
        let ends = ["ke", "nia", "rik", "dor", "lin", "mund"], stems = ["Brük", "Hössel", "Zän", "Mürk", "Kalb", "Torn", "Weiß", "Grun", "Lös", "Fahl"]
        let tails = ["ler", "mann", "inger", "eck", "hardt", "witz", "ow", "rich", "bach"]
        var entries: [Pseudonymizer.Entry] = [], index: [String: Int] = [:], fullTags: Set<String> = [], fullNames: [String: String] = [:]
        var number = 0
        func newTag(_ label: String) -> String {
            var n = number, letters = ""
            repeat { letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters; n = n / 26 - 1 } while n >= 0
            number += 1
            return "[\(label) \(letters)]"
        }
        func add(_ e: Pseudonymizer.Entry) { guard index[Pseudonymizer.key(e.original)] == nil else { return }; index[Pseudonymizer.key(e.original)] = entries.count; entries.append(e) }
        func person(_ whole: String, given: String?, family: String, title: String? = nil) {
            guard index[Pseudonymizer.key(whole)] == nil else { return }
            guard let given else {
                let tag = index[Pseudonymizer.key(family)].flatMap { Pseudonymizer.personTag(entries[$0].standIn) } ?? newTag("Person")
                add(.init(kind: .person, original: whole, standIn: [title, tag].compactMap { $0 }.joined(separator: " ")))
                add(.init(kind: .person, original: family, standIn: tag, partOf: whole))
                return
            }
            let key = Pseudonymizer.key(given) + "|" + Pseudonymizer.key(family)
            let tag = fullNames[key] ?? newTag("Person")
            fullNames[key] = tag
            fullTags.insert(tag)
            add(.init(kind: .person, original: whole, standIn: [title, tag].compactMap { $0 }.joined(separator: " ")))
            for part in [given, family] {
                if let at = index[Pseudonymizer.key(part)] {
                    guard let old = Pseudonymizer.personTag(entries[at].standIn), old != tag, fullTags.contains(old) else { continue }
                    let own = newTag("Person")
                    for i in entries.indices where Pseudonymizer.personTag(entries[i].standIn) == old {
                        let words = Pseudonymizer.words(entries[i].original).filter { !Pseudonymizer.isTitle($0) }
                        if i == at || words.map(Pseudonymizer.key) == [Pseudonymizer.key(part)] {
                            entries[i].standIn = entries[i].standIn.replacingOccurrences(of: old, with: own)
                        }
                    }
                } else { add(.init(kind: .person, original: part, standIn: tag, partOf: whole)) }
            }
        }
        for i in 0..<count {
            let given = first[i % first.count] + middle[(i / first.count) % middle.count] + ends[(i / 7) % ends.count]
            let family = stems[(i / 3) % stems.count] + tails[(i / 11) % tails.count] + (i % 5 == 0 ? "" : String(repeating: "e", count: i % 4))
            person("\(given) \(family)", given: given, family: family)
            let spelled = family.replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ö", with: "oe")
                .replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ß", with: "ss")
            if i % 3 == 0 { person("Herr \(family)", given: nil, family: family, title: "Herr") }
            if i % 4 == 0, spelled != family { person("\(given) \(spelled)", given: given, family: spelled) }
            if i % 5 == 0 { person("\(family), \(given)", given: given, family: family) }
            if i % 6 == 0 { person("\(family.uppercased()) \(given)", given: family.uppercased(), family: given) }
            if i % 9 == 0 { add(.init(kind: .organization, original: "\(family) Werkstatt GmbH", standIn: newTag("Company"))) }
            if i % 9 == 0 { add(.init(kind: .organization, original: "'\(family) Werkstatt GmbH'", standIn: newTag("Company"))) }
        }
        var mapping = Pseudonymizer.Mapping()
        mapping.version = 6
        mapping.joined = nil
        mapping.placeholder = entries
        mapping.switches = [:]
        return mapping
    }

    @Test("F027 AC-13 · never less hidden: every name of a grown made-up list, disguised before and after, word by word")
    func neverLessHidden() throws {
        let titles = Pseudonymizer.frenchTitles
        // The list from before.
        let before = try Self.olderList()
        var after = before
        after.upgrade()
        let lost = Self.lost(before, after)
        #expect(lost.values.allSatisfy { $0.isSubset(of: titles) }, "\(lost)")
        #expect(lost.values.contains { !$0.isEmpty }, "the French titles go out as written: the owner's one exception")
        // A grown list of thousands, in one go: the time is printed, and nothing goes out that was hidden.
        let grown = Self.grownList(people: 2_400)
        var joined = grown
        let start = Date()
        joined.upgrade()
        let seconds = Date().timeIntervalSince(start)
        func people(_ m: Pseudonymizer.Mapping) -> (rows: Int, standIns: Int) {
            let persons = m.placeholder.filter { $0.kind == .person }
            return (persons.filter { $0.partOf == nil && $0.formOf == nil }.count, Set(persons.compactMap { Pseudonymizer.personTag($0.standIn) }).count)
        }
        print("F027 AC-12 · a made-up list of \(grown.placeholder.count) entries joined and checked in \(String(format: "%.2f", seconds)) s;",
              "person rows \(people(grown).rows) → \(people(joined).rows), person stand-ins \(people(grown).standIns) → \(people(joined).standIns)")
        #expect(people(joined).rows < people(grown).rows && people(joined).standIns < people(grown).standIns)
        let grownLost = Self.lost(grown, joined)
        #expect(grownLost.isEmpty, "\(grownLost.prefix(5))")
        // A word a faulty join would let out is put back: a row of its own, with a stand-in no one else has.
        var faulty = after
        faulty.placeholder.removeAll { $0.original == "Ottilie" }
        let used = Set(faulty.placeholder.flatMap { Pseudonymizer.tags(in: $0.standIn) })
        #expect(faulty.putBack(before: before) == 1)
        let back = try #require(Self.entry(faulty, "Ottilie"))
        #expect(back.partOf == nil && back.formOf == nil && !used.contains(back.standIn))
        #expect(Self.lost(before, faulty).values.allSatisfy { $0.isSubset(of: titles) })
    }
}
