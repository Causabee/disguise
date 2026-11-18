import Foundation
import SwiftData
import Testing
@testable import Disguise

/// F021 AC-18: the owner's real sources — what came in (mail, screenshots, photos, files and scans),
/// notes, the chat, and what was added by hand — measured by the rules, on the owner's Mac only.
/// The set is a copy outside the repository (`scripts/real-sources.sh`), named by
/// `CAUSABEE_REAL_SOURCES`, which only the owner sets. It prints counts and places only, never a
/// word of the text; no agent reads it. Without the set it says so and skips.
@Suite("F021 · The owner's real sources", .serialized)
@MainActor
struct RealSourcesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The tiers, as fixed labels.
    enum TierLabel: String, CaseIterable, Sendable { case A, B, C }

    /// What the report can say of a place: fixed labels only.
    enum What: String, Sendable { case found, miss, ordinary }


    /// The tier of what a rule found: a date of birth is C, a name A, the rest B.
    static func tier(_ entity: Entity) -> TierLabel {
        switch entity.kind {
        case .person, .organization: return .A
        case .reference where !NumberRuns.dates(in: entity.text).isEmpty: return .C
        default: return .B
        }
    }


    /// The test's one `print`.
    static func emit(_ lines: [String]) { print(lines.joined(separator: "\n")) }

    static let skipLine = "F021 AC-18 · no real sources set (CAUSABEE_REAL_SOURCES not set): skipped"





    // MARK: The source tests, which read the file above this line


    #if os(macOS)
    #endif

}
