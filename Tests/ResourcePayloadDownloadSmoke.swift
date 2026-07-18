import CryptoKit
import Darwin
import Foundation

private struct PayloadTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct PayloadHarness {
    private(set) var passed = 0

    mutating func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
        guard condition() else { throw PayloadTestFailure(message: name) }
        passed += 1
    }

    mutating func expectError(
        _ name: String,
        matching expected: ResourcePayloadDownloadError,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw PayloadTestFailure(message: "\(name): unexpectedly succeeded")
        } catch let error as ResourcePayloadDownloadError {
            guard error == expected else {
                throw PayloadTestFailure(message: "\(name): wrong error \(error)")
            }
            passed += 1
        }
    }

    mutating func expectBuildError(
        _ name: String,
        matching expected: ResourcePayloadDownloadError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw PayloadTestFailure(message: "\(name): unexpectedly succeeded")
        } catch let error as ResourcePayloadDownloadError {
            guard error == expected else {
                throw PayloadTestFailure(message: "\(name): wrong error \(error)")
            }
            passed += 1
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ operation: (inout Value) -> Void) {
        lock.withLock { operation(&value) }
    }
}

private struct CapturedPayloadRequest: Equatable, Sendable {
    let url: String
    let method: String?
    let headers: [String: String]
    let hasBody: Bool
}

private enum PayloadResponsePlan: Sendable {
    case response(status: Int, headers: [String: String], chunks: [Data], finalURL: String?)
    case redirect(status: Int, location: String)
    case nonHTTP(Data)
    case failure(URLError.Code)
    case stall(headers: [String: String], chunks: [Data])
}

private final class PayloadMockStore: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [String: [PayloadResponsePlan]] = [:]
    private var requests: [CapturedPayloadRequest] = []
    private var stops = 0

    func reset(_ newPlans: [String: [PayloadResponsePlan]]) {
        lock.withLock {
            plans = newPlans
            requests = []
            stops = 0
        }
    }

    func take(_ request: URLRequest) -> PayloadResponsePlan? {
        lock.withLock {
            requests.append(CapturedPayloadRequest(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                hasBody: request.httpBody != nil || request.httpBodyStream != nil
            ))
            guard let key = request.url?.absoluteString,
                  var queue = plans[key], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            plans[key] = queue
            return next
        }
    }

    func recordStop() { lock.withLock { stops += 1 } }

    func snapshot() -> (requests: [CapturedPayloadRequest], stops: Int) {
        lock.withLock { (requests, stops) }
    }
}

private final class MockPayloadURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = PayloadMockStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let plan = Self.store.take(request), let requestURL = request.url else {
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
        case .nonHTTP(let data):
            let response = URLResponse(
                url: requestURL,
                mimeType: "application/octet-stream",
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .stall(let headers, let chunks):
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        }
    }

    override func stopLoading() { Self.store.recordStop() }
}

private let payloadURL = "https://payload.example.test/synthetic.mdx"
private let payloadHost = "payload.example.test"

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeResource(
    payload: Data,
    resourceID: String = "synthetic-resource",
    downloadURL: String? = payloadURL,
    allowedHosts: [String]? = [payloadHost],
    fileName: String? = "synthetic.mdx",
    distributionMode: ResourceDistributionMode = .mirroredDownload,
    archiveFormat: ResourceArchiveFormat? = ResourceArchiveFormat.none,
    compressedSize: UInt64? = nil,
    maximumDownloadedSize: UInt64? = nil,
    sha256: String? = nil,
    status: ResourceManifestStatus = .active
) -> ResourceManifestResource {
    let exact = compressedSize ?? UInt64(payload.count)
    let maximum = maximumDownloadedSize ?? max(exact, 1)
    return ResourceManifestResource(
        resourceID: resourceID,
        resourceRevision: 1,
        displayName: "Synthetic Resource",
        version: "1.0",
        languages: ["en"],
        description: "Synthetic payload used only by an offline test.",
        category: "general",
        queryLevel: .fallback,
        distributionMode: distributionMode,
        sourceProjectURL: "https://source.example.test",
        officialDownloadPage: "https://source.example.test/download",
        downloadURL: distributionMode == .mirroredDownload ? downloadURL : nil,
        allowedDownloadHosts: distributionMode == .mirroredDownload ? allowedHosts : nil,
        fileName: distributionMode == .mirroredDownload ? fileName : nil,
        archiveFormat: distributionMode == .mirroredDownload ? archiveFormat : nil,
        compressedSize: distributionMode == .mirroredDownload ? exact : nil,
        maximumDownloadedSize: distributionMode == .mirroredDownload ? maximum : nil,
        maximumExpandedSize: distributionMode == .mirroredDownload ? maximum : nil,
        sha256: distributionMode == .mirroredDownload ? (sha256 ?? digest(payload)) : nil,
        licenseName: "Synthetic Test License",
        licenseVersion: "1.0",
        licenseURL: "https://license.example.test",
        attribution: "Synthetic test data",
        notice: ResourceManifestNotice(kind: .inline, text: "Synthetic only"),
        redistributionAllowed: true,
        mirroringAllowed: distributionMode == .mirroredDownload,
        modificationAllowed: true,
        formatConversionAllowed: true,
        commercialUseAllowed: true,
        shareAlikeRequired: false,
        minimumAppVersion: "1.0",
        dictionaryFormat: .genericMDictV1,
        expectedEntryCount: ResourceManifestEntryCountRange(minimum: 1, maximum: 1),
        status: status,
        reviewedAt: "2030-01-01T00:00:00Z",
        reviewEvidence: []
    )
}

private func makeVerified(
    resources: [ResourceManifestResource],
    revocations: [RevokedResourceRange] = []
) throws -> VerifiedResourceManifest {
    let manifest = ResourceManifestV1(
        schemaVersion: 1,
        manifestVersion: 1,
        issuedAt: "2030-01-01T00:00:00Z",
        expiresAt: "2030-02-01T00:00:00Z",
        keyID: "TEST-ONLY-d1b2b",
        minimumAppVersion: "1.0",
        resources: resources,
        revokedResources: revocations
    )
    return VerifiedResourceManifest(
        validated: ValidatedResourceManifest(
            manifest: manifest,
            issuedAt: Date(timeIntervalSince1970: 1_893_456_000),
            expiresAt: Date(timeIntervalSince1970: 1_896_134_400),
            minimumAppVersion: try ManifestAppVersion("1.0"),
            freshness: .current
        ),
        manifestSHA256: String(repeating: "0", count: 64),
        verifiedKeyID: "TEST-ONLY-d1b2b"
    )
}

private func makePolicy(
    hosts: [String] = [payloadHost],
    cap: UInt64 = 1_024,
    margin: UInt64 = 16,
    redirects: Int = 5
) throws -> ResourcePayloadDownloadPolicy {
    try ResourcePayloadDownloadPolicy(
        applicationAllowedHosts: hosts,
        applicationHardLimit: cap,
        diskSafetyMargin: margin,
        maximumRedirects: redirects,
        requestTimeout: 2,
        resourceTimeout: 5
    )
}

private func makePlan(payload: Data,
                      root: URL,
                      resource: ResourceManifestResource? = nil,
                      policy: ResourcePayloadDownloadPolicy? = nil) throws
    -> ResourcePayloadDownloadPlan {
    let actualPolicy = try policy ?? makePolicy(cap: max(1_024, UInt64(payload.count)))
    let actualResource = resource ?? makeResource(payload: payload)
    return try ResourcePayloadDownloadPlanBuilder.build(
        verifiedManifest: makeVerified(resources: [actualResource]),
        resourceID: actualResource.resourceID,
        applicationAllowedHosts: actualPolicy.applicationAllowedHosts,
        stagingRoot: root,
        policy: actualPolicy
    )
}

private func hooks(
    capacity: UInt64 = UInt64.max,
    failWrite: Bool = false,
    failSyncCall: Int? = nil,
    failRenameCall: Int? = nil
) -> ResourcePayloadFileSystemHooks {
    let base = ResourcePayloadFileSystemHooks.production
    let syncCount = LockedBox(0)
    let renameCount = LockedBox(0)
    return ResourcePayloadFileSystemHooks(
        availableCapacity: { _ in capacity },
        writeAll: { descriptor, data in
            if failWrite { throw ResourcePayloadDownloadError.writeFailure }
            try base.writeAll(descriptor, data)
        },
        synchronize: { descriptor in
            var current = 0
            syncCount.update { $0 += 1; current = $0 }
            if current == failSyncCall { throw ResourcePayloadDownloadError.stagingFailure }
            try base.synchronize(descriptor)
        },
        close: base.close,
        rename: { source, destination in
            var current = 0
            renameCount.update { $0 += 1; current = $0 }
            if current == failRenameCall { throw ResourcePayloadDownloadError.stagingFailure }
            try base.rename(source, destination)
        }
    )
}

private let mockConfiguration: ResourcePayloadFileDownloader.ConfigurationFactory = { policy in
    let configuration = ResourcePayloadFileDownloader.ephemeralConfiguration(policy: policy)
    configuration.protocolClasses = [MockPayloadURLProtocol.self]
    return configuration
}

private func makeDownloader(
    hooks customHooks: ResourcePayloadFileSystemHooks = hooks(),
    operationID: UUID? = nil
) -> ResourcePayloadFileDownloader {
    let store = ResourcePayloadStagingStore(
        hooks: customHooks,
        operationIDFactory: { operationID ?? UUID() }
    )
    return ResourcePayloadFileDownloader(
        stagingStore: store,
        configurationFactory: mockConfiguration
    )
}

private func response(_ payload: Data,
                      status: Int = 200,
                      headers: [String: String] = [:],
                      chunks: [Data]? = nil,
                      finalURL: String? = nil) -> PayloadResponsePlan {
    var merged = ["Content-Type": "application/octet-stream"]
    for (key, value) in headers { merged[key] = value }
    return .response(
        status: status,
        headers: merged,
        chunks: chunks ?? [payload],
        finalURL: finalURL
    )
}

private func waitForRequestCount(_ expected: Int) async throws {
    for _ in 0..<200 {
        if MockPayloadURLProtocol.store.snapshot().requests.count >= expected { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PayloadTestFailure(message: "transport did not receive request")
}

private func directoryEntries(_ root: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
}

private func mode(_ url: URL) -> mode_t? {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return nil }
    return value.st_mode & mode_t(0o777)
}

@main
private struct ResourcePayloadDownloadSmoke {
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-payload-smoke-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        var harness = PayloadHarness()
        try testPlanBuilder(&harness, base: base)
        try await testSuccessAndSHA(&harness, base: base)
        try await testSizeAndHashFailures(&harness, base: base)
        try await testFileSystemSafety(&harness, base: base)
        try await testNetworkPolicy(&harness, base: base)
        try await testCancellationAndConcurrency(&harness, base: base)
        try await testDiskCapacity(&harness, base: base)
        print("Resource payload download smoke passed (\(harness.passed) checks)")
    }

    private static func testPlanBuilder(_ harness: inout PayloadHarness,
                                        base: URL) throws {
        let payload = Data("synthetic-mdx".utf8)
        let root = base.appendingPathComponent("builder", isDirectory: true)
        let policy = try makePolicy(hosts: [payloadHost, "app-only.example.test"])
        let resource = makeResource(
            payload: payload,
            allowedHosts: [payloadHost, "signed-only.example.test"]
        )
        let plan = try makePlan(payload: payload, root: root, resource: resource, policy: policy)
        try harness.check("signed and app host intersection", plan.allowedHosts == [payloadHost])
        try harness.check("signed exact size retained", plan.expectedBytes == UInt64(payload.count))
        try harness.check("signed maximum retained", plan.maximumBytes == UInt64(payload.count))
        try harness.check("production payload hosts empty",
                          ResourcePayloadDownloadPolicy.productionAllowedHosts.isEmpty)
        try harness.check("safe MDX filename",
                          ResourcePayloadDownloadPlanBuilder.isSafeMDXFileName("safe-name.mdx"))
        for name in ["../escape.mdx", "path/file.mdx", "path\\file.mdx", ".hidden.mdx",
                     "trailing..mdx", "not-mdx.txt"] {
            try harness.check("unsafe filename rejected: \(name)",
                              !ResourcePayloadDownloadPlanBuilder.isSafeMDXFileName(name))
        }
        try harness.expectBuildError("empty app allowlist", matching: .disabledConfiguration) {
            let disabled = try makePolicy(hosts: [])
            _ = try makePlan(payload: payload, root: root, resource: resource, policy: disabled)
        }
        try harness.expectBuildError("host intersection required", matching: .disallowedHost) {
            let disjoint = try makePolicy(hosts: ["other.example.test"])
            _ = try makePlan(payload: payload, root: root, resource: resource, policy: disjoint)
        }
        try harness.expectBuildError("official page unsupported",
                                     matching: .unsupportedDistributionMode) {
            let official = makeResource(payload: payload, distributionMode: .officialPageOnly)
            _ = try makePlan(payload: payload, root: root, resource: official)
        }
        try harness.expectBuildError("zero signed maximum", matching: .invalidSignedSize) {
            let invalid = makeResource(payload: payload, maximumDownloadedSize: 0)
            _ = try makePlan(payload: payload, root: root, resource: invalid)
        }
        try harness.expectBuildError("signed max above app cap", matching: .invalidSignedSize) {
            let invalid = makeResource(payload: payload, maximumDownloadedSize: 2_048)
            _ = try makePlan(payload: payload, root: root, resource: invalid,
                             policy: makePolicy(cap: 1_024))
        }
        for host in ["0x7f.0.0.1", "0177.0.0.1", "2130706433", "::1",
                     "[::ffff:127.0.0.1]"] {
            try harness.expectBuildError("IP literal rejected: \(host)", matching: .disallowedHost) {
                let invalid = makeResource(
                    payload: payload,
                    downloadURL: "https://\(host)/synthetic.mdx",
                    allowedHosts: [host]
                )
                _ = try makePlan(payload: payload, root: root, resource: invalid,
                                 policy: makePolicy(hosts: [host]))
            }
        }
        try harness.expectBuildError("suffix host is not exact", matching: .disallowedHost) {
            let invalid = makeResource(
                payload: payload,
                downloadURL: "https://example.com.evil.test/synthetic.mdx",
                allowedHosts: ["example.com.evil.test"]
            )
            _ = try makePlan(payload: payload, root: root, resource: invalid,
                             policy: makePolicy(hosts: ["example.com"]))
        }
    }

    private static func testSuccessAndSHA(_ harness: inout PayloadHarness,
                                          base: URL) async throws {
        let payload = Data("synthetic MDX bytes delivered in several chunks".utf8)
        let root = base.appendingPathComponent("success", isDirectory: true)
        let plan = try makePlan(payload: payload, root: root)
        let events = LockedBox<[ResourcePayloadDownloadProgress]>([])
        MockPayloadURLProtocol.store.reset([
            payloadURL: [response(
                payload,
                headers: ["Content-Length": String(payload.count)],
                chunks: [payload.prefix(8), payload.dropFirst(8).prefix(11), payload.dropFirst(19)]
            )]
        ])
        let result = try await makeDownloader().download(plan: plan) { event in
            events.update { $0.append(event) }
        }
        try harness.check("verified file exists",
                          FileManager.default.fileExists(atPath: result.verifiedFileURL.path))
        let verifiedContent = try Data(contentsOf: result.verifiedFileURL)
        try harness.check("verified content exact", verifiedContent == payload)
        try harness.check("incremental SHA result", result.verifiedSHA256 == digest(payload))
        try harness.check("actual byte count", result.actualByteCount == UInt64(payload.count))
        try harness.check("verified directory name",
                          result.verifiedFileURL.deletingLastPathComponent().lastPathComponent
                            .hasPrefix("verified-"))
        try harness.check("no partial residue",
                          directoryEntries(root).allSatisfy { !$0.hasPrefix(".partial-") })
        try harness.check("file permission 0600", mode(result.verifiedFileURL) == 0o600)
        try harness.check("operation directory permission 0700",
                          mode(result.verifiedFileURL.deletingLastPathComponent()) == 0o700)
        try harness.check("root permission 0700", mode(root) == 0o700)
        let progress = events.read()
        let byteProgress = progress.filter { $0.phase == .downloading }.map(\.receivedBytes)
        try harness.check("progress monotonic", zip(byteProgress, byteProgress.dropFirst())
            .allSatisfy { $0 <= $1 })
        try harness.check("progress completed", progress.last?.phase == .completed)
        try harness.check("signed expected progress", progress.allSatisfy {
            $0.expectedBytes == UInt64(payload.count)
        })
        let request = MockPayloadURLProtocol.store.snapshot().requests.first
        try harness.check("GET without body", request?.method == "GET" && request?.hasBody == false)
        try harness.check("identity encoding", request?.headers["Accept-Encoding"] == "identity")
        try harness.check("no authorization", request?.headers["Authorization"] == nil)
        try harness.check("no cookie", request?.headers["Cookie"] == nil)
    }

    private static func testSizeAndHashFailures(_ harness: inout PayloadHarness,
                                                base: URL) async throws {
        let payload = Data("12345678".utf8)

        func run(_ name: String, plan: PayloadResponsePlan,
                 expected: ResourcePayloadDownloadError) async throws {
            let root = base.appendingPathComponent("size-\(name)", isDirectory: true)
            let downloadPlan = try makePlan(payload: payload, root: root)
            MockPayloadURLProtocol.store.reset([payloadURL: [plan]])
            try await harness.expectError(name, matching: expected) {
                _ = try await makeDownloader().download(plan: downloadPlan)
            }
            try harness.check("\(name) cleans partial", directoryEntries(root).isEmpty)
        }

        try await run("Content-Length too large",
                      plan: response(payload, headers: ["Content-Length": "1025"]),
                      expected: .responseTooLarge)
        try await run("Content-Length mismatch",
                      plan: response(payload, headers: ["Content-Length": "7"]),
                      expected: .sizeMismatch)
        try await run("missing length actual too large",
                      plan: response(payload + Data("x".utf8)),
                      expected: .responseTooLarge)
        try await run("final size too small",
                      plan: response(Data(payload.dropLast())),
                      expected: .sizeMismatch)
        try await run("hash mismatch",
                      plan: response(Data("12345679".utf8)),
                      expected: .hashMismatch)
        try await run("206 rejected",
                      plan: response(payload, status: 206),
                      expected: .unacceptableStatus(206))
        for encoding in ["gzip", "br", "deflate"] {
            try await run("encoding-\(encoding)",
                          plan: response(payload, headers: ["Content-Encoding": encoding]),
                          expected: .unsupportedContentEncoding)
        }
        try await run("content type rejected",
                      plan: response(payload, headers: ["Content-Type": "text/plain"]),
                      expected: .unsupportedContentType)

        let exactRoot = base.appendingPathComponent("exact-limit", isDirectory: true)
        let exactPolicy = try makePolicy(cap: UInt64(payload.count), margin: 0)
        let exactPlan = try makePlan(payload: payload, root: exactRoot, policy: exactPolicy)
        MockPayloadURLProtocol.store.reset([payloadURL: [response(payload)]])
        let exact = try await makeDownloader(hooks: hooks(capacity: UInt64(payload.count)))
            .download(plan: exactPlan)
        try harness.check("exact limit succeeds", exact.actualByteCount == UInt64(payload.count))
    }

    private static func testFileSystemSafety(_ harness: inout PayloadHarness,
                                             base: URL) async throws {
        let payload = Data("filesystem".utf8)
        let target = base.appendingPathComponent("symlink-target", isDirectory: true)
        let symlink = base.appendingPathComponent("symlink-root", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let symlinkPlan = try makePlan(payload: payload, root: symlink)
        MockPayloadURLProtocol.store.reset([payloadURL: [response(payload)]])
        try await harness.expectError("symlink staging root", matching: .stagingFailure) {
            _ = try await makeDownloader().download(plan: symlinkPlan)
        }
        try harness.check("symlink target untouched", directoryEntries(target).isEmpty)

        let collisionRoot = base.appendingPathComponent("collision", isDirectory: true)
        try FileManager.default.createDirectory(at: collisionRoot, withIntermediateDirectories: true)
        let collisionID = UUID()
        let collisionDirectory = collisionRoot.appendingPathComponent(
            ".partial-\(collisionID.uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: collisionDirectory,
                                                withIntermediateDirectories: false)
        let collisionPlan = try makePlan(payload: payload, root: collisionRoot)
        try await harness.expectError("existing operation not overwritten", matching: .stagingFailure) {
            _ = try await makeDownloader(operationID: collisionID).download(plan: collisionPlan)
        }
        try harness.check("existing operation remains",
                          FileManager.default.fileExists(atPath: collisionDirectory.path))

        for (name, customHooks, expected) in [
            ("write", hooks(failWrite: true), ResourcePayloadDownloadError.writeFailure),
            ("fsync", hooks(failSyncCall: 1), ResourcePayloadDownloadError.stagingFailure),
            ("rename", hooks(failRenameCall: 1), ResourcePayloadDownloadError.stagingFailure)
        ] {
            let root = base.appendingPathComponent("failure-\(name)", isDirectory: true)
            let plan = try makePlan(payload: payload, root: root)
            MockPayloadURLProtocol.store.reset([payloadURL: [response(payload)]])
            try await harness.expectError("\(name) failure", matching: expected) {
                _ = try await makeDownloader(hooks: customHooks).download(plan: plan)
            }
            try harness.check("\(name) failure cleans partial", directoryEntries(root).isEmpty)
        }

        let sharedRoot = base.appendingPathComponent("preserve-verified", isDirectory: true)
        let firstPlan = try makePlan(payload: payload, root: sharedRoot)
        MockPayloadURLProtocol.store.reset([payloadURL: [response(payload)]])
        let first = try await makeDownloader().download(plan: firstPlan)
        let secondPlan = try makePlan(payload: payload, root: sharedRoot)
        MockPayloadURLProtocol.store.reset([payloadURL: [response(payload)]])
        try await harness.expectError("later failure", matching: .writeFailure) {
            _ = try await makeDownloader(hooks: hooks(failWrite: true)).download(plan: secondPlan)
        }
        try harness.check("verified result survives later failure",
                          FileManager.default.fileExists(atPath: first.verifiedFileURL.path))
    }

    private static func testNetworkPolicy(_ harness: inout PayloadHarness,
                                          base: URL) async throws {
        let payload = Data("network".utf8)

        func run(_ name: String, responsePlan: PayloadResponsePlan,
                 expected: ResourcePayloadDownloadError,
                 hosts: [String] = [payloadHost]) async throws {
            let root = base.appendingPathComponent("network-\(name)", isDirectory: true)
            let policy = try makePolicy(hosts: hosts)
            let resource = makeResource(payload: payload, allowedHosts: hosts)
            let plan = try makePlan(payload: payload, root: root, resource: resource,
                                    policy: policy)
            MockPayloadURLProtocol.store.reset([payloadURL: [responsePlan]])
            try await harness.expectError(name, matching: expected) {
                _ = try await makeDownloader().download(plan: plan)
            }
        }

        try await run("non HTTP", responsePlan: .nonHTTP(payload), expected: .invalidResponse)
        try await run("transport timeout", responsePlan: .failure(.timedOut), expected: .timedOut)
        try await run("redirect outside allowlist",
                      responsePlan: .redirect(status: 302,
                                              location: "https://evil.example.test/file.mdx"),
                      expected: .disallowedHost)
        try await run("redirect downgrade",
                      responsePlan: .redirect(status: 302,
                                              location: "http://payload.example.test/file.mdx"),
                      expected: .disallowedHost)

        let finalRoot = base.appendingPathComponent("final-url", isDirectory: true)
        let finalPlan = try makePlan(payload: payload, root: finalRoot)
        MockPayloadURLProtocol.store.reset([
            payloadURL: [response(payload, finalURL: "https://evil.example.test/file.mdx")]
        ])
        try await harness.expectError("final URL revalidated", matching: .disallowedHost) {
            _ = try await makeDownloader().download(plan: finalPlan)
        }

        let redirectRoot = base.appendingPathComponent("redirect-limit", isDirectory: true)
        let redirectPlan = try makePlan(payload: payload, root: redirectRoot)
        var redirects: [String: [PayloadResponsePlan]] = [:]
        redirects[payloadURL] = [.redirect(
            status: 302, location: "https://payload.example.test/r1"
        )]
        for index in 1...5 {
            redirects["https://payload.example.test/r\(index)"] = [.redirect(
                status: 302,
                location: "https://payload.example.test/r\(index + 1)"
            )]
        }
        MockPayloadURLProtocol.store.reset(redirects)
        try await harness.expectError("sixth redirect rejected", matching: .invalidResponse) {
            _ = try await makeDownloader().download(plan: redirectPlan)
        }

        let missingRoot = base.appendingPathComponent("unmatched", isDirectory: true)
        let missingPlan = try makePlan(payload: payload, root: missingRoot)
        MockPayloadURLProtocol.store.reset([:])
        try await harness.expectError("unmatched URLProtocol fails closed",
                                      matching: .transportFailure) {
            _ = try await makeDownloader().download(plan: missingPlan)
        }
    }

    private static func testCancellationAndConcurrency(_ harness: inout PayloadHarness,
                                                       base: URL) async throws {
        let payload = Data("cancel-me".utf8)
        let policy = try makePolicy()
        let root = base.appendingPathComponent("cancel", isDirectory: true)
        let verified = try makeVerified(resources: [makeResource(payload: payload)])
        let coordinator = ResourcePayloadDownloadCoordinator(
            policy: policy,
            stagingRoot: root,
            downloader: makeDownloader()
        )
        MockPayloadURLProtocol.store.reset([
            payloadURL: [.stall(
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [payload.prefix(3)]
            )]
        ])
        let first = Task {
            try await coordinator.download(
                verifiedManifest: verified,
                resourceID: "synthetic-resource"
            )
        }
        try await waitForRequestCount(1)
        try await harness.expectError("single-flight second request",
                                      matching: .operationInProgress) {
            _ = try await coordinator.download(
                verifiedManifest: verified,
                resourceID: "synthetic-resource"
            )
        }
        first.cancel()
        do {
            _ = try await first.value
            throw PayloadTestFailure(message: "cancelled download succeeded")
        } catch let error as ResourcePayloadDownloadError {
            try harness.check("cancel error distinguished", error == .cancelled)
        }
        try harness.check("cancel cleans partial", directoryEntries(root).isEmpty)

        MockPayloadURLProtocol.store.reset([payloadURL: [response(payload)]])
        let retry = try await coordinator.download(
            verifiedManifest: verified,
            resourceID: "synthetic-resource"
        )
        try harness.check("retry after cancellation succeeds", retry.actualByteCount == UInt64(payload.count))
    }

    private static func testDiskCapacity(_ harness: inout PayloadHarness,
                                         base: URL) async throws {
        let payload = Data("capacity".utf8)
        let root = base.appendingPathComponent("insufficient", isDirectory: true)
        let plan = try makePlan(payload: payload, root: root)
        MockPayloadURLProtocol.store.reset([payloadURL: [response(payload)]])
        try await harness.expectError("insufficient capacity before file creation",
                                      matching: .insufficientDiskSpace) {
            _ = try await makeDownloader(hooks: hooks(capacity: 1)).download(plan: plan)
        }
        try harness.check("insufficient capacity creates no payload file",
                          directoryEntries(root).isEmpty)

        let overflowRoot = base.appendingPathComponent("capacity-overflow", isDirectory: true)
        let overflowPolicy = try makePolicy(margin: UInt64.max)
        let overflowPlan = try makePlan(payload: payload, root: overflowRoot,
                                        policy: overflowPolicy)
        try await harness.expectError("capacity addition overflow",
                                      matching: .insufficientDiskSpace) {
            _ = try await makeDownloader().download(plan: overflowPlan)
        }
        try harness.check("capacity overflow creates no payload file",
                          directoryEntries(overflowRoot).isEmpty)
    }
}
