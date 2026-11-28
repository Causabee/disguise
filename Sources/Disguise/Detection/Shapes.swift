import Foundation

/// F021, tier B and C: what has a shape — on every source, what comes in (mail, screenshots,
/// photos, files and scans), notes, the chat, and tasks and dates added by hand. Written again from
/// the tier set's cases, not copied from the old rules' table; a shape that is the same shape looks
/// the same.
enum Shapes {
    struct Shape: Sendable {
        var kind: Entity.Kind
        var rule: Gate.Rule
        var regex: NSRegularExpression
        /// The capture group that is the item, when a label stands before it.
        var group = 0
        var minimumDigits = 0
        /// S3: exactly eight digits that are a day, in a file's name, are the file's date.
        var leavesFileDates = false
        /// S4: a street that opens with a day, a month or a common word is a date or a sentence.
        var opensWithWord = false
    }

    static func rx(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) }
        catch { fatalError("A shape does not compile: \(pattern)") }
    }

    // MARK: S1 · shapes

    static let email = rx(#"(?<![\p{L}\p{N}._%+\-])[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)+"#)
    /// An IBAN: two letters, two digits, then 11 to 30 letters or digits, spaced or not; a space after
    /// the country code; in lowercase. No checksum: a mistyped IBAN is still the owner's number.
    static let iban = rx(#"(?<![A-Za-z0-9])(?:[A-Z]{2}[ ]?\d{2}(?:[ ]?[A-Z0-9]){11,30}|[a-z]{2}[ ]?\d{2}(?:[ ]?\d){11,30})(?![A-Za-z0-9])"#)
    /// A phone: `+` and a country code, or a leading `0`; never out of the middle of a number or a date.
    static let phone = rx(#"(?<![\p{L}\p{N}\-./+])(?:\+[ ]?\d{1,3}|\(?0\d{1,5}\)?)(?:[ \-/]{1,3}\(?\d+\)?)*(?:[ \-/]{0,3}\d)+"#)
    /// A UK postcode, with its town in front when there is one: `Oxford OX2 6PE`.
    static let postcode = rx(#"(?:\b\p{Lu}\p{Ll}+[ \t]+)?\b[A-Z]{1,2}\d[A-Z\d]?[ \t]\d[A-Z]{2}\b"#)
    /// A plate after the word that names a vehicle: `Kennzeichen: K-LM 7302`, `Ihr Wagen B-HV 2041`, `Vereinsbus: WOB-TV 88`.
    static let plate = rx(#"(?i:\b(?:kfz-?)?kennzeichen|\bkfz(?:-schein)?|\p{L}*wagen|\p{L}*bus|\bauto|\bfahrzeug|\bpkw|\blkw|\b(?:licen[cs]e|number|registration)[ \t]+plate|\bplate)[ \t]*[:#.]?[ \t]*([A-ZÄÖÜ]{1,3}-[A-Z]{1,2}[ ]?\d{1,4}[EH]?)(?![\p{L}\p{N}])"#)
    /// A bank's code after its label: `BIC COBADEFFXXX`.
    static let bic = rx(#"(?i:\b(?:bic|swift(?:[\- ]?code)?))(?![\p{L}])[ \t]*[:#.]?[ \t]*([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)(?![\p{L}\p{N}])"#)

    // MARK: S2 · labelled numbers

    static let labels = [
        #"(?:bahncard|versicherten|versicherungs|kunden|vorgangs?|vertrags|mitglieds|rechnungs|policen|referenz|buchungs|auftrags|schadens?|fall|patienten|akten|steuer|mandanten|bestell|antrags|sozialversicherungs|rentenversicherungs|versicherungsschein|ausweis|identifikations|steueridentifikations|sendungs|konto|mitglied)[\- ]?(?:nummer|nr\.?|zeichen|code|no\.?)"#,
        #"versichertenkarte(?:[ \t]+nr\.?)?|versicherungsschein|police|polizze|steuer[\- ]?id|ust[\-. ]?id(?:[\-. ]?nr\.?)?|personalausweis|reisepass|aktenzeichen|az\.|kvnr|mrn|nhs[ \t]+no\.?|iban|kontonr\.?|konto|bankverbindung|account"#,
        #"(?:policy|claim|customer|account|booking|reference|membership|member|national[ \t]+insurance|tax|passport|id[ \t]+card)[ \t]+(?:number|no\.?|ref(?:erence)?|code|id)"#,
    ].joined(separator: "|")
    /// The number after its label, whole, with its spaces and letters, never across a line: the
    /// label stays, the number goes. A run of capitals counts only before a number (`DE 1000 …`).
    static let labelled = rx(#"(?i:\b(?:"# + labels + #"))(?![\p{L}])[ \t_]*[:#.]?[ \t]*((?:[A-Z0-9][A-Z0-9./\-]*\d[A-Z0-9./\-]*|\p{L}*\d[\p{L}\p{N}./\-]*|[A-Z]{1,4}(?=[ \t]\p{L}*\d))(?:[ \t](?:[A-Z0-9][A-Z0-9./\-]*\d[A-Z0-9./\-]*|\p{L}*\d[\p{L}\p{N}./\-]*|[A-Z]{1,4}(?=[ \t]\p{L}*\d)))*)(?<=[\p{L}\p{N}])"#)

    // MARK: S3 · a long run of digits

    static let digits = rx(#"(?<![A-Za-z0-9])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![A-Za-z0-9])|(?<![A-Za-z0-9])(?!0\d+(?![A-Za-z0-9]))[A-Za-z0-9]*\d{8,}[A-Za-z0-9]*(?![A-Za-z0-9])"#)

    // MARK: S4 · streets and places

    static let suffixes = "stra(?:ß|ss)e|str\\.?|weg|allee|platz|gasse|damm|ufer|ring|chaussee|steig|pfad|kamp|stieg|wall|graben|markt|promenade|zeile|twiete|kai|feld"
    static let english = "Road|Rd\\.|Street|St\\.|Avenue|Ave\\.|Lane|Drive|Close|Square|Court|Gardens|Terrace|Way|Place|Crescent|Grove|Mews|Row|Hill|Walk"
    static let number = #"[ \t_]+\d{1,4}(?:[ \t]?[a-zA-Z](?![\p{L}]))?(?![\p{N}])"#
    static let streets: [NSRegularExpression] = [
        rx(#"(?<![\p{L}])\p{Lu}[\p{L}.\-]*(?:"# + suffixes + ")" + number),
        rx(#"(?<![\p{L}])\p{Lu}[\p{L}.\-]+[ \t]+(?i:"# + suffixes + ")" + number),
        rx(#"\b\d{1,4}[ \t]+\p{Lu}[\p{L}\-]+(?:[ \t]+\p{Lu}[\p{L}\-]+)*[ \t]+(?:"# + english + #")\b"#),
        rx(#"\b\p{Lu}[\p{L}\-]+(?:[ \t]+\p{Lu}[\p{L}\-]+)*[ \t]+(?:"# + english + #")[ \t]+\d{1,4}[a-zA-Z]?\b"#),
        // No number, when the last word is plainly a street's: `Lindenstraße`, `Hollybush Lane`.
        rx(#"(?<![\p{L}])\p{Lu}[\p{Ll}\-]+(?:stra(?:ß|ss)e|allee|gasse|chaussee|promenade)(?![\p{L}])"#),
        rx(#"\b\p{Lu}\p{Ll}+[ \t]+(?:Lane|Road|Avenue|Terrace|Crescent|Close|Mews)\b"#),
    ]
    /// `Am Markt 3`, `Unter den Linden 12`: a street by its opener.
    static let opened = rx(#"\b(?:Am|An der|An den|Im|In der|In den|Auf dem|Auf der|Unter den|Zum|Zur|Hinter dem|Hinter der|Vor dem|Beim|Alt)[ \t]+\p{Lu}[\p{L}\-]+(?:[ \t]+\p{Lu}[\p{L}\-]+)?[ \t]+\d{1,3}[a-zA-Z]?\b(?![.,]\d|[ \t]*(?:Uhr|h\b|Euro|EUR|€|%|Jahre|Tage|Minuten|Stunden|Prozent))"#)
    /// Fix, 28 Nov 2026: a PO box with its number is an address part, as a street is: `Postfach 4120`,
    /// `PO Box 4120`, `P.O. Box 4120`. The word alone (`im Postfach`) is no address.
    static let poBox = rx(#"(?i:(?<![\p{L}])(?:postfach|p\.?[ ]?o\.?[ ]?box)(?:[ \t]*(?:nr\.?|no\.?))?)[ \t]*:?[ \t]*\d{1,6}(?![\p{N}])"#)
    static let fourDigitTowns = [
        "Wien", "St\\. Pölten", "Linz", "Salzburg", "Innsbruck", "Bregenz", "Graz", "Klagenfurt", "Eisenstadt",
        "Zürich", "Zuerich", "Bern", "Luzern", "Altdorf", "Schwyz", "Sarnen", "Stans", "Glarus", "Zug", "Freiburg", "Fribourg",
        "Solothurn", "Basel", "Liestal", "Schaffhausen", "Herisau", "Appenzell", "St\\. Gallen", "Chur", "Aarau", "Frauenfeld",
        "Bellinzona", "Lausanne", "Sitten", "Sion", "Neuenburg", "Neuchâtel", "Genf", "Genève", "Geneva", "Delsberg", "Delémont",
    ].joined(separator: "|")
    /// A postal code with its town: five digits; four with a known Austrian or Swiss town or a country letter in front.
    static let postal = [
        // Never on past a sentence's end: `18119 Rostock. Am Markt` is a town and a street.
        rx(#"\b\d{5}[ \t]+\p{Lu}[\p{L}\-]+(?:[ \-]\p{Lu}[\p{L}\-]+)*"#),
        rx(#"\b(?:(?:A|CH)-\d{4}[ \t]+\p{Lu}[\p{L}.\-]+|\d{4}[ \t]+(?:"# + fourDigitTowns + #"))(?![\p{L}])"#),
    ]

    // MARK: C1 · a date of birth by its label

    static let months = "januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember|january|february|march|may|june|july|october|december|jan|feb|mär|apr|jun|jul|aug|sep|sept|okt|oct|nov|dez|dec"
    /// The label, then a name or `vom` between, then the date in any written form. A date with no
    /// label is not hidden: a deadline has to be read.
    static let birth = rx(#"(?i:\b(?:geburtsdatum|geboren(?:[ \t]+am)?|geb\.:?(?:[ \t]+am)?|date[ \t]+of[ \t]+birth|born(?:[ \t]+on)?|dob))[^\d\n]{0,40}?(\d{1,2}\.[ ]?\d{1,2}\.[ ]?(?:\d{4}|\d{2})(?!\d)|\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}\.?[ ](?i:"# + months + #")\.?[ ]\d{4})"#)
    static let star = rx(#"(?<![\p{L}\p{N}])\*[ ]?(\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2}))(?!\d)"#)
    static let jahrgang = rx(#"(?i:\bjahrgang)[ \t]+(\d{4})\b"#)

    static let table: [Shape] = [
        Shape(kind: .email, rule: .S1, regex: email),
        Shape(kind: .iban, rule: .S1, regex: iban, minimumDigits: 12),
        Shape(kind: .phone, rule: .S1, regex: phone, minimumDigits: 8),
        Shape(kind: .postalCity, rule: .S1, regex: postcode, minimumDigits: 2),
        Shape(kind: .reference, rule: .S1, regex: plate, group: 1, minimumDigits: 1),
        Shape(kind: .reference, rule: .S1, regex: bic, group: 1),
        Shape(kind: .reference, rule: .S2, regex: labelled, group: 1, minimumDigits: 2),
        Shape(kind: .reference, rule: .S3, regex: digits, leavesFileDates: true),
    ] + streets.map { Shape(kind: .street, rule: .S4, regex: $0) } + [
        Shape(kind: .street, rule: .S4, regex: opened, opensWithWord: true),
        Shape(kind: .street, rule: .S4, regex: poBox, minimumDigits: 1),
    ] + postal.map { Shape(kind: .postalCity, rule: .S4, regex: $0) } + [
        Shape(kind: .reference, rule: .C1, regex: birth, group: 1, minimumDigits: 4),
        Shape(kind: .reference, rule: .C1, regex: star, group: 1, minimumDigits: 4),
        Shape(kind: .reference, rule: .C1, regex: jahrgang, group: 1, minimumDigits: 4),
    ]

    static func candidates(in text: String, field: Entity.Field) -> [Gate.Candidate] {
        var out: [Gate.Candidate] = []
        let whole = NSRange(text.startIndex..., in: text)
        for shape in table {
            for match in shape.regex.matches(in: text, range: whole) {
                let span = match.range(at: shape.group)
                guard span.location != NSNotFound, let range = Range(span, in: text) else { continue }
                var found = String(text[range])
                // A sentence's full stop or a dash after an item is no part of it.
                while let last = found.last, ".-/ ".contains(last), shape.kind != .postalCity || last != "." { found.removeLast() }
                if shape.minimumDigits > 0, found.filter(\.isNumber).count < shape.minimumDigits { continue }
                if shape.leavesFileDates, isFileDate(found, at: range, in: text, field: field) { continue }
                if shape.opensWithWord, let first = found.split(separator: " ").dropFirst().first(where: { $0.first?.isUppercase == true }),
                   Ordinary.isCalendar(String(first)) || Ordinary.isCommon(String(first)) || ["jahr", "jahre", "ende", "anfang", "tag"].contains(first.lowercased()) { continue }
                out.append(Gate.Candidate(kind: shape.kind, text: found, field: field, start: span.location,
                                          length: (found as NSString).length, evidence: [.shape], rule: shape.rule))
            }
        }
        return out
    }

    /// S3's one exception: exactly eight digits that are a day — `yyyymmdd` or `ddmmyyyy` — in a
    /// file's name: the attachment's own, or a name in the text that ends in a file's extension.
    static func isFileDate(_ hit: String, at range: Range<String.Index>, in text: String, field: Entity.Field) -> Bool {
        guard hit.count == 8, hit.allSatisfy(\.isNumber), NumberRuns.isCompactDate(hit) else { return false }
        return field == .attachmentName || FileNames.inFileName(range, in: text)
    }
}
