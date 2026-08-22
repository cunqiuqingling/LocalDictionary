import Darwin
import Foundation

private enum ProductionProbeError: Error {
    case usage
    case unknownResource(String)
    case networkStageTimeout(String)
    case cancellationDidNotPropagate(String)
}

private final class ProductionProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ResourcePayloadDownloadProgress] = []
    private var lastPrintedBytes: UInt64 = 0

    func record(_ event: ResourcePayloadDownloadProgress) {
        lock.lock()
        events.append(event)
        let shouldPrint = !event.diagnosticLines.isEmpty || event.receivedBytes == 0 ||
            event.receivedBytes >= lastPrintedBytes + 1_048_576 ||
            event.phase == .completed || event.phase == .failed
        if shouldPrint { lastPrintedBytes = event.receivedBytes }
        lock.unlock()
        guard shouldPrint else { return }
        let diagnostics = event.diagnosticLines.joined(separator: " | ")
        let expected = event.expectedBytes.map(String.init) ?? "unknown"
        print("PROGRESS operation=\(event.operationID.uuidString.lowercased()) " +
              "phase=\(String(describing: event.phase)) bytes=\(event.receivedBytes) " +
              "expected=\(expected) \(diagnostics)")
    }

    func reachedAcceptedBytes() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let responseAccepted = events.contains { event in
            event.diagnosticLines.contains(where: {
                $0.contains("stage=response_accepted")
            })
        }
        return responseAccepted && events.contains(where: { $0.receivedBytes > 0 })
    }

    func lastDiagnostics() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.last?.diagnosticLines ?? []
    }
}

@main
private enum ProductionOpenResourceNetworkProbe {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2,
              arguments[0] == "--full" || arguments[0] == "--probe" else {
            throw ProductionProbeError.usage
        }
        let mode = arguments[0]
        let requested = Array(arguments.dropFirst())
        let resources = try requested.map { id in
            guard let value = BundledOpenResourceCatalog.resources.first(where: {
                $0.resourceID == id
            }) else { throw ProductionProbeError.unknownResource(id) }
            return value
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-production-network-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        guard chmod(base.path, 0o700) == 0 else {
            throw ResourcePayloadDownloadError.permissionDenied
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let policy = try ResourcePayloadDownloadPolicy(
            applicationAllowedHosts:
                ResourceCenterProductionConfiguration.current.payloadAllowedHosts
        )

        for resource in resources {
            let applicationSupport = base.appendingPathComponent(
                resource.resourceID, isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: applicationSupport, withIntermediateDirectories: false
            )
            guard chmod(applicationSupport.path, 0o700) == 0 else {
                throw ResourcePayloadDownloadError.permissionDenied
            }
            let stagingRoot = applicationSupport.appendingPathComponent(
                "ResourceCenter-Staging", isDirectory: true
            )
            let coordinator = ResourcePayloadDownloadCoordinator(
                policy: policy, stagingRoot: stagingRoot
            )
            let recorder = ProductionProgressRecorder()
            print("BEGIN mode=\(mode) resource=\(resource.resourceID) " +
                  "url=\(resource.downloadURL.absoluteString)")
            if mode == "--full" {
                let result = try await coordinator.download(starter: resource) {
                    recorder.record($0)
                }
                guard result.actualByteCount == resource.downloadBytes,
                      result.verifiedSHA256 == resource.sha256,
                      FileManager.default.fileExists(atPath: result.verifiedFileURL.path) else {
                    throw ResourcePayloadDownloadError.hashMismatch
                }
                print("PASS resource=\(resource.resourceID) stage=verified " +
                      "bytes=\(result.actualByteCount) sha256=\(result.verifiedSHA256) " +
                      "temporary_file_exists=false verified_file_exists=true")
                continue
            }

            let download = Task {
                try await coordinator.download(starter: resource) {
                    recorder.record($0)
                }
            }
            let deadline = ContinuousClock.now + .seconds(600)
            while !recorder.reachedAcceptedBytes(), ContinuousClock.now < deadline,
                  !download.isCancelled {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard recorder.reachedAcceptedBytes() else {
                download.cancel()
                _ = try? await download.value
                throw ProductionProbeError.networkStageTimeout(resource.resourceID)
            }
            download.cancel()
            do {
                let result = try await download.value
                print("PASS resource=\(resource.resourceID) completed_before_stop=true " +
                      "bytes=\(result.actualByteCount) sha256=\(result.verifiedSHA256)")
            } catch let error as ResourcePayloadDownloadError where error == .cancelled {
                print("PASS resource=\(resource.resourceID) " +
                      "stage=http_and_staging_verified_then_safely_stopped " +
                      recorder.lastDiagnostics().joined(separator: " | "))
            } catch {
                throw ProductionProbeError.cancellationDidNotPropagate(resource.resourceID)
            }
        }
    }
}
