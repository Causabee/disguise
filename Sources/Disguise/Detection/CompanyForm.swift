import Foundation

/// F021: what a company's name looks like, moved verbatim from `EntityDetector` when the old rules
/// went (AC-9): a legal form or a business word in a name, and the parts of a sender's address.
/// Read by `Spike.learnTrusted`, `NameDecision`, and the new rules' N6 and N7.
public enum CompanyForm {
    /// The parts of a sender's address, split at `@` and `.` only: `noreply@apple.example` is
    /// `noreply`, `apple`, `example`; `dispo@fahrdienst-ost.example` keeps `fahrdienst-ost` whole.
    public static func addressParts(of field: String) -> Set<String> {
        let address: Substring
        if let open = field.lastIndex(of: "<"), let close = field.lastIndex(of: ">"), open < close {
            address = field[field.index(after: open)..<close]
        } else if let word = field.split(separator: " ").first(where: { $0.contains("@") }) {
            address = word
        } else { return [] }
        return Set(address.split(whereSeparator: { $0 == "@" || $0 == "." }).map { Pseudonymizer.key(String($0)) })
    }

    public static let legalForms = ["gmbh", "mbh", " ag", "e.v.", "e. v.", " ug", " kg", " ohg", " se",
                             "hausverwaltung", "verwaltung", "kanzlei", "rechtsanwalt", "notar",
                             "praxis", "versicherung", "bank", "sparkasse", "gbr", "ltd", "inc",
                             "team", "service", "support"]

    public static func looksIncorporated(_ name: String) -> Bool {
        let lowered = " " + name.lowercased()
        return legalForms.contains { lowered.contains($0) }
    }
}
