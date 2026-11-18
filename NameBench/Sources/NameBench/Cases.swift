import Foundation

/// A case in the shape of `disguise-corpus.jsonl`, `disguise-unseen.jsonl`, `detection-tiers.jsonl`
/// and `bench-names.jsonl`: what comes in from one source (mail, screenshots, photos, files and
/// scans), a note, the chat, or a task or date added by hand; what must be found; what must stay.
public struct BenchCase: Decodable, Sendable {
    public struct Field: Decodable, Sendable { public var field: String; public var text: String }
    public struct Item: Decodable, Sendable {
        public var text: String
        public var kind: String
        public var tier: String?
        /// A names, B places and numbers, C dates of birth: the tier set's own, else by kind.
        public var tierOrKind: String { tier ?? Tier.of(kind) }
    }
    public var id: String
    public var source: String
    public var lang: String
    public var fields: [Field]
    public var identifiers: [Item]
    public var stay: [String]
}

public enum Tier {
    public static let order = ["A", "B", "C"]
    public static let title = ["A": "A names", "B": "B places and numbers", "C": "C dates of birth"]
    public static func of(_ kind: String) -> String {
        switch kind {
        case "name", "person", "company": "A"
        case "birth-date": "C"
        default: "B"
        }
    }
}

public struct CaseSet: Sendable {
    public var title: String
    public var cases: [BenchCase]
    public var items: Int { cases.reduce(0) { $0 + $1.identifiers.count } }

    /// One case per line; a line with no `id` (the tier set's head) is not a case.
    public static func load(_ url: URL, title: String) throws -> CaseSet {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let cases = try lines.compactMap { line -> BenchCase? in
            let data = Data(line.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] != nil else { return nil }
            return try JSONDecoder().decode(BenchCase.self, from: data)
        }
        return CaseSet(title: title, cases: cases)
    }
}
