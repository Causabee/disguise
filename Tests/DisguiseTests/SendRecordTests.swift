import Foundation
import Testing
@testable import Disguise

private func found(_ kind: Entity.Kind, _ text: String) -> Entity {
    Entity(kind: kind, text: text, field: .body, start: 0, length: (text as NSString).length, source: .rule)
}

/// F027 AC-9 to AC-11, AC-13: the way back is the send's own record — each stand-in comes back as the words
/// it replaced in that send. Every name here is made up.
@Suite("F027 · The send's record")
struct SendRecordTests {
    /// The list knows Patrick Schüßler, written several ways, and P. Schüßler apart.
    static func list() -> Pseudonymizer {
        var p = Pseudonymizer(mode: .placeholder)
        p.learnAdmitted([found(.person, "Patrick Schüßler"), found(.organization, "Radwerk Berlin GmbH")])
        p.learnAdmitted(["Herrn Patrick Schüßler", "Patrick Schuessler", "Dr. Patrick Schüßler", "SCHÜSSLER Patrick", "Schüßler, Patrick",
                         "P. Schüßler"].map { found(.person, $0) })
        return p
    }

    /// One send: the owner's question, and the facts beside it, each disguised and noted.
    static func send(_ p: Pseudonymizer, question: String? = nil, facts: [String]) -> (texts: [String], record: SendRecord) {
        var record = SendRecord()
        var texts: [String] = []
        if let question { texts.append(p.disguiser.apply(question, noting: &record, in: "question", question: true).text) }
        for (n, fact) in facts.enumerated() { texts.append(p.disguiser.apply(fact, noting: &record, in: "fact \(n)").text) }
        return (texts, record.cut(to: texts.joined(separator: "\n")))
    }

    @Test("F027 AC-9 · a stand-in comes back as the words it replaced in this send")
    func wordsOfThisSend() throws {
        let p = Self.list()
        let a = try #require(p.standIn(for: "Patrick Schüßler"))
        // The owner asks by first name; the facts hold his full name: the question's words come back.
        let asked = Self.send(p, question: "Was muss Patrick bis Freitag schicken?", facts: ["Patrick Schüßler hat das Formular. Herrn Patrick Schüßler schreiben."])
        #expect(asked.texts[0] == "Was muss \(a) bis Freitag schicken?")
        #expect(asked.record.restore("\(a) sends the form by Friday") == "Patrick sends the form by Friday")
        #expect(asked.record.restore("Herrn \(a) schreiben") == "Herrn Patrick Schüßler schreiben")
        // Without a question, as sent: a spelling comes back as that spelling, the initial as the initial.
        #expect(Self.send(p, facts: ["Patrick Schuessler kommt."]).record.restore("\(a) kommt.") == "Patrick Schuessler kommt.")
        let initial = try #require(p.standIn(for: "P. Schüßler"))
        #expect(Self.send(p, facts: ["P. Schüßler unterschreibt."]).record.restore("\(initial) unterschreibt.") == "P. Schüßler unterschreibt.")
        // Several ways in one send, no question: the plainest of them, never a way this send did not hold.
        let many = Self.send(p, facts: ["Dr. Patrick Schüßler, SCHÜSSLER Patrick und Schüßler, Patrick"])
        #expect(many.record.restore("\(a) kommt") == "Patrick Schüßler kommt")
        #expect(Self.send(p, facts: ["Schüßler, Patrick"]).record.restore("\(a) kommt") == "Patrick Schüßler kommt", "comma order, in reading order")
        let alone = Self.send(p, facts: ["Patrick kommt."])
        #expect(alone.record.restore("\(a) kommt.") == "Patrick kommt.")
        // A stand-in this send did not carry keeps its brackets.
        #expect(alone.record.restore("\(a) und [Person Z]") == "Patrick und [Person Z]")
        #expect(alone.record.restore("[Company A] schreibt") == "[Company A] schreibt")
    }

    @Test("F027 AC-9 · first and last name parts come only from words this send held")
    func nameParts() throws {
        let p = Self.list()
        let a = try #require(p.standIn(for: "Patrick Schüßler")).dropLast()
        func greet(_ send: (texts: [String], record: SendRecord)) -> String { send.record.restore("Hi \(a)·first]! Ms \(a)·last].") }
        #expect(greet(Self.send(p, facts: ["Patrick Schuessler kommt."])) == "Hi Patrick! Ms Schuessler.")
        // Only his first name was sent: no surname is written in; the words it held come back.
        #expect(greet(Self.send(p, facts: ["Patrick kommt."])) == "Hi Patrick! Ms Patrick.")
        // The question's first name first; the surname from the first held way that has one.
        #expect(greet(Self.send(p, question: "Was will Patrick?", facts: ["Patrick Schüßler schreibt."])) == "Hi Patrick! Ms Schüßler.")
        #expect(Self.send(p, facts: ["Patrick kommt."]).record.restore("[Person Z·first]") == "[Person Z·first]")
    }

    @Test("F027 AC-9 · an ending and a surname after another first name come back as today")
    func endingAndSurname() throws {
        var p = Self.list()
        p.learnAdmitted([found(.person, "Ella Kloss")])
        let a = try #require(p.standIn(for: "Patrick Schüßler")), b = try #require(p.standIn(for: "Ella Kloss"))
        let lawyer = Self.send(p, facts: ["Schüßlers Anwalt meldet sich."])
        #expect(lawyer.texts[0] == "\(a)s Anwalt meldet sich.")
        #expect(lawyer.record.restore(lawyer.texts[0]) == "Schüßlers Anwalt meldet sich.")
        // „Herta Kloss“: her surname goes out as Ella's stand-in; Herta comes back Herta Kloss, Ella Ella Kloss.
        let mother = Self.send(p, facts: ["Herta Kloss und Ella Kloss kommen."])
        #expect(mother.texts[0] == "Herta \(b) und \(b) kommen.")
        #expect(mother.record.restore("Herta \(b) ruft an, \(b) auch.") == "Herta Kloss ruft an, Ella Kloss auch.")
    }

    @Test("F027 AC-10 · the record is cut to the exact text that leaves; a stand-in it does not hold keeps its brackets")
    func cutToWhatLeaves() throws {
        var p = Self.list()
        p.learnAdmitted([found(.person, "Lotta Kloss")])
        var record = SendRecord()
        let body = p.disguiser.apply("Patrick Schüßler und Lotta Kloss.", noting: &record, in: "body").text
        let subject = p.disguiser.apply("Radwerk Berlin GmbH", noting: &record, in: "subject").text
        #expect(record.notes.count == 3)
        // Only the body leaves.
        let cut = record.cut(to: body)
        #expect(cut.notes.count == 2 && cut.notes.allSatisfy { $0.source == "body" })
        #expect(cut.restore("\(subject) schreibt") == "\(subject) schreibt")
        #expect(cut.restore(body) == "Patrick Schüßler und Lotta Kloss.")
        // Each note says where it stands: which text, and from where to where.
        for note in record.notes {
            let text = note.source == "body" ? body : subject
            let range = Range(NSRange(location: note.range.lowerBound, length: note.range.count), in: text)
            #expect(range.map { String(text[$0]) } == note.standIn)
        }
    }

    @Test("F027 AC-10 · the record cannot be written: SendRecord is not Codable")
    func notCodable() throws {
        #expect(!(SendRecord.self is any Encodable.Type) && !(SendRecord.self is any Decodable.Type))
        #expect(!(SendRecord.Note.self is any Encodable.Type) && !(SendRecord.Note.self is any Decodable.Type))
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Disguise")
        let record = try String(contentsOf: sources.appendingPathComponent("SendRecord.swift"), encoding: .utf8)
        #expect(record.contains("public struct SendRecord: Sendable"))
        for file in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL }) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("SendRecord") && (line.contains("struct ") || line.contains("extension ")) {
                for word in ["Codable", "Encodable", "Decodable"] { #expect(!line.contains(word), "\(file.lastPathComponent): \(line)") }
            }
        }
    }

    @Test("F027 AC-11 · the sister, the cousin and the stranger")
    func sisterCousinStranger() throws {
        var p = Pseudonymizer(mode: .placeholder)
        p.learnAdmitted([found(.person, "Tamsin Harlander")])
        p.learnAdmitted([found(.person, "Tamsin Mittwoch"), found(.person, "Tamsin")])
        let cousin = try #require(p.standIn(for: "Tamsin Mittwoch")), stranger = try #require(p.standIn(for: "Tamsin Harlander"))
        #expect(cousin != stranger && p.entries.first { $0.original == "Tamsin Mittwoch" }?.formOf == nil)
        let send = Self.send(p, facts: ["Tamsin Mittwoch ist meine Cousine", "Tamsin ist meine Schwester", "Am Mittwoch, 3. Dezember"])
        #expect(!send.texts.joined().contains("Tamsin"))
        #expect(send.texts[0] == "\(cousin) ist meine Cousine")
        #expect(send.texts[2] == "Am Mittwoch, 3. Dezember")
        let sister = try #require(Pseudonymizer.tags(in: send.texts[1]).first)
        #expect(![cousin, stranger].contains(sister))
        let answer = send.record.restore("\(sister) und \(cousin) treffen sich am Mittwoch.")
        #expect(answer == "Tamsin und Tamsin Mittwoch treffen sich am Mittwoch.")
        #expect(!send.record.restore("\(stranger) \(sister) \(cousin)").contains("Harlander"))
    }

    @Test("F027 AC-13 · noting changes no byte: apply with notes gives what apply gives, over the golden cases")
    func notingChangesNoByte() throws {
        let golden = try JSONDecoder().decode([F024GoldenTests.Row].self,
                                              from: Data(contentsOf: F024GoldenTests.fixtures.appendingPathComponent("f024-golden.json")))
        var rows = 0
        for set in F024GoldenTests.sets {
            let text = try String(contentsOf: F024GoldenTests.fixtures.appendingPathComponent(set), encoding: .utf8)
            for (number, line) in text.split(separator: "\n").enumerated() {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let fields = object["fields"] as? [[String: Any]] else { continue }
                let id = "\(set)#\((object["id"] as? String) ?? String(number))"
                for (index, field) in fields.enumerated() {
                    guard let body = field["text"] as? String else { continue }
                    let kind = Entity.Field(rawValue: (field["field"] as? String) ?? "body") ?? .body
                    let entities = Detection.finder().entities(in: body, field: kind)
                    let row = golden.first { $0.id == "\(id).\(index)" }
                    for mode in Pseudonymizer.Mode.allCases {
                        var p = Pseudonymizer(mode: mode)
                        Detection.learn(entities, into: &p)
                        var record = SendRecord()
                        let plain = p.disguiser.apply(body), noted = p.disguiser.apply(body, noting: &record, in: kind.rawValue)
                        #expect(noted.text == plain.text && noted.count == plain.count, "\(id).\(index) \(mode)")
                        #expect(noted.text == (mode == .placeholder ? row?.placeholder : row?.standin), "\(id).\(index) \(mode) is not the golden bytes")
                    }
                    rows += 1
                }
            }
        }
        #expect(rows == golden.count && rows > 100)
        // And for a whole item, every field.
        let p = Self.list()
        let email = Email(source: URL(fileURLWithPath: "/dev/null"), id: "f027", headers: [:], subject: "Patrick Schüßler",
                          from: "Radwerk Berlin GmbH", to: ["Herrn Patrick Schüßler"], cc: [], date: nil,
                          body: "SCHÜSSLER Patrick schreibt.", attachments: [])
        var record = SendRecord()
        #expect(p.disguise(email, noting: &record) == p.disguise(email))
        #expect(Set(record.notes.map(\.source)) == ["subject", "from", "to", "body"])
    }
}
