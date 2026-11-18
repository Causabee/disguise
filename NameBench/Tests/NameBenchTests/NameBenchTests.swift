import CryptoKit
import Foundation
import NameBench
import Testing

/// F021 AC-1 · The bench: Apple's on-device model and one small multilingual name model, on the
/// corpus, the unseen set, the tier set and the owner's named cases, from every source — what
/// comes in (mail, screenshots, photos, files and scans), notes, the chat, and tasks and dates
/// added by hand. It prints a table per candidate and device; it decides nothing (AC-2).
@Suite("F021 · The name bench", .serialized)
struct NameBenchTests {
    /// The copies in the test bundle, the same on the Mac and on a device.
    static let resources = Bundle.module.url(forResource: "Cases", withExtension: nil)!
    /// The package's folder and the repository's, reachable on the Mac only.
    static let bench = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let originals = bench.deletingLastPathComponent().appendingPathComponent("Tests/DisguiseTests/Fixtures")
    static var onMac: Bool { FileManager.default.fileExists(atPath: originals.path) }

    /// The SHA-256 of each case file, as committed on the Mac; a copy that differs is not the same cases.
    /// F024 AC-2: re-pinned when every personal detail in the cases was made up.
    static let pins = [
        "disguise-corpus.jsonl": "8c81b9e652687051eecc5160f7d4ad1deddf9d236948590814fd1af876777333",
        "disguise-unseen.jsonl": "fcd00eefdf0f9f6404cea40ab48f0c84c5b2fece436d995b3e8d47735023f687",
        "detection-tiers.jsonl": "7f1c83efe108ef1bf64b1fe4c3c72c58be8893fec5ccd29c898f326872d9f978",
        "bench-names.jsonl": "471f5760b68eef1afc1da0ac0b6e3f0d03593d8bcb5d7e3f38e672887adfa502",
    ]

    static func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func engine(_ name: String) -> any NameEngine {
        name == "apple" ? AppleNames() : CoreMLNames(folder: resources.appendingPathComponent("Model"))
    }

    @Test("F021 AC-1 · both candidates on the corpus, the unseen set and the bench's names, per device", arguments: ["apple", "coreml"])
    func both(candidate: String) async throws {
        let sets = try Sets.all(in: Self.resources)
        #expect(sets.map(\.cases.count) == [87, 30, 80, 22])
        #expect(sets.map(\.items) == [198, 122, 211, sets[3].items])
        let result = await Bench.run(Self.engine(candidate), on: sets, detailed: [Sets.named], run: "tests")
        print("\n" + result.text + "\n")
        if let why = result.unavailable {
            #expect(!why.isEmpty && result.text.contains("not available there: \(why)"))
            return
        }
        #expect(result.sets.map(\.title) == Sets.files.map(\.1))
        for (set, score) in zip(sets, result.sets) {
            #expect(score.tiers.values.reduce(0) { $0 + $1.total } == set.items, "every item of \(set.title) is counted")
            #expect(score.stays == set.cases.reduce(0) { $0 + $1.stay.count })
        }
        #expect(result.text.contains("per 1,000 characters") && result.text.contains("highest during the run"))
    }

    @Test("F021 AC-1 · not available there, never zero")
    func notAvailable() async throws {
        let sets = try Sets.all(in: Self.resources)
        let missing = CoreMLNames(folder: FileManager.default.temporaryDirectory.appendingPathComponent("no-model-\(UUID().uuidString)"))
        let result = await Bench.run(missing, on: sets, run: "tests")
        #expect(result.unavailable?.contains("the Core ML file is missing") == true)
        #expect(result.text.contains("not available there: the Core ML file is missing"))
        #expect(result.sets.isEmpty)
        #expect(!result.text.contains(" found") && !result.text.contains("0 of"), "no count is printed for a candidate that cannot run")
    }

    struct Failing: NameEngine {
        var name: String { "a candidate that fails every text" }
        func unavailable() async -> String? { nil }
        func load() async throws {}
        func names(in text: String) async throws -> [Found] { throw CocoaError(.featureUnsupported) }
    }

    @Test("F021 AC-1 · not available there, never zero: a candidate that fails every text")
    func everyTextFails() async throws {
        let result = await Bench.run(Failing(), on: try Sets.all(in: Self.resources), run: "tests")
        #expect(result.unavailable?.hasPrefix("every text failed") == true)
        #expect(result.text.contains("not available there: every text failed") && !result.text.contains("0 of"))
    }

    @Test("F021 AC-1 · the bench's fixtures equal the Mac's by hash")
    func sameCases() throws {
        for (file, pin) in Self.pins {
            #expect(try Self.sha(Self.resources.appendingPathComponent(file)) == pin, "the copy of \(file): run NameBench/copy.sh")
            if Self.onMac {
                #expect(try Self.sha(Self.originals.appendingPathComponent(file)) == pin, "the original \(file)")
            }
        }
    }

    @Test("F021 AC-1 · sends nothing: no URLSession, no Claude, no key, no Prompts", .enabled(if: NameBenchTests.onMac))
    func sendsNothing() throws {
        // Spelled in pieces, so this file can be read too.
        let needles = ["URL" + "Session", "Clau" + "de", "Prom" + "pts", "api" + "Key", "API" + "_KEY", "OPEN" + "AI",
                       "Sec" + "Item", "Key" + "chain", "pre" + "trained:", "hugging" + "face.co", "http" + "://"]
        var read = 0
        let walker = FileManager.default.enumerator(at: Self.bench, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            let path = url.path.dropFirst(Self.bench.path.count + 1)
            if path.hasPrefix(".build") || path.hasPrefix(".swiftpm") || path.hasPrefix("Model") || path.hasPrefix("Tests/NameBenchTests/Cases") {
                walker?.skipDescendants(); continue
            }
            guard ["swift", "py", "sh"].contains(url.pathExtension) else { continue }
            // A test's own title names what it looks for; it is not code.
            let text = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("@Test(") }.joined(separator: "\n")
            read += 1
            for needle in needles { #expect(!text.contains(needle), "\(path) holds \(needle)") }
        }
        #expect(read >= 8, "NameBench's files were read")
    }
}
