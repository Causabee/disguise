import Foundation
import NaturalLanguage
import SwiftData
import Testing
@testable import Disguise

/// F019 AC-9: before every send — the reading of what comes in (mail, screenshots, photos, files and
/// scans, notes), a digest, the chat, a brief, a summary, a next step — a check on the device runs
/// over the exact text. A known original still in it stops the send. And F019 AC-1: OpenAI is asked
/// to keep nothing of a request.
@Suite("F019 · The check before every send", .serialized)
@MainActor
struct SendGateTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()


    static func sources() throws -> [(name: String, text: String)] {
        let folder = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
    }

    // MARK: AC-9








    @Test("F019 AC-9 · only SendGate makes a Disguised")
    func onlyTheGateMakesTheProof() throws {
        var makers: [String] = []
        for (name, text) in try Self.sources() where !name.hasSuffix("/SendGate.swift") {
            if text.contains("Disguised(") { makers.append(name) }
        }
        #expect(makers.isEmpty, "\(makers)")
    }





    // MARK: AC-1


}

/// A dictionary that knows every word: the check alone, without the second pass.
struct KnowsAll: WordKnowledge {
    func knows(_ word: String) -> Bool? { true }
}

/// F021: a finder that misses everything, for a test of what the check does when the rules missed a name.
struct FindsNothing: NameFinding {
    var language: NLLanguage?
    var runsTagger = false
    var typed = false
    func entities(in email: Email) -> [Entity] { [] }
    func entities(in text: String, field: Entity.Field) -> [Entity] { [] }
}
