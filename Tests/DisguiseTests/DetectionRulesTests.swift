import Foundation
import Testing
@testable import Disguise

/// F021: the new rules, one group per rule id, on the owner's cases of 17 November 2026 (AC-10 to
/// AC-17). Each sentence goes through the real code of a source — what comes in (mail, screenshots,
/// photos, files and scans), notes, the chat, and tasks and dates added by hand — on a fresh list,
/// under the new rules (`Detection.override`), and the test reads what would have left the device.
@Suite("F021 · The new rules", .serialized)
@MainActor
struct DetectionRulesTests {
    /// The sources a sentence of the owner's can come by, each with the field its door reads.
    static let sources: [(source: String, field: String)] = [
        ("note", "body"), ("todo-by-hand", "todo"), ("chat-typed", "body"), ("screenshot-other", "body"),
        ("mail", "body"), ("scan", "body"), ("photo", "body"), ("date-by-hand", "what"),
    ]


    /// The words of what was sent, outside the stand-ins.
    static func words(_ sent: String) -> Set<String> {
        let shown = sent.replacing(/\[[^\[\]\n]{1,40}\]/, with: " ")
        return Set(shown.split { !$0.isLetter }.map { String($0) })
    }


    // MARK: AC-11 · N3, N2, P1




    @Test("F021 AC-11 · P2 holds for calendar words only (3c): Selig and Schüßler alone are hidden, Treffen am Sonntag stays")
    func p2CalendarOnly() {
        Detection.$override.withValue(.new) {
            var list = Pseudonymizer(mode: .placeholder)
            list.learnAdmitted([Entity(kind: .person, text: "Wulf Selig", field: .from, start: 0, length: 0, source: .rule),
                                Entity(kind: .person, text: "Patrick Schüßler", field: .from, start: 0, length: 0, source: .rule),
                                Entity(kind: .person, text: "Sonja Sonntag", field: .body, start: 0, length: 0, source: .rule)])
            for text in ["Siehe Selig[link](http://x.example)", "Selig hat angerufen.", "SCHÜßLER und die Ferberstraße", "Gruß von Schüßler"] {
                let out = list.disguiser.apply(text).text
                #expect(!out.lowercased().contains("selig") && !out.lowercased().contains("schüßler"), "\(text) → \(out)")
            }
            #expect(list.disguiser.apply("Treffen am Sonntag").text == "Treffen am Sonntag")
        }
    }

    @Test("F021 AC-11 · P2: in a file's name, a surname beside its first name is beside it, joined by - or _")
    func surnameInFileName() {
        Detection.$override.withValue(.new) {
            var list = Pseudonymizer(mode: .placeholder)
            list.learnAdmitted([Entity(kind: .person, text: "sonja sonntag", field: .attachmentName, start: 0, length: 0, source: .rule)])
            for name in ["scan-sonja-sonntag.jpg", "Brief_Sonja_Sonntag.pdf", "Sonja-Sonntag.pdf"] {
                let out = list.disguiser.apply(name).text
                #expect(!out.lowercased().contains("sonntag") && !out.lowercased().contains("sonja"), "\(name) → \(out)")
            }
            #expect(list.disguiser.apply("Treffen am Sonntag").text.contains("Sonntag"))
        }
    }


    // MARK: AC-12 · N2


    // MARK: AC-12, AC-11 · N5 and the span rule

    /// What the new finder admits from one text, by rule.
    static func found(_ text: String, typed: Bool = false) -> [(text: String, rule: Gate.Rule, entity: Entity)] {
        Detection.$override.withValue(.new) {
            var finder = RuleFinder()
            finder.typed = typed
            return finder.found(in: text, field: .body).map { ($0.entity.text, $0.rule, $0.entity) }
        }
    }

    @Test("F021 AC-12 · N5: the tagger's lone name is learned; a lone word the dictionary knows is not; a small word ends a span")
    func taggerAlone() {
        let paket = Self.found("Das Paket liegt bei Malinowski im Flur.")
        #expect(paket.contains { $0.text == "Malinowski" && $0.rule == .N5 }, "\(paket)")
        let kasse = Self.found("Die Kasse zahlt den Fahrdienst für Herrn Kobberke.")
        #expect(kasse.contains { $0.text.hasSuffix("Kobberke") }, "\(kasse)")
        #expect(!kasse.contains { $0.text.contains("Kasse") || $0.text.contains("Fahrdienst") }, "\(kasse)")
        #expect(RuleFinder.span(of: "Kasse den Fahrdienst") == [["Kasse"], ["Fahrdienst"]])
        #expect(RuleFinder.span(of: "Julian von Elmhorst") == [["Julian", "von", "Elmhorst"]])
    }




    // MARK: AC-15 · N7 the sender, N6 the company




    @Test("F021 AC-15 · N6: a company by its kind word or legal form; the kind word alone is no one")
    func companies() {
        let werkstatt = Self.found("Die Werkstatt Sadowski hat angerufen.")
        #expect(werkstatt.contains { $0.text.contains("Sadowski") && $0.rule == .N6 }, "\(werkstatt)")
        // The whole company is hidden, its kind word too (N6, the lead's word at Build); not the word before it.
        let krull = Self.found("Rückruf Sanitätshaus Krull KG wegen Rollator")
        #expect(krull.contains { $0.text == "Sanitätshaus Krull KG" && $0.rule == .N6 }, "\(krull)")
        #expect(!krull.contains { $0.text.contains("Rückruf") }, "\(krull)")
        let kasse = Self.found("Muss die Krankenkasse vorher zustimmen?")
        #expect(kasse.isEmpty, "\(kasse)")
    }

    // MARK: AC-13 · N8, each text in its own language; the owner's own words through the gate





    // MARK: AC-16 · N3 at the start of a line, N4 a word no dictionary knows


    @Test("F021 AC-16 · N4: a capitalised word no dictionary knows, in running text, is a person; a file's name is read by its words")
    func unknownWord() {
        let found = Self.found("Gestern hat Kottmeier wegen der Hecke angerufen.")
        #expect(found.contains { $0.text == "Kottmeier" && $0.rule == .N4 }, "\(found)")
        #expect(!found.contains { $0.text == "Hecke" }, "\(found)")
        let file = Detection.$override.withValue(.new) {
            RuleFinder().entities(in: Email(source: URL(fileURLWithPath: "/tmp/x"), id: "x", headers: [:], subject: "Scan", from: "", to: [], cc: [],
                                            date: Date(), body: "", attachments: [.init(filename: "Arztbrief_Simone_Hollenbach_2026.pdf", contentType: "application/pdf", byteCount: 1)]))
        }
        #expect(file.contains { $0.text == "Simone Hollenbach" }, "\(file)")
        let inText = Self.found("Anbei Kuendigung_Casper_Hermanns.pdf und scan-lotta-lemke.jpg")
        #expect(inText.contains { $0.text == "Casper Hermanns" } && inText.contains { $0.text == "lotta lemke" }, "\(inText)")
    }

    // MARK: AC-20 · L1, the second opinion

    static let f020Words = ["Haus", "Markt", "Post", "Oma", "Park", "Keller", "Kasse", "Falle", "Sonntag", "Med", "Sehr", "Bitte", "der", "die"]


    @Test("F021 AC-20 · the tagger and the first-name list keep a lone name the lowercase test doubts; never Sonntag")
    func taggerAndList() {
        let gernot = Self.found("Die Wohnung Gernot ist frei.") + Self.found("Wohnung Gernot")
        #expect(gernot.contains { $0.text == "Gernot" }, "\(gernot)")
        let sonntag = Self.found("Wir sehen uns Sonntag wieder.")
        #expect(!sonntag.contains { $0.text.contains("Sonntag") }, "\(sonntag)")
    }

    @Test("F021 AC-20 · a lowercase first name beside the word that stands before a person is found, whatever the dictionary knows")
    func lowercaseFirstNames() {
        for (text, name) in [("frag tobias ob er am samstag beim umzug hilft", "tobias"), ("was hat paulina zur kaution gesagt?", "paulina"),
                             ("anruf bei irmtraud wegen dem garten", "irmtraud"), ("sina's idea: book the weekend", "sina")] {
            let found = Self.found(text)
            #expect(found.contains { $0.text == name && $0.rule == .L1 }, "\(text): \(found)")
        }
        for text in ["ich will morgen anrufen", "bei max. 20 grad", "die rose blüht", "mark it as done"] {
            #expect(Self.found(text).isEmpty, "\(text): \(Self.found(text))")
        }
    }

    @Test("F021 AC-20 · Sonja Sonntag is")
    func listBesideFirstName() {
        let found = Self.found("Morgen kommt Sonja Sonntag vorbei.")
        #expect(found.contains { $0.text == "Sonja Sonntag" }, "\(found)")
    }

    @Test("F021 AC-20 · a list never raises a title or a small word")
    func listNeverRaises() {
        let opinion = SecondOpinion()
        for word in ["Frau", "Herr", "Herrn", "Dr.", "Prof.", "Bei", "Liebe", "der", "Die", "Von", "Und", "Mit"] {
            #expect(!opinion.isFirstName(word) && !opinion.isName(word), "\(word)")
        }
        #expect(opinion.isFirstName("Sonja") && opinion.isFirstName("Gesche"))
    }

    @Test("F021 AC-20 · the lists' first load within 150 ms and 8 MB")
    func listsLoad() {
        _ = SecondOpinion().isFirstName("Gesche")
        let lists = NameKnowledge.shared
        print("F021 AC-20 · the lists: \(lists.loads) load(s), \(String(format: "%.0f", lists.loadSeconds * 1000)) ms, \(lists.bytesHeld / 1_000_000) MB held (this process, \(DetectionMeasureTests.isSimulator ? "simulator" : "device"))")
        #expect(lists.loads >= 1)
        #expect(lists.bytesHeld <= 8_000_000, "\(lists.bytesHeld) bytes")
        // The 150 ms are the iPhone's (F020 AC-17), held on the device at Proof; the Mac's debug
        // build and a simulator print theirs.
        #if os(iOS) && !targetEnvironment(simulator)
        #expect(lists.loadSeconds <= 0.150, "\(lists.loadSeconds) s")
        #endif
    }

    // MARK: AC-10, AC-17 · the owner's two sentences of 17 November, tier A

    static let rehaMama = "Reha Mama – Gudula Volkmar braucht einen Fahrdienst, und der Fahrdienst benötigt ihr Geburtsdatum vom 17.06.59 und muss entsprechend bei der Krankenkasse gemeldet werden."




    // MARK: AC-14 · B, the shapes: S1, S2, S3, S4


    @Test("F021 AC-14 · a policy number, a labelled number, nine digits still found")
    func numbersStillFound() {
        let text = "Police_KV-0000-31876_2026.pdf, Versichertennummer: M704219385, Kundennummer: HV-000-7731, Code 123456789."
        let found = Self.found(text).map(\.text)
        for number in ["KV-0000-31876", "M704219385", "HV-000-7731", "123456789"] {
            #expect(found.contains { $0.contains(number) }, "\(number): \(found)")
        }
    }

    @Test("F021 AC-6 · S1, S4: an IBAN, a phone, a plate after its label, a street, a postal town, a place the tagger reads")
    func shapes() {
        let text = "IBAN DE41 2330 6697 0587 1505 11, Handy +49 151 0000 2290, Tel. 0151 0000 6612. Kennzeichen: K-LM 7302. Neue Adresse: Möwenstraße 21, 18119 Rostock. Am Markt 3 und 14 Larchmere Road. Wir fahren nach Lübbecke."
        let found = Self.found(text).map(\.text)
        for item in ["DE41 2330 6697 0587 1505 11", "+49 151 0000 2290", "0151 0000 6612", "K-LM 7302", "Möwenstraße 21", "18119 Rostock", "Am Markt 3", "14 Larchmere Road", "Lübbecke"] {
            #expect(found.contains { $0.contains(item) }, "\(item): \(found)")
        }
        let dated = Self.found("Am Montag 12 Uhr treffen wir uns, im Jahr 2026.").map(\.text)
        #expect(dated.isEmpty, "\(dated)")
    }

    @Test("F021 AC-6 · a BIC or an IBAN is never a name: S1 takes it before N4")
    func bicIsNoName() {
        for (text, code) in [("BIC: COBADEFFXXX, danke.", "COBADEFFXXX"), ("SWIFT DEUTDEFF500 bitte", "DEUTDEFF500")] {
            let found = Self.found(text)
            #expect(found.contains { $0.text == code && $0.entity.kind == .reference }, "\(text): \(found)")
            #expect(!found.contains { $0.rule == .N4 }, "\(text): \(found)")
        }
    }

    // MARK: C · C1, the date of birth by its label

    @Test("F021 AC-6 · C1: a date of birth by its label, in every written form; a date with no label stays")
    func birthDates() {
        for (text, date) in [("Geburtsdatum vom 17.06.59", "17.06.59"), ("geb. 21.07.1939", "21.07.1939"), ("geboren am 7. Juni 1949", "7. Juni 1949"),
                             ("born 19 May 1951", "19 May 1951"), ("DOB: 13/02/1953", "13/02/1953"), ("Date of birth: 1941-07-19", "1941-07-19"),
                             ("*26.05.1958", "26.05.1958"), ("Jahrgang 1958", "1958"), ("geb.: 29.02.1964", "29.02.1964")] {
            let found = Self.found(text)
            #expect(found.contains { $0.text == date && $0.rule == .C1 }, "\(text): \(found.map(\.text))")
        }
        #expect(Self.found("Frist bis 15.12.2026, Termin am 24.11.").isEmpty)
    }


    // MARK: AC-9 · what the old admission's tests guarded, through the gate

    /// What a text teaches an empty list under the rules, from the text itself.
    static func learned(_ text: String) -> Pseudonymizer {
        var list = Pseudonymizer(mode: .placeholder)
        Detection.learn(Detection.finder().entities(in: text, field: .body), into: &list)
        return list
    }

    @Test("F021 AC-9 · what „The ordinary words at the edge of a tagger's span come off“ guarded, through the gate")
    func trimmingThroughTheGate() {
        let stein = Self.learned("Liebe Frau Stein,\nvielen Dank für Ihre Nachricht.")
        #expect(stein.standIn(for: "Frau Stein") != nil && stein.standIn(for: "Liebe") == nil, "\(stein.entries.map(\.original))")
        for text in ["Bis Montag", "Sie behalten jederzeit den Kalender"] {
            let list = Self.learned(text)
            #expect(list.entries.isEmpty, "\(text): \(list.entries.map(\.original))")
        }
    }

    @Test("F021 AC-9 · what „A noun the tagger passes over nearly every time is not a name“ guarded, through the gate")
    func frequencyThroughTheGate() {
        let list = Self.learned(String(repeating: "Rückfragen bitte an Bittner. ", count: 10))
        #expect(list.standIn(for: "Rückfragen") == nil, "\(list.entries.map(\.original))")
        #expect(list.standIn(for: "Bittner") != nil, "\(list.entries.map(\.original))")
    }

    @Test("F021 AC-9 · what „The tagger's common-word guesses are left alone“ guarded, through the gate")
    func skipReasonsThroughTheGate() {
        let list = Self.learned("Mit Sie und Martin. Die Eigentuemer Honigwabenallee 47 sind eingeladen.")
        let learned = list.entries.map(\.original)
        #expect(!learned.contains { Pseudonymizer.words($0).contains(where: Ordinary.isSmall) }, "\(learned)")
        #expect(list.standIn(for: "Martin") != nil, "\(learned)")
        #expect(list.standIn(for: "Eigentuemer") == nil, "\(learned)")
    }

    @Test("F021 AC-12 · TestFlight 276: a tagger's span with two known words before a first name is cut without running past its end")
    func spanBeforeFirstName() {
        let text = "Heute war der Schöner Garten Hella Ferber hier."
        var read = RuleFinder.Reading(text: text, finder: RuleFinder(runsTagger: false))
        let span = text.range(of: "Schöner Garten Hella Ferber")!
        read.tagged = [RuleFinder.Tagged(kind: .person, range: span)]
        read.people = [span]
        let found = RuleFinder().taggedPeople(read, field: .body).map(\.text)
        #expect(found == ["Hella Ferber"], "\(found)")
    }

    // MARK: The gate, alone

    @Test("F021 AC-11 · the gate: a title anchors a calendar word; a small word and a title alone are never a name")
    func gateAnchors() {
        let words = SystemWords.shared
        func person(_ text: String, _ evidence: Set<Gate.Evidence>) -> Gate.Candidate {
            Gate.Candidate(kind: .person, text: text, field: .body, start: 0, length: text.utf16.count, evidence: evidence, rule: .N2)
        }
        #expect(Gate.admit(person("Frau Sonntag", [.title]), typed: false, words: words) != nil)
        #expect(Gate.admit(person("Frau", [.title]), typed: false, words: words) == nil)
        #expect(Gate.admit(person("der", [.tagger]), typed: true, words: words) == nil)
        #expect(Gate.admit(person("Sonntag", [.tagger]), typed: true, words: words) == nil)
        #expect(Gate.admit(person("Krankenkasse", [.tagger]), typed: true, words: words) == nil)
        #expect(Gate.admit(person("Sonja Sonntag", [.firstName]), typed: false, words: words) != nil)
    }
}
