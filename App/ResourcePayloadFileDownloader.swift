import CryptoKit
import Foundation

struct ResourcePayloadFileDownloader: Sendable {
    typealias ConfigurationFactory = @Sendable (ResourcePayloadDownloadPolicy)
        -> URLSessionConfiguration
    typealias ProgressSink = @Sendable (ResourcePayloadDownloadProgress) -> Void

    private let stagingStore: ResourcePayloadStagingStore
    private let configurationFactory: ConfigurationFactory

    init(stagingStore: ResourcePayloadStagingStore = ResourcePayloadStagingStore(),
         configurationFactory: ConfigurationFactory? = nil) {
        self.stagingStore = stagingStore
        self.configurationFactory = configurationFactory ?? { policy in
            Self.ephemeralConfiguration(policy: policy)
        }
    }

    func download(plan: ResourcePayloadDownloadPlan,
                  progress: @escaping ProgressSink = { _ in }) async throws
        -> VerifiedPayloadStagingResult {
        let urlPolicy: ResourceNetworkURLPolicy
        do {
            urlPolicy = try ResourceNetworkURLPolicy(pinnedAllowedHosts: plan.allowedHosts)
            _ = try urlPolicy.validate(plan.downloadURL)
        } catch {
            throw ResourcePayloadDownloadError.disallowedHost
        }

        let operation = try stagingStore.prepare(plan: plan)
        progress(ResourcePayloadDownloadProgress(
            operationID: operation.operationID,
            receivedBytes: 0,
            expectedBytes: plan.expectedBytes,
            phase: .preparing
        ))
        let delegate = ResourcePayloadDownloadDelegate(
            plan: plan,
            urlPolicy: urlPolicy,
            operation: operation,
            progress: progress
        )
        let queue = OperationQueue()
        queue.name = "LocalDictionary.ResourcePayloadDownload"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(
            configuration: configurationFactory(plan.policy),
            delegate: delegate,
            delegateQueue: queue
        )
        do {
            let result = try await delegate.perform(
                session: session,
                request: Self.request(for: plan.downloadURL, policy: plan.policy)
            )
            session.finishTasksAndInvalidate()
            return result
        } catch let error as ResourcePayloadDownloadError {
            session.invalidateAndCancel()
            throw error
        } catch is CancellationError {
            session.invalidateAndCancel()
            throw ResourcePayloadDownloadError.cancelled
        } catch {
            session.invalidateAndCancel()
            throw ResourcePayloadDownloadError.transportFailure
        }
    }

    static func ephemeralConfiguration(policy: ResourcePayloadDownloadPolicy)
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
                                    policy: ResourcePayloadDownloadPolicy) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: policy.requestTimeout
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

/// URLSession uses a serial delegate queue; Swift cancellation may arrive concurrently. Every
/// mutable lifecycle field, the file descriptor capability, and the incremental SHA state are
/// accessed only while `lock` is held. No mutable state escapes this object.
private final class ResourcePayloadDownloadDelegate: NSObject,
    URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let plan: ResourcePayloadDownloadPlan
    private let urlPolicy: ResourceNetworkURLPolicy
    private let operation: ResourcePayloadStagingOperation
    private let progress: ResourcePayloadFileDownloader.ProgressSink
    private let lock = NSLock()

    private var continuation: CheckedContinuation<VerifiedPayloadStagingResult, Error>?
    private var task: URLSessionDataTask?
    private var hasher = SHA256()
    private var receivedBytes: UInt64 = 0
    private var responseAccepted = false
    private var completed = false
    private var cancellationRequested = false
    private var redirectCount = 0
    private var visitedURLs: Set<String>

    init(plan: ResourcePayloadDownloadPlan,
         urlPolicy: ResourceNetworkURLPolicy,
         operation: ResourcePayloadStagingOperation,
         progress: @escaping ResourcePayloadFileDownloader.ProgressSink) {
        self.plan = plan
        self.urlPolicy = urlPolicy
        self.operation = operation
        self.progress = progress
        visitedURLs = [urlPolicy.canonicalIdentifier(for: plan.downloadURL)]
    }

    func perform(session: URLSession, request: URLRequest) async throws
        -> VerifiedPayloadStagingResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(session: session, request: request, continuation: continuation)
            }
        } onCancel: {
            finish(.failure(ResourcePayloadDownloadError.cancelled), cancelTask: true)
        }
    }

    private func begin(
        session: URLSession,
        request: URLRequest,
        continuation: CheckedContinuation<VerifiedPayloadStagingResult, Error>
    ) {
        let dataTask = session.dataTask(with: request)
        lock.lock()
        if cancellationRequested || completed {
            lock.unlock()
            operation.cleanup()
            continuation.resume(throwing: ResourcePayloadDownloadError.cancelled)
            dataTask.cancel()
            return
        }
        self.continuation = continuation
        task = dataTask
        lock.unlock()
        dataTask.resume()
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
                throw ResourcePayloadDownloadError.invalidResponse
            }
            let target: URL
            do {
                target = try urlPolicy.validateRedirect(
                    location: location,
                    relativeTo: responseURL,
                    proposedRequest: request,
                    statusCode: response.statusCode
                )
            } catch let error as ResourceNetworkError {
                if error == .tooManyRedirects {
                    throw ResourcePayloadDownloadError.invalidResponse
                }
                throw ResourcePayloadDownloadError.disallowedHost
            }
            let identity = urlPolicy.canonicalIdentifier(for: target)
            lock.lock()
            let inactive = completed || cancellationRequested
            let tooMany = redirectCount >= plan.policy.maximumRedirects
            let loop = visitedURLs.contains(identity)
            if !inactive, !tooMany, !loop {
                redirectCount += 1
                visitedURLs.insert(identity)
            }
            lock.unlock()
            guard !inactive, !tooMany, !loop else {
                throw ResourcePayloadDownloadError.invalidResponse
            }
            completionHandler(ResourcePayloadFileDownloader.request(
                for: target,
                policy: plan.policy
            ))
        } catch let error as ResourcePayloadDownloadError {
            completionHandler(nil)
            finish(.failure(error), cancelTask: true)
        } catch {
            completionHandler(nil)
            finish(.failure(ResourcePayloadDownloadError.invalidResponse), cancelTask: true)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse,
                  let responseURL = http.url else {
                throw ResourcePayloadDownloadError.invalidResponse
            }
            do {
                _ = try urlPolicy.validate(responseURL)
            } catch {
                throw ResourcePayloadDownloadError.disallowedHost
            }
            guard http.statusCode == 200 else {
                throw ResourcePayloadDownloadError.unacceptableStatus(http.statusCode)
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding?.isEmpty == true || encoding == "identity" else {
                throw ResourcePayloadDownloadError.unsupportedContentEncoding
            }
            guard Self.acceptsContentType(http.value(forHTTPHeaderField: "Content-Type")) else {
                throw ResourcePayloadDownloadError.unsupportedContentType
            }
            if let rawLength = http.value(forHTTPHeaderField: "Content-Length") {
                let trimmed = rawLength.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = UInt64(trimmed) else {
                    throw ResourcePayloadDownloadError.invalidResponse
                }
                guard length <= plan.maximumBytes else {
                    throw ResourcePayloadDownloadError.responseTooLarge
                }
                guard length == plan.expectedBytes else {
                    throw ResourcePayloadDownloadError.sizeMismatch
                }
            }
            lock.lock()
            let allowed = !completed && !cancellationRequested
            if allowed { responseAccepted = true }
            lock.unlock()
            completionHandler(allowed ? .allow : .cancel)
            if allowed {
                progress(ResourcePayloadDownloadProgress(
                    operationID: operation.operationID,
                    receivedBytes: 0,
                    expectedBytes: plan.expectedBytes,
                    phase: .downloading
                ))
            }
        } catch let error as ResourcePayloadDownloadError {
            completionHandler(.cancel)
            finish(.failure(error), cancelTask: true)
        } catch {
            completionHandler(.cancel)
            finish(.failure(ResourcePayloadDownloadError.invalidResponse), cancelTask: true)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        var event: ResourcePayloadDownloadProgress?
        var failure: ResourcePayloadDownloadError?
        lock.lock()
        if !completed, !cancellationRequested {
            let count = UInt64(data.count)
            let addition = receivedBytes.addingReportingOverflow(count)
            if addition.overflow || addition.partialValue > plan.maximumBytes {
                failure = .responseTooLarge
            } else if addition.partialValue > plan.expectedBytes {
                failure = .sizeMismatch
            } else {
                do {
                    try operation.write(data)
                    hasher.update(data: data)
                    receivedBytes = addition.partialValue
                    event = ResourcePayloadDownloadProgress(
                        operationID: operation.operationID,
                        receivedBytes: receivedBytes,
                        expectedBytes: plan.expectedBytes,
                        phase: .downloading
                    )
                } catch let error as ResourcePayloadDownloadError {
                    failure = error == .stagingFailure ? .writeFailure : error
                } catch {
                    failure = .writeFailure
                }
            }
        }
        lock.unlock()
        if let failure {
            finish(.failure(failure), cancelTask: true)
        } else if let event {
            progress(event)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(Self.safeTransportError(error)), cancelTask: false)
            return
        }

        lock.lock()
        guard !completed, !cancellationRequested, responseAccepted else {
            lock.unlock()
            finish(.failure(cancellationRequested ? .cancelled : .invalidResponse),
                   cancelTask: false)
            return
        }
        guard receivedBytes == plan.expectedBytes else {
            lock.unlock()
            finish(.failure(.sizeMismatch), cancelTask: false)
            return
        }
        let actualBytes = receivedBytes
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.unlock()

        progress(ResourcePayloadDownloadProgress(
            operationID: operation.operationID,
            receivedBytes: actualBytes,
            expectedBytes: plan.expectedBytes,
            phase: .verifying
        ))
        guard digest == plan.expectedSHA256 else {
            finish(.failure(.hashMismatch), cancelTask: false)
            return
        }

        lock.lock()
        guard !completed, !cancellationRequested else {
            lock.unlock()
            finish(.failure(.cancelled), cancelTask: true)
            return
        }
        lock.unlock()
        progress(ResourcePayloadDownloadProgress(
            operationID: operation.operationID,
            receivedBytes: actualBytes,
            expectedBytes: plan.expectedBytes,
            phase: .publishingToStaging
        ))
        lock.lock()
        guard !completed, !cancellationRequested else {
            lock.unlock()
            finish(.failure(.cancelled), cancelTask: true)
            return
        }
        do {
            try operation.publish()
        } catch let error as ResourcePayloadDownloadError {
            lock.unlock()
            finish(.failure(error), cancelTask: false)
            return
        } catch {
            lock.unlock()
            finish(.failure(.stagingFailure), cancelTask: false)
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        lock.unlock()

        let result = VerifiedPayloadStagingResult(
            resourceID: plan.resourceID,
            resourceRevision: plan.resourceRevision,
            operationID: operation.operationID,
            verifiedFileURL: operation.verifiedFile,
            signedFileName: plan.signedFileName,
            actualByteCount: actualBytes,
            verifiedSHA256: digest
        )
        progress(ResourcePayloadDownloadProgress(
            operationID: operation.operationID,
            receivedBytes: actualBytes,
            expectedBytes: plan.expectedBytes,
            phase: .completed
        ))
        continuation?.resume(returning: result)
    }

    private func finish(_ result: Result<Never, ResourcePayloadDownloadError>,
                        cancelTask: Bool) {
        let continuation: CheckedContinuation<VerifiedPayloadStagingResult, Error>?
        let taskToCancel: URLSessionDataTask?
        let error: ResourcePayloadDownloadError
        switch result {
        case .success:
            return
        case .failure(let failure):
            error = failure
        }
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        if error == .cancelled { cancellationRequested = true }
        continuation = self.continuation
        self.continuation = nil
        taskToCancel = cancelTask ? task : nil
        task = nil
        operation.cleanup()
        lock.unlock()
        taskToCancel?.cancel()
        continuation?.resume(throwing: error)
    }

    private static func acceptsContentType(_ value: String?) -> Bool {
        guard let raw = value?.split(separator: ";", maxSplits: 1).first else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
            "application/octet-stream"
    }

    private static func safeTransportError(_ error: Error) -> ResourcePayloadDownloadError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .transportFailure }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        default: return .transportFailure
        }
    }
}
