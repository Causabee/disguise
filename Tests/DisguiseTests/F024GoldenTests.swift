import Foundation
import Testing
#if canImport(Disguise)
@testable import Disguise
#else
@testable import MatterCore
#endif

/// F024 AC-3: the hiding moved to a package of its own and gives the same bytes as before. The
/// golden file was written by the app's code before the move (commit dd001f6f), over every case text
/// of the fixtures: what the rules find in each field, and the field disguised in both modes, with a
/// list learned from what was found. The same test runs in the app and in the package.
@Suite("F024 · The same hiding as before")
struct F024GoldenTests {
    static let fixtures: URL = {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        if FileManager.default.fileExists(atPath: here.path) { return here }
        return Bundle.module.url(forResource: "Fixtures", withExtension: nil) ?? here
    }()
    static let sets = ["disguise-corpus.jsonl", "disguise-unseen.jsonl", "detection-tiers.jsonl", "bench-names.jsonl"]

    struct Row: Codable, Equatable {
        var id: String
        var field: String
        var found: [String]
        var placeholder: String
        var standin: String
    }

    /// Every field of every case, through the rules and the disguise.
    static func rows() throws -> [Row] {
        var rows: [Row] = []
        for set in sets {
            let text = try String(contentsOf: fixtures.appendingPathComponent(set), encoding: .utf8)
            for (number, line) in text.split(separator: "\n").enumerated() {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let fields = object["fields"] as? [[String: Any]] else { continue }
                let id = "\(set)#\((object["id"] as? String) ?? String(number))"
                for (index, field) in fields.enumerated() {
                    guard let body = field["text"] as? String else { continue }
                    let kind = Entity.Field(rawValue: (field["field"] as? String) ?? "body") ?? .body
                    let entities = Detection.finder().entities(in: body, field: kind)
                    var placeholder = Pseudonymizer(mode: .placeholder)
                    Detection.learn(entities, into: &placeholder)
                    var standin = Pseudonymizer(mode: .standin)
                    Detection.learn(entities, into: &standin)
                    rows.append(Row(id: "\(id).\(index)", field: kind.rawValue,
                                    found: entities.map { "\($0.kind.rawValue):\($0.text)@\($0.start)+\($0.length)" },
                                    placeholder: placeholder.disguiser.apply(body).text,
                                    standin: standin.disguiser.apply(body).text))
                }
            }
        }
        return rows
    }

    @Test("F024 AC-3 · the hiding gives the bytes the untouched code gave")
    func same() throws {
        let rows = try Self.rows()
        let file = Self.fixtures.appendingPathComponent("f024-golden.json")
        if let out = ProcessInfo.processInfo.environment["F024_WRITE_GOLDEN"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: out))
            return
        }
        let golden = try JSONDecoder().decode([Row].self, from: Data(contentsOf: file))
        #expect(rows.count == golden.count && rows.count > 100, "\(rows.count) fields now, \(golden.count) in the golden file")
        for (now, before) in zip(rows, golden) where now != before {
            Issue.record("\(now.id) differs: \(before) became \(now)")
        }
    }
}
