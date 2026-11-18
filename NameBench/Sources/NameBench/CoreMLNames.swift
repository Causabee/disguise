import CoreML
import Foundation
import Tokenizers

/// The small multilingual name model, `Davlan/distilbert-base-multilingual-cased-ner-hrl`
/// (AFL-3.0), converted to Core ML once by hand (`convert.py`), read from a folder that holds
/// `NameNER.mlmodelc`, `config.json` and the tokenizer's files. Nothing is downloaded here.
public final class CoreMLNames: NameEngine, @unchecked Sendable {
    public var name: String { "Core ML: distilbert-base-multilingual-cased-ner-hrl" }
    /// Tokens per window, as converted; [CLS] and [SEP] take two.
    static let length = 256

    let folder: URL
    var model: MLModel?
    var tokenizer: (any Tokenizer)?
    var labels: [Int: String] = [:]
    var cls = 101, sep = 102, pad = 0

    public init(folder: URL) { self.folder = folder }

    var compiled: URL { folder.appendingPathComponent("NameNER.mlmodelc") }

    public func unavailable() async -> String? {
        for file in [compiled.lastPathComponent, "config.json", "tokenizer.json", "tokenizer_config.json"]
        where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
            return "the Core ML file is missing: \(file) in \(folder.lastPathComponent)/"
        }
        return nil
    }

    public func load() async throws {
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("config.json"))) as? [String: Any]
        let names = config?["id2label"] as? [String: String] ?? [:]
        labels = Dictionary(uniqueKeysWithValues: names.compactMap { key, value in Int(key).map { ($0, value) } })
        cls = tokenizer.convertTokenToId("[CLS]") ?? cls
        sep = tokenizer.convertTokenToId("[SEP]") ?? sep
        pad = tokenizer.convertTokenToId("[PAD]") ?? pad
        self.tokenizer = tokenizer
    }

    struct Word { var range: Range<String.Index>; var ids: [Int]; var label = "O" }

    public func names(in text: String) async throws -> [Found] {
        guard let tokenizer, let model else { throw CocoaError(.featureUnsupported) }
        var words = Self.words(in: text).compactMap { range -> Word? in
            let ids = tokenizer.encode(text: String(text[range]), addSpecialTokens: false)
            return ids.isEmpty ? nil : Word(range: range, ids: Array(ids.prefix(Self.length - 2)))
        }
        // Windows of whole words, read one after another.
        var start = 0
        while start < words.count {
            var end = start, count = 0
            while end < words.count, count + words[end].ids.count <= Self.length - 2 { count += words[end].ids.count; end += 1 }
            let tags = try tag(Array(words[start..<end]), model: model)
            for (offset, tag) in tags.enumerated() { words[start + offset].label = tag }
            start = end
        }
        return Self.entities(words, in: text)
    }

    /// Each word's label is its first piece's.
    func tag(_ window: [Word], model: MLModel) throws -> [String] {
        let ids = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: Self.length)], dataType: .int32)
        var tokens = [cls], firsts: [Int] = []
        for word in window { firsts.append(tokens.count); tokens += word.ids }
        tokens.append(sep)
        for i in 0..<Self.length {
            ids[i] = NSNumber(value: i < tokens.count ? tokens[i] : pad)
            mask[i] = NSNumber(value: i < tokens.count ? 1 : 0)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        guard let logits = try model.prediction(from: input).featureValue(for: "logits")?.multiArrayValue else { return window.map { _ in "O" } }
        let classes = logits.shape[2].intValue
        return firsts.map { position in
            var best = 0, value = -Float.infinity
            for c in 0..<classes {
                let v = logits[[0, NSNumber(value: position), NSNumber(value: c)]].floatValue
                if v > value { value = v; best = c }
            }
            return labels[best] ?? "O"
        }
    }

    /// BERT's own first cut: spaces part words, and each punctuation mark is a word of its own.
    static func words(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i], next = text.index(after: i)
            if c.isWhitespace {
                if let s = start { ranges.append(s..<i); start = nil }
            } else if c.isPunctuation || (c.isASCII && c.isSymbol) {
                if let s = start { ranges.append(s..<i); start = nil }
                ranges.append(i..<next)
            } else if start == nil {
                start = i
            }
            i = next
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }

    /// B- opens a span, I- of the same kind goes on, anything else closes it.
    static func entities(_ words: [Word], in text: String) -> [Found] {
        var found: [Found] = []
        var open: (kind: String, range: Range<String.Index>)?
        func close() {
            if let o = open, let kind = kind(o.kind) { found.append(Found(text: String(text[o.range]), kind: kind)) }
            open = nil
        }
        for word in words {
            let tag = word.label
            guard tag != "O", tag.count > 2 else { close(); continue }
            let kind = String(tag.dropFirst(2))
            if tag.hasPrefix("I-"), let o = open, o.kind == kind {
                open = (kind, o.range.lowerBound..<word.range.upperBound)
            } else {
                close()
                open = (kind, word.range)
            }
        }
        close()
        return found
    }

    static func kind(_ tag: String) -> Found.Kind? {
        switch tag {
        case "PER": .person
        case "ORG": .company
        case "LOC": .place
        case "DATE": .date
        default: nil
        }
    }
}
