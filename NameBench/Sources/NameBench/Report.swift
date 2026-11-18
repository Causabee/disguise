import Foundation

/// Runs one candidate over the sets and prints what the spec asks for: recall per tier (in
/// total, per language, per kind, per source), the ordinary words it took for names, time and
/// memory, under the device's header. It scores; it decides nothing (AC-2).
public enum Bench {
    public struct Tally: Sendable { public var found = 0; public var partly = 0; public var total = 0 }

    public struct SetScore: Sendable {
        public var title: String
        public var tiers: [String: Tally] = [:]
        public var hidden: [String] = []
        public var stays = 0
    }

    public struct Result: Sendable {
        public var text: String
        /// Nil when it ran; otherwise the reason, printed as "not available there: …".
        public var unavailable: String?
        public var sets: [SetScore] = []
        public var msPerThousand: Double = 0
        public var peakMB: Double = 0
    }

    struct Read { var found: [Found] = []; var errors: [String] = [] }

    public static func run(_ engine: any NameEngine, on sets: [CaseSet], detailed: Set<String> = [], run: String) async -> Result {
        var lines = [Machine.header("candidate: \(engine.name)", run: run)]
        if let why = await engine.unavailable() {
            lines.append("\(engine.name): not available there: \(why)")
            return Result(text: lines.joined(separator: "\n"), unavailable: why)
        }
        let sampler = Sampler()
        sampler.start()
        let loadStart = Date()
        do { try await engine.load() } catch {
            _ = sampler.stop()
            let why = "it did not load: \(error)"
            lines.append("\(engine.name): not available there: \(why)")
            return Result(text: lines.joined(separator: "\n"), unavailable: why)
        }
        let loadMs = Date().timeIntervalSince(loadStart) * 1000
        let afterLoad = Machine.memory().resident

        var reads: [[Read]] = []
        var first: Double?
        var times: [Double] = []
        var characters = 0
        for set in sets {
            var perCase: [Read] = []
            for item in set.cases {
                var read = Read()
                for field in item.fields {
                    let start = Date()
                    do { read.found += try await engine.names(in: field.text) } catch { read.errors.append("\(item.id) \(field.field): \(error)") }
                    let ms = Date().timeIntervalSince(start) * 1000
                    if first == nil { first = ms } else { times.append(ms); characters += field.text.count }
                }
                perCase.append(read)
            }
            reads.append(perCase)
        }
        let peak = sampler.stop()
        // A candidate whose every call failed did not run here: that is never a zero.
        let errors = reads.flatMap { $0.flatMap(\.errors) }
        if !errors.isEmpty, errors.count == times.count + (first == nil ? 0 : 1) {
            let why = "every text failed, the first with: \(errors[0])"
            lines.append("\(engine.name): not available there: \(why)")
            return Result(text: lines.joined(separator: "\n"), unavailable: why)
        }

        var result = Result(text: "", unavailable: nil)
        for (set, perCase) in zip(sets, reads) {
            let (score, text) = score(set, perCase, detailed: detailed.contains(set.title))
            result.sets.append(score)
            lines += text
        }
        let sorted = times.sorted()
        func at(_ share: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * share).rounded()))] }
        result.msPerThousand = characters == 0 ? 0 : times.reduce(0, +) / Double(characters) * 1000
        result.peakMB = Double(peak) / 1_048_576
        lines.append("")
        lines.append("time: load \(ms(loadMs)) · first call \(ms((first ?? 0) + loadMs)) with the load · then per text: median \(ms(at(0.5))) · 95th percentile \(ms(at(0.95))) · \(ms(result.msPerThousand)) per 1,000 characters (\(times.count) texts, \(characters) characters)")
        lines.append("memory, this process, by task_info: resident after load \(mb(afterLoad)) · highest during the run \(mb(peak))"
            + (engine is AppleNames ? " (Apple's model runs in the system's own process and is not counted here)" : ""))
        lines.append("errors: \(errors.isEmpty ? "none" : "\(errors.count): " + errors.joined(separator: "; "))")
        result.text = lines.joined(separator: "\n")
        return result
    }

    static func ms(_ value: Double) -> String { value >= 100 ? "\(Int(value.rounded())) ms" : String(format: "%.1f ms", value) }
    static func mb(_ bytes: UInt64) -> String { "\(Int((Double(bytes) / 1_048_576).rounded())) MB" }
    static func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "–" : String(format: "%.1f %%", Double(part) / Double(whole) * 100) }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// An item is found when every word of it stands in what the candidate returned for that
    /// case; partly when some do. A word that must stay is hidden when a returned span holds it
    /// and is more than the case's own names (a span made only of them hides no ordinary word).
    static func score(_ set: CaseSet, _ reads: [Read], detailed: Bool) -> (SetScore, [String]) {
        var score = SetScore(title: set.title)
        var lines = ["", "\(set.title): \(set.cases.count) cases, \(set.items) items"]
        var byLang: [String: [String: Tally]] = [:], byKind = byLang, bySource = byLang
        var missed: [String: [String]] = [:]
        var each: [String] = []
        for (item, read) in zip(set.cases, reads) {
            let returned = Set(read.found.flatMap { tokens($0.text) })
            var line: [String] = []
            for id in item.identifiers {
                let words = tokens(id.text)
                let have = words.filter(returned.contains).count
                let tier = id.tierOrKind
                func add(_ t: inout Tally) { t.total += 1; if have == words.count { t.found += 1 } else if have > 0 { t.partly += 1 } }
                add(&score.tiers[tier, default: Tally()])
                add(&byLang[tier, default: [:]][item.lang, default: Tally()])
                add(&byKind[tier, default: [:]][id.kind, default: Tally()])
                add(&bySource[tier, default: [:]][item.source, default: Tally()])
                let state = have == words.count ? "found" : have > 0 ? "partly" : "missed"
                if have < words.count { missed[tier, default: []].append("\(item.id) \(id.kind): \(id.text)\(have > 0 ? " (partly)" : "")") }
                line.append("\(id.text) \(state)")
            }
            let own = Set(item.identifiers.flatMap { tokens($0.text) })
            for word in item.stay {
                score.stays += 1
                let words = Set(tokens(word))
                guard !words.isEmpty else { continue }
                let by = read.found.first { span in
                    let spanWords = Set(tokens(span.text))
                    return words.isSubset(of: spanWords) && !spanWords.isSubset(of: own)
                }
                if let by {
                    score.hidden.append("\(item.id) \(word) (\(by.kind.rawValue) „\(by.text)“)")
                    line.append("\(word) hidden")
                } else {
                    line.append("\(word) stays")
                }
            }
            each.append("    \(item.id) \(item.source): " + line.joined(separator: " · "))
        }
        for tier in Tier.order {
            guard let t = score.tiers[tier] else { continue }
            lines.append("  \(Tier.title[tier]!): \(t.found) of \(t.total) (\(percent(t.found, t.total))) found\(t.partly > 0 ? ", \(t.partly) more in part" : "")")
            func row(_ name: String, _ table: [String: Tally]?) {
                guard let table else { return }
                lines.append("    by \(name): " + table.keys.sorted().map { "\($0) \(table[$0]!.found)/\(table[$0]!.total)" }.joined(separator: " · "))
            }
            row("language", byLang[tier]); row("kind", byKind[tier]); row("source", bySource[tier])
            if let gone = missed[tier], !gone.isEmpty { lines.append("    not found: " + gone.joined(separator: "; ")) }
        }
        lines.append("  ordinary words taken for names: \(score.hidden.count) of \(score.stays) (\(percent(score.hidden.count, score.stays))) of the words that must stay")
        lines += score.hidden.map { "    \($0)" }
        if detailed { lines.append("  each case:"); lines += each }
        return (score, lines)
    }
}
