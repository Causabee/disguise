import Foundation

/// F021: the old rules' table of shapes, moved verbatim from `EntityDetector` when the old rules
/// went (AC-9). Only what a scan offers to save reads it (`VaultOffers`: an address, a phone number,
/// an IBAN) — a feature the owner sees, not a send — so the offers do not change with the rules.
/// No send's disguise reads it; the new rules' shapes are `Shapes`.
public enum VaultShapes {
    public struct Pattern: Sendable {
        public var kind: Entity.Kind
        var expression: String
        var options: NSRegularExpression.Options = []
        /// Minimum digits, for the patterns that are mostly digits and easy to fool.
        public var minimumDigits: Int = 0
        /// The capture group that is the entity, when the pattern needs context around it:
        /// `Frau Volkmar` is found by its `Frau`, and the entity is the whole of it.
        public var group: Int = 0
        /// A name found by its context, checked against the list of ordinary words: "Liebe Grüße"
        /// is a closing, not Frau Grüße.
        var isName = false
        /// F019 AC-4: a lowercase word after a title or a greeting is a name only where the
        /// dictionary does not know it: `frau wojciechowski` is, `die frau hat` is not.
        var unknownWord = false
        /// F019 AC-7: a street found by a word in front of it — `Am Markt 3` — whose first word is a
        /// day, a month or a common word is a date or a sentence: `Am Montag 12`, `Im Jahr 2026`.
        var isStreet = false
        /// F020 AC-14: eight digits that are a day, in a file's name, are the file's date — not learned.
        var leavesFileDates = false
    }

    /// F019 AC-7: the towns a four-digit postcode is read with — Austria's state capitals and
    /// Switzerland's cantonal capitals, in the spellings people write. A code with its country in
    /// front (`A-1010`, `CH-8001`) is read with any town.
    static let fourDigitTowns = [
        "Wien", "St\\. Pölten", "Linz", "Salzburg", "Innsbruck", "Bregenz", "Graz", "Klagenfurt", "Eisenstadt",
        "Zürich", "Zuerich", "Bern", "Luzern", "Altdorf", "Schwyz", "Sarnen", "Stans", "Glarus", "Zug", "Freiburg", "Fribourg",
        "Solothurn", "Basel", "Liestal", "Schaffhausen", "Herisau", "Appenzell", "St\\. Gallen", "Chur", "Aarau", "Frauenfeld",
        "Bellinzona", "Lausanne", "Sitten", "Sion", "Neuenburg", "Neuchâtel", "Genf", "Genève", "Geneva", "Delsberg", "Delémont",
    ].joined(separator: "|")

    static let streetSuffixes = "stra(?:ß|ss)e|str\\.?|weg|allee|platz|gasse|damm|ufer|ring|chaussee|steig|pfad|kamp|stieg|wall|graben|markt|promenade|zeile|twiete|kai"
    static let englishStreets = "Road|Rd\\.|Street|St\\.|Avenue|Ave\\.|Lane|Drive|Close|Square|Court|Gardens|Terrace|Way|Place|Crescent|Grove|Mews|Row|Hill|Walk"

    /// House number after the name, house number before it, and the German habit of writing the
    /// same street as one word or two. `Honigwabenallee 47` and `Wabenhöfer Allee 12` are the
    /// same shape to a reader and two different problems to a regex, and the second one is what
    /// the first run of the spike missed in four mails out of five.
    static let streetPatterns = [
        // F019 AC-7: `Hauptstr 5` without its dot, and the suffixes `Markt`, `Pfad`, `Kamp`, `Stieg`, `Wall`, `Graben` …
        #"\b[A-ZÄÖÜ][\w.\-]*(?:"# + streetSuffixes + #")[ \t]+\d{1,4}(?:[ \t]?[a-zA-Z])?\b"#,
        #"\b[A-ZÄÖÜ][\w.\-]+[ \t]+(?i:"# + streetSuffixes + #")[ \t]+\d{1,4}(?:[ \t]?[a-zA-Z])?\b"#,
        #"\b\d{1,4}[ \t]+[A-Z][\w.\-]+(?:[ \t]+[A-Z][\w.\-]+)*[ \t]+(?:"# + englishStreets + #")\b"#,
        // `Birch Road 12`: the English street with its number after it.
        #"\b[A-Z][\w\-]+(?:[ \t]+[A-Z][\w\-]+)*[ \t]+(?:"# + englishStreets + #")[ \t]+\d{1,4}[a-zA-Z]?\b"#,
        // `Am Markt 3`, `Unter den Linden 12`, `Auf dem Hügel 4a`.
        #"\b(?:Am|An der|An den|Im|In der|In den|Auf dem|Auf der|Unter den|Zum|Zur|Hinter dem|Hinter der|Vor dem|Beim|Alt)[ \t]+\p{Lu}[\p{L}\-]+(?:[ \t]+\p{Lu}[\p{L}\-]+)?[ \t]+\d{1,3}[a-zA-Z]?\b(?![.,]\d|[ \t]*(?:Uhr|h\b|Euro|EUR|€|%|Jahre|Tage|Minuten|Stunden|Prozent))"#,
        // A street with no number, when its last word is plainly a street's: `Lindenstraße`, `Hollybush Lane`.
        #"\b\p{Lu}[\p{Ll}\-]+(?:stra(?:ß|ss)e|allee|gasse|chaussee|promenade)\b"#,
        #"\b\p{Lu}[\p{Ll}]+[ \t]+(?:Lane|Road|Avenue|Terrace|Crescent|Close|Mews)\b"#,
    ]

    static let patterns: [Pattern] = [
        .init(kind: .email, expression: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#),
        .init(kind: .iban, expression: #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#),
        // TestFlight 264: `DE 1000 0005 5678 8764 32` — a space after the country code, and an IBAN
        // in lowercase, `de89370400440532013000`. No checksum is asked: a mistyped IBAN is still the
        // owner's number. Twelve digits and more keep `DE und AT` and `EUR 1000` out.
        .init(kind: .iban, expression: #"(?<![A-Za-z0-9])[A-Z]{2}[ ]\d{2}(?:[ ]?[A-Z0-9]){11,30}(?![A-Za-z0-9])"#,
              minimumDigits: 12),
        .init(kind: .iban, expression: #"(?<![A-Za-z0-9])[a-z]{2}[ ]?\d{2}(?:[ ]?\d){11,30}(?![A-Za-z0-9])"#,
              minimumDigits: 12),
        .init(kind: .street, expression: streetPatterns[0]),
        .init(kind: .street, expression: streetPatterns[1]),
        .init(kind: .street, expression: streetPatterns[2]),
        .init(kind: .street, expression: streetPatterns[3]),
        .init(kind: .street, expression: streetPatterns[4], isStreet: true),
        .init(kind: .street, expression: streetPatterns[5]),
        .init(kind: .street, expression: streetPatterns[6]),
        // F019 AC-7: never across a line break — `Rechnung 40917` / `Buchungscode …` is no town.
        .init(kind: .postalCity, expression: #"\b\d{5}[ \t]+[A-ZÄÖÜ][\w.\-]+(?:[ \-][A-ZÄÖÜ][\w.\-]+)*\b"#),
        .init(kind: .postalCity, expression: #"\b(?:(?:A|CH)-\d{4}[ \t]+\p{Lu}[\p{L}.\-]+|\d{4}[ \t]+(?:"# + fourDigitTowns + #"))(?![\p{L}])"#),
        // A British postcode, with the town in front of it when there is one: `London SW1A 1AA`.
        .init(kind: .postalCity, expression: #"(?:\b\p{Lu}[\p{Ll}]+[ \t]+)?\b[A-Z]{1,2}\d[A-Z\d]?[ \t]\d[A-Z]{2}\b"#, minimumDigits: 2),
        // A company writes its own name with its legal form attached, and that is the one shape
        // an organisation reliably has. The tagger read `Thermotec Kubiak GmbH` as a surname and
        // nothing else, which would have sent a party's name straight to the API.
        // The trailing guard is a lookahead rather than \b, because a legal form that ends in a
        // full stop — `e. V.`, `Ltd.` — has no word boundary after it and was missed.
        .init(kind: .organization,
              expression: #"\b(?:[A-ZÄÖÜ][\w.\-&]*[ ]){1,4}(?:GmbH|mbH|AG|UG|KG|OHG|GbR|SE|e\.[ ]?V\.|Ltd\.?|Inc\.?|LLC)(?!\w)"#),
        // Two shapes, because a country code replaces the leading zero rather than sitting in
        // front of it: `+49 30 09778110` has no 0 anywhere and was missed by a pattern that
        // insisted on one. The leading + or 0 keeps dates and amounts out; the digit count
        // keeps house numbers and years out. A signature spaces it as it likes — `+ 49 30 - 0977811 - 0` —
        // so a space may follow the + and a dash may stand between spaces.
        .init(kind: .phone, expression: #"\+[ ]?\d{1,3}[ \-/]{0,3}\(?\d{1,5}\)?[ \-/]{0,3}\d[\d \-/]{3,}\d"#,
              minimumDigits: 8),
        // F019: never out of the middle of a number — `2026-12-01 10:00` is a date and a time.
        .init(kind: .phone, expression: #"(?<![\p{L}\p{N}\-./])\(?0\d{1,5}\)?[ \-/]?\d[\d \-/]{3,}\d"#,
              minimumDigits: 8),
        // A reference number, found by the word before it: Versicherungsnummer, Kunden-Nr.,
        // Vorgang-Nr., Aktenzeichen, USt-IdNr. The number is what is replaced; the label stays,
        // so the model still knows what kind of number it was.
        // F019 AC-6: more labels, in German and English, and a number after one may have spaces
        // and a letter in it — `Sozialversicherungsnummer 65 170839 J 003`, `Steuer-ID: 12 345 678 901`.
        // Never across a line: the next line's word is no part of the number.
        // TestFlight 264: a word with a digit in it is part of the run, in any case — `kd4471 0532 0130`
        // is one number, not a word and a phone.
        .init(kind: .reference,
              expression: #"(?i:\b(?:(?:versicherten|versicherungs|kunden|vorgangs?|vertrags|mitglieds|rechnungs|policen|referenz|buchungs|auftrags|schadens?|fall|patienten|akten|steuer|ust[\-. ]?id|mandanten|bestell|antrags|sozialversicherungs|rentenversicherungs|versicherungsschein|personalausweis|ausweis|reisepass|sendungs|bahncard|identifikations|steueridentifikations|mitglied|konto)[\- ]?(?:nummer|nr\.?|zeichen|code|no\.?)|versicherungsschein|steuer[\- ]?id|personalausweis|reisepass|(?:policy|claim|customer|account|booking|reference|membership|member|national[ \t]+insurance|tax|passport|id[ \t]+card)[ \t]+(?:number|no\.?|ref(?:erence)?|code|id)|\baz\.|\bust[\-. ]?id(?:[\-. ]?nr\.?)?))[ \t]*[:#.]?[ \t]*((?:[A-Z0-9][A-Z0-9./\-]*|\p{L}*\d[\p{L}\p{N}./\-]*)(?:[ \t](?:[A-Z0-9][A-Z0-9./\-]*(?![a-zäöüß])|\p{L}*\d[\p{L}\p{N}./\-]*))*)(?<=[\p{L}\p{N}])"#,
              minimumDigits: 2, group: 1),
        // TestFlight 264: after a bank's label — `IBAN`, `Konto`, `Kontonummer`, `Account number` —
        // the whole run of numbers is one identifier, letters included, up to the next word with no
        // digit in it: never a phone and a rest. A group of capitals only counts before a number
        // (`DE 1000 …`, `NWBK 6016 …`).
        .init(kind: .reference,
              expression: #"(?i:\b(?:iban|konto(?:[\- ]?(?:nummer|nr\.?|no\.?))?|kontonr\.?|bankverbindung|account[ \t]+(?:number|no\.?)))(?![\p{L}])[ \t]*[:#.]?[ \t]*((?:\p{L}*\d[\p{L}\p{N}./\-]*|[A-Z]{1,4}(?=[ \t]\p{L}*\d))(?:[ \t](?:\p{L}*\d[\p{L}\p{N}./\-]*|[A-Z]{1,4}(?=[ \t]\p{L}*\d)))*)(?<=[\p{L}\p{N}])"#,
              minimumDigits: 6, group: 1),
        // A bank's code after its label: `BIC COBADEFFXXX`, `SWIFT: DEUTDEFF500`.
        .init(kind: .reference,
              expression: #"(?i:\b(?:bic|swift(?:[\- ]?code)?))(?![\p{L}])[ \t]*[:#.]?[ \t]*([A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)(?![\p{L}\p{N}])"#,
              group: 1),
        // A car's plate, only after its own label: `Kennzeichen B-KM 4711`.
        .init(kind: .reference,
              expression: #"(?i:\b(?:kfz[\- ]?)?kennzeichen|\b(?:licen[cs]e|number|registration)[ \t]+plate|\bplate)[ \t]*[:#.]?[ \t]*([A-ZÄÖÜ]{1,3}[\- ][A-Z]{1,2}[ \-]?\d{1,4}[EH]?)(?![\p{L}\p{N}])"#,
              minimumDigits: 1, group: 1),
        // A date of birth, found by the word before it — with a name in between, or not: "Geburtsdatum
        // Elfi Mustermann, 12.03.1950", "geb. 3.4.62". No other date is disguised: a deadline has to be read.
        // F019 AC-6: written out as well, `geb. am 12. März 1958`, and `*12.03.1958`, `Jahrgang 1958`.
        .init(kind: .reference,
              expression: #"(?i:\b(?:geburtsdatum|geburtstag|geboren(?:\s+am)?|geb\.(?:\s+am)?|date\s+of\s+birth|born(?:\s+on)?|dob))[^\d\n]{0,40}?(\d{1,2}\.\s?\d{1,2}\.\s?(?:\d{4}|\d{2})|\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}\.?\s?(?i:januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember|january|february|march|may|june|july|october|december|jan|feb|mär|apr|jun|jul|aug|sep|sept|okt|oct|nov|dez|dec)\.?\s\d{4})"#,
              minimumDigits: 4, group: 1),
        .init(kind: .reference, expression: #"(?<![\p{L}\p{N}])\*[ ]?(\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2}))(?!\d)"#, minimumDigits: 4, group: 1),
        .init(kind: .reference, expression: #"(?i:\bjahrgang)[ \t]+(\d{4})\b"#, minimumDigits: 4, group: 1),
        // A code that is plainly an identifier with no label: eight digits and more in a row, with
        // whatever letters and digits stand around them — X8200001234567, 123456789, a token — and
        // a UUID. No date or amount is written so: theirs have dots, commas, dashes or colons
        // between. Counted on the spike's own mail, ten digits and letters in front let customer
        // and tax numbers of eight and nine digits through to the model. Digits alone that begin
        // with a 0 are left to the phone rules above, so a phone number stays one to the model.
        .init(kind: .reference,
              expression: #"(?<![A-Za-z0-9])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![A-Za-z0-9])|(?<![A-Za-z0-9])(?!0\d+(?![A-Za-z0-9]))[A-Za-z0-9]*\d{8,}[A-Za-z0-9]*(?![A-Za-z0-9])"#,
              leavesFileDates: true),
        // A name found by what comes before it, where the tagger found nothing: "Frau Volkmar",
        // "Herrn Dr. Bittner", "Inh. Martina Baume". The title stays in the entity, and the
        // disguise keeps it readable: "Frau [Person A]".
        // F019 AC-5: any letter (`Frau Çetin`, `Herr Šimić`), more titles (`Freiherr von …`, `Mrs`,
        // `Dr` without its dot), and an academic title between title and name (`Dr. med.`, `Dipl.-Ing.`).
        // Found at Proof, 17 November: glued as well — `Dr.med. Hollenbach`, `Prof.Dr. Kortmann`, `Dipl.-Ing.Breitkopf`.
        .init(kind: .person,
              expression: #"\b(?:Frau|Herrn?|Freiherr|Freifrau|Graf|Gräfin|Mrs?\.?|Ms\.?|Miss|Dr\.?|Prof\.|Inh\.|Inhaber(?:in)?:?|Dipl\.-?\p{L}*\.)(?:(?<=\.)|(?![\p{L}]))(?:[ \t]+|(?<=\.))(?:(?:Dr|Prof|med|dent|vet|rer\.[ ]?nat|phil|jur|habil|Mag|Dipl\.?-?\p{L}*|Ing)\.[ \t]*)*(?:(?:von|van|de|zu|der|den|von der|van der|von und zu)[ \t]+)?(?:\p{Lu}[\p{Ll}\p{M}'’]+[ \-]){0,2}\p{Lu}[\p{Ll}\p{M}'’]+(?:-\p{Lu}[\p{Ll}\p{M}]+)?"#,
              isName: true),
        // F019 AC-4: the same in lowercase — `frau wojciechowski`, `herrn behnke`, `frau dr. hollenberg`: the
        // one word after the title, when the dictionary does not know it.
        .init(kind: .person,
              expression: #"(?i:\b(?:frau|herrn?|mrs?|ms|dr)\.?)[ \t]+(?:(?i:dr|prof)\.[ \t]*)?(\p{Ll}[\p{Ll}\p{M}]{2,})(?![\p{L}])"#,
              group: 1, isName: true, unknownWord: true),
        // F019: a name after the label a form or a portal puts before one — `Versicherungsnehmer: Gerwin
        // Schiefbein`, `Willkommen, Göran Tehrmann`, `Signed in as Hamish Lockhart`.
        .init(kind: .person,
              expression: #"(?i:\b(?:versicherungsnehmer(?:in)?|versicherte[r]?|patient(?:in)?|reisende[r]?|mieter(?:in)?|vermieter(?:in)?|kunde|kundin|inhaber(?:in)?|empfänger(?:in)?|absender(?:in)?|antragsteller(?:in)?|ansprechpartner(?:in)?|name|policyholder|passenger|tenant|landlord|customer|recipient|applicant|account holder|kontoinhaber(?:in)?|willkommen|welcome|signed ?in as|angemeldet als))[ \t]*[:,]?[ \t]+((?:\p{Lu}[\p{Ll}\p{M}'’]+[ \-]){0,2}\p{Lu}[\p{Ll}\p{M}'’]+)(?![\p{L}])"#,
              group: 1, isName: true),
        // A first name after a greeting: "Hallo Bertram,", "Lieber Tim".
        .init(kind: .person,
              expression: #"\b(?:Hallo|Hi|Hey|Liebe|Lieber|Moin|Servus|Dear)[ \t]+(\p{Lu}[\p{Ll}\p{M}]{2,})(?=\s*[,!\n])"#,
              group: 1, isName: true),
        .init(kind: .person,
              expression: #"(?i:\b(?:hallo|hi|hey|liebe|lieber|moin|servus|dear))[ \t]+(\p{Ll}[\p{Ll}\p{M}]{2,})(?=\s*[,!\n])"#,
              group: 1, isName: true, unknownWord: true),
    ]

    /// Compiled once, not again for every field of every mail — and a rule that does not compile
    /// stops the program rather than being skipped: a skipped rule would let what it finds leave.
    public static let compiled: [(pattern: Pattern, regex: NSRegularExpression)] = patterns.map { pattern in
        do { return (pattern, try NSRegularExpression(pattern: pattern.expression, options: pattern.options)) }
        catch { fatalError("A detector rule does not compile: \(pattern.expression)") }
    }
}
