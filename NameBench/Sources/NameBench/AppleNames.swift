import Foundation
import FoundationModels

/// Apple's on-device model, as `MatterBench`'s `AppleEngine` uses it: a session, guided output,
/// greedy, a text cut to the window. The instruction is the bench's own and lives here only.
public final class AppleNames: NameEngine, @unchecked Sendable {
    public var name: String { "Apple's on-device model (Foundation Models)" }
    /// The window is 4,096 tokens for instruction, text and answer: about 5,000 characters, as `AppleEngine` has it.
    static let window = 5_000

    static let instruction = """
    You find names in a text. List the names of people, the names of companies and organisations, \
    and the names of places that stand in the text, each exactly as it is written there. \
    A word that is not a name is not listed. The text may be German or English.
    """

    @Generable
    struct Names {
        @Guide(description: "Names of people, exactly as written in the text")
        var people: [String]
        @Guide(description: "Names of companies and organisations, exactly as written in the text")
        var companies: [String]
        @Guide(description: "Names of places and addresses, exactly as written in the text")
        var places: [String]
    }

    public init() {}

    public func unavailable() async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason): "\(reason)"
        }
    }

    public func load() async throws {
        let session = LanguageModelSession(instructions: Self.instruction)
        session.prewarm()
    }

    public func names(in text: String) async throws -> [Found] {
        var found: [Found] = []
        for piece in Self.pieces(of: text, upTo: Self.window) {
            let session = LanguageModelSession(instructions: Self.instruction)
            let answer = try await session.respond(to: "Text:\n" + piece, generating: Names.self,
                                                   options: GenerationOptions(samplingMode: .greedy)).content
            found += answer.people.map { Found(text: $0, kind: .person) }
            found += answer.companies.map { Found(text: $0, kind: .company) }
            found += answer.places.map { Found(text: $0, kind: .place) }
        }
        return found.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A longer text is read in pieces, cut where a line or a space ends, and the answers joined.
    static func pieces(of text: String, upTo limit: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let end = rest.index(rest.startIndex, offsetBy: limit)
            let cut = rest[..<end].lastIndex(where: { $0 == "\n" || $0 == " " }) ?? end
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...].drop(while: { $0 == "\n" || $0 == " " })
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }
}
