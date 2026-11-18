// swift-tools-version: 6.0
import PackageDescription

// How Causabee hides names, places and numbers before any text leaves the device. Apple's own
// frameworks only; nothing is fetched, nothing is sent.
let package = Package(
    name: "Disguise",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "Disguise", targets: ["Disguise"]),
    ],
    targets: [
        .target(name: "Disguise", resources: [.process("Resources")]),
        .testTarget(name: "DisguiseTests", dependencies: ["Disguise"], resources: [.copy("Fixtures")]),
    ]
)
