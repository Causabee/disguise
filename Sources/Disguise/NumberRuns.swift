import Foundation

/// F019, found at Proof (17 November): the list's phones, IBANs and references, found in a text as
/// the whole numbers they are, however they are split — `0171-1234567`, `(0171) 123 45 67`,
/// `DE89 37040044 0532013000`, `Police4471-22-918.pdf` — and never out of words run together or out
/// of a date. TestFlight 262 joined every word of a text and looked for the number anywhere in it:
/// `20261113`, a date read as a code out of a file's name, was "still in" every `2026-11-13`.
///
/// A run is digits and letters joined only by one space, dash, slash or dot (a bracket around a
/// group allowed): `0171) 123`. A word in it has a digit, or is a short code in capitals — `DE`,
/// `VN`, `J`. A run, or a part of it between spaces, matches when its bare form *equals* the
/// entry's: never a part of one, never across words.
///
/// The disguise and the check use this one matcher (`Replacer.found`).
public struct NumberRuns: Sendable {
    private var bare: [String: String] = [:]
    private var longest = 0

    public init(_ entries: [Pseudonymizer.Entry]) {
        for entry in entries where [.reference, .iban, .phone].contains(entry.kind) {
            let form = Self.bare(entry.original)
            // A written date — a date of birth, as its label's rule learned it — is matched as it is
            // written, by the table; a date is never a number out of a run.
            guard form.count >= 4, form.contains(where: \.isNumber), !Self.isDate(entry.original), !Self.isCompactDate(form) else { continue }
            if bare[form] == nil { bare[form] = entry.standIn }
            longest = max(longest, form.count)
        }
    }

    var isEmpty: Bool { bare.isEmpty }

    static func bare(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: The runs of a text

    struct Word { var range: Range<String.Index>; var text: Substring; var joined: Bool; var space: Bool }

    private static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    /// The runs of a text: each a list of words, each word after the first joined to the one before it.
    static func runs(in text: String) -> [[Word]] {
        var runs: [[Word]] = []
        var current: [Word] = []
        var previous: Range<String.Index>?
        for match in word.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let written = text[range]
            let counts = written.contains(where: \.isNumber) || (written.count <= 4 && written.allSatisfy { $0.isUppercase })
            guard counts else {
                if !current.isEmpty { runs.append(current); current = [] }
                previous = nil
                continue
            }
            var joined = false, space = false
            if let previous, !current.isEmpty {
                let gap = text[previous.upperBound..<range.lowerBound]
                let core = gap.filter { $0 != "(" && $0 != ")" }
                joined = (core.count == 1 && " -/.".contains(core)) || (core.isEmpty && gap.count == 1)
                space = core == " "
            }
            if !joined, !current.isEmpty { runs.append(current); current = [] }
            current.append(Word(range: range, text: written, joined: joined, space: space))
            previous = range
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The groups of a run, between its spaces: `2026-11-13`, `14`.
    static func groups(of run: [Word]) -> [[Word]] {
        var groups: [[Word]] = []
        for word in run {
            if word.space || groups.isEmpty { groups.append([word]) } else { groups[groups.count - 1].append(word) }
        }
        return groups
    }

    /// Where the text has a date: a group in a date's shape. Nothing in one is a number to hide.
    static func dates(in text: String) -> [Range<String.Index>] {
        runs(in: text).flatMap(groups).compactMap { group in
            let range = group.first!.range.lowerBound..<group.last!.range.upperBound
            return isDate(String(text[range])) ? range : nil
        }
    }

    /// The list's numbers in a text, longest first, none overlapping, none in a date.
    public func found(in text: String) -> [(range: Range<String.Index>, with: String)] {
        var out: [(range: Range<String.Index>, with: String)] = []
        for run in Self.runs(in: text) {
            let groups = Self.groups(of: run)
            var candidates: [(range: Range<String.Index>, with: String, length: Int)] = []
            for i in groups.indices {
                var form = ""
                for j in i..<groups.count {
                    form += groups[j].map { Self.bare(String($0.text)) }.joined()
                    guard form.count <= longest + 8 else { break }
                    let start = groups[i].first!, end = groups[j].last!.range.upperBound
                    let range = start.range.lowerBound..<end
                    if Self.isDate(String(text[range])) { continue }
                    if let standIn = bare[form] { candidates.append((range, standIn, form.count)) }
                    // A number glued to the word before it, in a file's name: `Police4471-22-918`. Six
                    // characters at least: `Juli2026` is a month and a year.
                    if form.count >= 6, let digit = start.text.firstIndex(where: \.isNumber), digit != start.text.startIndex,
                       start.text[..<digit].allSatisfy(\.isLetter) {
                        let rest = form.dropFirst(start.text.distance(from: start.text.startIndex, to: digit))
                        if rest.count >= 6, let standIn = bare[String(rest)] { candidates.append((digit..<end, standIn, rest.count)) }
                    }
                }
            }
            for candidate in candidates.sorted(by: { $0.length > $1.length }) where !out.contains(where: { $0.range.overlaps(candidate.range) }) {
                out.append((candidate.range, candidate.with))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Dates

    /// `13.11.2026`, `04.09.57`, `2026-11-13`, `13/11/2026`, `20261113`, `13112026`: a calendar date.
    public static func isDate(_ written: String) -> Bool {
        let text = written.trimmingCharacters(in: .whitespaces)
        if let m = text.wholeMatch(of: /(\d{1,2})\.(\d{1,2})\.(\d{2}|\d{4})/) { return valid(day: Int(m.1)!, month: Int(m.2)!, year: Int(m.3)!) }
        if let m = text.wholeMatch(of: /(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})/) { return valid(day: Int(m.1)!, month: Int(m.2)!, year: Int(m.3)!) }
        if let m = text.wholeMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/) { return valid(day: Int(m.3)!, month: Int(m.2)!, year: Int(m.1)!) }
        return isCompactDate(text)
    }

    /// Eight digits that are a date, `yyyymmdd` or `ddmmyyyy`: a file's name writes a day so.
    static func isCompactDate(_ written: String) -> Bool {
        let digits = written.trimmingCharacters(in: .whitespaces)
        guard digits.count == 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return false }
        let n = digits.compactMap(\.wholeNumberValue)
        func number(_ from: Int, _ count: Int) -> Int { n[from..<(from + count)].reduce(0) { $0 * 10 + $1 } }
        let ymd = (1900...2099).contains(number(0, 4)) && valid(day: number(6, 2), month: number(4, 2), year: number(0, 4))
        let dmy = (1900...2099).contains(number(4, 4)) && valid(day: number(0, 2), month: number(2, 2), year: number(4, 4))
        return ymd || dmy
    }

    static func valid(day: Int, month: Int, year: Int) -> Bool {
        (1...12).contains(month) && (1...31).contains(day) && (year < 100 || (1900...2099).contains(year))
    }
}
