import Foundation
import Testing

@testable import AgentSquad

@Suite struct JSONValueTests {
    @Test func roundTripsNestedValue() throws {
        let value: JSONValue = [
            "name": "PSG",
            "odds": 1.26,
            "live": true,
            "tags": ["home", "favorite"],
            "note": nil,
        ]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func decodesIntAndDoubleDistinctly() throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("3".utf8)) == .int(3))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("3.5".utf8)) == .double(3.5))
    }

    @Test func decodesBoolNotAsNumber() throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)) == .bool(true))
    }

    @Test func roundTripsDeepAndEmptyContainers() throws {
        let value: JSONValue = ["a": [["b": [:]], []], "empty": [:]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func throwsOnInvalidJSON() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(JSONValue.self, from: Data("{".utf8))
        }
    }

    // Characterizes the documented number-normalization contract so it can't drift silently.
    @Test func normalizesNumbersPerContract() throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("1.0".utf8)) == .int(1))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("-0.0".utf8)) == .int(0))
        let big = try JSONDecoder().decode(JSONValue.self, from: Data("9999999999999999999999".utf8))
        if case .double = big {} else { Issue.record("expected .double for an out-of-Int integer") }
    }
}
