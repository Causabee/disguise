import Foundation

extension Pseudonymizer {
    /// The entries without the wholes the ledger lists, and without a part of one of them — unless a
    /// whole that stays has that word in it too: entries are unique by word, so a part shared by a
    /// dropped and a kept name belongs to both. In doubt an entry stays: over-disguised, never out.
    ///
    /// F027: a way of writing is a whole: it goes with its row where it is listed with it — what goes
    /// out as written lists every way of a row turned off (`Mapping.outAsWritten`), and a delete gives
    /// every way its own `gone` — and a name listed on its own takes no other way with it. A part of
    /// another kind than its row — the service of a via name, a company under a person — never goes with
    /// the person: where its row goes, it stays, hidden, a company row of its own.
    public static func shed(_ entries: [Pseudonymizer.Entry], dropped: Set<String>) -> [Pseudonymizer.Entry] {
        guard !dropped.isEmpty else { return entries }
        let gone = Set(entries.filter { $0.partOf == nil && dropped.contains(Pseudonymizer.Mapping.hashed($0.original)) }
            .map { Pseudonymizer.key($0.original) })
        guard !gone.isEmpty else { return entries }
        func folded(_ text: String) -> String { " " + Pseudonymizer.words(Pseudonymizer.key(text)).joined(separator: " ") + " " }
        let staying = entries.filter { $0.partOf == nil && !gone.contains(Pseudonymizer.key($0.original)) }.map { folded($0.original) }
        let people = Set(entries.filter { $0.kind == .person && $0.partOf == nil }.map { Pseudonymizer.key($0.original) })
        return entries.compactMap { entry in
            let key = Pseudonymizer.key(entry.original)
            guard let whole = entry.partOf else { return gone.contains(key) ? nil : entry }
            guard gone.contains(Pseudonymizer.key(whole)) else { return entry }
            let part = folded(entry.original)
            if staying.contains(where: { $0.contains(part) }) { return entry }
            guard entry.kind == .organization, people.contains(Pseudonymizer.key(whole)) else { return nil }
            var service = entry
            service.partOf = nil
            return service
        }
    }
}
