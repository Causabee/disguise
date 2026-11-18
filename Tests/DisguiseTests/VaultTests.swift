import Foundation
import SwiftData
import Testing
@testable import Disguise

@Suite("The matter's vault: contacts and details put in by hand")
@MainActor
struct VaultTests {




}

@Suite("What a photographed letter offers the vault")
@MainActor
struct VaultOffersTests {
    static let letter = """
        hkk Krankenkasse
        Kormoranstraße 26, 28195 Bremen
        Telefon 0421 7777 0
        Fax 0421 7777 3700
        reha@hkk.de

        Versichertennummer: A123456789
        Unser Zeichen: RH 4711/26

        Sehr geehrte Frau Muster,
        bitte senden Sie uns den Befundbericht bis zum 20.10.2026.
        """





    @Test("A date of birth is disguised by the word before it; a deadline's date is not")
    func birth() {
        let found = Detection.finder().entities(in: "Geburtsdatum Elfi Mustermann, 28.06.1950. Bitte bis 20.10.2026 antworten.", field: .body)
        #expect(found.contains { $0.kind == .reference && $0.text == "28.06.1950" })
        #expect(!found.contains { $0.text.contains("20.10.2026") })
    }
}
