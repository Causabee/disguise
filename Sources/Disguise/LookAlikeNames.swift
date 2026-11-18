import Foundation
import NaturalLanguage
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// What the system's own dictionary says of a word. Asked on the device; no word is sent anywhere.
public protocol WordKnowledge: Sendable {
    /// Known as written, in German or in English. Nil when this device has no dictionary to ask.
    func knows(_ word: String) -> Bool?
    /// Whether this device has a dictionary for the language: `de`, `en`.
    func has(language: String) -> Bool
    /// F021: known as written in one language's dictionary (`de`, `en`).
    func knows(_ word: String, language: String) -> Bool?
}

extension WordKnowledge {
    public func has(language: String) -> Bool { true }
    /// F021: known in one language's dictionary (`de`, `en`) — a text read in its own language.
    /// A dictionary that cannot tell answers as `knows`.
    public func knows(_ word: String, language: String) -> Bool? { knows(word) }
}

/// The system's spell checker: `NSSpellChecker` on the Mac, `UITextChecker` on iPhone and iPad.
/// Verdicts are remembered for the life of the process, and asked one at a time.
public final class SystemWords: WordKnowledge, @unchecked Sendable {
    public static let shared = SystemWords()
    private let lock = NSLock()
    private var verdicts: [String: Bool] = [:]
    private lazy var languages: (de: String?, en: String?) = Self.findLanguages()
    #if canImport(AppKit)
    private lazy var tag = NSSpellChecker.uniqueSpellDocumentTag()
    #endif

    public func has(language: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return language == "de" ? languages.de != nil : language == "en" ? languages.en != nil : false
    }

    public func knows(_ word: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        if let known = verdicts[word] { return known }
        let found = [languages.de, languages.en].compactMap { $0 }
        guard !found.isEmpty else { return nil }
        let known = found.contains { Self.spelledRight(word, language: $0, tag: tagged) }
        verdicts[word] = known
        return known
    }

    /// F021: known as written in one language's dictionary; nil when the device has none for it.
    public func knows(_ word: String, language: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        let key = language + "\u{0}" + word
        if let known = verdicts[key] { return known }
        guard let found = language == "en" ? languages.en : languages.de else { return nil }
        let known = Self.spelledRight(word, language: found, tag: tagged)
        verdicts[key] = known
        return known
    }

    private var tagged: Int {
        #if canImport(AppKit)
        return tag
        #else
        return 0
        #endif
    }

    private static func findLanguages() -> (de: String?, en: String?) {
        #if canImport(AppKit)
        let all = NSSpellChecker.shared.availableLanguages
        #elseif canImport(UIKit)
        let all = UITextChecker.availableLanguages
        #else
        let all: [String] = []
        #endif
        func pick(_ prefix: String, preferred: [String]) -> String? {
            preferred.first(where: all.contains) ?? all.first { $0 == prefix || $0.hasPrefix(prefix + "_") || $0.hasPrefix(prefix + "-") }
        }
        return (pick("de", preferred: ["de", "de_DE"]), pick("en", preferred: ["en", "en_US", "en_GB"]))
    }

    private static func spelledRight(_ word: String, language: String, tag: Int) -> Bool {
        #if canImport(AppKit)
        let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                        inSpellDocumentWithTag: tag, wordCount: nil)
        return range.location == NSNotFound
        #elseif canImport(UIKit)
        let checker = UITextChecker()
        let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                                  startingAt: 0, wrap: false, language: language)
        return range.location == NSNotFound
        #else
        return true
        #endif
    }
}

/// F019 AC-4, AC-9: the second pass. A word the rules, the tagger and the list did not take, and
/// that neither the German nor the English dictionary knows as written, looks like a name: it is
/// disguised for this one send. Lowercase too (the owner's answer 1a): `julian` in a chat goes,
/// even though a lowercase German noun goes with it. Without a dictionary for the text's language
/// the pass is left out for that text (answer 2a); the rules, the owner's words and the check still run.
public enum LookAlikeNames {
    /// Never name-like: legal forms, units, the request's own words.
    static let allowed: Set<String> = [
        "gmbh", "mbh", "ag", "ug", "kg", "ohg", "gbr", "ltd", "inc", "llc", "plc", "ev",
        "eur", "usd", "gbp", "chf", "kwh", "qm", "km", "cm", "mm", "kg", "std", "min", "ca", "inkl", "zzgl", "evtl", "bzgl", "usw", "ggf",
        "iban", "bic", "pdf", "jpg", "jpeg", "png", "heic", "docx", "xlsx", "txt", "eml", "emlx", "ok", "okay", "email", "mails",
        "whatsapp", "imessage", "telegram", "threema", "causabee", "todo", "todos", "nachname", "vorname",
        "screenshot", "screenshots", "chat", "chats", "link", "links", "online", "newsletter", "app", "apps",
    ]

    /// The distinct words of a text that look like names, outside stand-ins, links and words with
    /// digits. `ordinary`: words the caller knows are its own — a matter's key.
    public static func find(in text: String, words: any WordKnowledge, known: Pseudonymizer? = nil, ordinary: Set<String> = []) -> [String] {
        let prose = text.replacing(/\[[^\[\]\n]{1,40}\]/, with: " ")
            .replacing(/\S+@\S+|https?:\/\/\S+|www\.\S+/, with: " ")
        let language = Self.language(of: prose)
        guard words.has(language: language) else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for match in prose.matches(of: /\p{L}[\p{L}\p{M}]*/) {
            let word = String(match.output)
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }
        let lowered = Dictionary(grouping: order, by: { $0.lowercased() }).mapValues { forms in forms.reduce(0) { $0 + counts[$1, default: 0] } }
        var out: [String] = []
        for word in order where word.count >= 3 {
            let key = word.lowercased()
            if allowed.contains(key) || ordinary.contains(key) { continue }
            // An abbreviation: `AOK`, `KFZ`. A shouted name is read by its capitalised form.
            if word == word.uppercased(), word.count <= 4 { continue }
            // A word the text itself uses again and again is ordinary.
            if lowered[key, default: 0] >= 5 { continue }
            if Pseudonymizer.isListed(word) || Pseudonymizer.particles.contains(key) { continue }
            if let known, known.standIn(for: word) != nil { continue }
            let asked = word == word.uppercased() ? word.prefix(1) + word.dropFirst().lowercased() : word
            guard let knows = words.knows(String(asked)) else { return [] }
            if knows { continue }
            // `Kuendigung`, typed without its umlaut, is `Kündigung`.
            let umlauts = withUmlauts(String(asked))
            if umlauts != String(asked), words.knows(umlauts) == true { continue }
            if word.first?.isUppercase == true, isCompound(String(asked), words: words) { continue }
            out.append(word)
        }
        return out
    }

    /// `Kuendigung` as `Kündigung`: `ae`, `oe`, `ue` as the umlauts they stand for.
    public static func withUmlauts(_ word: String) -> String {
        word.replacingOccurrences(of: "ae", with: "ä").replacingOccurrences(of: "oe", with: "ö").replacingOccurrences(of: "ue", with: "ü")
            .replacingOccurrences(of: "Ae", with: "Ä").replacingOccurrences(of: "Oe", with: "Ö").replacingOccurrences(of: "Ue", with: "Ü")
    }

    /// `Badewannensitz`: two words the dictionary knows, with `s`, `n`, `es` or `en` between.
    static func isCompound(_ word: String, words: any WordKnowledge) -> Bool {
        let letters = Array(word)
        guard letters.count >= 7 else { return false }
        for cut in 3...(letters.count - 3) {
            let rest = String(letters[cut...])
            let right = rest.prefix(1).uppercased() + rest.dropFirst()
            guard words.knows(right) == true else { continue }
            let left = String(letters[..<cut])
            for link in ["", "s", "n", "es", "en", "e"] where left.hasSuffix(link) {
                let stem = String(left.dropLast(link.count))
                if stem.count >= 3, words.knows(stem) == true || words.knows(stem.lowercased()) == true { return true }
            }
        }
        return false
    }

    /// German or English, by the words; German when it cannot be told.
    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.german, .english]
        recognizer.processString(String(text.prefix(2_000)))
        return recognizer.dominantLanguage == .english ? "en" : "de"
    }
}
