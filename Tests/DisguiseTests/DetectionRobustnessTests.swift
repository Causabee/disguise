import Foundation
import Testing
@testable import Disguise

/// F021, after TestFlight 276 (an index out of range in the new rules, on the owner's real text):
/// the rules run over every fixture text in the repository — what comes in (mail, screenshots,
/// photos, files and scans), notes, the chat, tasks and dates added by hand — and over each of them
/// shuffled, cut short, in lowercase and in capitals, and with every short run of words handed to
/// them as a tagger's span. Nothing may crash; what they find is not judged here.
@Suite("F021 · The rules never crash", .serialized)
@MainActor
struct DetectionRobustnessTests {
    static func texts() throws -> [String] {
        var out: [String] = []
        for file in ["disguise-corpus.jsonl", "disguise-unseen.jsonl", "detection-tiers.jsonl", "bench-names.jsonl"] {
            let url = DisguiseCorpusTests.fixtures.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                for field in (object["fields"] as? [[String: Any]]) ?? [] { if let t = field["text"] as? String { out.append(t) } }
                if let t = object["text"] as? String { out.append(t) }
            }
        }
        return out
    }

    /// The same text shuffled (a fixed order), cut short, small, shouted.
    static func variants(_ text: String, seed: Int) -> [String] {
        var words = text.split(separator: " ").map(String.init)
        var state = UInt64(seed + 1)
        for i in words.indices.reversed() where i > 0 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            words.swapAt(i, Int(state >> 33) % (i + 1))
        }
        return [text, words.joined(separator: " "), String(text.prefix(text.count / 2)), String(text.prefix(text.count / 3)),
                text.lowercased(), text.uppercased()]
    }

    @Test("F021 · every fixture text and its variants, through the finder and every tagger span: no crash")
    func noCrash() throws {
        let texts = try Self.texts()
        #expect(texts.count > 200, "\(texts.count) texts")
        let finder = RuleFinder()
        var runs = 0
        for (n, text) in texts.enumerated() {
            for variant in Self.variants(text, seed: n) {
                _ = finder.found(in: variant, field: .body)
                _ = finder.found(in: variant, field: .attachmentName)
                var typed = finder
                typed.typed = true
                _ = typed.found(in: variant, field: .body)
                // Every run of two to five words as a person's, a place's and a company's span.
                var read = RuleFinder.Reading(text: variant, finder: RuleFinder(runsTagger: false))
                let tokens = read.tokens
                for start in tokens.indices {
                    for length in 2...5 where start + length <= tokens.count {
                        let span = tokens[start].range.lowerBound..<tokens[start + length - 1].range.upperBound
                        read.tagged = [.init(kind: .person, range: span), .init(kind: .place, range: span), .init(kind: .organization, range: span)]
                        read.people = [span]
                        _ = finder.taggedPeople(read, field: .body)
                        _ = finder.taggedPlaces(read, field: .body)
                        _ = finder.companies(read, field: .body)
                        runs += 1
                    }
                }
            }
        }
        print("F021 · the rules ran over \(texts.count) texts, \(texts.count * 6) variants, \(runs) spans, with no crash")
    }
}
