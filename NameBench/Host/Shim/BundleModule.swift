import Foundation

/// SwiftPM gives each target with resources a `Bundle.module`; an Xcode test bundle has none.
/// The same lookup here: the test bundle itself, which carries `Cases` or `Fixtures`.
private final class BundleToken {}

extension Bundle {
    static let module = Bundle(for: BundleToken.self)
}
