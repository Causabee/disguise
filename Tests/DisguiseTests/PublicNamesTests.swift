import Foundation
import Testing
@testable import Disguise

/// A made-up brand, so no other test that runs at the same time is touched by the list.
@Suite(.serialized)
struct PublicNamesTests {
    private func entity(_ kind: Entity.Kind, _ text: String) -> Entity {
        Entity(kind: kind, text: text, field: .body, start: 0, length: (text as NSString).length, source: .rule)
    }

    @Test func aPublicNameIsNotDisguisedAndEverythingElseStillIs() {
        PublicNames.set(["Wanderlustia"])
        defer { PublicNames.set([]) }
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        let skipped = pseudonymizer.learn([entity(.organization, "Wanderlustia Inc."), entity(.person, "Sibylle Ferber")])
        #expect(skipped.contains { $0.text == "Wanderlustia Inc." && $0.reason.contains("public") })
        let out = pseudonymizer.disguiser.apply("Sibylle Ferber booked the hotel with Wanderlustia Inc. in March.").text
        #expect(out.contains("Wanderlustia Inc."))
        #expect(!out.contains("Sibylle"))
    }

    @Test func aNameLearnedBeforeItWasMarkedIsLeftAloneToo() {
        var pseudonymizer = Pseudonymizer(mode: .placeholder)
        pseudonymizer.learn([entity(.organization, "Wanderlustia")])
        #expect(!pseudonymizer.disguiser.apply("Refund from Wanderlustia").text.contains("Wanderlustia"))
        PublicNames.set(["Wanderlustia"])
        defer { PublicNames.set([]) }
        #expect(pseudonymizer.disguiser.apply("Refund from Wanderlustia").text == "Refund from Wanderlustia")
    }


}
