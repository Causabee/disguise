import Foundation

/// F021 L1 (AC-20, the owner's 6b): the shipped name lists of F020, as a second opinion only.
/// A list can raise a word another rule doubts — a word beside a first name or a title, or one the
/// tagger half-reads. A list never finds a name alone; never raises a word the dictionary knows in
/// lowercase when it stands alone („Haus“, „Markt“, „Post“, „Oma“, „Kasse“, „Sonntag“); never
/// raises a title or a word on the small-word list. The lists stay on the device; nothing is
/// looked up. The only new reader of `NameKnowledge`, loaded on the first word that needs it.
struct SecondOpinion: Sendable {
    var lists: any NameKnowing = NameKnowledge.shared

    /// Never raised, by any list: a title, a small word, a greeting, a word of the common list.
    static func neverRaised(_ word: String) -> Bool {
        Ordinary.isSmall(word) || Ordinary.isTitle(word) || Ordinary.isGreeting(word) || Ordinary.isKin(word)
            || (Ordinary.isCommon(word) && !Ordinary.isCalendar(word))
    }

    /// A first name, by the list: `Anja`, `Agathe`; `Klaus-Dieter` by its first part. Nil-safe: a
    /// list that cannot be read says no, and no rule needs it alone.
    func isFirstName(_ word: String) -> Bool {
        guard word.count >= 2, word.first?.isUppercase == true, !Self.neverRaised(word), !Ordinary.isCalendar(word) else { return false }
        if lists.isFirstName(word) == true { return true }
        // `Klaus-Dieter`, `Anna-Lena`: each part a first name.
        let parts = word.split(separator: "-").map(String.init)
        if parts.count == 2, parts.allSatisfy({ $0.count >= 2 && $0.first?.isUppercase == true }) {
            return parts.allSatisfy { lists.isFirstName($0) == true }
        }
        return false
    }

    /// The list of first names cannot be read: nothing may be said of the word by it, and N5 keeps
    /// the tagger's lone word, as a missing dictionary keeps it (fails toward hiding, F020 AC-18).
    func cannotTell(_ word: String) -> Bool {
        !Self.neverRaised(word) && lists.isFirstName(word) == nil
    }

    /// On either list, or a list that cannot be read: for a sender's one-word name the dictionary
    /// knows, which is learned unless the lists say it is no name (fails toward hiding).
    func mayBeName(_ word: String) -> Bool {
        guard !Self.neverRaised(word) else { return false }
        return lists.isName(word) != false
    }

    /// On the list of surnames: for the word beside a first name that is an ordinary word too.
    func holdsSurname(_ word: String) -> Bool {
        guard !Self.neverRaised(word) else { return false }
        return lists.isSurname(word) == true
    }

    /// On either list. For a word another rule already doubts, never for a word alone.
    func isName(_ word: String) -> Bool {
        guard !Self.neverRaised(word) else { return false }
        return lists.isName(word) == true
    }

    /// P2 (the owner's 3c, 18 November 2026): a surname that is a day or a month — a word of
    /// `Pseudonymizer.calendarWords` (`Sonntag`, `Montag`, `Mai`). Every other part that is an
    /// ordinary word (`Milde`, `Süß`, `Koch`) is hidden wherever it stands, as today.
    static func isOrdinarySurname(_ word: String) -> Bool {
        Ordinary.isCalendar(word)
    }
}
