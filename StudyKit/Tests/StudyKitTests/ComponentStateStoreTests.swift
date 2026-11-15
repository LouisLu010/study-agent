import Foundation
import Testing
@testable import StudyKit

@Suite struct ComponentStateStoreTests {
    @Test func addsUpdatesAndRemovesState() {
        var json = ComponentStateStore.updating("", key: "c0", state: ["a": 2.5])
        #expect(json == #"{"c0":{"a":2.5}}"#)

        json = ComponentStateStore.updating(json, key: "c1", state: ["step": 2])
        #expect(json == #"{"c0":{"a":2.5},"c1":{"step":2}}"#)

        json = ComponentStateStore.updating(json, key: "c0", state: NSNull())
        #expect(json == #"{"c1":{"step":2}}"#)

        json = ComponentStateStore.updating(json, key: "c1", state: nil)
        #expect(json == "")
    }

    @Test func ignoresMalformedJSON() {
        #expect(ComponentStateStore.decode("not json").isEmpty)
        #expect(ComponentStateStore.updating("[1,2]", key: "c0", state: 1) == #"{"c0":1}"#)
    }
}
