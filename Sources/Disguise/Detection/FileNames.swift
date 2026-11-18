import Foundation

/// F021: where a file's name stands in a text, moved verbatim from `EntityDetector` when the old
/// rules went (AC-9). Read by `NameRebuild` and the new rules' S3.
public enum FileNames {
    /// F020 AC-14 (the owner's answer a to open question L): exactly eight digits that are a day —
    /// `yyyymmdd` or `ddmmyyyy` — standing in a file's name: the attachment's own name, or a name in
    /// the text that ends in a file's extension (`Scan_20261113_Bescheid.pdf`). Any day, a date of
    /// birth too: what is hidden comes in an order, names first and dates last (principle 11). A
    /// number after a label, a number that is no day, nine digits and more are learned as before.
    static func isFileDate(_ hit: String, at range: Range<String.Index>, in text: String, field: Entity.Field) -> Bool {
        guard hit.count == 8, NumberRuns.isCompactDate(hit) else { return false }
        return field == .attachmentName || inFileName(range, in: text)
    }

    /// The span lies inside a file's name in the text: the run of letters, digits, `_`, `-` and `.`
    /// around it ends in a file's extension.
    public static func inFileName(_ range: Range<String.Index>, in text: String) -> Bool {
        func part(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." }
        var start = range.lowerBound, end = range.upperBound
        while start > text.startIndex, part(text[text.index(before: start)]) { start = text.index(before: start) }
        while end < text.endIndex, part(text[end]) { end = text.index(after: end) }
        let name = text[start..<end].trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard let dot = name.lastIndex(of: "."), name[dot...].count > 1 else { return false }
        return fileExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    static let fileExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "doc", "docx", "xls", "xlsx",
                                              "txt", "eml", "emlx", "pages", "numbers", "odt", "rtf"]
}
