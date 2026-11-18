// swift-tools-version: 6.2
import PackageDescription

// F021 · The name bench. Apple's on-device model and one small multilingual name model, run on
// made-up cases, printed for the owner. Its own package, so the app never builds a model runtime
// or a tokenizer (AC-2): the app's Package.swift names WhisperKit alone. It decides nothing.
let package = Package(
    name: "NameBench",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "NameBench", targets: ["NameBench"]),
        .executable(name: "name-bench", targets: ["name-bench"]),
    ],
    dependencies: [
        // The same version WhisperKit already brings into the app's resolved graph.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.9"),
    ],
    targets: [
        .target(name: "NameBench", dependencies: [.product(name: "Tokenizers", package: "swift-transformers")]),
        // The quick look on the Mac: `swift run --package-path NameBench name-bench --engine apple|coreml`.
        .executableTarget(name: "name-bench", dependencies: ["NameBench"]),
        // Cases/: copies of the cases (copy.sh), and Cases/Model/ (ignored) for a device. Not
        // "Resources": a folder of that name in an iOS bundle breaks its signature.
        .testTarget(name: "NameBenchTests", dependencies: ["NameBench"], resources: [.copy("Cases")]),
    ]
)
