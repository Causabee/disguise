import Foundation

/// What a candidate returns: a span of the text it takes for a name, a company, a place or a date.
public struct Found: Sendable, Hashable {
    public enum Kind: String, Sendable { case person, company, place, date }
    public var text: String
    public var kind: Kind
    public init(text: String, kind: Kind) { self.text = text; self.kind = kind }
}

/// A candidate for a second name finder. Swapping it costs one file.
public protocol NameEngine: Sendable {
    var name: String { get }
    /// Nil when it can run here; otherwise why not, printed as "not available there: <why>".
    func unavailable() async -> String?
    /// Loads what it needs, once, before the first text.
    func load() async throws
    func names(in text: String) async throws -> [Found]
}
