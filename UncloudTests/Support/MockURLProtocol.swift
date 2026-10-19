import Foundation

/// A canned HTTP reply for `MockURLProtocol`.
struct MockReply: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    init(status: Int = 200, headers: [String: String] = [:], json: String = "") {
        self.status = status
        self.headers = headers
        body = Data(json.utf8)
    }
}

/// A request as the mock saw it. Copied out, so tests can inspect it without touching URLSession.
struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var path: String { url.path }

    /// The JSON body as a dictionary, or nil when there is none.
    var json: [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// Answers every request from a handler and records it. No network. Tests that use it run `.serialized`,
/// because the handler and the recorded requests are shared process-wide.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (RecordedRequest) throws -> MockReply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    /// Installs the handler and clears the record. Returns a URLSession that uses this protocol only.
    static func install(_ handler: @escaping Handler) -> URLSession {
        lock.lock()
        Self.handler = handler
        recorded = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://invalid.example")!
        let recordedRequest = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.bodyStream(request)
        )
        Self.lock.lock()
        Self.recorded.append(recordedRequest)
        let handler = Self.handler
        Self.lock.unlock()

        do {
            let reply = try handler?(recordedRequest) ?? MockReply(status: 500)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
