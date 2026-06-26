import Foundation
import Testing

@testable import AgentSquad

@Suite struct ChatCompletionsClientTests {
    // MARK: - Test double

    /// Replays a scripted outcome per attempt and records the requests it received.
    private final class MockTransport: ChatCompletionsTransport, @unchecked Sendable {
        enum Outcome {
            case lines([String])
            case fail(any Error)
            case linesThenFail([String], any Error)
        }
        private let outcomes: [Outcome]
        private let lock = NSLock()
        private var _attempts = 0
        private var _requests: [URLRequest] = []

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }
        convenience init(lines: [String]) { self.init([.lines(lines)]) }

        var attempts: Int { lock.withLock { _attempts } }
        var requests: [URLRequest] { lock.withLock { _requests } }

        func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<String, any Error> {
            let index: Int = lock.withLock { let i = _attempts; _attempts += 1; _requests.append(request); return i }
            switch outcomes[min(index, outcomes.count - 1)] {
            case .fail(let error):
                throw error
            case .lines(let lines):
                return AsyncThrowingStream { c in for line in lines { c.yield(line) }; c.finish() }
            case .linesThenFail(let lines, let error):
                return AsyncThrowingStream { c in for line in lines { c.yield(line) }; c.finish(throwing: error) }
            }
        }
    }

    // MARK: - Chunk helpers

    private func contentChunk(_ text: String) -> String {
        #"data: {"choices":[{"delta":{"content":"\#(text)"},"finish_reason":null}]}"#
    }
    private func finishChunk(_ reason: String) -> String {
        #"data: {"choices":[{"delta":{},"finish_reason":"\#(reason)"}]}"#
    }
    private let done = "data: [DONE]"

    private func client(_ outcomes: [MockTransport.Outcome], maxRetries: Int = 2) -> (ChatCompletionsClient, MockTransport) {
        let transport = MockTransport(outcomes)
        let client = ChatCompletionsClient(
            model: "gpt", apiKey: "k", maxRetries: maxRetries, retryDelay: .zero, transport: transport
        )
        return (client, transport)
    }

    private func collect(_ client: ChatCompletionsClient, _ request: LLMRequest = LLMRequest(messages: [.init(role: .user, text: "hi")])) async throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for try await event in client.complete(request) { events.append(event) }
        return events
    }

    // MARK: - Streaming

    @Test func streamsTextDeltasThenDone() async throws {
        let (client, _) = client([.lines([contentChunk("Hel"), contentChunk("lo"), finishChunk("stop"), done])])
        let events = try await collect(client)

        let deltas = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
        #expect(deltas == ["Hel", "lo"])
        guard case .done(let reason, _) = events.last else { Issue.record("expected .done"); return }
        #expect(reason == .stop)
    }

    @Test func accumulatesToolCallFragmentsIntoOneCompleteCall() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_odds","arguments":""}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"team\":"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"PSG\"}"}}]},"finish_reason":null}]}"#,
            finishChunk("tool_calls"),
            done,
        ]
        let (client, _) = client([.lines(lines)])
        let events = try await collect(client)

        guard case .toolCall(let id, let name, let arguments) = events.first(where: { if case .toolCall = $0 { return true } else { return false } })
        else { Issue.record("expected .toolCall"); return }
        #expect(id == "call_1")
        #expect(name == "get_odds")
        #expect(arguments == .object(["team": .string("PSG")]))
        guard case .done(let reason, _) = events.last else { Issue.record("expected .done"); return }
        #expect(reason == .toolCalls)
    }

    @Test func parsesUsageIntoDone() async throws {
        let usageChunk = #"data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7}}"#
        let (client, _) = client([.lines([contentChunk("hi"), finishChunk("stop"), usageChunk, done])])
        let events = try await collect(client)
        guard case .done(_, let usage) = events.last else { Issue.record("expected .done"); return }
        #expect(usage?.promptTokens == 11)
        #expect(usage?.completionTokens == 7)
    }

    @Test func terminatesWhenStreamEndsWithoutDoneSentinel() async throws {
        // No "[DONE]" line — the stream just ends. The client must still emit a terminal .done.
        let (client, _) = client([.lines([contentChunk("hi"), finishChunk("stop")])])
        let events = try await collect(client)
        #expect(events.contains { if case .done = $0 { return true } else { return false } })
    }

    // MARK: - Request shaping

    @Test func buildsRequestBodyWithMessagesToolsResponseFormatAndExtraBody() async throws {
        let transport = MockTransport(lines: [finishChunk("stop"), done])
        let client = ChatCompletionsClient(
            model: "gpt-x", apiKey: "secret",
            responseFormat: .json, extraBody: ["temperature": .double(0.2)],
            transport: transport
        )
        let request = LLMRequest(
            system: "be terse",
            messages: [.init(role: .user, text: "odds?")],
            tools: [AgentTool(name: "get_odds", description: "odds")]
        )
        _ = try await collect(client, request)

        let httpBody = try #require(transport.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(json["model"] as? String == "gpt-x")
        #expect(json["stream"] as? Bool == true)
        #expect(json["temperature"] as? Double == 0.2)                                  // extraBody merged
        #expect(((json["response_format"] as? [String: Any])?["type"]) as? String == "json_object")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")                         // system prepended
        #expect(messages.contains { ($0["role"] as? String) == "user" })
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(((tools.first?["function"] as? [String: Any])?["name"]) as? String == "get_odds")
        // Auth header set from apiKey.
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func encodesAssistantToolCallAndToolResultMessages() async throws {
        let transport = MockTransport(lines: [finishChunk("stop"), done])
        let client = ChatCompletionsClient(model: "gpt", transport: transport)
        let history: [ConversationMessage] = [
            .init(role: .assistant, parts: [.toolCall(id: "c1", name: "get_odds", arguments: .object(["t": .string("PSG")]))]),
            .init(role: .tool, parts: [.toolResult(id: "c1", content: .string("2.5"))]),
        ]
        _ = try await collect(client, LLMRequest(messages: history))

        let body = try #require(transport.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { ($0["role"] as? String) == "assistant" })
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(((toolCalls.first?["function"] as? [String: Any])?["name"]) as? String == "get_odds")
        let toolMessage = try #require(messages.first { ($0["role"] as? String) == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "c1")
        #expect(toolMessage["content"] as? String == "2.5")
    }

    // MARK: - Errors & retries

    @Test func throwsHTTPStatusOnNon2xx() async throws {
        let (client, _) = client([.fail(ChatCompletionsError.httpStatus(400, body: "bad request"))])
        await #expect(throws: ChatCompletionsError.httpStatus(400, body: "bad request")) {
            _ = try await collect(client)
        }
    }

    @Test func retriesBeforeFirstEventThenSucceeds() async throws {
        let (client, transport) = client([
            .fail(ChatCompletionsError.httpStatus(503, body: nil)),   // attempt 1 — retryable
            .lines([contentChunk("ok"), finishChunk("stop"), done]),  // attempt 2 — succeeds
        ], maxRetries: 2)
        let events = try await collect(client)

        #expect(transport.attempts == 2)
        #expect(events.contains { if case .textDelta("ok") = $0 { return true } else { return false } })
    }

    @Test func doesNotRetryNonRetryable4xx() async throws {
        let (client, transport) = client([.fail(ChatCompletionsError.httpStatus(400, body: nil))], maxRetries: 3)
        await #expect(throws: (any Error).self) { _ = try await collect(client) }
        #expect(transport.attempts == 1)   // 400 is not retried
    }

    @Test func emitsToolCallWhenProviderOmitsIndex() async throws {
        // Some OpenAI-compatible providers omit `index` on tool-call deltas — the call must survive.
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        let (client, _) = client([.lines([line, done])])
        let events = try await collect(client)
        guard case .toolCall(let id, let name, _) = events.first(where: { if case .toolCall = $0 { return true } else { return false } })
        else { Issue.record("expected .toolCall"); return }
        #expect(id == "c1")
        #expect(name == "f")
    }

    @Test func handlesCRLFFramedStream() async throws {
        let (client, _) = client([.lines([contentChunk("hi") + "\r", finishChunk("stop") + "\r", "data: [DONE]\r"])])
        let events = try await collect(client)
        let deltas = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
        #expect(deltas == ["hi"])
        guard case .done(let reason, _) = events.last else { Issue.record("expected .done"); return }
        #expect(reason == .stop)
    }

    @Test func accumulatesParallelToolCallsByIndex() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f0","arguments":"{}"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"f1","arguments":"{}"}}]},"finish_reason":null}]}"#,
            finishChunk("tool_calls"), done,
        ]
        let (client, _) = client([.lines(lines)])
        let events = try await collect(client)
        let names = events.compactMap { if case .toolCall(_, let name, _) = $0 { return name } else { return nil } }
        #expect(names == ["f0", "f1"])
    }

    @Test func surfacesEmptyStreamOnGarbage200Body() async throws {
        // 200 OK but the body is an HTML/error page — must surface, not become a silent empty turn.
        let (client, _) = client([.lines(["<html>gateway error</html>", "not json"])])
        await #expect(throws: ChatCompletionsError.emptyStream) { _ = try await collect(client) }
    }

    @Test func emitsBothTextAndToolCallInOneTurn() async throws {
        let line = #"data: {"choices":[{"delta":{"content":"calling","tool_calls":[{"index":0,"id":"c1","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        let (client, _) = client([.lines([line, done])])
        let events = try await collect(client)
        #expect(events.contains { if case .textDelta("calling") = $0 { return true } else { return false } })
        #expect(events.contains { if case .toolCall = $0 { return true } else { return false } })
    }

    @Test func textResponseFormatOmitsTheField() async throws {
        let transport = MockTransport(lines: [finishChunk("stop"), done])
        let client = ChatCompletionsClient(model: "gpt", transport: transport)   // responseFormat defaults to .text
        _ = try await collect(client)
        let body = try #require(transport.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["response_format"] == nil)
    }

    @Test func joinsBaseURLPathWithOrWithoutTrailingSlash() async throws {
        for base in ["https://host/v1", "https://host/v1/"] {
            let transport = MockTransport(lines: [finishChunk("stop"), done])
            let client = ChatCompletionsClient(baseURL: URL(string: base)!, model: "gpt", transport: transport)
            _ = try await collect(client)
            #expect(transport.requests.first?.url?.absoluteString == "https://host/v1/chat/completions")
        }
    }

    @Test func doesNotRetryAfterFirstEventEmitted() async throws {
        // A delta reaches the consumer, then the stream drops — must propagate, not retry.
        let (client, transport) = client([
            .linesThenFail([contentChunk("partial")], URLError(.networkConnectionLost)),
            .lines([contentChunk("should-not-reach"), finishChunk("stop"), done]),
        ], maxRetries: 3)

        var events: [LLMStreamEvent] = []
        await #expect(throws: (any Error).self) {
            for try await event in client.complete(LLMRequest(messages: [.init(role: .user, text: "hi")])) { events.append(event) }
        }
        #expect(transport.attempts == 1)   // no retry once "partial" was emitted
        #expect(events.contains { if case .textDelta("partial") = $0 { return true } else { return false } })
    }
}
