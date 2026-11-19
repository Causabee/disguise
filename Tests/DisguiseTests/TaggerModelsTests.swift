import Foundation
import NaturalLanguage
import Testing
@testable import Disguise

/// Fix, 19 November 2026 (principle 11): on iPhone, Apple's name tagger stays empty for the whole
/// process when it reads a text before its language models are asked for: no error, no names. On the
/// owner's iPhone 15 Pro (iOS 27.0.1) the suite's tagger tests failed that way (126 of 140 passed;
/// 87 rows of the golden file differed) and pass with the models asked for first (132 of 140; 8 rows,
/// all names the Mac's model finds and the iPhone's does not). The Mac's tagger works either way, so
/// here the test checks that reading a text asks for the models: nothing else in the package asks.
/// Made-up sentence.
@Suite("Fix · The name tagger's models are asked for first")
struct TaggerModelsTests {
    @Test("Fix · reading a text asks for the tagger's models first: German and English")
    func modelsFirst() {
        let found = RuleFinder().found(in: "Das Paket liegt bei Malinowski im Flur.", field: .body)
        // Read before anything else touches `modelsAsked`: only the reading itself can have asked.
        let asked = RuleFinder.asked
        #expect(Set(asked) == [.german, .english], "the models were not asked for by reading: \(asked)")
        #expect(found.contains { $0.entity.text == "Malinowski" && $0.rule == .N5 }, "the tagger read no name: \(found.map(\.entity.text))")
    }
}
