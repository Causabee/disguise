import Foundation

/// F021: one gate that every path passes — what comes in (mail, screenshots, photos, files and
/// scans), notes, the chat, and tasks and dates added by hand, the sender's line, a file's name and
/// the rebuild. A candidate is a span of text with a kind and the evidence that found it; `admit`
/// is the only function that turns one into something learned. No path has its own filter, and no
/// word is protected on one path only. Evidence decides at the first sighting: no count of sightings.
enum Gate {
    /// What found a candidate.
    enum Evidence: String, Sendable, CaseIterable {
        case shape, label, title, legalForm, kindWord, firstName, tagger, own, secondOpinion, unknownWord, sender
    }

    /// The rule ids of How's table.
    enum Rule: String, Sendable, CaseIterable {
        case N1, N2, N3, N4, N5, N6, N7, N8, P1, P2, S1, S2, S3, S4, C1, L1
    }

    struct Candidate: Sendable {
        var kind: Entity.Kind
        var text: String
        var field: Entity.Field
        /// UTF-16 offset and length in the field's text; length 0 for a name read out of a file's name.
        var start: Int
        var length: Int
        var evidence: Set<Evidence>
        var rule: Rule
        /// The language its text is read in (`de`, `en`), for the lowercase test; nil asks both.
        var language: String? = nil
    }

    /// What the gate let through, with the rule that found it (the measure names it).
    struct Admitted: Sendable {
        var entity: Entity
        var rule: Rule
    }

    /// The words of a person's span that are its name: not a title, not a particle.
    static func nameWords(_ text: String) -> [String] {
        Pseudonymizer.words(text).filter { !Ordinary.isTitle($0) && !Ordinary.particles.contains(Ordinary.key($0)) }
    }

    /// `typed`: the owner's own question to the chat, and nothing else (the owner's answer 2b):
    /// N5's lone-word test is skipped there. Every other veto still applies to it.
    static func admit(_ candidate: Candidate, typed: Bool, words: any WordKnowledge) -> Admitted? {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return nil }
        let evidence = candidate.evidence
        func admitted() -> Admitted {
            Admitted(entity: Entity(kind: candidate.kind, text: text, field: candidate.field, start: candidate.start,
                                    length: candidate.length, source: .rule), rule: candidate.rule)
        }
        // N1: the owner's names and each party's are names, always.
        if evidence.contains(.own) { return admitted() }
        // Shapes, labels of numbers, legal forms: what they found is what it is.
        if evidence.contains(.shape) { return admitted() }

        switch candidate.kind {
        case .person:
            let names = nameWords(text)
            guard !names.isEmpty else { return nil }
            // A small word is never a name, nor part of one.
            if names.contains(where: Ordinary.isSmall) { return nil }
            if names.count == 1 {
                let word = names[0]
                if Ordinary.isGreeting(word) { return nil }
                // A sender's shown name was judged by N7 already (a recipient's is learned as before).
                if evidence.contains(.sender), !Ordinary.isSmall(word), !Ordinary.isTitle(word) { return admitted() }
                if Ordinary.isKindWord(word) { return nil }
                // A title, a label, a first name, a sender: an anchor. The word is the name
                // whatever it is otherwise (`Frau Sonntag`, `Herr Post`).
                if !evidence.isDisjoint(with: [.title, .label, .firstName, .sender]) { return admitted() }
                // Alone: never a calendar word or a word of the common list.
                if Ordinary.neverAlone(word) { return nil }
                if evidence.contains(.unknownWord) { return admitted() }
                // N5: the tagger's lone guess. Not a word the dictionary knows in lowercase — except
                // in the owner's own question (2b). A list never raises such a word alone (L1).
                if typed { return admitted() }
                // L1 with N5: the tagger and the first-name list together keep what the lowercase test doubts.
                if evidence.isSuperset(of: [.tagger, .secondOpinion]) { return admitted() }
                if Ordinary.knowsLower(word, words: words, language: candidate.language) == true { return nil }
                return admitted()
            }
            // Two words or more: every word ordinary is a misread sentence, not a name.
            if names.allSatisfy({ Ordinary.neverAlone($0) || Ordinary.knowsLower($0, words: words) == true }),
               evidence.isDisjoint(with: [.title, .label, .firstName, .sender]) { return nil }
            return admitted()
        case .organization:
            if evidence.contains(.legalForm) { return admitted() }
            let names = Pseudonymizer.words(text).filter { !Ordinary.isKindWord($0) }
            guard !names.isEmpty, !names.allSatisfy({ Ordinary.isSmall($0) || Ordinary.isCalendar($0) }) else { return nil }
            // The kind word beside it is its anchor, as a title is a person's: `Kanzlei Eisenreich`.
            if evidence.contains(.kindWord) { return admitted() }
            // A company of one ordinary word and no legal form is not hidden alone.
            if names.allSatisfy({ Ordinary.neverAlone($0) || Ordinary.knowsLower($0, words: words) == true }) { return nil }
            return admitted()
        case .place, .street, .postalCity:
            let names = Pseudonymizer.words(text)
            if names.count == 1 {
                if Ordinary.neverAlone(text) { return nil }
                if Ordinary.knowsLower(text, words: words, language: candidate.language) == true { return nil }
            } else if names.allSatisfy({ Ordinary.neverAlone($0) || Ordinary.knowsLower($0, words: words, language: candidate.language) == true }) {
                return nil
            }
            return admitted()
        case .email, .phone, .iban, .reference:
            return admitted()
        }
    }
}
