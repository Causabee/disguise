import Foundation
import NameBench

// F021 · The quick look on the Mac: one candidate over the corpus, the unseen set, the tier set
// and the bench's names. `swift run --package-path NameBench name-bench --engine apple|coreml`.
// Sends nothing, reads no key; the Core ML file comes from NameBench/Model/ (ignored).
let arguments = CommandLine.arguments
let engineName = arguments.firstIndex(of: "--engine").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "apple"
let bench = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fixtures = bench.deletingLastPathComponent().appendingPathComponent("Tests/MatterCoreTests/Fixtures")

let engine: any NameEngine
switch engineName {
case "apple": engine = AppleNames()
case "coreml": engine = CoreMLNames(folder: bench.appendingPathComponent("Model"))
default: print("Unknown engine \(engineName). Known: apple, coreml"); exit(1)
}
let sets = try Sets.all(in: fixtures)
let result = await Bench.run(engine, on: sets, detailed: [Sets.named], run: "name-bench")
print(result.text)
