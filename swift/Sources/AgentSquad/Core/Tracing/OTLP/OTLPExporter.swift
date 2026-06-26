import Foundation

/// A `TraceExporter` that POSTs spans as OTLP/HTTP JSON — the wire format Langfuse, Langsmith,
/// Datadog, Grafana, and Honeycomb all ingest. URLSession-only (core stays dependency-free); the
/// caller supplies the endpoint and any auth headers (Basic, `x-api-key`, `dd-api-key`, …).
///
/// `export` throws on a non-2xx. No retry/offline persistence — a dropped batch is gone.
public struct OTLPExporter: TraceExporter {
    private let endpoint: URL
    private let headers: [String: String]
    private let serviceName: String
    private let http: any HTTPPoster

    public init(
        endpoint: URL,
        headers: [String: String] = [:],
        serviceName: String = "agent-squad",
        http: any HTTPPoster = URLSessionPoster()
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.serviceName = serviceName
        self.http = http
    }

    public func export(_ batch: [TraceEvent]) async throws {
        guard !batch.isEmpty else { return }
        let body = try JSONEncoder().encode(OTLPMapper.request(for: batch, serviceName: serviceName))
        var headers = headers
        headers["Content-Type"] = "application/json"
        let (response, responseBody) = try await http.post(url: endpoint, headers: headers, body: body)
        guard (200..<300).contains(response.statusCode) else {
            // Surface a truncated prefix of the body — collectors put the rejection reason there.
            let detail = responseBody.isEmpty ? nil : String(decoding: responseBody.prefix(1024), as: UTF8.self)
            throw OTLPExporterError.httpStatus(response.statusCode, body: detail)
        }
    }
}

public enum OTLPExporterError: Error, Equatable {
    case httpStatus(Int, body: String?)
    case nonHTTPResponse
}

/// The single HTTP call `OTLPExporter` needs — a seam for unit-testing without a network round-trip.
/// Returns the response and its body (the body carries a collector's error detail on a non-2xx).
public protocol HTTPPoster: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> (response: HTTPURLResponse, body: Data)
}

public struct URLSessionPoster: HTTPPoster {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func post(url: URL, headers: [String: String], body: Data) async throws -> (response: HTTPURLResponse, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OTLPExporterError.nonHTTPResponse }
        return (http, data)
    }
}
