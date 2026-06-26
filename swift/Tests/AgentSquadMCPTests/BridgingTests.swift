import Foundation
import Testing

import MCP
@testable import AgentSquad
@testable import AgentSquadMCP

@Suite struct BridgingTests {
    @Test func valueToJSONCoversAllCases() {
        #expect(Bridging.toJSON(.null) == .null)
        #expect(Bridging.toJSON(.bool(true)) == .bool(true))
        #expect(Bridging.toJSON(.int(3)) == .int(3))
        #expect(Bridging.toJSON(.double(1.5)) == .double(1.5))
        #expect(Bridging.toJSON(.string("x")) == .string("x"))
        #expect(Bridging.toJSON(.data(mimeType: nil, Data("hi".utf8))) == .string(Data("hi".utf8).base64EncodedString()))
        #expect(Bridging.toJSON(.array([.int(1), .string("a")])) == .array([.int(1), .string("a")]))
        #expect(Bridging.toJSON(.object(["k": .bool(false)])) == .object(["k": .bool(false)]))
    }

    // Int stays int, double stays double — no silent numeric coercion.
    @Test func jsonToValuePreservesNumericKinds() {
        #expect(Bridging.toValue(.int(5)) == .int(5))
        #expect(Bridging.toValue(.double(5.0)) == .double(5.0))
    }

    @Test func argumentsFromObjectAndNonObject() {
        #expect(Bridging.arguments(["match": "PSG", "n": 2]) == ["match": .string("PSG"), "n": .int(2)])
        #expect(Bridging.arguments(.string("not an object")).isEmpty)
    }

    @Test func uiResourceURIFromMetaAndAlias() {
        let viaUI: [String: Value] = ["ui": .object(["resourceUri": .string("ui://matches")])]
        #expect(Bridging.uiResourceURI(viaUI) == "ui://matches")

        let viaAlias: [String: Value] = ["openai/outputTemplate": .string("ui://alias")]
        #expect(Bridging.uiResourceURI(viaAlias) == "ui://alias")

        #expect(Bridging.uiResourceURI(nil) == nil)
        #expect(Bridging.uiResourceURI(["ui": .string("wrong type")]) == nil)   // tolerant
    }

    @Test func visibilityParsing() {
        #expect(Bridging.visibility(nil) == .all)                                          // absent → default both
        #expect(Bridging.visibility(["ui": .object([:])]) == .all)                         // no visibility key → both
        #expect(Bridging.visibility(["ui": .object(["visibility": .array([.string("model")])])]) == .model)
        #expect(Bridging.visibility(["ui": .object(["visibility": .array([.string("model"), .string("app")])])]) == .all)
        #expect(Bridging.visibility(["ui": .object(["visibility": .array([])])]) == [])    // explicit empty → neither
    }

    @Test func metaToJSON() {
        #expect(Bridging.metaToJSON(nil) == nil)
        #expect(Bridging.metaToJSON(["a": .int(1)]) == .object(["a": .int(1)]))
    }

    @Test func contentMapping() {
        #expect(Bridging.content([]) == nil)
        #expect(Bridging.content([.text(text: "hi", annotations: nil, _meta: nil)]) == [.text("hi")])
        #expect(Bridging.content([.image(data: "x", mimeType: "image/png", annotations: nil, _meta: nil)]) == [.text("[image]")])
    }
}
