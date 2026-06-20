import Foundation

/// A mock URLProtocol for intercepting HTTP requests in tests.
///
/// Configure via the static `requestHandler` before creating a URLSession
/// that uses this protocol. Tests using this mock should be in `@Suite(.serialized)`
/// to avoid cross-test interference on the shared static handler.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// Handler called for each intercepted request.
    /// Returns the response data and HTTP response.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Create a URLSession configured to use this mock protocol.
    static func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Reset handler between tests.
    static func reset() {
        requestHandler = nil
    }

    /// Extract the HTTP body from a request, reading from `httpBodyStream`
    /// if `httpBody` is nil (which happens when URLSession sends through URLProtocol).
    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
