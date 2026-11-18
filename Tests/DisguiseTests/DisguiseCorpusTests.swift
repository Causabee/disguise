import Foundation
import SwiftData
import Testing
@testable import Disguise

/// F019 AC-10: a corpus of made-up texts from every source — mail, screenshots, photos, files and
/// scans, notes, the chat, and tasks and dates added by hand — run through the real code of its
/// source, with a stand-in for the network that keeps exactly what would have left the device.
/// It prints how much of the names, addresses and numbers never left, per source and per kind,
/// and how many words that must stay were disguised.
@Suite("F019 · The disguise, measured on a corpus", .serialized)
@MainActor
struct DisguiseCorpusTests {
    /// Beside this file on the Mac; on an iPhone or iPad, where `#filePath` has no folder, the
    /// copy in the test bundle (F021 Build 2.2).
    static let fixtures: URL = {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        if FileManager.default.fileExists(atPath: here.path) { return here }
        return Bundle.module.url(forResource: "Fixtures", withExtension: nil) ?? here
    }()

    struct Case: Decodable {
        struct Field: Decodable { var field: String; var text: String }
        struct Identifier: Decodable { var text: String; var kind: String }
        var id: String
        var source: String
        var lang: String
        var fields: [Field]
        var identifiers: [Identifier]
        var stay: [String]
        var from: String

        func all(_ name: String) -> [String] { fields.filter { $0.field == name }.map(\.text) }
        func one(_ name: String) -> String? { all(name).first }
    }

    static func cases(_ file: String) throws -> [Case] {
        let text = try String(contentsOf: fixtures.appendingPathComponent(file), encoding: .utf8)
        return try text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
    }

    // MARK: Running a case through its source

    /// What left the device for one case: the user's part of every request, or nothing when the
    /// send was held.
    struct Run {
        var sent: [String]; var held: Bool
        /// The list after the case, to say why a word that must stay was disguised (F021 AC-7).
        var learned: [Pseudonymizer.Entry] = []
    }



    /// An item as the doors make it: a mail as it came, a photo, a scan or a file under its name, a
    /// note in the owner's own words.
    static func email(_ item: Case, owner: String?) -> Email {
        let body = item.one("body") ?? ""
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let file = item.one("file-name")
        let attachments = file.map { [Email.Attachment(filename: $0, contentType: "application/pdf", byteCount: 1000)] } ?? []
        let (subject, from): (String, String) = switch item.source {
        case "mail": (item.one("subject") ?? "", item.one("from") ?? "")
        case "screenshot-other": ("Screenshot: \(first.prefix(70))", "Screenshot")
        case "note": (String(first.prefix(80)), "Notiz")
        case "file-name": (file ?? "", "Dokument")
        default: (file.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? String(first.prefix(70)), "Dokument")
        }
        return Email(source: URL(fileURLWithPath: "/tmp/\(item.id)"), id: "item:\(item.id)", headers: ["subject": [subject]],
                     subject: subject, from: from, to: owner.map { [$0] } ?? [], cc: [], date: Date(timeIntervalSince1970: 1_794_000_000),
                     body: body, attachments: attachments)
    }



    // MARK: Counting

    /// Folded as the gate folds: case, accents, `ß`, the German `ae` for `ä`.
    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .applyingTransform(.stripDiacritics, reverse: false)!
            .replacingOccurrences(of: "ae", with: "a").replacingOccurrences(of: "oe", with: "o").replacingOccurrences(of: "ue", with: "u")
    }

    static func words(_ text: String) -> Set<String> {
        Set(fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static let titles: Set<String> = ["frau", "herr", "herrn", "dr", "med", "prof", "mr", "mrs", "ms", "von", "van", "der", "de", "uncle", "freiherr", "dipl", "ing"]

    /// Still in what was sent? A name by any of its words — `Jan` left of `Jan Kramer` is a leak; a
    /// number, an address, a mail address whole, with or without its spaces.
    static func survives(_ identifier: Case.Identifier, in sent: String) -> Bool {
        let shown = sent.replacing(/\[[^\[\]\n]{1,40}\]/, with: " ")
        if identifier.kind == "name" {
            let present = words(shown)
            let parts = fold(identifier.text).split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && !titles.contains($0) }
            return parts.contains { present.contains($0) }
        }
        let folded = fold(identifier.text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let text = fold(shown).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.contains(folded) { return true }
        let bare = folded.filter { $0.isLetter || $0.isNumber }
        return bare.count >= 6 && text.filter { $0.isLetter || $0.isNumber }.contains(bare)
    }

    struct Tally {
        var found = 0, all = 0
        var share: String { all == 0 ? "–" : String(format: "%.0f %%", 100 * Double(found) / Double(all)) }
        var ratio: Double { all == 0 ? 1 : Double(found) / Double(all) }
    }

    struct Measure {
        var bySource: [String: Tally] = [:]
        var byKind: [String: Tally] = [:]
        var total = Tally()
        var stayLost = Tally()
        var held = 0
        var leaks: [String] = []
        var lostWords: [String] = []
        var asWas: [String] = []
    }


    static func print(_ m: Measure, title: String) {
        var lines = ["", "F019 · \(title)", "recall, all: \(m.total.share) of \(m.total.all)  ·  held: \(m.held)  ·  over-disguised: \(m.stayLost.share) of \(m.stayLost.all) must-stay words", "by source:"]
        for (source, t) in m.bySource.sorted(by: { $0.key < $1.key }) { lines.append("  \(source.padding(toLength: 18, withPad: " ", startingAt: 0)) \(t.share)  (\(t.found)/\(t.all))") }
        lines.append("by kind:")
        for (kind, t) in m.byKind.sorted(by: { $0.key < $1.key }) { lines.append("  \(kind.padding(toLength: 18, withPad: " ", startingAt: 0)) \(t.share)  (\(t.found)/\(t.all))") }
        if !m.leaks.isEmpty { lines.append("left the device: " + m.leaks.joined(separator: "; ")) }
        if !m.lostWords.isEmpty { lines.append("must-stay words disguised: " + m.lostWords.joined(separator: "; ")) }
        Swift.print(lines.joined(separator: "\n"))
    }


    /// The share of must-stay words the disguise may take, set from the first run with every rule
    /// (16 November 2026: 9 of 169, 5.3 %). Moved only with a reason written in the commit.
    static let overDisguisingCeiling = 0.06
    /// The owner, 16 November 2026 ("a"): AC-10 is the measured number, and these are the known gaps
    /// of the manifesto (section 7, principle 11) — a name the dictionary knows, with no title or rule beside it.
    /// Only these may go out; a new one fails. Closing one means taking it off this list.
    static let knownGaps: Set<String> = ["Kessler", "Mats"]




    @Test("F019 AC-10 · the fixtures hold made-up text only")
    func madeUp() throws {
        for file in ["disguise-corpus.jsonl", "disguise-unseen.jsonl"] {
            let text = try String(contentsOf: Self.fixtures.appendingPathComponent(file), encoding: .utf8)
            for match in text.matches(of: /[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)/) {
                let domain = String(match.output.1).lowercased()
                // The reserved names, and the names under them (RFC 2606): no one can own them.
                let reserved = ["example.org", "example.com", "example.net"].contains { domain == $0 || domain.hasSuffix("." + $0) }
                #expect(reserved, "\(file): a real-looking address \(match.output.0)")
            }
            // Every IBAN fails its own check: none can belong to anyone.
            for match in text.matches(of: /\b([A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30})\b/) {
                let bare = String(match.output.1).filter { $0 != " " }
                let moved = bare.dropFirst(4) + bare.prefix(4)
                var rest = 0
                for character in moved {
                    let value = character.isNumber ? Int(String(character))! : Int(character.asciiValue! - 55)
                    for digit in String(value) { rest = (rest * 10 + Int(String(digit))!) % 97 }
                }
                #expect(rest != 1, "\(file): \(bare) passes its check")
            }
        }
    }
}

/// The network, as the corpus sees it: every request kept, by the relay a test was given, and an
/// empty answer for its job. One relay a test, so tests that run side by side never see each other's.
final class CorpusStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var byHost: [String: [URLRequest]] = [:]
    private static let lock = NSLock()
    private static let registered: Bool = { URLProtocol.registerClass(CorpusStub.self); return true }()

    /// A relay of its own, for one test.
    static func relay() -> URL {
        _ = registered
        return URL(string: "https://\(UUID().uuidString.lowercased()).corpus.test")!
    }

    static func seen(_ relay: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return byHost[relay.host ?? ""] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".corpus.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.byHost[request.url?.host ?? "", default: []].append(request)
        Self.lock.unlock()
        let job = request.value(forHTTPHeaderField: "causabee-job") ?? ""
        let text = job == "read"
            ? #"{"matter":null,"matter_is_new":false,"matter_confidence":0,"matter_reason":"x","parties":[],"todos":[],"deadlines":[]}"#
            : #"{"lines":[],"cards":[],"not_in_facts":null}"#
        let answer: [String: Any] = [
            "model": "gpt-6.1-sol", "status": "completed",
            "output": [["type": "message", "content": [["type": "output_text", "text": text]]]],
            "usage": ["input_tokens": 100, "output_tokens": 10],
        ]
        let data = try! JSONSerialization.data(withJSONObject: answer)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
