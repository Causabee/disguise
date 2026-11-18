import SwiftUI

/// F021 3.5 · The host the bench's tests need on a device ("Tool-hosted testing is unavailable on
/// device destinations"). Measuring only; never part of Causabee, never shipped. It shows one
/// line and does nothing else: the tests run inside it and xcodebuild removes it afterwards.
@main
struct BenchHostApp: App {
    var body: some Scene {
        WindowGroup { Text("Causabee bench · measuring only").padding() }
    }
}
