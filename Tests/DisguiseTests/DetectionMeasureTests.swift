import Foundation
import NaturalLanguage
import Testing
@testable import Disguise

/// F021 AC-4: one measure, per tier in the owner's order — A names, B places and numbers, C dates
/// of birth — on the corpus, the unseen set, the tier set and the owner-like list. Each case goes
/// through the real code of its source (`DisguiseCorpusTests.run`): what comes in (mail,
/// screenshots, photos, files and scans), notes, the chat, and tasks and dates added by hand.
@Suite("F021 · The measure, per tier", .serialized)
@MainActor
struct DetectionMeasureTests {
    // MARK: The header

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static var model: String {
        let env = ProcessInfo.processInfo.environment
        if let simulated = env["SIMULATOR_MODEL_IDENTIFIER"] { return "\(env["SIMULATOR_DEVICE_NAME"] ?? "simulator") (\(simulated))" }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }


    // MARK: The tier set, in the runner's shape

    /// A case of the tier set as the runner takes it, and the texts no door of the app carries
    /// (a date's own day and time, a question beside a note): their items are not measured here.
    struct Adapted {
        var item: DisguiseCorpusTests.Case
        var tiers: [Tier]
        var kinds: [String]
        var notFed: [String]
    }

    /// The tier set writes `name` for a file's name, `text` for what is read off a picture or a
    /// scan, and a `title` beside it; a date added by hand has `title`, `place`, `notes`, `date`.
    static func adapt(_ t: DetectionTierSetTests.Case) -> Adapted {
        typealias Field = DisguiseCorpusTests.Case.Field
        var fields: [Field] = [], notFed: [String] = []
        let texts = { (name: String) in t.fields.filter { $0.field == name }.map(\.text) }
        switch t.source {
        case "file-name":
            fields = texts("name").map { Field(field: "file-name", text: $0) }
            notFed = t.fields.filter { $0.field != "name" }.map(\.text)
        case "photo", "scan", "screenshot-other", "note":
            // The title first, as the door takes a first line for the heading.
            let body = (texts("title") + texts("text") + texts("body")).joined(separator: "\n")
            fields = [Field(field: "body", text: body)]
            notFed = t.fields.filter { !["title", "text", "body"].contains($0.field) }.map(\.text)
        case "date-by-hand":
            fields = texts("title").map { Field(field: "what", text: $0) } + texts("place").map { Field(field: "place", text: $0) }
                + texts("notes").map { Field(field: "note", text: $0) }
            notFed = t.fields.filter { !["title", "place", "notes"].contains($0.field) }.map(\.text)
        default:
            fields = t.fields.map { Field(field: $0.field, text: $0.text) }
        }
        let identifiers = t.identifiers.map { DisguiseCorpusTests.Case.Identifier(text: $0.text, kind: $0.tier == "A" ? "name" : $0.kind) }
        let item = DisguiseCorpusTests.Case(id: t.id, source: t.source, lang: t.lang, fields: fields, identifiers: identifiers, stay: t.stay, from: t.from)
        return Adapted(item: item, tiers: t.identifiers.map { Tier(rawValue: $0.tier)! }, kinds: t.identifiers.map(\.kind), notFed: notFed)
    }

    static func corpusCases(_ file: String) throws -> [Adapted] {
        try DisguiseCorpusTests.cases(file).map { item in
            Adapted(item: item, tiers: item.identifiers.map { Tier.of($0.kind)! }, kinds: item.identifiers.map(\.kind), notFed: [])
        }
    }

    // MARK: Measuring

    struct Count {
        var kept = 0, all = 0
        var text: String { all == 0 ? "–" : "\(kept) of \(all) (\(String(format: "%.1f", 100 * Double(kept) / Double(all))) %)" }
    }

    struct Result {
        var title: String
        var cases = 0
        var tier: [Tier: Count] = [:]
        var bySource: [Tier: [String: Count]] = [:]
        var byKind: [Tier: [String: Count]] = [:]
        var leaks: [Tier: [String]] = [:]
        var stay = Count()
        /// Each word that must stay and was disguised, with why.
        var hidden: [String] = []
        var notMeasured: [String] = []
        var held = 0
        var items: Int { tier.values.map(\.all).reduce(0, +) }
    }

    /// Why a word that must stay was disguised: the list entry that holds it.
    static func why(_ word: String, in learned: [Pseudonymizer.Entry]) -> String {
        let folded = DisguiseCorpusTests.fold(word)
        if let entry = learned.first(where: { DisguiseCorpusTests.fold($0.original) == folded }) {
            return "learned as \(entry.kind.rawValue) „\(entry.original)“\(entry.partOf.map { ", part of „\($0)“" } ?? "")"
        }
        if let entry = learned.first(where: { DisguiseCorpusTests.words($0.original).contains(folded) }) {
            return "inside \(entry.kind.rawValue) „\(entry.original)“"
        }
        return "no entry holds it alone: taken inside a longer match"
    }


    static let names: [Tier: String] = [.A: "names", .B: "places and numbers", .C: "dates of birth"]

    static func lines(_ r: Result) -> [String] {
        var lines = ["", "\(r.title): \(r.cases) cases, \(r.items) items\(r.held > 0 ? ", \(r.held) held" : "")"]
        for tier in Tier.allCases {
            lines.append("  \(tier.rawValue) \(names[tier]!): \(r.tier[tier]?.text ?? "–") never left")
            let sources = (r.bySource[tier] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.kept)/\($0.value.all)" }
            if !sources.isEmpty { lines.append("    by source: " + sources.joined(separator: " · ")) }
            if tier == .B {
                let kinds = (r.byKind[tier] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.kept)/\($0.value.all)" }
                lines.append("    by kind: " + kinds.joined(separator: " · "))
            }
            if let leaks = r.leaks[tier], !leaks.isEmpty { lines.append("    left: " + leaks.joined(separator: "; ")) }
        }
        lines.append("  ordinary words hidden: \(r.stay.text) of the words that must stay")
        for word in r.hidden { lines.append("    \(word)") }
        if !r.notMeasured.isEmpty { lines.append("  not measured (no door carries that text): " + r.notMeasured.joined(separator: "; ")) }
        return lines
    }

    // MARK: The owner-like list (F020 AC-7's measure)

    struct ListResult { var label: String; var gone: Int; var of: Int; var held: Int; var words: [String] }


    // MARK: Both rule sets



    /// One line per set and tier: old beside new.
    static func beside(_ old: [Result], _ new: [Result]) -> [String] {
        var out = ["", "old beside new, items that never left:"]
        for (o, n) in zip(old, new) {
            let tiers = Tier.allCases.map { "\($0.rawValue) \(o.tier[$0]?.text ?? "–") → \(n.tier[$0]?.text ?? "–")" }
            out.append("  \(o.title): " + tiers.joined(separator: " · ") + " · ordinary words hidden \(o.stay.text) → \(n.stay.text)")
        }
        return out
    }


    // MARK: The old rules' numbers, frozen

    /// The old rules went after the switch (AC-9); their numbers are the record kept in the test
    /// report, "The old rules, before any new rule" (Mac, Build 2.5) and the owner's devices'
    /// run of 17 November (iPhone 15 Pro, iPad Air): items that never left, per tier, and B per kind.
    static func baseline() -> [Result] {
        func result(_ title: String, _ a: (Int, Int), _ b: (Int, Int), _ c: (Int, Int), _ kinds: [String: (Int, Int)]) -> Result {
            var r = Result(title: title)
            r.tier = [.A: Count(kept: a.0, all: a.1), .B: Count(kept: b.0, all: b.1), .C: Count(kept: c.0, all: c.1)]
            r.byKind[.B] = kinds.mapValues { Count(kept: $0.0, all: $0.1) }
            return r
        }
        #if os(macOS)
        let a = (125, 59, 76)
        #else
        let a = (122, 58, 76)
        #endif
        return [
            result("the corpus", (a.0, 127), (66, 66), (5, 5),
                   ["address": (27, 27), "email": (8, 8), "iban": (2, 2), "id-number": (19, 19), "phone": (7, 7), "plate": (3, 3)]),
            result("the unseen set", (a.1, 61), (55, 58), (3, 3),
                   ["address": (28, 29), "email": (6, 6), "iban": (2, 3), "id-number": (6, 7), "phone": (11, 11), "plate": (2, 2)]),
            result("the tier set", (a.2, 91), (68, 80), (35, 40),
                   ["address": (19, 21), "email": (12, 12), "iban": (9, 10), "id-number": (4, 6), "insurance-number": (9, 11), "phone": (12, 12), "plate": (3, 8)]),
        ]
    }

    /// The names the old rules left on the owner's devices besides the Mac's gaps (the device run).
    static let deviceGaps: [String: Set<String>] = ["the corpus": ["tobias", "paulina", "irmtraud"], "the unseen set": ["sina"]]

    // MARK: AC-5, AC-6, AC-7 · tier by tier, A first

    static var both: (old: [Result], new: [Result])?


    /// The first tier, in the owner's order, where the new rules fall below the old on a set; nil
    /// when none does. B is judged per kind. Never the sum.
    static func firstFailure(old: [Result], new: [Result]) -> String? {
        for tier in Tier.allCases {
            for (o, n) in zip(old, new) {
                if tier == .B {
                    for (kind, count) in o.byKind[.B] ?? [:] where (n.byKind[.B]?[kind]?.kept ?? 0) < count.kept {
                        return "B \(kind) on \(o.title): \(n.byKind[.B]?[kind]?.kept ?? 0) < \(count.kept)"
                    }
                } else if (n.tier[tier]?.kept ?? 0) < (o.tier[tier]?.kept ?? 0) {
                    return "\(tier.rawValue) on \(o.title): \(n.tier[tier]?.kept ?? 0) < \(o.tier[tier]?.kept ?? 0)"
                }
            }
        }
        return nil
    }

    /// The known gaps (the manifesto's section 7): only these may leave, and the set only shrinks.
    static let knownGaps: [String: Set<String>] = [
        "the corpus": ["Keppler", "Mats"],
        "the unseen set": ["QQ 12 34 56 C", "GB30 NWBK 6016 1331 9268 19", "Kanzlei Eisenhut & Partner", "8400 Winterthur", "Lechner"],
    ]






    @Test("F021 AC-6 · a rule that raises C and lowers A fails")
    func raisesCLowersA() {
        var old = Result(title: "the corpus"), new = Result(title: "the corpus")
        old.tier = [.A: Count(kept: 10, all: 10), .B: Count(kept: 5, all: 5), .C: Count(kept: 1, all: 5)]
        new.tier = [.A: Count(kept: 9, all: 10), .B: Count(kept: 5, all: 5), .C: Count(kept: 5, all: 5)]
        #expect(Self.firstFailure(old: [old], new: [new])?.hasPrefix("A ") == true)
    }




    // MARK: AC-4

}
