import CryptoKit
import Foundation

private struct NetworkTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct NetworkHarness {
    private(set) var passed = 0

    mutating func recordPass() { passed += 1 }

    mutating func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
        guard condition() else { throw NetworkTestFailure(message: name) }
        passed += 1
    }

    mutating func expectNetworkError(
        _ name: String,
        _ expected: ResourceNetworkError,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw NetworkTestFailure(message: "\(name): unexpectedly succeeded")
        } catch let error as ResourceNetworkError {
            guard error == expected else {
                throw NetworkTestFailure(message: "\(name): wrong error \(error)")
            }
            passed += 1
        }
    }

    mutating func expectEndpointFailure(_ name: String,
                                        operation: () throws -> Void) throws {
        do {
            try operation()
            throw NetworkTestFailure(message: "\(name): unexpectedly succeeded")
        } catch let error as ResourceNetworkError {
            guard error == .invalidEndpoint else {
                throw NetworkTestFailure(message: "\(name): wrong error \(error)")
            }
            passed += 1
        }
    }
}

private struct FixedNetworkClock: ManifestClock {
    let value: Date
    func now() -> Date { value }
}

private struct CapturedRequest: Equatable, Sendable {
    let url: String
    let method: String?
    let headers: [String: String]
    let hasBody: Bool
}

private enum MockResponsePlan: Sendable {
    case response(status: Int, headers: [String: String], chunks: [Data], finalURL: String?)
    case redirect(status: Int, location: String)
    case nonHTTP(chunks: [Data])
    case failure(code: Int)
    case stall(headers: [String: String], chunks: [Data])
}

/// Tests only. All shared mutable transport state is protected by `lock` and snapshots are
/// returned by value. No production code references this type.
private final class MockTransportStore: @unchecked Sendable {
    private let lock = NSLock()
    private var plansByURL: [String: [MockResponsePlan]] = [:]
    private var capturedRequests: [CapturedRequest] = []
    private var stopCount = 0

    func reset(_ plans: [String: [MockResponsePlan]]) {
        lock.withLock {
            plansByURL = plans
            capturedRequests = []
            stopCount = 0
        }
    }

    func takePlan(for request: URLRequest) -> MockResponsePlan? {
        lock.withLock {
            let headers = request.allHTTPHeaderFields ?? [:]
            capturedRequests.append(CapturedRequest(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod,
                headers: headers,
                hasBody: request.httpBody != nil || request.httpBodyStream != nil
            ))
            guard let key = request.url?.absoluteString,
                  var plans = plansByURL[key],
                  !plans.isEmpty else { return nil }
            let plan = plans.removeFirst()
            plansByURL[key] = plans
            return plan
        }
    }

    func recordStop() { lock.withLock { stopCount += 1 } }

    func snapshot() -> (requests: [CapturedRequest], stopCount: Int) {
        lock.withLock { (capturedRequests, stopCount) }
    }
}

private final class MockManifestURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = MockTransportStore()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let plan = Self.store.takePlan(for: request),
              let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        switch plan {
        case .response(let status, let headers, let chunks, let finalURL):
            let responseURL = finalURL.flatMap(URL.init(string:)) ?? requestURL
            guard let response = HTTPURLResponse(
                url: responseURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let location):
            guard let target = URL(string: location, relativeTo: requestURL)?.absoluteURL,
                  let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            var redirected = URLRequest(url: target)
            redirected.httpMethod = "GET"
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        case .nonHTTP(let chunks):
            let response = URLResponse(
                url: requestURL,
                mimeType: "application/octet-stream",
                expectedContentLength: -1,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
        case .stall(let headers, let chunks):
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        }
    }

    override func stopLoading() { Self.store.recordStop() }
}

/// Tests only. The lock protects the counter and byte snapshots. The wrapped verifier is an
/// immutable Sendable value and performs the real D1b-1 verification.
private final class RecordingVerifier: ResourceManifestPreparing, @unchecked Sendable {
    let manifestVerificationPolicy: ManifestVerificationPolicy
    private let verifier: ResourceManifestVerifier
    private let lock = NSLock()
    private var calls = 0
    private var signatureSnapshot = Data()
    private var manifestSnapshot = Data()

    init(_ verifier: ResourceManifestVerifier) {
        self.verifier = verifier
        manifestVerificationPolicy = verifier.policy
    }

    func prepareVerification(signatureBytes: Data,
                             manifestBytes: Data,
                             priorState: VerifiedManifestState?) throws
        -> PreparedManifestVerification {
        lock.withLock {
            calls += 1
            signatureSnapshot = signatureBytes
            manifestSnapshot = manifestBytes
        }
        return try verifier.prepareVerification(
            signatureBytes: signatureBytes,
            manifestBytes: manifestBytes,
            priorState: priorState
        )
    }

    func snapshot() -> (calls: Int, signature: Data, manifest: Data) {
        lock.withLock { (calls, signatureSnapshot, manifestSnapshot) }
    }
}

private let testKeyID = "TEST-ONLY-d1b2a-network"
private let signatureURL = "https://manifest.example.test/resources.sig"
private let manifestURL = "https://manifest.example.test/resources.json"

private func fixedDate(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.isLenient = false
    return formatter.date(from: value)!
}

private func manifestBytes() -> Data {
    Data("""
    {
      "schemaVersion":1,
      "manifestVersion":1,
      "issuedAt":"2030-01-01T00:00:00Z",
      "expiresAt":"2030-02-01T00:00:00Z",
      "keyID":"\(testKeyID)",
      "minimumAppVersion":"1.0.0",
      "resources":[],
      "revokedResources":[]
    }
    """.utf8)
}

private func makeVerificationPolicy(maximumManifestBytes: Int = 1_048_576,
                                    maximumSignatureBytes: Int = 4_096) throws
    -> ManifestVerificationPolicy {
    var policy = ManifestVerificationPolicy(currentAppVersion: try ManifestAppVersion("1.0.0"))
    policy.maximumManifestBytes = maximumManifestBytes
    policy.maximumSignatureBytes = maximumSignatureBytes
    return policy
}

private func makeVerifier(privateKey: Curve25519.Signing.PrivateKey,
                          policy: ManifestVerificationPolicy? = nil) throws
    -> ResourceManifestVerifier {
    let trustedKey = try TrustedManifestKey(
        keyID: testKeyID,
        publicKeyBytes: privateKey.publicKey.rawRepresentation
    )
    return ResourceManifestVerifier(
        trustStore: try TrustedManifestKeyStore(keys: [trustedKey]),
        policy: try policy ?? makeVerificationPolicy(),
        clock: FixedNetworkClock(value: fixedDate("2030-01-15T00:00:00Z"))
    )
}

private func signedEnvelope(_ manifest: Data,
                            privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
    try ResourceManifestSignatureEnvelope(
        keyID: testKeyID,
        signature: privateKey.signature(for: manifest)
    ).serialized()
}

private let mockConfiguration: BoundedHTTPSDataFetcher.ConfigurationFactory = { policy in
    let configuration = BoundedHTTPSDataFetcher.ephemeralConfiguration(policy: policy)
    configuration.protocolClasses = [MockManifestURLProtocol.self]
    return configuration
}

private func makeEndpoint(hosts: [String] = ["manifest.example.test"]) throws
    -> ResourceManifestEndpoint {
    try ResourceManifestEndpoint(
        manifestURL: manifestURL,
        signatureURL: signatureURL,
        pinnedAllowedHosts: hosts
    )
}

private func response(headers: [String: String], chunks: [Data], status: Int = 200,
                      finalURL: String? = nil) -> MockResponsePlan {
    .response(status: status, headers: headers, chunks: chunks, finalURL: finalURL)
}

private func waitForRequestCount(_ expected: Int) async throws {
    for _ in 0..<100 {
        if MockManifestURLProtocol.store.snapshot().requests.count >= expected { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw NetworkTestFailure(message: "transport did not receive \(expected) requests")
}

private func waitForStopCount(_ expected: Int) async throws {
    for _ in 0..<100 {
        if MockManifestURLProtocol.store.snapshot().stopCount >= expected { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw NetworkTestFailure(message: "transport did not observe cancellation")
}

@main
private struct ResourceManifestNetworkSmoke {
    static func main() async throws {
        var harness = NetworkHarness()
        try testURLPolicy(&harness)
        try testConfiguration(&harness)
        try await testSuccessfulLoader(&harness)
        try await testSizeLimits(&harness)
        try await testHTTPPolicy(&harness)
        try await testRedirects(&harness)
        try await testCancellationAndConcurrency(&harness)
        try await testCookiesAndCache(&harness)
        try testProductionBoundaries(&harness)
        print("Resource manifest network smoke passed (\(harness.passed) checks)")
    }

    private static func testURLPolicy(_ harness: inout NetworkHarness) throws {
        let policy = try ResourceNetworkURLPolicy(pinnedAllowedHosts: [
            "Manifest.Example.Test", "cdn.example.test", "xn--bcher-kva.example"
        ])
        try harness.check("allowlist normalized", policy.pinnedAllowedHosts == [
            "cdn.example.test", "manifest.example.test", "xn--bcher-kva.example"
        ])
        let normalized = try policy.validateInitialURL(
            "HTTPS://MANIFEST.EXAMPLE.TEST/resources.json?channel=stable"
        )
        try harness.check("uppercase scheme and host accepted",
                          normalized.host?.lowercased() == "manifest.example.test")
        try harness.check("query preserved", normalized.query == "channel=stable")
        _ = try policy.validateInitialURL("https://xn--bcher-kva.example/resources.json")
        try harness.check("punycode accepted", true)

        let invalidURLs = [
            "http://manifest.example.test/resources.json",
            "ftp://manifest.example.test/resources.json",
            "file:///synthetic/resources.json",
            "data:application/json,{}",
            "https://user@manifest.example.test/resources.json",
            "https://user:pass@manifest.example.test/resources.json",
            "https://manifest.example.test/resources.json#fragment",
            "https://manifest.example.test.:443/resources.json",
            "https://localhost/resources.json",
            "https://127.0.0.1/resources.json",
            "https://2130706433/resources.json",
            "https://0177.0.0.1/resources.json",
            "https://[::1]/resources.json",
            "https://[::ffff:127.0.0.1]/resources.json",
            "https://manifest.example.test:8443/resources.json",
            "https://example.com.evil.test/resources.json",
            "https://%6danifest.example.test/resources.json",
            "https://例子.example/resources.json",
            "javascript:alert(1)",
            "//manifest.example.test/resources.json",
            "resources.json"
        ]
        for value in invalidURLs {
            try harness.expectEndpointFailure("initial URL rejected: \(value)") {
                _ = try ResourceManifestEndpoint(
                    manifestURL: value,
                    signatureURL: signatureURL,
                    pinnedAllowedHosts: ["manifest.example.test"]
                )
            }
        }
        let invalidHosts = [
            [], ["localhost"], ["127.0.0.1"], ["2130706433"], ["::1"],
            ["manifest.example.test."], ["例子.example"]
        ]
        for hosts in invalidHosts {
            try harness.expectEndpointFailure("allowlist host rejected") {
                _ = try ResourceManifestEndpoint(
                    manifestURL: manifestURL,
                    signatureURL: signatureURL,
                    pinnedAllowedHosts: hosts
                )
            }
        }

        let responseURL = URL(string: "https://manifest.example.test/start")!
        let safeTarget = URL(string: "https://cdn.example.test/next")!
        var safeRequest = URLRequest(url: safeTarget)
        safeRequest.httpMethod = "GET"
        let redirected = try policy.validateRedirect(
            location: "https://cdn.example.test/next",
            relativeTo: responseURL,
            proposedRequest: safeRequest,
            statusCode: 302
        )
        try harness.check("allowed cross-host redirect", redirected == safeTarget)
        for status in [301, 302, 307, 308] {
            _ = try policy.validateRedirect(
                location: "/next",
                relativeTo: responseURL,
                proposedRequest: URLRequest(
                    url: URL(string: "https://manifest.example.test/next")!
                ),
                statusCode: status
            )
            try harness.check("allowed redirect status \(status)", true)
        }
        let rejectedRedirects: [(String, URL, Int)] = [
            ("https://evil.example.test/next", URL(string: "https://evil.example.test/next")!, 302),
            ("http://manifest.example.test/next", URL(string: "http://manifest.example.test/next")!, 302),
            ("https://user@manifest.example.test/next", URL(string: "https://user@manifest.example.test/next")!, 302),
            ("https://manifest.example.test/next#x", URL(string: "https://manifest.example.test/next#x")!, 302),
            ("https://127.0.0.1/next", URL(string: "https://127.0.0.1/next")!, 302),
            ("https://[::1]/next", URL(string: "https://[::1]/next")!, 302),
            ("https://manifest.example.test:8443/next", URL(string: "https://manifest.example.test:8443/next")!, 302),
            ("https://manifest.example.test/next", URL(string: "https://manifest.example.test/next")!, 303)
        ]
        for (location, target, status) in rejectedRedirects {
            var request = URLRequest(url: target)
            request.httpMethod = "GET"
            do {
                _ = try policy.validateRedirect(
                    location: location,
                    relativeTo: responseURL,
                    proposedRequest: request,
                    statusCode: status
                )
                throw NetworkTestFailure(message: "unsafe redirect accepted: \(location)")
            } catch is ResourceNetworkError {
                harness.recordPass()
            }
        }
        var post = URLRequest(url: URL(string: "https://manifest.example.test/next")!)
        post.httpMethod = "POST"
        post.httpBody = Data("x".utf8)
        do {
            _ = try policy.validateRedirect(
                location: "/next",
                relativeTo: responseURL,
                proposedRequest: post,
                statusCode: 302
            )
            throw NetworkTestFailure(message: "POST redirect accepted")
        } catch is ResourceNetworkError {
            harness.recordPass()
        }
    }

    private static func testConfiguration(_ harness: inout NetworkHarness) throws {
        let verificationPolicy = try makeVerificationPolicy(
            maximumManifestBytes: 1234,
            maximumSignatureBytes: 9000
        )
        let policy = try ResourceNetworkPolicy(
            verificationPolicy: verificationPolicy,
            maximumRedirects: 5,
            requestTimeout: 7,
            resourceTimeout: 11
        )
        try harness.check("signature policy capped at 4 KiB",
                          policy.maximumSignatureBytes == 4096)
        try harness.check("manifest policy inherited", policy.maximumManifestBytes == 1234)
        try harness.check("redirect cap configured", policy.maximumRedirects == 5)
        let configuration = BoundedHTTPSDataFetcher.ephemeralConfiguration(policy: policy)
        try harness.check("ephemeral cache absent", configuration.urlCache == nil)
        try harness.check("reload ignoring cache",
                          configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        try harness.check("cookie store absent", configuration.httpCookieStorage == nil)
        try harness.check("cookies disabled", !configuration.httpShouldSetCookies)
        try harness.check("cookie acceptance disabled",
                          configuration.httpCookieAcceptPolicy == .never)
        try harness.check("credential store absent", configuration.urlCredentialStorage == nil)
        try harness.check("waits for connectivity disabled", !configuration.waitsForConnectivity)
        try harness.check("one connection per host",
                          configuration.httpMaximumConnectionsPerHost == 1)
        try harness.check("not a background session", configuration.identifier == nil)
        try harness.check("request timeout applied", configuration.timeoutIntervalForRequest == 7)
        try harness.check("resource timeout applied", configuration.timeoutIntervalForResource == 11)
    }

    private static func testSuccessfulLoader(_ harness: inout NetworkHarness) async throws {
        let key = Curve25519.Signing.PrivateKey()
        let manifest = manifestBytes()
        let signature = try signedEnvelope(manifest, privateKey: key)
        let recording = RecordingVerifier(try makeVerifier(privateKey: key))
        let loader = try ResourceManifestRemoteLoader(
            verifier: recording,
            configurationFactory: mockConfiguration
        )
        MockManifestURLProtocol.store.reset([
            signatureURL: [response(
                headers: ["Content-Type": "application/octet-stream",
                          "Content-Length": String(signature.count)],
                chunks: [signature.prefix(7), signature.dropFirst(7)]
            )],
            manifestURL: [response(
                headers: ["Content-Type": "application/json"],
                chunks: [manifest.prefix(11), manifest.dropFirst(11).prefix(17),
                         manifest.dropFirst(28)]
            )]
        ])
        let prepared = try await loader.fetchAndPrepare(endpoint: makeEndpoint(), priorState: nil)
        try harness.check("prepared manifest version",
                          prepared.verifiedManifest.validated.manifest.manifestVersion == 1)
        let verifierSnapshot = recording.snapshot()
        try harness.check("verifier called once", verifierSnapshot.calls == 1)
        try harness.check("raw signature unchanged", verifierSnapshot.signature == signature)
        try harness.check("raw manifest unchanged", verifierSnapshot.manifest == manifest)
        let requests = MockManifestURLProtocol.store.snapshot().requests
        try harness.check("signature fetched first", requests.map(\.url) == [
            signatureURL, manifestURL
        ])
        try harness.check("GET only", requests.allSatisfy { $0.method == "GET" && !$0.hasBody })
        try harness.check("identity encoding", requests.allSatisfy {
            $0.headers["Accept-Encoding"] == "identity"
        })
        try harness.check("no authorization", requests.allSatisfy {
            $0.headers["Authorization"] == nil
        })
        try harness.check("no cookie", requests.allSatisfy { $0.headers["Cookie"] == nil })
        try harness.check("signature accept header",
                          requests[0].headers["Accept"] == "application/octet-stream")
        try harness.check("manifest accept header",
                          requests[1].headers["Accept"] ==
                            "application/json, application/octet-stream")

        try await harness.expectNetworkError("disabled endpoint", .disabledConfiguration) {
            _ = try await loader.fetchAndPrepare(endpoint: nil, priorState: nil)
        }

        let tamperedManifest = manifest + Data(" ".utf8)
        MockManifestURLProtocol.store.reset([
            signatureURL: [response(
                headers: ["Content-Type": "application/octet-stream"], chunks: [signature]
            )],
            manifestURL: [response(
                headers: ["Content-Type": "application/json"], chunks: [tamperedManifest]
            )]
        ])
        try await harness.expectNetworkError(
            "verification failure remains typed",
            .verificationFailure(.invalidSignature)
        ) {
            _ = try await loader.fetchAndPrepare(endpoint: makeEndpoint(), priorState: nil)
        }
    }

    private static func testSizeLimits(_ harness: inout NetworkHarness) async throws {
        let policy = try ResourceNetworkPolicy(
            verificationPolicy: makeVerificationPolicy(maximumManifestBytes: 64),
            requestTimeout: 1,
            resourceTimeout: 2
        )
        let fetcher = BoundedHTTPSDataFetcher(
            policy: policy,
            configurationFactory: mockConfiguration
        )
        let urlPolicy = try ResourceNetworkURLPolicy(
            pinnedAllowedHosts: ["manifest.example.test"]
        )
        let sigURL = URL(string: signatureURL)!
        let manURL = URL(string: manifestURL)!

        MockManifestURLProtocol.store.reset([
            signatureURL: [response(
                headers: ["Content-Type": "application/octet-stream",
                          "Content-Length": "4097"],
                chunks: []
            )]
        ])
        try await harness.expectNetworkError("signature Content-Length limit", .responseTooLarge) {
            _ = try await fetcher.fetch(sigURL, kind: .signature, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            signatureURL: [response(
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [Data(repeating: 1, count: 3000), Data(repeating: 2, count: 1097)]
            )]
        ])
        try await harness.expectNetworkError("signature streaming limit", .responseTooLarge) {
            _ = try await fetcher.fetch(sigURL, kind: .signature, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            manifestURL: [response(
                headers: ["Content-Type": "application/json", "Content-Length": "65"],
                chunks: []
            )]
        ])
        try await harness.expectNetworkError("manifest Content-Length limit", .responseTooLarge) {
            _ = try await fetcher.fetch(manURL, kind: .manifest, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            manifestURL: [response(
                headers: ["Content-Type": "application/json"],
                chunks: [Data(repeating: 3, count: 40), Data(repeating: 4, count: 25)]
            )]
        ])
        try await harness.expectNetworkError("manifest streaming limit", .responseTooLarge) {
            _ = try await fetcher.fetch(manURL, kind: .manifest, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            manifestURL: [response(
                headers: ["Content-Type": "application/json", "Content-Length": "8"],
                chunks: [Data(repeating: 5, count: 32), Data(repeating: 6, count: 33)]
            )]
        ])
        try await harness.expectNetworkError("forged small Content-Length", .responseTooLarge) {
            _ = try await fetcher.fetch(manURL, kind: .manifest, urlPolicy: urlPolicy)
        }
        let exactly64 = Data(repeating: 7, count: 64)
        MockManifestURLProtocol.store.reset([
            manifestURL: [response(
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [exactly64.prefix(31), exactly64.dropFirst(31)]
            )]
        ])
        let accepted = try await fetcher.fetch(manURL, kind: .manifest, urlPolicy: urlPolicy)
        try harness.check("exact size limit accepted", accepted == exactly64)
        let exactly4096 = Data(repeating: 8, count: 4096)
        MockManifestURLProtocol.store.reset([
            signatureURL: [response(
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [exactly4096.prefix(2048), exactly4096.dropFirst(2048)]
            )]
        ])
        let acceptedSignature = try await fetcher.fetch(
            sigURL,
            kind: .signature,
            urlPolicy: urlPolicy
        )
        try harness.check("exact signature limit accepted", acceptedSignature == exactly4096)

        let key = Curve25519.Signing.PrivateKey()
        let verifier = RecordingVerifier(try makeVerifier(
            privateKey: key,
            policy: makeVerificationPolicy(maximumManifestBytes: 64)
        ))
        let loader = try ResourceManifestRemoteLoader(
            verifier: verifier,
            configurationFactory: mockConfiguration
        )
        let manifest = manifestBytes()
        let signature = try signedEnvelope(manifest, privateKey: key)
        MockManifestURLProtocol.store.reset([
            signatureURL: [response(
                headers: ["Content-Type": "application/octet-stream"], chunks: [signature]
            )],
            manifestURL: [response(
                headers: ["Content-Type": "application/json"], chunks: [manifest]
            )]
        ])
        try await harness.expectNetworkError("network limit prevents verifier", .responseTooLarge) {
            _ = try await loader.fetchAndPrepare(endpoint: makeEndpoint(), priorState: nil)
        }
        try harness.check("verifier not called after network limit",
                          verifier.snapshot().calls == 0)
    }

    private static func testHTTPPolicy(_ harness: inout NetworkHarness) async throws {
        let networkPolicy = try ResourceNetworkPolicy(
            verificationPolicy: makeVerificationPolicy(maximumManifestBytes: 1024),
            requestTimeout: 1,
            resourceTimeout: 2
        )
        let fetcher = BoundedHTTPSDataFetcher(
            policy: networkPolicy,
            configurationFactory: mockConfiguration
        )
        let urlPolicy = try ResourceNetworkURLPolicy(
            pinnedAllowedHosts: ["manifest.example.test"]
        )
        let url = URL(string: manifestURL)!
        for status in [204, 206, 400, 404, 500] {
            MockManifestURLProtocol.store.reset([
                manifestURL: [response(
                    headers: ["Content-Type": "application/json"], chunks: [], status: status
                )]
            ])
            try await harness.expectNetworkError("HTTP \(status) rejected", .unacceptableStatus(status)) {
                _ = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
            }
        }
        for encoding in ["gzip", "br", "deflate"] {
            MockManifestURLProtocol.store.reset([
                manifestURL: [response(
                    headers: ["Content-Type": "application/json",
                              "Content-Encoding": encoding],
                    chunks: [Data("{}".utf8)]
                )]
            ])
            try await harness.expectNetworkError("encoding \(encoding) rejected",
                                                 .unsupportedContentEncoding) {
                _ = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
            }
        }
        for encoding in [nil, "identity"] as [String?] {
            var headers = ["Content-Type": "application/json"]
            if let encoding { headers["Content-Encoding"] = encoding }
            MockManifestURLProtocol.store.reset([
                manifestURL: [response(headers: headers, chunks: [Data("{}".utf8)])]
            ])
            let data = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
            try harness.check("identity or absent encoding accepted", data == Data("{}".utf8))
        }
        for contentType in ["text/plain", "text/html", "application/jsonp"] {
            MockManifestURLProtocol.store.reset([
                manifestURL: [response(
                    headers: ["Content-Type": contentType], chunks: [Data("{}".utf8)]
                )]
            ])
            try await harness.expectNetworkError("content type rejected", .unsupportedContentType) {
                _ = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
            }
        }
        MockManifestURLProtocol.store.reset([
            manifestURL: [.nonHTTP(chunks: [Data("{}".utf8)])]
        ])
        try await harness.expectNetworkError("non HTTP response rejected", .invalidResponse) {
            _ = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            manifestURL: [.failure(code: URLError.timedOut.rawValue)]
        ])
        try await harness.expectNetworkError("timeout classified", .timedOut) {
            _ = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            manifestURL: [.failure(code: URLError.notConnectedToInternet.rawValue)]
        ])
        try await harness.expectNetworkError("transport failure classified", .transportFailure) {
            _ = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            manifestURL: [response(
                headers: ["Content-Type": "application/json"],
                chunks: [Data("{}".utf8)],
                finalURL: "https://evil.example.test/resources.json"
            )]
        ])
        try await harness.expectNetworkError("final URL allowlist enforced", .disallowedHost) {
            _ = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
        }
    }

    private static func testRedirects(_ harness: inout NetworkHarness) async throws {
        let policy = try ResourceNetworkPolicy(
            verificationPolicy: makeVerificationPolicy(maximumManifestBytes: 1024),
            maximumRedirects: 5,
            requestTimeout: 1,
            resourceTimeout: 2
        )
        let fetcher = BoundedHTTPSDataFetcher(policy: policy,
                                              configurationFactory: mockConfiguration)
        let urlPolicy = try ResourceNetworkURLPolicy(pinnedAllowedHosts: [
            "manifest.example.test", "cdn.example.test"
        ])
        let start = URL(string: "https://manifest.example.test/start")!
        let final = "https://cdn.example.test/final"
        MockManifestURLProtocol.store.reset([
            start.absoluteString: [.redirect(status: 302, location: final)],
            final: [response(
                headers: ["Content-Type": "application/json"], chunks: [Data("{}".utf8)]
            )]
        ])
        do {
            let data = try await fetcher.fetch(start, kind: .manifest, urlPolicy: urlPolicy)
            try harness.check("URLProtocol redirect delegate integration", data == Data("{}".utf8))
        } catch {
            throw NetworkTestFailure(
                message: "URLProtocol could not exercise redirect delegate: \(error)"
            )
        }

        let disallowed = "https://evil.example.test/final"
        MockManifestURLProtocol.store.reset([
            start.absoluteString: [.redirect(status: 302, location: disallowed)]
        ])
        try await harness.expectNetworkError("redirect to disallowed host", .redirectRejected) {
            _ = try await fetcher.fetch(start, kind: .manifest, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            start.absoluteString: [.redirect(status: 302, location: "http://manifest.example.test/x")]
        ])
        try await harness.expectNetworkError("HTTPS downgrade redirect", .redirectRejected) {
            _ = try await fetcher.fetch(start, kind: .manifest, urlPolicy: urlPolicy)
        }
        MockManifestURLProtocol.store.reset([
            start.absoluteString: [.redirect(status: 302, location: start.absoluteString)]
        ])
        try await harness.expectNetworkError("redirect loop", .redirectRejected) {
            _ = try await fetcher.fetch(start, kind: .manifest, urlPolicy: urlPolicy)
        }

        var fiveHopPlans: [String: [MockResponsePlan]] = [:]
        for index in 0..<5 {
            let source = "https://manifest.example.test/five\(index)"
            let target = "https://manifest.example.test/five\(index + 1)"
            fiveHopPlans[source] = [.redirect(status: 302, location: target)]
        }
        fiveHopPlans["https://manifest.example.test/five5"] = [response(
            headers: ["Content-Type": "application/json"], chunks: [Data("{}".utf8)]
        )]
        MockManifestURLProtocol.store.reset(fiveHopPlans)
        let fiveHopData = try await fetcher.fetch(
            URL(string: "https://manifest.example.test/five0")!,
            kind: .manifest,
            urlPolicy: urlPolicy
        )
        try harness.check("exactly five redirects accepted", fiveHopData == Data("{}".utf8))

        var plans: [String: [MockResponsePlan]] = [:]
        for index in 0...5 {
            let source = "https://manifest.example.test/r\(index)"
            let target = "https://manifest.example.test/r\(index + 1)"
            plans[source] = [.redirect(status: 302, location: target)]
        }
        MockManifestURLProtocol.store.reset(plans)
        try await harness.expectNetworkError("more than five redirects", .tooManyRedirects) {
            _ = try await fetcher.fetch(
                URL(string: "https://manifest.example.test/r0")!,
                kind: .manifest,
                urlPolicy: urlPolicy
            )
        }
    }

    private static func testCancellationAndConcurrency(_ harness: inout NetworkHarness)
        async throws {
        let key = Curve25519.Signing.PrivateKey()
        let verifier = RecordingVerifier(try makeVerifier(privateKey: key))
        let loader = try ResourceManifestRemoteLoader(
            verifier: verifier,
            requestTimeout: 2,
            resourceTimeout: 3,
            configurationFactory: mockConfiguration
        )
        let endpoint = try makeEndpoint()
        MockManifestURLProtocol.store.reset([
            signatureURL: [.stall(
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [Data(repeating: 1, count: 8)]
            )]
        ])
        let signatureTask = Task {
            try await loader.fetchAndPrepare(endpoint: endpoint, priorState: nil)
        }
        try await waitForRequestCount(1)
        signatureTask.cancel()
        do {
            _ = try await signatureTask.value
            throw NetworkTestFailure(message: "signature cancellation succeeded")
        } catch let error as ResourceNetworkError {
            try harness.check("signature cancellation classified", error == .cancelled)
        }
        try harness.check("cancelled signature skipped verifier", verifier.snapshot().calls == 0)
        try await waitForStopCount(1)
        try harness.check("URLSession task cancelled", true)

        let manifest = manifestBytes()
        let signature = try signedEnvelope(manifest, privateKey: key)
        MockManifestURLProtocol.store.reset([
            signatureURL: [response(
                headers: ["Content-Type": "application/octet-stream"], chunks: [signature]
            )],
            manifestURL: [.stall(
                headers: ["Content-Type": "application/json"],
                chunks: [manifest.prefix(9)]
            )]
        ])
        let manifestTask = Task {
            try await loader.fetchAndPrepare(endpoint: endpoint, priorState: nil)
        }
        try await waitForRequestCount(2)
        try await harness.expectNetworkError("second refresh rejected", .operationInProgress) {
            _ = try await loader.fetchAndPrepare(endpoint: endpoint, priorState: nil)
        }
        manifestTask.cancel()
        do {
            _ = try await manifestTask.value
            throw NetworkTestFailure(message: "manifest cancellation succeeded")
        } catch let error as ResourceNetworkError {
            try harness.check("manifest cancellation classified", error == .cancelled)
        }
        try harness.check("cancelled manifest skipped verifier", verifier.snapshot().calls == 0)
    }

    private static func testCookiesAndCache(_ harness: inout NetworkHarness) async throws {
        let networkPolicy = try ResourceNetworkPolicy(
            verificationPolicy: makeVerificationPolicy(maximumManifestBytes: 1024)
        )
        let fetcher = BoundedHTTPSDataFetcher(policy: networkPolicy,
                                              configurationFactory: mockConfiguration)
        let urlPolicy = try ResourceNetworkURLPolicy(
            pinnedAllowedHosts: ["manifest.example.test"]
        )
        let url = URL(string: manifestURL)!
        MockManifestURLProtocol.store.reset([
            manifestURL: [
                response(
                    headers: ["Content-Type": "application/json",
                              "Set-Cookie": "session=synthetic; Secure"],
                    chunks: [Data("{\"first\":true}".utf8)]
                ),
                response(
                    headers: ["Content-Type": "application/json"],
                    chunks: [Data("{\"second\":true}".utf8)]
                )
            ]
        ])
        let first = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
        let second = try await fetcher.fetch(url, kind: .manifest, urlPolicy: urlPolicy)
        try harness.check("first response returned", first != second)
        let requests = MockManifestURLProtocol.store.snapshot().requests
        try harness.check("same URL traversed injected transport twice", requests.count == 2)
        try harness.check("Set-Cookie not replayed", requests.allSatisfy {
            $0.headers["Cookie"] == nil
        })
    }

    private static func testProductionBoundaries(_ harness: inout NetworkHarness) throws {
        try harness.check("production endpoint disabled",
                          ResourceManifestEndpoint.productionDefault == nil)
        try harness.check("production trust store empty",
                          TrustedManifestKeyStore.productionDefault.key(for: testKeyID) == nil)
        let safeErrors: [ResourceNetworkError] = [
            .invalidEndpoint, .disallowedURL, .disallowedHost, .redirectRejected,
            .responseTooLarge, .transportFailure, .verificationFailure(.invalidSignature)
        ]
        try harness.check("errors do not expose URLs", safeErrors.allSatisfy {
            let message = $0.errorDescription ?? ""
            return !message.contains("https://") && !message.contains("example.test")
        })
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
