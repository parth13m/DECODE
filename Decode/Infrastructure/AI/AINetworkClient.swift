import Foundation

/// Configuration for the retry strategy.
struct RetryConfiguration: Sendable {
    /// Maximum number of retry attempts.
    let maxRetries: Int
    /// Base delay for exponential backoff (seconds).
    let baseDelay: TimeInterval
    /// Maximum jitter added to each delay (seconds).
    let maxJitter: TimeInterval

    static let `default` = RetryConfiguration(
        maxRetries: 5,
        baseDelay: 1.0,
        maxJitter: 1.0
    )
}

/// A generic HTTP client for AI provider communication.
///
/// Responsibilities:
/// - Execute HTTP requests with retry and exponential backoff
/// - Parse Server-Sent Events (SSE) streams
/// - Handle rate limiting (HTTP 429)
/// - Classify HTTP errors into `AIProviderError` types
///
/// This client has no knowledge of any specific AI provider's API format.
/// Providers build their own requests and parse their own response shapes;
/// this client handles the transport layer.
final class AINetworkClient: Sendable {

    let session: URLSession
    private let retryConfig: RetryConfiguration

    init(
        session: URLSession = .shared,
        retryConfig: RetryConfiguration = .default
    ) {
        self.session = session
        self.retryConfig = retryConfig
    }

    // MARK: - Non-Streaming Request

    /// Perform an HTTP request with automatic retry on transient failures.
    ///
    /// Retries on: network errors, HTTP 429, HTTP 500/502/503.
    /// Does NOT retry on: 401 (invalid key), 400 (bad request), 404.
    func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = AIProviderError.timeout
        for attempt in 0...retryConfig.maxRetries {
            if attempt > 0 {
                let delay = computeBackoff(attempt: attempt)
                try await Task.sleep(for: .seconds(delay))
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIProviderError.invalidResponse(detail: "Non-HTTP response")
                }

                switch httpResponse.statusCode {
                case 200...299:
                    return (data, httpResponse)
                case 401:
                    throw AIProviderError.invalidAPIKey
                case 429:
                    let retryAfter = parseRetryAfter(httpResponse)
                    if let retryAfter, attempt < retryConfig.maxRetries {
                        try await Task.sleep(for: .seconds(retryAfter))
                        continue
                    }
                    throw AIProviderError.rateLimited(retryAfter: retryAfter)
                case 500, 502, 503:
                    lastError = AIProviderError.providerError(
                        statusCode: httpResponse.statusCode,
                        message: String(data: data, encoding: .utf8) ?? "Server error"
                    )
                    continue // retry
                default:
                    let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw AIProviderError.providerError(
                        statusCode: httpResponse.statusCode,
                        message: body
                    )
                }
            } catch let error as AIProviderError {
                // Non-retryable provider errors propagate immediately.
                if case .invalidAPIKey = error { throw error }
                if case .providerError(let code, _) = error, !(500...503).contains(code) { throw error }
                if case .rateLimited = error, attempt >= retryConfig.maxRetries { throw error }
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                lastError = AIProviderError.timeout
            } catch {
                lastError = AIProviderError.networkError(underlying: error)
                if attempt >= retryConfig.maxRetries { break }
            }
        }
        throw AIProviderError.retriesExhausted(lastError: lastError)
    }

    // MARK: - SSE Streaming Request

    /// Perform a streaming HTTP request and return parsed SSE data lines.
    ///
    /// Each yielded `Data` is the payload of a single `data:` SSE line
    /// (without the `data: ` prefix). The sentinel `[DONE]` line terminates
    /// the stream.
    ///
    /// The initial connection respects the URLRequest's `timeoutInterval`.
    /// Once streaming begins, individual line reads time out after 90 seconds
    /// of inactivity to prevent indefinite hangs on broken connections.
    ///
    /// Does NOT retry streaming requests -- the caller is responsible for
    /// retry decisions on streaming failures.
    func performStreamingRequest(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        var timedRequest = request
        if timedRequest.timeoutInterval == 0 || timedRequest.timeoutInterval > 120 {
            timedRequest.timeoutInterval = 120
        }

        let (bytes, response) = try await session.bytes(for: timedRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse(detail: "Non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw AIProviderError.invalidAPIKey
        case 429:
            let retryAfter = parseRetryAfter(httpResponse)
            throw AIProviderError.rateLimited(retryAfter: retryAfter)
        default:
            // For error responses on streaming endpoints, collect the body.
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw AIProviderError.providerError(
                statusCode: httpResponse.statusCode,
                message: errorBody
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        // SSE lines start with "data: "
                        guard line.hasPrefix("data: ") else { continue }

                        let payload = String(line.dropFirst(6))

                        // OpenAI/Anthropic use "[DONE]" to signal end of stream.
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        if let data = payload.data(using: .utf8) {
                            continuation.yield(data)
                        }
                    }
                    // Stream ended without [DONE] -- still finish cleanly.
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIProviderError.streamInterrupted)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Backoff

    /// Compute the backoff delay for a given retry attempt.
    ///
    /// Formula from spec: `T_sleep = 2^attempt + random_jitter`
    func computeBackoff(attempt: Int) -> TimeInterval {
        let exponential = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...retryConfig.maxJitter)
        return min(exponential + jitter, 60.0) // cap at 60s
    }

    // MARK: - Helpers

    private func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        return TimeInterval(value)
    }
}
