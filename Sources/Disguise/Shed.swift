import Foundation

extension Pseudonymizer {
    /// The entries without the wholes the ledger lists, and without a part of one of them — unless a
    /// whole that stays has that word in it too: entries are unique by word, so a part shared by a
    /// dropped and a kept name belongs to both. In doubt an entry stays: over-disguised, never out.
    public static func shed(_ entries: [Pseudonymizer.Entry], dropped: Set<String>) -> [Pseudonymizer.Entry] {
        guard !dropped.isEmpty else { return entries }
        let gone = Set(entries.filter { $0.partOf == nil && dropped.contains(Pseudonymizer.Mapping.hashed($0.original)) }
            .map { Pseudonymizer.key($0.original) })
        guard !gone.isEmpty else { return entries }
        func folded(_ text: String) -> String { " " + Pseudonymizer.words(Pseudonymizer.key(text)).joined(separator: " ") + " " }
        let staying = entries.filter { $0.partOf == nil && !gone.contains(Pseudonymizer.key($0.original)) }.map { folded($0.original) }
        return entries.filter { entry in
            let key = Pseudonymizer.key(entry.original)
            guard let whole = entry.partOf else { return !gone.contains(key) }
            guard gone.contains(Pseudonymizer.key(whole)) else { return true }
            let part = folded(entry.original)
            return staying.contains { $0.contains(part) }
        }
    }
}
