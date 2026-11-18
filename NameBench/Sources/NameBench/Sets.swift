import Foundation

/// The four sets, from one folder: the corpus, the unseen set, the tier set, the bench's names.
public enum Sets {
    public static let files = [("disguise-corpus.jsonl", "the corpus"), ("disguise-unseen.jsonl", "the unseen set"),
                               ("detection-tiers.jsonl", "the tier set"), ("bench-names.jsonl", named)]
    public static let named = "the owner's named cases (bench-names.jsonl)"

    public static func all(in folder: URL) throws -> [CaseSet] {
        try files.map { try CaseSet.load(folder.appendingPathComponent($0.0), title: $0.1) }
    }
}
