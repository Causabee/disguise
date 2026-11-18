import Foundation
import SwiftData
import Testing
@testable import Disguise

/// F019, found at Proof on TestFlight 262 (17 November): the owner's first tries were held —
/// „Beträge“, „20261113“, „Falle“ stood "still in it". Each was junk in the list of names, found by
/// a check that matched more widely than the disguise. The check is now the disguise's own matcher,
/// run again over the exact text that leaves.
@Suite("F019 · A realistic owner: what is held, on every send path", .serialized)
@MainActor
struct RealOwnerTests {
    static func list(_ extra: [(Entity.Kind, String)]) -> Pseudonymizer.Mapping {
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        for (kind, text) in extra { _ = pseudonymizer.record(kind, text, pseudonymizer.placeholder(kind), partOf: nil) }
        var mapping = Pseudonymizer.Mapping()
        mapping.placeholder = pseudonymizer.entries
        return mapping
    }









    // MARK: Every send path

    struct Count: CustomStringConvertible {
        var sends = 0, held = 0, reasons: [String] = []
        var description: String { "\(held) held of \(sends)" + (reasons.isEmpty ? "" : " — " + reasons.prefix(6).joined(separator: "; ")) }
    }

    /// Strings of the demo matters, English and German, as the texts of what came in.
    static func demoTexts() -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var out: [String] = []
        for file in ["Sources/Causabee/DemoData.swift", "Sources/Causabee/DemoDataGerman.swift"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { continue }
            for match in text.matches(of: /"((?:[^"\\\n]|\\.){30,})"/) {
                let literal = String(match.output.1).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\(", with: "(")
                if literal.contains(" ") { out.append(literal) }
            }
        }
        return out
    }

    /// German care, insurance and rent, as they come in.
    static let incoming: [(source: String, subject: String, from: String, body: String, file: String?)] = [
        ("mail", "Ihr Antrag auf Kostenübernahme", "AOK Nordost <service@aok.example>",
         "Sehr geehrte Frau Selig,\n\nwir haben Ihren Antrag vom 13.11.2026 erhalten. In diesen Fällen benötigen wir das Geburtsdatum und die Versichertennummer. Die Beträge der Zuzahlung werden mit der Rechnung verrechnet. Erstattung des Betrages bis 2026-12-15.\n\nMit freundlichen Grüßen\nIhre Krankenkasse", nil),
        ("mail", "Nebenkostenabrechnung 2025", "Hausverwaltung Kortmann <info@hv.example>",
         "Hallo Gesine,\n\nanbei die Abrechnung. Nachzahlung des Betrages von 312,40 Euro bis zum 2026-11-27 auf DE89 3704 0044 0532 0130 00. Termin zur Wohnungsübergabe am 13.11. um 11:13 Uhr.\n\nGruß Piers Kortmann", "Abrechnung_20261113.pdf"),
        ("screenshot-other", "Screenshot: Termin bestätigt", "Screenshot",
         "Ihr Termin am 2026-11-13 um 14:00 Uhr bei Praxis am Markt ist bestätigt. Bitte bringen Sie Ihre Versichertenkarte mit.", nil),
        ("photo", "Zettel am Kühlschrank", "Dokument", "Mama: Rollator abholen, Rezept bei Dr. Wärtele, Fahrdienst anrufen 0171 1234567, Kasse fragen wegen Zuzahlung", "IMG_20261113_101530.jpg"),
        ("scan", "Bescheid Pflegekasse", "Dokument",
         "Bescheid über den Pflegegrad\nVersicherte: Irmtraud Selig, geb. 17.06.59\nVersichertennummer A123456789\nIn diesen Fällen ist ein Widerspruch innerhalb eines Monats möglich. Die Leistungen beginnen am 01.12.2026.", "Scan_20261113_Bescheid.pdf"),
        ("file-name", "2024_Xircle_AG_Jahresabschluss_Januar_bis_Juli2026_20261113.pdf", "Dokument", "", "2024_Xircle_AG_Jahresabschluss_Januar_bis_Juli2026_20261113.pdf"),
        ("note", "Notiz zum Fahrdienst", "Notiz", "Fahrdienst ab Dezember. Hartmuth schickt die Unterlagen. Falle nicht auf die Werbung rein. Fälle wie diese kennt die Kasse.", nil),
    ]

    static func email(_ item: (source: String, subject: String, from: String, body: String, file: String?), n: Int) -> Email {
        let attachments = item.file.map { [Email.Attachment(filename: $0, contentType: "application/pdf", byteCount: 1000)] } ?? []
        return Email(source: URL(fileURLWithPath: "/tmp/owner-\(n)"), id: "owner:\(n)", headers: ["subject": [item.subject]],
                     subject: item.subject, from: item.from, to: ["Wulf Beispiel"], cc: [], date: Date(timeIntervalSince1970: 1_794_000_000),
                     body: item.body, attachments: attachments)
    }



    @Test("F019 AC-5 · a title between title and name is never learned as a person: Dr. med. hollenbach")
    func titleNeverLearned() {
        for text in ["Termin bei Dr. med. Hollenbach.", "termin bei dr. med. hollenbach", "Rezept von Dr. med. dent. Wärtele."] {
            var pseudonymizer = Pseudonymizer(mode: .placeholder)
            pseudonymizer.learn(Detection.finder(runsTagger: false).entities(in: text, field: .body))
            let learned = pseudonymizer.entries.map { $0.original.lowercased() }
            for title in ["med", "med.", "dent", "dent.", "dr", "dr."] { #expect(!learned.contains(title), "\(text): \(title) learned — \(learned)") }
        }
    }




}
