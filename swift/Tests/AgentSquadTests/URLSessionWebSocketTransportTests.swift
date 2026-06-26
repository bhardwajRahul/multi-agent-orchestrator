import Foundation
import Testing

@testable import AgentSquad

@Suite struct URLSessionWebSocketTransportTests {
    @Test func appendsModelQueryToEndpoint() {
        let url = URLSessionWebSocketTransport.endpoint(URL(string: "wss://api.openai.com/v1/realtime")!, model: "gpt-realtime")
        #expect(url.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime")
    }

    @Test func preservesExistingQueryItems() {
        let url = URLSessionWebSocketTransport.endpoint(URL(string: "wss://host/realtime?region=eu")!, model: "m")
        #expect(url.absoluteString.contains("region=eu"))
        #expect(url.absoluteString.contains("model=m"))
    }

    @Test func sendBeforeConnectThrowsNotConnected() async throws {
        let transport = URLSessionWebSocketTransport(apiKey: "k")
        await #expect(throws: RealtimeTransportError.notConnected) {
            try await transport.send("{}")
        }
    }
}
