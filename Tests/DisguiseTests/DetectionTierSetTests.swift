import CryptoKit
import Foundation
import Testing
@testable import Disguise

/// F021's tiers, in the owner's order: A names, B places and numbers, C dates of birth. The map
/// from a kind to its tier (How, "The map", answer 1a). The old fixtures' `name` is A.
enum Tier: String, CaseIterable, Comparable {
    case A, B, C

    static func of(_ kind: String) -> Tier? {
        switch kind {
        case "person", "company", "name": .A
        case "address", "iban", "insurance-number", "id-number", "phone", "email", "plate": .B
        case "birth-date": .C
        default: nil
        }
    }

    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
}

/// F021 AC-3: the tier set, written by someone who did not write the rules, frozen by its hash.
/// Its cases come by every source: what comes in (mail, screenshots, photos, files and scans),
/// notes, the chat, and tasks and dates added by hand.
@Suite("F021 · The tier set")
@MainActor
struct DetectionTierSetTests {
    static let file = "detection-tiers.jsonl"
    /// The set as committed alone in 1b42db4. A change of the set is a change of this pin, with a
    /// README line, and goes to the owner. F024 AC-2: re-pinned when every personal detail in the
    /// cases was made up (new names, birth dates and numbers; the cases and their kinds unchanged).
    static let pin = "7f1c83efe108ef1bf64b1fe4c3c72c58be8893fec5ccd29c898f326872d9f978"
    static let sources = ["mail", "screenshot-chat", "screenshot-other", "photo", "scan", "note", "chat-typed", "todo-by-hand", "date-by-hand", "file-name"]

    struct Head: Decodable { var set: String; var by: String; var saw: String; var written: String; var made_up: Bool }

    struct Case: Decodable {
        struct Field: Decodable { var field: String; var text: String }
        struct Identifier: Decodable { var text: String; var kind: String; var tier: String }
        var id: String
        var source: String
        var lang: String
        var fields: [Field]
        var identifiers: [Identifier]
        var stay: [String]
        var from: String

        var tiers: Set<String> { Set(identifiers.map(\.tier)) }
    }

    static func lines() throws -> [Substring] {
        let text = try String(contentsOf: DisguiseCorpusTests.fixtures.appendingPathComponent(file), encoding: .utf8)
        return text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func head() throws -> Head { try JSONDecoder().decode(Head.self, from: Data(try lines()[0].utf8)) }

    static func cases() throws -> [Case] {
        try lines().dropFirst().map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
    }

    /// Cases per source and tier.
    static func table() throws -> [String: [String: Int]] {
        var table: [String: [String: Int]] = [:]
        for item in try cases() { for tier in item.tiers { table[item.source, default: [:]][tier, default: 0] += 1 } }
        return table
    }

    @Test("F021 AC-3 · the head line says who and when")
    func headLine() throws {
        let head = try Self.head()
        print("F021 AC-3 · the tier set: \(try Self.lines()[0])")
        #expect(head.set == "F021 tiers")
        #expect(!head.by.isEmpty && !head.saw.isEmpty)
        #expect(head.written.hasPrefix("2026-11-"))
        #expect(head.made_up)
    }

    @Test("F021 AC-3 · at least 30 cases in B and in C")
    func minima() throws {
        let cases = try Self.cases()
        var lines = ["F021 AC-3 · \(cases.count) cases; per tier (cases with one of its items), per kind (items):"]
        for tier in Tier.allCases {
            let n = cases.filter { $0.tiers.contains(tier.rawValue) }.count
            let kinds = Dictionary(grouping: cases.flatMap(\.identifiers).filter { $0.tier == tier.rawValue }, by: \.kind)
                .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
            lines.append("  \(tier.rawValue): \(n) cases · \(kinds)")
        }
        print(lines.joined(separator: "\n"))
        #expect(cases.filter { $0.tiers.contains("B") }.count >= 30)
        #expect(cases.filter { $0.tiers.contains("C") }.count >= 30)
        #expect(cases.contains { $0.tiers.contains("A") })
    }

    @Test("F021 AC-3 · every source in every tier it can stand in")
    func everySource() throws {
        let table = try Self.table()
        var lines = ["F021 AC-3 · cases per source and tier (A B C):"]
        for source in Self.sources {
            let row = Tier.allCases.map { String(format: "%3d", table[source]?[$0.rawValue] ?? 0) }.joined(separator: " ")
            lines.append("  \(source.padding(toLength: 18, withPad: " ", startingAt: 0)) \(row)")
        }
        print(lines.joined(separator: "\n"))
        #expect(Set(try Self.cases().map(\.source)) == Set(Self.sources))
        // Every tier can stand in every source: a name in a to-do, an IBAN in a photo, a date of
        // birth in a file's name.
        for source in Self.sources {
            for tier in Tier.allCases {
                #expect((table[source]?[tier.rawValue] ?? 0) >= 3, "\(source), tier \(tier.rawValue): fewer than three cases")
            }
        }
    }

    @Test("F021 AC-3 · German or English only")
    func languages() throws {
        for item in try Self.cases() { #expect(["de", "en"].contains(item.lang), "\(item.id): \(item.lang)") }
    }

    @Test("F021 AC-3 · made-up only")
    func madeUp() throws {
        let text = try String(contentsOf: DisguiseCorpusTests.fixtures.appendingPathComponent(Self.file), encoding: .utf8)
        var addresses = 0, ibans = 0
        for match in text.matches(of: /[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)/) {
            let domain = String(match.output.1).lowercased()
            let reserved = ["example.org", "example.com", "example.net"].contains { domain == $0 || domain.hasSuffix("." + $0) }
            #expect(reserved, "a real-looking address \(match.output.0)")
            addresses += 1
        }
        for match in text.matches(of: /\b([A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30})\b/) {
            let bare = String(match.output.1).filter { $0 != " " }
            let moved = bare.dropFirst(4) + bare.prefix(4)
            var rest = 0
            for character in moved {
                let value = character.isNumber ? Int(String(character))! : Int(character.asciiValue! - 55)
                for digit in String(value) { rest = (rest * 10 + Int(String(digit))!) % 97 }
            }
            #expect(rest != 1, "\(bare) passes its check")
            ibans += 1
        }
        let kinds = try Self.cases().flatMap(\.identifiers)
        #expect(addresses >= kinds.filter { $0.kind == "email" }.count, "every mail address of the set was checked")
        #expect(ibans >= kinds.filter { $0.kind == "iban" }.count, "every IBAN of the set was checked")
    }

    @Test("F021 AC-3 · each identifier's tier is the map")
    func map() throws {
        for item in try Self.cases() {
            for identifier in item.identifiers {
                #expect(Tier.of(identifier.kind)?.rawValue == identifier.tier, "\(item.id): \(identifier.kind) is \(identifier.tier)")
            }
        }
    }

    @Test("F021 AC-3 · the set is pinned")
    func pinned() throws {
        let data = try Data(contentsOf: DisguiseCorpusTests.fixtures.appendingPathComponent(Self.file))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == Self.pin, "the tier set changed since it was committed alone")
    }
}
