import Foundation
import NaturalLanguage

/// F021: what finds the names, places and numbers to disguise, on every source — what comes in
/// (mail, screenshots, photos, files and scans), notes, the chat, and tasks and dates added by
/// hand. One set of rules finds, on every path: `RuleFinder` (F021).
public protocol NameFinding: Sendable {
    /// Left nil to detect per text.
    var language: NLLanguage? { get set }
    var runsTagger: Bool { get set }
    /// The owner's own question to the chat (2b): N5's lone-word test is skipped there.
    var typed: Bool { get set }
    func entities(in email: Email) -> [Entity]
    func entities(in text: String, field: Entity.Field) -> [Entity]
}

/// The one seam: which rules decide. A constant, not a setting: one build is one set of rules, on
/// every device (principle 12). It changes only after the owner's word is in the feature's README.
public enum Detection {
    public enum Rules: String, Sendable, CaseIterable {
        /// F021: the new rules. The old rules went after the switch (AC-9); their numbers are kept in
        /// the feature's test report.
        case new
    }

    /// The rules every door, the chat and the check use.
    /// `.new` since the owner's word of 17 November 2026 ("Yes, switch"), in the feature's README.
    public static let decides: Rules = .new

    /// Set by tests only, for one run, so old and new can be measured on the same cases.
    @TaskLocal public static var override: Rules?

    public static var active: Rules { override ?? decides }

    /// The finder of the rules that decide.
    public static func finder(language: NLLanguage? = nil, runsTagger: Bool = true) -> any NameFinding {
        switch active {
        case .new: RuleFinder(language: language, runsTagger: runsTagger)
        }
    }

    /// What the gate admitted, learned into the list (`learnAdmitted`).
    @discardableResult
    public static func learn(_ entities: [Entity], into pseudonymizer: inout Pseudonymizer, vocabulary: Vocabulary = Vocabulary([])) -> [Pseudonymizer.Skip] {
        pseudonymizer.learnAdmitted(entities)
    }
}
