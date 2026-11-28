import Foundation
import Testing
@testable import Disguise

/// Fix CAU-278, 28 Nov 2026: three ways the name hiding let something out or hid wrongly, on every
/// source — what comes in (mail, screenshots, photos, files and scans), notes, the chat, and tasks and
/// dates added by hand. Every name is made up.
/// 1. `Herr Pfleger hat geschrieben` went out as written: after a title, a role word that is a surname
///    too (`Pfleger`, `Nachbar`: on the shipped surname list) was read as a second title, and nothing
///    was hidden. Now that word after a title is the name when no name follows it; with a name after it,
///    it stays a visible role (`Herr Pfleger [Person A]`), as in 1.1.8. A role no list holds as a surname
///    stays a role after a title (`Herr Hausmeister kommt`, F021's "Not a name").
/// 2. `Check the PO box today.` hid `PO` as a company: a PO box without a number is an everyday phrase.
/// 3. A made-up town in running text (`Treffen in Feldau`) went out unless Apple's tagger read it. After
///    `in`, `aus`, `nach` or `bei`, a capitalised word that is not on the shipped everyday list is a
///    place; the set phrases that follow these words stay as written (`in Ordnung`, `in Time`).
@Suite("Fix CAU-278 · A role after a title, a PO box, a town in running text", .serialized)
@MainActor
struct TitleRolePOBoxTownRulesTests {
    func run(_ text: String, typed: Bool) -> (found: [String], sent: String, list: Pseudonymizer) {
        Detection.$override.withValue(.new) {
            var finder = RuleFinder()
            finder.typed = typed
            let entities = finder.entities(in: text, field: .body)
            var list = Pseudonymizer(Pseudonymizer.Mapping())
            Detection.learn(entities, into: &list)
            return (entities.map(\.text), list.disguiser.apply(text).text, list)
        }
    }

    static let titles = ["Frau", "Herr", "Herrn", "Dr.", "Prof.", "Herr Dr.", "Frau Dr."]
    /// The roles that are titles (`Pseudonymizer.roles`) and on the shipped surname list.
    static let titleRoles = ["Pfleger", "Nachbar"]

    @Test("The roles that are surnames too are on the shipped surname list; the other roles are not")
    func surnameRolesOnTheList() {
        let lists = NameKnowledge.shared
        for role in Self.titleRoles { #expect(lists.isSurname(role) == true, "\(role)") }
        for role in ["Hausmeister", "Rechtsanwältin", "Kollege", "Kollegin", "Nachbarin", "Pflegerin", "Notar"] {
            #expect(lists.isSurname(role) == false, "\(role)")
        }
    }

    @Test("A role word after a title, with no name after it, is the name: hidden, the title stays")
    func roleAfterTitleIsTheName() {
        for typed in [true, false] {
            for title in Self.titles {
                for role in Self.titleRoles {
                    for frame in ["%@ hat geschrieben.", "Gestern rief %@ an.", "%@, bitte melden.", "Bitte %@ anrufen."] {
                        let text = String(format: frame, "\(title) \(role)")
                        let (found, sent, _) = run(text, typed: typed)
                        #expect(!Self.words(sent).contains(role), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
                        #expect(sent.contains(title), "typed \(typed): \(text) ⇒ \(sent)")
                    }
                }
            }
        }
    }

    @Test("The owner's case: Herr Pfleger hat geschrieben")
    func herrPfleger() {
        for typed in [true, false] {
            #expect(run("Herr Pfleger hat geschrieben.", typed: typed).sent == "Herr [Person A] hat geschrieben.")
            #expect(run("Mr Neighbour called.", typed: typed).sent == "Mr [Person A] called.")
        }
    }

    @Test("Guard: a role word after a title, with a name after it, stays a visible role, as in 1.1.8")
    func roleBeforeNameStaysARole() {
        for typed in [true, false] {
            for (text, sent) in [("Frau Nachbarin Quellbach hat angerufen.", "Frau Nachbarin [Person A] hat angerufen."),
                                 ("Herr Pfleger Quellbach kommt.", "Herr Pfleger [Person A] kommt."),
                                 ("Herr Nachbar Tannhauf hat geschrieben.", "Herr Nachbar [Person A] hat geschrieben."),
                                 ("Frau Nachbarin Ilka Sternwald kommt.", "Frau Nachbarin [Person A] kommt.")] {
                #expect(run(text, typed: typed).sent == sent, "typed \(typed): \(text) ⇒ \(run(text, typed: typed).sent)")
            }
        }
    }

    @Test("Guard: a role word with no title before it goes as written, as in 1.1.8")
    func roleAloneStays() {
        for typed in [true, false] {
            for text in ["Der Nachbar hat angerufen.", "Pfleger kommt um acht.", "Die Kollegin ist krank.", "Nachbarin hat geschrieben."] {
                #expect(run(text, typed: typed).sent == text, "typed \(typed): \(text) ⇒ \(run(text, typed: typed).sent)")
            }
        }
    }

    @Test("Guard: a role no list holds as a surname stays a role after a title, as in 1.1.8")
    func otherRolesAfterTitleStay() {
        for typed in [true, false] {
            for text in ["Herr Hausmeister kommt", "Sehr geehrte Frau Rechtsanwältin,", "Liebe Frau Kollegin,", "Frau Nachbarin hat angerufen.",
                         "Herr Notar hat geschrieben."] {
                #expect(run(text, typed: typed).sent == text, "typed \(typed): \(text) ⇒ \(run(text, typed: typed).sent)")
            }
        }
    }

    @Test("The chat's whole path: Herr Pfleger comes back as written")
    func herrPflegerRoundTrip() {
        for typed in [true, false] {
            for question in ["Herr Pfleger hat geschrieben, was will er?", "Was schreibt Herr Nachbar?"] {
                let (_, asked, list) = run(question, typed: typed)
                #expect(!asked.contains("Pfleger") && !asked.contains("Nachbar"), "\(asked)")
                #expect(list.restore(asked) == question, "\(list.restore(asked))")
            }
        }
    }

    @Test("A PO box without a number is an everyday phrase and goes as written")
    func poBoxWithoutNumber() {
        for typed in [true, false] {
            for text in ["Check the PO box today.", "Check the PO Box today.", "The PO box is full.", "PO box key is in the drawer.",
                         "Please check the P.O. box.", "Empty the PO Box on Monday."] {
                #expect(run(text, typed: typed).sent == text, "typed \(typed): \(text) ⇒ \(run(text, typed: typed).sent)")
            }
        }
    }

    @Test("Guard: a PO box with its number is still hidden")
    func poBoxWithNumber() {
        for typed in [true, false] {
            for text in ["Send it to PO Box 4120.", "The PO Box 4120 in Feldau is ours.", "Ilka Sternwald, PO Box 12, Feldau"] {
                let sent = run(text, typed: typed).sent
                #expect(!sent.contains("4120") && !sent.contains(" 12") && !sent.contains("Feldau"), "typed \(typed): \(text) ⇒ \(sent)")
            }
        }
    }

    static let madeUpTowns = ["Feldau", "Moorbrück", "Quellingen", "Tannwiesen", "Kleinhorst"]

    @Test("A made-up town after in, aus, nach or bei, with no address on the line, is hidden")
    func townInRunningText() {
        for typed in [true, false] {
            for town in Self.madeUpTowns {
                for text in ["Treffen in \(town).", "Sie kommt aus \(town).", "Wir fahren nach \(town).", "Er wohnt bei \(town).",
                             "In \(town) ist es kalt.", "Aus \(town) kam ein Brief.", "Ist das Paket schon in \(town) angekommen?",
                             "We met in \(town) yesterday.", "Termin bei \(town) und Ilka."] {
                    let (found, sent, _) = run(text, typed: typed)
                    #expect(!sent.contains(town), "typed \(typed): \(text) ⇒ \(sent) (found \(found))")
                }
            }
        }
    }

    @Test("Guard: a set phrase after in, aus, nach or bei goes as written")
    func setPhrasesStay() {
        let texts = ["Alles in Ordnung.", "Das war aus Versehen.", "In Zukunft bitte früher.", "Bei Gelegenheit anrufen.",
                     "Ich gehe nach Hause.", "We made it in Time.", "Bitte in Eile lesen.","Nach Absprache mit der Praxis.",
                     "Das ist in Arbeit.", "Das gilt ab sofort, in Kraft seit Mai.", "Bitte in Bar zahlen.", "Alles nach Plan.", "Sie kommt nach Feierabend.",
                     "Bitte in Kopie an die Kasse.", "Please reply in Writing.", "Keep in Touch.", "Pay in Advance.",
                     "Der Screenshot aus WhatsApp.", "Die Datei in Outlook öffnen."]
        for typed in [true, false] {
            for text in texts {
                #expect(run(text, typed: typed).sent == text, "typed \(typed): \(text) ⇒ \(run(text, typed: typed).sent)")
            }
        }
    }

    /// Not typed: in the owner's own question the tagger's lone guess is taken as it was in 1.1.8
    /// (`Bitte bei Rückfragen melden` asked in the chat hides `Rückfragen` there already).
    @Test("Guard: a compound of two everyday words after in, aus, nach or bei goes as written")
    func everydayCompoundsStay() {
        let texts = ["Bitte bei Rückfragen melden.", "Das kam aus Kostengründen nicht.", "Nach Terminabsprache kommt der Techniker.",
                     "Wir wohnen in Wohnungsnähe.", "Bitte in Druckbuchstaben schreiben.", "Bitte bei Nebenkosten prüfen."]
        for typed in [false] {
            for text in texts {
                #expect(run(text, typed: typed).sent == text, "typed \(typed): \(text) ⇒ \(run(text, typed: typed).sent)")
            }
        }
    }

    @Test("A made-up town made of everyday words, with a town's end, is hidden")
    func compoundTownsHidden() {
        for typed in [true, false] {
            for town in ["Steinfelde", "Erlenhausen", "Moosheim", "Lindenstadt"] {
                for text in ["Wir sind in \(town).", "Sie kommt aus \(town).", "Wir fahren nach \(town)."] {
                    let sent = run(text, typed: typed).sent
                    #expect(!sent.contains(town), "typed \(typed): \(text) ⇒ \(sent)")
                }
            }
        }
    }

    @Test("The same text on every device: the town and the role word are read from shipped lists only")
    func sameTextEverywhere() {
        for typed in [true, false] {
            for (text, sent) in [("Treffen in Feldau.", "Treffen in [Place A]."), ("Sie kommt aus Feldau.", "Sie kommt aus [Place A]."),
                                 ("Wir fahren nach Kleinhorst.", "Wir fahren nach [Place A]."), ("Er wohnt bei Feldau.", "Er wohnt bei [Place A]."),
                                 ("Herr Nachbar kommt morgen.", "Herr [Person A] kommt morgen."), ("Check the PO box today.", "Check the PO box today."),
                                 ("Alles in Ordnung, bis nach Hause.", "Alles in Ordnung, bis nach Hause.")] {
                #expect(run(text, typed: typed).sent == sent, "typed \(typed): \(text) ⇒ \(run(text, typed: typed).sent)")
            }
        }
    }

    /// The set `EverydayNouns` was built from: nouns of care, health, money, housing, work and shopping.
    /// The list was grown from its misses, so it is no measure of new words; `heldOutNouns` is.
    static let listBuildingNouns = [
        "Pflegegrad", "Hüftoperation", "Paragraph", "Gleitzeit", "Kaution", "Widerruf", "Pfändung", "Minijob", "Retoure",
        "Spesen", "Tilgung", "Krankschreibung", "Lieferverzug", "Pieces", "Knieoperation", "Kataraktoperation", "Herzkatheter",
        "Magenspiegelung", "Darmspiegelung", "Mammographie", "Hautkrebsscreening", "Gesundheitscheck", "Zahnarzttermin",
        "Wurzelbehandlung", "Implantat", "Prothese", "Gehhilfe", "Toilettenstuhl", "Badewannenlift", "Duschhocker",
        "Notrufknopf", "Sturzprophylaxe", "Mobilisation", "Grundpflege", "Behandlungspflege", "Pflegeplanung",
        "Pflegedokumentation", "Pflegevisite", "Medikamentengabe", "Blutdruckmessung", "Gewichtskontrolle",
        "Ernährungsberatung", "Diätberatung", "Trinkmenge", "Schluckstörung", "Sondenernährung", "Wundheilung", "Dekubitus",
        "Kontrakturen", "Gangunsicherheit", "Schwindel", "Atemnot", "Herzinsuffizienz", "Vorhofflimmern", "Schlaganfall",
        "Herzinfarkt", "Lungenentzündung", "Harnwegsinfekt", "Blasenentzündung", "Bronchitis", "Grippe", "Erkältung", "Fieber",
        "Durchfall", "Verstopfung", "Übelkeit", "Schlafstörung", "Depression", "Angststörung", "Verwirrtheit", "Nachtunruhe",
        "Tagesstruktur", "Beschäftigungstherapie", "Gedächtnistraining", "Seniorentreff", "Begegnungsstätte", "Mittagstisch",
        "Fahrdienstleistung", "Begleitdienst", "Besuchsdienst", "Alltagsbegleitung", "Haushaltshilfe", "Putzhilfe",
        "Einkaufshilfe", "Nachbarschaftshilfe", "Kurzzeitpflegeplatz", "Heimplatz", "Wohngruppe", "Betreutes",
        "Seniorenwohnung", "Barrierefreiheit", "Rampe", "Haltegriffe", "Wohnberatung", "Pflegestützpunkt", "Sozialberatung",
        "Rentenberatung", "Steuerberatung", "Schuldenberatung", "Verbraucherberatung", "Mieterverein", "Mieterbund",
        "Nebenkostennachzahlung", "Heizkostenabrechnung", "Wasserverbrauch", "Stromverbrauch", "Abschlagsänderung",
        "Preiserhöhung", "Sonderkündigungsrecht", "Vertragsverlängerung", "Tarifänderung", "Mobilfunkvertrag", "Handyvertrag",
        "Internetanschluss", "Glasfaser", "Router", "Störung", "Entstörung", "Technikertermin", "Portierung",
        "Rufnummernmitnahme", "Kündigungsbestätigung", "Eingangsbestätigung", "Zahlungseingang", "Zahlungserinnerung",
        "Mahnbescheid", "Vollstreckungsbescheid", "Kontopfändung", "Lohnpfändung", "Ratenvereinbarung", "Zahlungsplan",
        "Schuldenregulierung", "Privatinsolvenz", "Restschuldbefreiung", "Kontoführung", "Kontoführungsgebühr", "Dispo",
        "Dispokredit", "Überziehung", "Kreditkarte", "Girokarte", "Onlinebanking", "Überweisungslimit", "Sparbuch", "Festgeld",
        "Tagesgeld", "Bausparvertrag", "Riester", "Lebensversicherung", "Berufsunfähigkeit", "Zahnzusatzversicherung",
        "Reiseversicherung", "Rechtsschutzversicherung", "Kfz-Versicherung", "Beitragserhöhung", "Beitragsrückerstattung",
        "Selbstbehalt", "Leistungsantrag", "Kostenübernahme", "Kostenzusage", "Genehmigung", "Ablehnungsbescheid",
        "Widerspruchsfrist", "Klagefrist", "Fristverlängerung", "Aufschub", "Verjährung", "Arbeitsamt", "Arbeitssuche",
        "Jobsuche", "Vermittlung", "Eingliederungsvereinbarung", "Maßnahme", "Sperrzeit", "Krankenschein", "Attest",
        "Bescheinigung", "Lohnfortzahlung", "Entgeltfortzahlung", "Urlaubsgeld", "Weihnachtsgeld", "Prämie", "Zulage",
        "Nachtzuschlag", "Fahrtkosten", "Pendlerpauschale", "Jobticket", "Dienstwagen", "Gleitzeitkonto", "Zeiterfassung",
        "Stempelkarte", "Dienstplan", "Schichtplan", "Personalgespräch", "Abmahnung", "Aufhebungsvertrag", "Freistellung",
        "Elternzeitantrag", "Wiedereinstieg", "Paketzustellung", "Lieferadresse", "Rechnungsadresse", "Retourenschein",
        "Rücksendeetikett", "Erstattungsbetrag", "Ersatzlieferung", "Teillieferung", "Nachlieferung", "Lieferengpass",
        "Ausverkauf", "Schlussverkauf", "Treuepunkte", "Kundenkarte", "Kundenkonto", "Passwortänderung", "Zwei-Faktor",
    ]

    /// Nouns of the same kinds written after the list and the noun ends were made, and never added to
    /// either (the test checks it): the measure of nouns the list has not seen.
    static let heldOutNouns = [
        "Augentropfen", "Nasenspray", "Hustensaft", "Halsschmerzen", "Ohrenschmerzen", "Zahnschmerzen", "Bauchschmerzen",
        "Muskelkater", "Zerrung", "Prellung", "Verstauchung", "Platzwunde", "Schürfwunde", "Sonnenbrand", "Insektenstich",
        "Zeckenbiss", "Heuschnupfen", "Pollenallergie", "Laktoseintoleranz", "Glutenunverträglichkeit", "Bluterguss",
        "Wasserablagerung", "Krampfadern", "Hämorrhoiden", "Sodbrennen", "Reflux", "Magengeschwür", "Nierenschwäche",
        "Leberwerterhöhung", "Blutarmut", "Eisenmangel", "Vitaminmangel", "Dehydrierung", "Unterzuckerung", "Überzuckerung",
        "Herzrasen", "Herzstolpern", "Ohnmacht", "Kreislaufkollaps", "Schwächeanfall", "Bettlägerigkeit", "Pflegeaufwand",
        "Rundumbetreuung", "Nachtwache", "Sitzwache", "Pflegekraftmangel", "Personalmangel", "Zahnarztrechnung", "Arztrechnung",
        "Laborrechnung", "Privatrechnung", "Zahnzusatz", "Brillenzuschuss", "Festzuschuss", "Heil-und-Kostenplan", "Kostenplan",
        "Behandlungsplan", "Therapieplan", "Trainingsplan", "Ernährungsplan", "Wochenplan", "Putzplan", "Einkaufsliste",
        "Wunschliste", "Warteliste", "Nachrückerliste", "Mietspiegel", "Vergleichsmiete", "Indexmiete", "Staffelmiete",
        "Kaltmiete", "Warmmiete", "Bruttomiete", "Mietsenkung", "Mietpreisbremse", "Nebenkostenpauschale",
        "Heizkostenpauschale", "Gartenpflege", "Dachrinne", "Fallrohr", "Regenrinne", "Dachboden", "Kellerabteil",
        "Fahrradkeller", "Waschküche", "Trockenraum", "Müllraum", "Briefkastenschlüssel", "Haustürschlüssel", "Zweitschlüssel",
        "Ersatzschlüssel", "Schließanlage", "Gegensprechanlage", "Klingelschild", "Namensschild", "Rauchmelder", "Feuerlöscher",
        "Heizkörper", "Thermostat", "Boiler", "Durchlauferhitzer", "Spülmaschine", "Waschmaschine", "Trockner", "Kühlschrank",
        "Gefrierschrank", "Herdplatte", "Dunstabzug", "Abfluss", "Silikonfuge", "Gehaltserhöhung", "Lohnerhöhung",
        "Tariferhöhung", "Inflationsausgleich", "Einmalzahlung", "Sonderzahlung", "Provision", "Bonus", "Gewinnbeteiligung",
        "Firmenwagen", "Diensthandy", "Dienstlaptop", "Arbeitskleidung", "Schutzkleidung", "Sicherheitsschuhe", "Spind",
        "Kantine", "Essensmarken", "Betriebsausflug", "Weihnachtsfeier", "Teambesprechung", "Mitarbeitergespräch",
        "Zielvereinbarung", "Leistungsbeurteilung", "Beförderung", "Versetzung", "Probezeitverlängerung", "Befristung",
        "Entfristung", "Festanstellung", "Leiharbeit", "Zeitarbeit", "Werkvertrag", "Honorarvertrag", "Freiberuflichkeit",
        "Scheinselbstständigkeit", "Kassenzettel", "Wechselgeld", "Pfandbon", "Pfandflasche", "Leergut", "Einkaufswagen",
        "Einkaufstüte", "Mehrwegtasche", "Treuekarte", "Payback", "Coupon", "Rabattmarke", "Sonderposten", "Restposten",
        "Mängelexemplar", "Vorführgerät", "Ausstellungsstück", "Lieferschwierigkeit", "Vorbestellung", "Wunschtermin",
        "Zeitfenster", "Lieferfenster", "Abstellgenehmigung", "Nachbarzustellung", "Zustellversuch", "Benachrichtigungskarte",
        "Abholschein", "Lagerfrist", "Rücksendefrist", "Umtauschfrist", "Kulanzfrist", "Kontostand", "Kontonummer",
        "Bankleitzahl", "Überweisungsbeleg", "Echtzeitüberweisung", "Auslandsüberweisung", "Wechselkurs", "Bargeldabhebung",
        "Geldautomat", "Abhebegebühr", "Sollzinsen", "Habenzinsen", "Negativzinsen", "Kontosperrung", "Kartensperrung",
        "Sperrnummer", "Pinbrief", "Tan-Liste", "Pushtan", "Sicherheitsfrage",
    ]

    /// Made-up towns with a town's end (`RuleFinder.proseTownEnds`): every one is hidden after the four words.
    static let madeUpTownsWithEnd = [
        "Feldau", "Kleinhorst", "Quellingen", "Moorbrück", "Tannwiesen", "Steinfelde", "Erlenhausen", "Moosheim", "Lindenstadt",
        "Birkwalde", "Ellerbeck", "Grauenstein", "Fichtenhain", "Weidenbüttel", "Ottersleben", "Haselrode", "Ulmenstedt",
        "Lerchenborn", "Dachsfurt", "Kiefernhagen", "Eschenweiler", "Holderbach", "Tannkirchen", "Quendorf", "Mühlberg",
        "Rabenburg", "Seelitz", "Gramzow", "Sumpfhausen", "Ahornfeld", "Blaubach", "Nebelheim", "Krautingen", "Fuchsau",
        "Ackerstedt", "Talbrück", "Schilfhorst", "Lehmrode", "Mergelstein", "Wacholderdorf", "Pappelburg", "Kreidenberg",
        "Torfhausen", "Sandleben", "Heidenau", "Krummbach", "Zwiebelstedt",
    ]

    /// Made-up towns with no such end (`-bruch`, `-tal`, `-hof`, `-see`, `-ach`, `-ing`, …): in running text
    /// they may go out as written, as in 1.1.8 (the owner, 28 Nov: "b — only clear cases"); in an address
    /// they are hidden.
    static let madeUpTownsWithoutEnd = [
        "Moorbruch", "Krähwinkel", "Brombachtal", "Wiesenhof", "Tessenach", "Wolfering", "Bühlum", "Haltens", "Reppede",
        "Merzlar", "Kranichsee", "Silbertal", "Grünwiese", "Hirschwald", "Ginsterbruch",
    ]

    /// What the town rule itself takes, and what any rule hides. The town rule reads shipped lists only,
    /// so its share is the same on every device; the older rules (the dictionary's unknown word, the
    /// tagger's lone guess after `bei`) differ by device, as in 1.1.8.
    func overHiding(_ nouns: [String], _ name: String) -> (taken: Double, hidden: Double) {
        var taken: [String] = [], hidden: [String] = [], probes = 0
        for noun in nouns {
            for word in ["in", "aus", "nach", "bei"] {
                let text = "Es geht \(word) \(noun) weiter."
                probes += 1
                let finder = RuleFinder()
                if !finder.townsAfterWord(RuleFinder.Reading(text: text, finder: finder), field: .body).isEmpty { taken.append("\(word) \(noun)") }
                if !run(text, typed: false).sent.contains(noun) { hidden.append("\(word) \(noun)") }
            }
        }
        let share = (Double(taken.count) / Double(probes), Double(hidden.count) / Double(probes))
        print("CAU-278 \(name): the town rule takes \(taken.count) of \(probes) (\(String(format: "%.1f", share.0 * 100)) %): \(taken)")
        print("CAU-278 \(name): hidden by any rule \(hidden.count) of \(probes) (\(String(format: "%.1f", share.1 * 100)) %): \(hidden)")
        return share
    }

    @Test("The nouns the list was built from: the town rule takes at most 5 in 100 of them")
    func overHidingListBuildingSet() {
        #expect(Self.listBuildingNouns.count >= 150)
        #expect(overHiding(Self.listBuildingNouns, "list-building set").taken <= 0.05)
    }

    /// The owner, 28 Nov: "b — only clear cases". The town rule fires only on a town's end, so on the
    /// held-out nouns it takes next to none (bound 3 in 100). What all rules hide there is the older
    /// rules' (the dictionary's unknown word, the tagger's guess after `bei`), as in 1.1.8: printed.
    @Test("Held-out nouns, on no list: the town rule takes at most 3 in 100")
    func overHidingHeldOut() {
        #expect(Self.heldOutNouns.count >= 150)
        for noun in Self.heldOutNouns {
            #expect(!EverydayNouns.contains(noun) && !Self.listBuildingNouns.contains(noun), "\(noun) is no longer held out")
        }
        #expect(overHiding(Self.heldOutNouns, "held-out set").taken <= 0.03)
    }

    @Test("Every made-up town with a town's end is hidden after in, aus, nach and bei")
    func madeUpTownsHidden() {
        #expect(Self.madeUpTownsWithEnd.count + Self.madeUpTownsWithoutEnd.count == 62)
        var shown: [String] = []
        for town in Self.madeUpTownsWithEnd {
            for word in ["in", "aus", "nach", "bei"] where run("Es geht \(word) \(town) weiter.", typed: false).sent.contains(town) {
                shown.append("\(word) \(town)")
            }
        }
        #expect(shown.isEmpty, "\(shown)")
    }

    @Test("Guard: -au is a town's end, but not where an everyday word ends the word: Ausbau, Umbau, Neubau")
    func auIsNoTownInEverydayWords() {
        for text in ["Das Haus ist nach Ausbau fertig.", "Die Küche ist in Umbau.", "Fragen bei Neubau klären.", "Die Straße ist in Rückbau.",
                     "Er steht in Stau."] {
            #expect(run(text, typed: false).sent == text, "\(text) ⇒ \(run(text, typed: false).sent)")
        }
    }

    /// The owner, 28 Nov: "b — only clear cases". A made-up town with no town's end may go out in a
    /// plain sentence (printed: which do, on this device); in an address line it is hidden.
    @Test("A made-up town with no town's end: hidden in an address, may go out in running text")
    func madeUpTownsWithoutEndInAddress() {
        var inProse: [String] = []
        for town in Self.madeUpTownsWithoutEnd {
            for text in ["Anschrift: Lindenweg 4, \(town)", "Lindenweg 4 in \(town)", "79098 \(town)"] {
                let sent = run(text, typed: false).sent
                #expect(!sent.contains(town), "\(text) ⇒ \(sent)")
            }
            if run("Treffen in \(town).", typed: false).sent.contains(town) { inProse.append(town) }
        }
        print("CAU-278 made-up towns with no town's end that go out in \"Treffen in …\": \(inProse)")
    }

    @Test("The review's care case: in Pflegegrad 3, nach Hüftoperation, bei Pfändung go as written")
    func careNounsStay() {
        for text in ["Er ist in Pflegegrad 3.", "Sie ist nach Hüftoperation zu Hause.", "Das Konto ist in Pfändung.", "Sie ist nach Schlaganfall in Kurzzeitpflege."] {
            #expect(run(text, typed: false).sent == text, "\(text) ⇒ \(run(text, typed: false).sent)")
        }
    }

    @Test("The everyday nouns hold no first name or surname of the shipped lists, and no old detail of F024")
    func everydayNounsHoldNoName() {
        let lists = NameKnowledge.shared
        #expect(EverydayNouns.words.count >= 250)
        for word in EverydayNouns.words {
            #expect(lists.isFirstName(word) == false && lists.isSurname(word) == false, "\(word)")
            #expect(!F024NamesTests.old.contains(F024NamesTests.hash(word)), "an old detail")
        }
    }

    @Test("A word written small after Herr Pfleger never decides: Pfleger is hidden on every device")
    func smallWordAfterRole() {
        for typed in [true, false] {
            for text in ["Herr Pfleger whatsappt gerade.", "Herr Pfleger hat geschrieben.", "Herr Nachbar mailt morgen."] {
                let sent = run(text, typed: typed).sent
                #expect(!sent.contains("Pfleger") && !sent.contains("Nachbar"), "typed \(typed): \(text) ⇒ \(sent)")
                #expect(sent.hasPrefix("Herr [Person A]"), "typed \(typed): \(text) ⇒ \(sent)")
            }
        }
    }

    @Test("A first name after bei is a person, and hidden")
    func firstNameAfterBei() {
        for typed in [true, false] {
            #expect(run("Der Schlüssel ist bei Ilka.", typed: typed).sent == "Der Schlüssel ist bei [Person A].")
        }
    }

    @Test("A known city after aus may be hidden; the rest of the sentence goes as written")
    func cityAfterAus() {
        for typed in [true, false] {
            let sent = run("Sie kommt aus Berlin.", typed: typed).sent
            #expect(sent == "Sie kommt aus Berlin." || sent == "Sie kommt aus [Place A].", "typed \(typed): \(sent)")
        }
    }

    static func words(_ text: String) -> Set<String> { Set(text.matches(of: /[\p{L}]+/).map { String($0.output) }) }

    struct Probe: Codable { var text: String; var typed: Bool; var sent: String }

    /// The words 1.1.8 hid that go as written now: `PO box` with no number after it (case 2).
    static func meantToShow(_ word: String, in text: String) -> Bool {
        ["PO", "Box"].contains(word) && text.range(of: #"\bP\.?O\.? [Bb]ox(?![ \t]*:?[ \t]*\d)"#, options: .regularExpression) != nil
    }

    /// Against 1.1.8's own output on the same kind of device: recorded from a clean 141aef6 on the Mac
    /// and on the Causabee Tests iPhone simulator. The two differ in 90 of 9,346 probes, all the tagger's
    /// (the Mac's reads `Reha`, `Theory` as places, the simulator's does not), as they did in 1.1.8.
    @Test("Nothing 1.1.8 hid goes out now: every word it hid is hidden still, but a PO box without a number")
    func nothingLessHiddenThan118() throws {
        let record = DetectionMeasureTests.isSimulator ? "cau-278-1.1.8-simulator.json" : "cau-278-1.1.8.json"
        let file = F024GoldenTests.fixtures.appendingPathComponent(record)
        let probes = try JSONDecoder().decode([Probe].self, from: Data(contentsOf: file))
        #expect(probes.count > 9000)
        for probe in probes {
            let now = run(probe.text, typed: probe.typed).sent
            let all = Self.words(probe.text)
            let hiddenThen = all.subtracting(Self.words(probe.sent)).filter { !Self.meantToShow($0, in: probe.text) }
            let hiddenNow = all.subtracting(Self.words(now))
            #expect(hiddenThen.isSubset(of: hiddenNow), "typed \(probe.typed): \(probe.text) ⇒ 1.1.8 \(probe.sent), now \(now)")
        }
    }
}
