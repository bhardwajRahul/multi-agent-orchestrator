import Foundation
import Testing

@testable import AgentSquad

@Suite struct MessageTests {
    @Test func roundTripsMessageWithMixedParts() throws {
        let payload = UIPayload(
            resourceURI: "ui://sport/matches",
            mimeType: "text/html;profile=mcp-app",
            structuredContent: ["match": "PSG vs Monaco"]
        )
        let message = ConversationMessage(
            id: "m1",
            role: .assistant,
            parts: [
                .text("Here are tonight's odds."),
                .toolCall(id: "c1", name: "get_odds", arguments: ["match": "PSG vs Monaco"]),
                .toolResult(id: "c1", content: ["home": 1.26]),
                .widget(payload),
            ]
        )
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ConversationMessage.self, from: data) == message)
    }

    @Test func textConvenienceInitWrapsASingleTextPart() {
        let message = ConversationMessage(role: .user, text: "hello")
        #expect(message.parts == [.text("hello")])
    }

    // Guards the persisted format against silent drift: a frozen JSON literal (the synthesized
    // shape) must keep decoding into the same value. A renamed case/label would fail this.
    @Test func decodesFrozenPersistedFormat() throws {
        let json = #"""
        {"id":"m1","role":"assistant","parts":[{"text":{"_0":"hi"}},{"toolResult":{"id":"c1","content":{"home":1.26}}},{"audioTranscript":{"_0":"live"}}],"timestamp":0}
        """#
        let expected = ConversationMessage(
            id: "m1",
            role: .assistant,
            parts: [
                .text("hi"),
                .toolResult(id: "c1", content: ["home": 1.26]),
                .audioTranscript("live"),
            ],
            timestamp: Date(timeIntervalSinceReferenceDate: 0)
        )
        #expect(try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8)) == expected)
    }

    @Test func uiPayloadRoundTrips() throws {
        let payload = UIPayload(
            resourceURI: "ui://sport/lineup",
            mimeType: "text/html;profile=mcp-app",
            template: .html("<div>x</div>"),
            structuredContent: ["home": ["A", "B"]],
            security: UISecurity(connectDomains: ["api.example.com"], prefersBorder: true)
        )
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(UIPayload.self, from: data) == payload)
    }
}
