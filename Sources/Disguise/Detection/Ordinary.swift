import Foundation

/// F021: the vetoes, in one list, for every path — what comes in (mail, screenshots, photos, files
/// and scans), notes, the chat, and tasks and dates added by hand. Small words, titles, greetings
/// and words on the calendar list are never a person or a place alone; a small word is never one at
/// all; a title is never one. A calendar word, or any word the dictionary knows in lowercase, is a
/// name only with an anchor that a rule names.
enum Ordinary {
    static func key(_ word: String) -> String { Pseudonymizer.key(word) }

    /// Articles, prepositions, pronouns: never a name, never a part of one but a particle.
    static func isSmall(_ word: String) -> Bool { Pseudonymizer.smallWords.contains(key(word)) }

    static func isTitle(_ word: String) -> Bool { Pseudonymizer.isTitle(word) }

    /// A greeting or a closing: the old list, and `Grüßen` of `Mit freundlichen Grüßen`.
    static func isGreeting(_ word: String) -> Bool { Pseudonymizer.greetings.contains(key(word)) || ["grüßen", "grüssen"].contains(key(word)) }

    static func isCalendar(_ word: String) -> Bool { Pseudonymizer.calendarWords.contains(key(word)) }

    /// The common-word list (`Pseudonymizer.commonWords`): words that are never disguised alone.
    static func isCommon(_ word: String) -> Bool { Pseudonymizer.commonWords.contains(key(word)) }

    /// `von`, `van`, `de`, `zu`: the lowercase words a name may hold (N5's span rule).
    static let particles: Set<String> = ["von", "van", "de", "zu", "der", "den", "ten", "ter", "da", "di", "del", "du", "la", "le"]

    /// N6: the words that say what a business is. They stay readable, and alone they are no one.
    static let kindWords: Set<String> = Pseudonymizer.companyWords.union([
        "kanzlei", "praxis", "arztpraxis", "tierarztpraxis", "zahnarztpraxis", "hausverwaltung", "verwaltung",
        "krankenkasse", "pflegekasse", "kasse", "fahrdienst", "pflegedienst", "sanitätshaus", "apotheke", "werkstatt",
        "autohaus", "versicherung", "versicherungsbüro", "bank", "sparkasse", "volksbank", "stadtwerke", "bürgeramt",
        "finanzamt", "standesamt", "jobcenter", "amt", "klinik", "klinikum", "krankenhaus", "physiotherapie", "schule",
        "kita", "verein", "notar", "rechtsanwalt", "rechtsanwälte", "steuerberater", "handwerker", "malerbetrieb",
        "pharmacy", "surgery", "clinic", "hospital", "lettings", "insurance", "council", "school", "partner", "partners",
        "service", "support", "team",
        "bkk", "aok", "ikk", "hkk", "reisebüro", "fahrschule", "physiotherapiepraxis", "pflegeheim", "seniorenheim",
        // Fix, 24 Nov 2026: a matter's detail "Büro" was taken for a person.
        "büro",
        // Fix CAU-269, 27 Nov 2026: a housing company said in the chat ("Kaution von Wohnbau …") went out as said.
        "wohnbau", "wohnungsbau", "wohnungsbaugesellschaft", "baugesellschaft", "baugenossenschaft",
        "wohnungsgenossenschaft", "genossenschaft", "immobilien",
    ])

    static func isKindWord(_ word: String) -> Bool { kindWords.contains(key(word)) }

    /// What someone is to the owner, written before a name like a title (`Oma Gretl Furtkamp`,
    /// `Aunt Winifred`): no name, and no part of one.
    static let kin: Set<String> = [
        "mama", "mami", "mutti", "mutter", "papa", "papi", "vati", "vater", "oma", "omi", "opa", "opi", "tante", "onkel",
        "sohn", "tochter", "bruder", "enkel", "enkelin", "cousin", "cousine", "schwager", "schwägerin", "schwiegermutter",
        "schwiegervater", "mum", "mom", "mummy", "mother", "dad", "daddy", "father", "grandma", "grandpa", "granny", "nan",
        "aunt", "auntie", "uncle", "son", "daughter", "brother", "sister", "nephew", "niece",
    ]

    static func isKin(_ word: String) -> Bool { kin.contains(key(word)) }

    /// Everyone greeted at once: "Sehr geehrte Damen und Herren", "Ladies and Gentlemen". No one
    /// alone, and no part of a name (fix, 24 Nov 2026: "Herren" was taken for a person).
    static let everyone: Set<String> = ["damen", "herren", "ladies", "gentlemen"]

    static func isEveryone(_ word: String) -> Bool { everyone.contains(key(word)) }

    /// `Familie`, `Fräulein`: before a name they anchor it as a title does (`Familie Herren`), though
    /// they are kept out of the stand-in's title (the reviewer, 24 Nov 2026).
    static func anchorsLikeTitle(_ word: String) -> Bool { ["familie", "fräulein", "frl", "frl."].contains(key(word)) }

    /// An id of a letter or two and digits — `X1`, `M2`, `T14` — written before a word: no part of a name.
    static func isID(_ word: String) -> Bool { word.wholeMatch(of: /[A-Z]{1,2}[0-9]+/) != nil }

    /// The words that stand before a person: prepositions, and asking, telling, calling (L1, and the
    /// second pass's words written small, CAU-258).
    static let beforePerson: Set<String> = [
        // Not `und`, `and`, `an`, `for`: they stand before ordinary words as often (`and set up`).
        "bei", "mit", "von", "für", "zu", "frag", "frage", "fragt", "sag", "sage", "sagt", "ruf", "rufe", "schreib",
        "schreibe", "grüß", "grüße", "hat", "hast", "meint", "ask", "tell", "call", "ring", "text",
    ]

    /// How a street's name ends (N4, and the second pass's words written small, CAU-258).
    static let streetEnds = ["straße", "strasse", "str", "weg", "allee", "platz", "gasse", "damm", "ufer", "ring", "chaussee", "steig",
                             "pfad", "stieg", "wall", "graben", "markt", "promenade", "zeile", "twiete", "kai", "lane", "road", "street"]

    /// Never a person or a place alone, on any path, typed or not.
    static func neverAlone(_ word: String) -> Bool {
        isSmall(word) || isTitle(word) || isGreeting(word) || isCalendar(word) || isCommon(word) || isKindWord(word) || isKin(word)
            || isEveryone(word)
    }

    /// The lowercase test: does the dictionary know the word written small? An ordinary German
    /// noun it knows that way („treffen“, „fragen“, „hecke“); a name it does not („sonja“). Nil when
    /// the device has no dictionary: then nothing is said, and the candidate is kept — it fails
    /// toward hiding.
    static func knowsLower(_ word: String, words: any WordKnowledge) -> Bool? {
        words.knows(word.lowercased())
    }

    /// The lowercase test in the text's own language (N8): a German text asks the German dictionary,
    /// an English one the English. `thore` is a German word and `ada` an English one; neither is
    /// asked of a text in the other language.
    static func knowsLower(_ word: String, words: any WordKnowledge, language: String?) -> Bool? {
        guard let language else { return knowsLower(word, words: words) }
        return words.knows(word.lowercased(), language: language)
    }

    /// Known as written, in German or English. Nil without a dictionary.
    static func knows(_ word: String, words: any WordKnowledge) -> Bool? {
        words.knows(word)
    }
}
