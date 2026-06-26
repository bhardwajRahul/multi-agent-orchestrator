import Foundation
import Testing

@testable import AgentSquad

@Suite struct OTLPExporterTests {
    // MARK: - Test double

    /// Captures POSTs and returns a configurable status — no network.
    private final class MockPoster: HTTPPoster, @unchecked Sendable {
        struct Call: Sendable { let url: URL; let headers: [String: String]; let body: Data }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private let statusCode: Int

        init(statusCode: Int = 200) { self.statusCode = statusCode }

        var calls: [Call] { lock.withLock { _calls } }

        func post(url: URL, headers: [String: String], body: Data) async throws -> (response: HTTPURLResponse, body: Data) {
            lock.withLock { _calls.append(Call(url: url, headers: headers, body: body)) }
            return (HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, Data())
        }
    }

    // MARK: - Helpers

    private let endpoint = URL(string: "https://collector.example/v1/traces")!

    private func event(
        id: String, traceId: String, parentId: String? = nil,
        kind: TraceEvent.Kind = .span, name: String = "n",
        status: TraceEvent.Status = .ok, error: String? = nil,
        input: JSONValue? = nil, output: JSONValue? = nil,
        model: String? = nil, promptTokens: Int? = nil, completionTokens: Int? = nil,
        userId: String? = nil, sessionId: String? = nil, metadata: JSONValue? = nil
    ) -> TraceEvent {
        TraceEvent(
            traceId: traceId, id: id, parentId: parentId, kind: kind, name: name,
            status: status, startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2),
            input: input, output: output,
            error: error, model: model, promptTokens: promptTokens, completionTokens: completionTokens,
            userId: userId, sessionId: sessionId, metadata: metadata
        )
    }

    /// Decode the single POSTed body to a dictionary for structural assertions.
    private func postedJSON(_ poster: MockPoster) throws -> [String: Any] {
        let body = try #require(poster.calls.first?.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func spans(in json: [String: Any]) throws -> [[String: Any]] {
        let resourceSpans = try #require(json["resourceSpans"] as? [[String: Any]])
        let scopeSpans = try #require(resourceSpans.first?["scopeSpans"] as? [[String: Any]])
        return try #require(scopeSpans.first?["spans"] as? [[String: Any]])
    }

    // MARK: - Tests

    @Test func buildsOTLPRequestStructure() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, serviceName: "betclic", http: poster)
        let root = "11111111-2222-3333-4444-555555555555"
        let gen = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

        try await exporter.export([
            event(id: root, traceId: root, kind: .trace, name: "turn"),
            event(id: gen, traceId: root, parentId: root, kind: .generation, name: "llm",
                  model: "gpt", promptTokens: 10, completionTokens: 5,
                  userId: "u", sessionId: "s")
        ])

        let json = try postedJSON(poster)
        let resourceSpans = try #require(json["resourceSpans"] as? [[String: Any]])
        let resourceAttrs = try #require(((resourceSpans.first?["resource"] as? [String: Any])?["attributes"]) as? [[String: Any]])
        #expect(resourceAttrs.contains { ($0["key"] as? String) == "service.name" })

        let spans = try spans(in: json)
        #expect(spans.count == 2)

        let rootSpan = try #require(spans.first { ($0["name"] as? String) == "turn" })
        let genSpan = try #require(spans.first { ($0["name"] as? String) == "llm" })

        // IDs: 32 hex for trace, 16 hex for span; child parent links to root span id; root omits parent.
        #expect((rootSpan["traceId"] as? String)?.count == 32)
        #expect((rootSpan["spanId"] as? String)?.count == 16)
        #expect(rootSpan["parentSpanId"] == nil)
        #expect(genSpan["parentSpanId"] as? String == rootSpan["spanId"] as? String)
        #expect(genSpan["traceId"] as? String == rootSpan["traceId"] as? String)

        // Kind: CLIENT(3) for the generation, INTERNAL(1) for the trace.
        #expect(rootSpan["kind"] as? Int == 1)
        #expect(genSpan["kind"] as? Int == 3)

        // Timestamps are stringified nanos (2s → 2e9), end >= start.
        #expect(genSpan["startTimeUnixNano"] as? String == "1000000000")
        #expect(genSpan["endTimeUnixNano"] as? String == "2000000000")

        // GenAI-semconv attributes; int64 tokens encoded as strings.
        let genAttrs = try #require(genSpan["attributes"] as? [[String: Any]])
        func attr(_ key: String) -> [String: Any]? { genAttrs.first { ($0["key"] as? String) == key } }
        #expect((attr("gen_ai.request.model")?["value"] as? [String: Any])?["stringValue"] as? String == "gpt")
        #expect((attr("gen_ai.usage.input_tokens")?["value"] as? [String: Any])?["intValue"] as? String == "10")
        #expect((attr("gen_ai.usage.output_tokens")?["value"] as? [String: Any])?["intValue"] as? String == "5")
        #expect((attr("enduser.id")?["value"] as? [String: Any])?["stringValue"] as? String == "u")
        #expect((attr("session.id")?["value"] as? [String: Any])?["stringValue"] as? String == "s")
    }

    @Test func setsContentTypeAndCustomHeaders() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, headers: ["Authorization": "Basic abc"], http: poster)
        try await exporter.export([event(id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555", kind: .trace)])

        let headers = try #require(poster.calls.first?.headers)
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["Authorization"] == "Basic abc")
    }

    @Test func mapsErrorStatus() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555", status: .error, error: "boom")])

        let span = try #require(try spans(in: postedJSON(poster)).first)
        let status = try #require(span["status"] as? [String: Any])
        #expect(status["code"] as? Int == 2)
        #expect(status["message"] as? String == "boom")
    }

    @Test func throwsOnNon2xx() async throws {
        let poster = MockPoster(statusCode: 500)
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        await #expect(throws: OTLPExporterError.httpStatus(500, body: nil)) {
            try await exporter.export([event(id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555")])
        }
    }

    @Test func okSpanLeavesStatusUnset() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555")])

        let span = try #require(try spans(in: postedJSON(poster)).first)
        let status = try #require(span["status"] as? [String: Any])
        #expect(status["code"] as? Int == 0)        // UNSET, not OK
        #expect(status["message"] == nil)
    }

    @Test func stringifiesJSONInputAndOutputAttributes() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(
            id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555",
            kind: .generation,
            input: .object(["q": .string("hi")]),
            output: .array([.int(1), .string("a")])
        )])

        let attrs = try #require(try spans(in: postedJSON(poster)).first?["attributes"] as? [[String: Any]])
        func value(_ key: String) -> String? {
            (attrs.first { ($0["key"] as? String) == key }?["value"] as? [String: Any])?["stringValue"] as? String
        }
        #expect(value("gen_ai.prompt") == #"{"q":"hi"}"#)
        #expect(value("gen_ai.completion") == #"[1,"a"]"#)
    }

    @Test func mapsMetadataKeysToAttributesVerbatim() async throws {
        // The realtime token breakdown / modality marker ride in metadata; its top-level keys must
        // reach the backend as attributes (otherwise the feature ships dark). Scalars keep their
        // OTLP type, `null` is dropped, non-scalars are JSON-stringified.
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(
            id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555",
            kind: .generation, name: "response", promptTokens: 1_240, completionTokens: 820,
            metadata: .object([
                "gen_ai.usage.input_audio_tokens": .int(1_000),
                "modality": .string("audio"),
                "cache_hit_rate": .double(0.5),
                "barge_in": .bool(true),
                "dropped": .null,
                "tags": .array([.string("voice")])
            ])
        )])

        let attrs = try #require(try spans(in: postedJSON(poster)).first?["attributes"] as? [[String: Any]])
        func value(_ key: String) -> [String: Any]? { (attrs.first { ($0["key"] as? String) == key }?["value"] as? [String: Any]) }
        // int64 → stringified intValue (proto3-JSON); the headline totals still map separately.
        #expect(value("gen_ai.usage.input_audio_tokens")?["intValue"] as? String == "1000")
        #expect(value("gen_ai.usage.input_tokens")?["intValue"] as? String == "1240")
        #expect(value("modality")?["stringValue"] as? String == "audio")
        #expect(value("cache_hit_rate")?["doubleValue"] as? Double == 0.5)
        #expect(value("barge_in")?["boolValue"] as? Bool == true)
        #expect(value("tags")?["stringValue"] as? String == #"["voice"]"#)
        #expect(attrs.contains { ($0["key"] as? String) == "dropped" } == false)   // null dropped
    }

    @Test func metadataDoesNotShadowReservedAttributeKeys() async throws {
        // A metadata key equal to one the mapper emits itself is skipped (OTLP attributes are a list,
        // so a duplicate would ship twice) — the reserved value from the typed field wins, once.
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(
            id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555",
            kind: .generation, promptTokens: 1_240,
            metadata: .object(["gen_ai.usage.input_tokens": .int(99)])   // collides with the real total
        )])

        let attrs = try #require(try spans(in: postedJSON(poster)).first?["attributes"] as? [[String: Any]])
        let inputTokenAttrs = attrs.filter { ($0["key"] as? String) == "gen_ai.usage.input_tokens" }
        #expect(inputTokenAttrs.count == 1)   // emitted once, not duplicated
        #expect((inputTokenAttrs.first?["value"] as? [String: Any])?["intValue"] as? String == "1240")   // the reserved value wins
    }

    @Test func nonFiniteMetadataDoubleIsDroppedNotSinkingTheBatch() async throws {
        // A `.nan`/`.inf` double would throw in JSONEncoder and lose the whole batch; it's dropped
        // instead, leaving the rest of the span intact and exportable.
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(
            id: "11111111-2222-3333-4444-555555555555", traceId: "11111111-2222-3333-4444-555555555555",
            kind: .generation, name: "response",
            metadata: .object(["cache_hit_rate": .double(.nan), "modality": .string("audio")])
        )])

        #expect(poster.calls.count == 1)   // the batch still exported
        let attrs = try #require(try spans(in: postedJSON(poster)).first?["attributes"] as? [[String: Any]])
        #expect(attrs.contains { ($0["key"] as? String) == "cache_hit_rate" } == false)   // non-finite dropped
        #expect(attrs.contains { ($0["key"] as? String) == "modality" })                  // the rest survives
    }

    @Test func groupsMultipleTracesUnderOneResourceAndScope() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([
            event(id: "11111111-1111-1111-1111-111111111111", traceId: "11111111-1111-1111-1111-111111111111", kind: .trace, name: "t1"),
            event(id: "22222222-2222-2222-2222-222222222222", traceId: "22222222-2222-2222-2222-222222222222", kind: .trace, name: "t2")
        ])

        let json = try postedJSON(poster)
        let resourceSpans = try #require(json["resourceSpans"] as? [[String: Any]])
        #expect(resourceSpans.count == 1)
        let scopeSpans = try #require(resourceSpans.first?["scopeSpans"] as? [[String: Any]])
        #expect(scopeSpans.count == 1)
        let spanCount = try spans(in: json).count
        #expect(spanCount == 2)
    }

    @Test func lowercasesUppercaseUUIDIds() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", traceId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", kind: .trace)])

        let traceId = try #require(try spans(in: postedJSON(poster)).first?["traceId"] as? String)
        #expect(traceId == traceId.lowercased())
        #expect(traceId == "aaaaaaaabbbbccccddddeeeeeeeeeeee")
    }

    @Test func flushSurfacesExporterHTTPStatus() async throws {
        let poster = MockPoster(statusCode: 503)
        let tracer = ProcessingTracer(exporter: OTLPExporter(endpoint: endpoint, http: poster), batchSize: 100)
        tracer.startTrace(name: "turn", userId: nil, sessionId: nil, metadata: nil).end(output: nil, error: nil)
        await #expect(throws: OTLPExporterError.httpStatus(503, body: nil)) {
            try await tracer.flush()
        }
    }

    @Test func emptyBatchMakesNoRequest() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([])
        #expect(poster.calls.isEmpty)
    }

    @Test func nonUUIDIdsFallBackToValidHex() async throws {
        let poster = MockPoster()
        let exporter = OTLPExporter(endpoint: endpoint, http: poster)
        try await exporter.export([event(id: "my-agent-span", traceId: "my-agent-trace", kind: .trace)])

        let span = try #require(try spans(in: postedJSON(poster)).first)
        let traceId = try #require(span["traceId"] as? String)
        let spanId = try #require(span["spanId"] as? String)
        #expect(traceId.count == 32)
        #expect(spanId.count == 16)
        let traceIsHex = traceId.allSatisfy(\.isHexDigit)
        let spanIsHex = spanId.allSatisfy(\.isHexDigit)
        #expect(traceIsHex)
        #expect(spanIsHex)
    }

    @Test func endToEndThroughProcessingTracer() async throws {
        let poster = MockPoster()
        let tracer = ProcessingTracer(exporter: OTLPExporter(endpoint: endpoint, http: poster), batchSize: 100)
        tracer.startTrace(name: "turn", userId: "u", sessionId: "s", metadata: nil).end(output: nil, error: nil)
        try await tracer.flush()

        #expect(poster.calls.count == 1)
        let spanCount = try spans(in: postedJSON(poster)).count
        #expect(spanCount == 1)
    }
}
