import Foundation
import Testing
@testable import Disguise

/// F021: the switch. One seam, `Detection`, says which rules find what is disguised; until the
/// owner's word is in the README, the old rules decide on every source — what comes in (mail,
/// screenshots, photos, files and scans), notes, the chat, and tasks and dates added by hand.
@Suite("F021 · The switch")
struct DetectionSwitchTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift file under `Sources/`, by its path from the root, with its text.
    static func sources() throws -> [(path: String, text: String)] {
        let folder = root.appendingPathComponent("Sources")
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var files: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append((String(url.path.dropFirst(root.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }


    /// The README's line for the switch, which the lead writes only after the owner's word.
    static func ownersWord() throws -> Bool {
        let readme = try String(contentsOf: root.appendingPathComponent("docs/features/021-detection-rules-rebuilt-from-scratch/README.md"), encoding: .utf8)
        return readme.split(separator: "\n").contains { $0.hasPrefix("- ") && $0.contains("· The switch to the new rules.") }
    }


    @Test("F021 AC-8 · no call of RuleFinder or learnAdmitted outside Detection.swift")
    func newUnreached() throws {
        for (path, text) in try Self.sources() {
            let inDetection = path.hasPrefix("Sources/Disguise/Detection/")
            if !inDetection {
                #expect(!text.contains("RuleFinder"), "\(path) names RuleFinder")
                let calls = text.components(separatedBy: "learnAdmitted(").count - 1
                // Pseudonymizer defines it, and its `learn` hands to it since the old admission went (AC-9).
                let defines = path.hasSuffix("Disguise/Pseudonymizer.swift") ? 2 : 0
                #expect(calls == defines, "\(path) calls learnAdmitted")
            } else if !path.hasSuffix("Detection/Detection.swift") {
                #expect(!text.contains("learnAdmitted("), "\(path) calls learnAdmitted")
                if !path.hasSuffix("Detection/RuleFinder.swift") { #expect(!text.contains("RuleFinder("), "\(path) makes a RuleFinder") }
            }
        }
    }

    @Test("F021 AC-8 · only tests set the override")
    func onlyTestsOverride() throws {
        let files = try Self.sources()
        #expect(files.count > 10, "Sources/ was read")
        for (path, text) in files {
            let sets = text.contains("$override") || text.contains("override.withValue")
            #expect(!sets, "\(path) sets Detection.override")
        }
        // The seam is the only maker of the old finder that decides a send.
        let makers = files.filter { $0.text.contains("EntityDetector(") && !$0.path.hasSuffix("Detection/Detection.swift") }.map(\.path)
        #expect(makers.isEmpty, "make EntityDetector themselves: \(makers)")
    }

    // MARK: AC-9 · after the switch, one set of rules

    @Test("F021 AC-9 · no call of the old rules under Sources")
    func oldRulesGone() throws {
        // The three helpers moved verbatim from the old finder name it in their comments, and find no name.
        let helpers = ["Detection/VaultShapes.swift", "Detection/CompanyForm.swift", "Detection/FileNames.swift"]
        let files = try Self.sources()
        #expect(!files.contains { $0.path.hasSuffix("MatterCore/EntityDetector.swift") })
        for (path, text) in files where !helpers.contains(where: path.hasSuffix) {
            for word in ["EntityDetector", "reasonToSkip", "dropsLoneWords", "insideEntities", "isLoneOrdinaryWord", "isOrdinarySender"] {
                #expect(!text.contains(word), "\(path) names \(word)")
            }
        }
        #expect(Detection.Rules.allCases == [.new])
    }



    // MARK: AC-2 · The bench decides nothing: the app holds no model for finding names

    /// Every file under `Sources/` and `App/`, folders too (a model package is a folder).
    static func appFiles() -> [URL] {
        ["Sources", "App"].flatMap { top -> [URL] in
            let walker = FileManager.default.enumerator(at: root.appendingPathComponent(top), includingPropertiesForKeys: nil)
            var all: [URL] = []
            while let url = walker?.nextObject() as? URL { all.append(url) }
            return all
        }
    }

    @Test("F021 AC-1 · the bench lives in NameBench, outside the app, with its own measured test")
    func benchApart() throws {
        let bench = try String(contentsOf: Self.root.appendingPathComponent("NameBench/Tests/NameBenchTests/NameBenchTests.swift"), encoding: .utf8)
        #expect(bench.contains("F021 AC-1"), "the bench's own test carries AC-1")
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!manifest.contains("NameBench"), "the app's package does not include the bench")
    }


    @Test("F021 AC-2 · nothing under Sources or App imports a model runtime")
    func noModelRuntime() throws {
        // FoundationModels is not on this list: the app already reads on the device with it
        // (DeviceReader, DeviceTask, PlainWords), and the bench's use of it lives in NameBench.
        let runtimes = ["CoreML", "Tokenizers", "Transformers", "Hub", "MLX", "MLXLLM", "MLXLMCommon", "NameBench"]
        var read = 0
        for url in Self.appFiles() where url.pathExtension == "swift" {
            read += 1
            let path = url.path.dropFirst(Self.root.path.count + 1)
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let words = line.split(separator: " ").filter { !$0.hasPrefix("@") }
                guard words.first == "import", words.count > 1 else { continue }
                let module = String(words[1].split(separator: ".").first ?? "")
                #expect(!runtimes.contains(module), "\(path) imports \(module)")
            }
        }
        #expect(read > 10, "Sources/ was read")
    }

    @Test("F021 AC-2 · no model file in the app")
    func noModelFile() {
        let kinds: Set<String> = ["mlmodel", "mlmodelc", "mlpackage", "safetensors", "gguf", "onnx", "tflite", "pt", "h5"]
        let models = Self.appFiles().filter { kinds.contains($0.pathExtension.lowercased()) }.map { String($0.path.dropFirst(Self.root.path.count + 1)) }
        #expect(models.isEmpty, "model files in the app: \(models)")
    }
}
