import Foundation
import Testing
@testable import Disguise

/// F020 AC-17, as the app checked it before the hiding became a package of its own (F024): the
/// three word lists ship with the package, only `NameKnowledge` reads them, nothing is fetched.
@Suite("F020 · The shipped lists, in the package")
struct NameListsTests {
    static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Disguise")
    }

    @Test("F024 AC-1 · each list loads from the package's own bundle")
    func loads() {
        for name in ["first-names", "surnames", "words"] {
            #expect(NameKnowledge.bundled(name) != nil, "\(name).lzfse is not in the package's bundle")
        }
        #expect(NameKnowledge.shared.counts.first > 10_000 && NameKnowledge.shared.counts.last > 10_000)
    }

    @Test("F020 AC-17 · only NameKnowledge reads the lists; nothing is fetched; the finder never reads the word list")
    func onlyOneReader() throws {
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 10, "Sources/Disguise was read")
        for file in files where file.lastPathComponent != "NameKnowledge.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["\"first-names\"", "\"surnames\"", "withExtension: \"lzfse\"", "subdirectory: \"Names\""] {
                #expect(!text.contains(word), "\(file.lastPathComponent) reads a list: \(word)")
            }
        }
        let own = try String(contentsOf: Self.sources.appendingPathComponent("NameKnowledge.swift"), encoding: .utf8)
        for word in ["URLSession", "Claude", "OpenAI", "URLRequest"] { #expect(!own.contains(word)) }
        let detection = Self.sources.appendingPathComponent("Detection")
        for file in try FileManager.default.contentsOfDirectory(at: detection, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("ordinaryWords()"), "\(file.lastPathComponent) reads the word list")
        }
    }

    @Test("F020 AC-17 · each list has its source, a licence that fits a paid app, and a date; 3 MB or less")
    func licences() throws {
        let folder = Self.sources.appendingPathComponent("Resources/Names")
        let licences = try String(contentsOf: folder.appendingPathComponent("LICENCES.txt"), encoding: .utf8)
        var total = 0
        for list in ["first-names", "surnames", "words"] {
            let file = folder.appendingPathComponent("\(list).lzfse")
            total += try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
            let block = licences.components(separatedBy: "\(list).lzfse").dropFirst().first?.components(separatedBy: "\n\n").first ?? ""
            #expect(block.contains("Source:"), "\(list): no source")
            #expect(block.contains("Date: 20"), "\(list): no date")
            // All three are CC0 today, so no credit line is owed anywhere.
            #expect(block.contains("Licence: CC0"), "\(list): not CC0")
        }
        #expect(total <= 3_000_000)
    }

    @Test("F024 AC-1 · the package imports only Apple's own frameworks")
    func onlyApple() throws {
        let allowed: Set<String> = ["Foundation", "CryptoKit", "NaturalLanguage", "Compression", "AppKit", "UIKit"]
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") where line.hasPrefix("import ") {
                let module = String(line.dropFirst("import ".count))
                #expect(allowed.contains(module), "\(file.lastPathComponent) imports \(module)")
            }
        }
    }
}
