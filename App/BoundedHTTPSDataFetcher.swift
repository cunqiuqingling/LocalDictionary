import Foundation

struct BoundedHTTPSDataFetcher: Sendable {
    typealias ConfigurationFactory = @Sendable (ResourceNetworkPolicy) -> URLSessionConfiguration

    let policy: ResourceNetworkPolicy
    private let configurationFactory: ConfigurationFactory

    init(policy: ResourceNetworkPolicy,
         configurationFactory: ConfigurationFactory? = nil) {
        self.policy = policy
        self.configurationFactory = configurationFactory ?? { policy in
            Self.ephemeralConfiguration(policy: policy)
        }
    }

    func fetch(_ url: URL,
               kind: ResourceNetworkPayloadKind,
               urlPolicy: ResourceNetworkURLPolicy) async throws -> Data {
        let validatedURL = try urlPolicy.validate(url)
        let byteLimit = kind == .signature
            ? policy.maximumSignatureBytes : policy.maximumManifestBytes
        let delegate = BoundedHTTPSRequestDelegate(
            kind: kind,
            byteLimit: byteLimit,
            networkPolicy: policy,
            urlPolicy: urlPolicy,
            initialURL: validatedURL
        )
        let queue = OperationQueue()
        queue.name = "LocalDictionary.ResourceManifestFetch"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(
            configuration: configurationFactory(policy),
            delegate: delegate,
            delegateQueue: queue
        )
        do {
            let data = try await delegate.perform(
                session: session,
                request: Self.request(
                    for: validatedURL,
                    kind: kind,
                    timeout: policy.requestTimeout
                )
            )
            session.finishTasksAndInvalidate()
            return data
        } catch {
            session.invalidateAndCancel()
            if let error = error as? ResourceNetworkError { throw error }
            if error is CancellationError { throw ResourceNetworkError.cancelled }
            throw ResourceNetworkError.transportFailure
        }
    }

    static func ephemeralConfiguration(policy: ResourceNetworkPolicy)
        -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = policy.requestTimeout
        configuration.timeoutIntervalForResource = policy.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    fileprivate static func request(for url: URL,
                                    kind: ResourceNetworkPayloadKind,
                                    timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(kind.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

/// URLSession invokes delegate callbacks from its serial delegate queue, while Swift Task
/// cancellation can arrive from another executor. Every mutable field below is protected by
/// `lock`; no buffer or continuation escapes the lock-protected state.
private final class BoundedHTTPSRequestDelegate: NSObject,
    URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let kind: ResourceNetworkPayloadKind
    private let byteLimit: Int
    private let networkPolicy: ResourceNetworkPolicy
    private let urlPolicy: ResourceNetworkURLPolicy
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var responseAccepted = false
    private var completed = false
    private var cancellationRequested = false
    private var redirectCount = 0
    private var visitedURLs: Set<String>

    init(kind: ResourceNetworkPayloadKind,
         byteLimit: Int,
         networkPolicy: ResourceNetworkPolicy,
         urlPolicy: ResourceNetworkURLPolicy,
         initialURL: URL) {
        self.kind = kind
        self.byteLimit = byteLimit
        self.networkPolicy = networkPolicy
        self.urlPolicy = urlPolicy
        visitedURLs = [urlPolicy.canonicalIdentifier(for: initialURL)]
    }

    func perform(session: URLSession, request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(session: session, request: request, continuation: continuation)
            }
        } onCancel: {
            cancelFromSwiftTask()
        }
    }

    private func begin(session: URLSession,
                       request: URLRequest,
                       continuation: CheckedContinuation<Data, Error>) {
        let dataTask = session.dataTask(with: request)
        lock.lock()
        if cancellationRequested || completed {
            lock.unlock()
            continuation.resume(throwing: ResourceNetworkError.cancelled)
            dataTask.cancel()
            return
        }
        self.continuation = continuation
        task = dataTask
        lock.unlock()
        dataTask.resume()
    }

    private func cancelFromSwiftTask() {
        finish(.failure(ResourceNetworkError.cancelled), cancelTask: true)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            guard [301, 302, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let responseURL = response.url else {
                throw ResourceNetworkError.redirectRejected
            }
            let target = try urlPolicy.validateRedirect(
                location: location,
                relativeTo: responseURL,
                proposedRequest: request,
                statusCode: response.statusCode
            )
            let identifier = urlPolicy.canonicalIdentifier(for: target)
            lock.lock()
            let inactive = completed
            let tooMany = redirectCount >= networkPolicy.maximumRedirects
            let redirectLoop = visitedURLs.contains(identifier)
            let rejectedForState = inactive || tooMany || redirectLoop
            if !rejectedForState {
                redirectCount += 1
                visitedURLs.insert(identifier)
            }
            lock.unlock()
            guard !rejectedForState else {
                throw (!inactive && tooMany) ? ResourceNetworkError.tooManyRedirects
                    : ResourceNetworkError.redirectRejected
            }
            completionHandler(BoundedHTTPSDataFetcher.request(
                for: target,
                kind: kind,
                timeout: networkPolicy.requestTimeout
            ))
        } catch let error as ResourceNetworkError {
            completionHandler(nil)
            finish(.failure(error), cancelTask: true)
        } catch {
            completionHandler(nil)
            finish(.failure(ResourceNetworkError.redirectRejected), cancelTask: true)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse,
                  let responseURL = http.url else {
                throw ResourceNetworkError.invalidResponse
            }
            _ = try urlPolicy.validate(responseURL)
            guard http.statusCode == 200 else {
                throw ResourceNetworkError.unacceptableStatus(http.statusCode)
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding?.isEmpty == true || encoding == "identity" else {
                throw ResourceNetworkError.unsupportedContentEncoding
            }
            guard kind.accepts(contentType: http.value(forHTTPHeaderField: "Content-Type")) else {
                throw ResourceNetworkError.unsupportedContentType
            }
            let expectedLength = response.expectedContentLength
            guard expectedLength < 0 || expectedLength <= Int64(byteLimit) else {
                throw ResourceNetworkError.responseTooLarge
            }
            lock.lock()
            if !completed { responseAccepted = true }
            let shouldAllow = !completed
            lock.unlock()
            completionHandler(shouldAllow ? .allow : .cancel)
        } catch let error as ResourceNetworkError {
            completionHandler(.cancel)
            finish(.failure(error), cancelTask: true)
        } catch {
            completionHandler(.cancel)
            finish(.failure(ResourceNetworkError.invalidResponse), cancelTask: true)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        guard !completed, !cancellationRequested else {
            lock.unlock()
            return
        }
        let addition = buffer.count.addingReportingOverflow(data.count)
        guard !addition.overflow, addition.partialValue <= byteLimit else {
            lock.unlock()
            finish(.failure(ResourceNetworkError.responseTooLarge), cancelTask: true)
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(Self.safeTransportError(error)), cancelTask: false)
            return
        }
        lock.lock()
        let accepted = responseAccepted
        lock.unlock()
        guard accepted else {
            finish(.failure(ResourceNetworkError.invalidResponse), cancelTask: false)
            return
        }
        finish(.success(()), cancelTask: false)
    }

    private func finish(_ result: Result<Void, Error>, cancelTask: Bool) {
        let continuation: CheckedContinuation<Data, Error>?
        let taskToCancel: URLSessionDataTask?
        let received: Data
        lock.lock()
        if completed {
            if case .failure(let error) = result,
               (error as? ResourceNetworkError) == .cancelled {
                cancellationRequested = true
            }
            lock.unlock()
            return
        }
        completed = true
        if case .failure(let error) = result,
           (error as? ResourceNetworkError) == .cancelled {
            cancellationRequested = true
        }
        continuation = self.continuation
        self.continuation = nil
        taskToCancel = cancelTask ? task : nil
        task = nil
        received = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        taskToCancel?.cancel()
        switch result {
        case .success:
            continuation?.resume(returning: received)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private static func safeTransportError(_ error: Error) -> ResourceNetworkError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .transportFailure }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default: return .transportFailure
        }
    }
}
