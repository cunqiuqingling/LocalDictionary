import Foundation

actor ResourcePayloadDownloadCoordinator {
    private let policy: ResourcePayloadDownloadPolicy
    private let stagingRoot: URL
    private let downloader: ResourcePayloadFileDownloader
    private var operationInProgress = false

    init(policy: ResourcePayloadDownloadPolicy,
         stagingRoot: URL,
         downloader: ResourcePayloadFileDownloader = ResourcePayloadFileDownloader()) {
        self.policy = policy
        self.stagingRoot = stagingRoot
        self.downloader = downloader
    }

    func download(verifiedManifest: VerifiedResourceManifest,
                  resourceID: String,
                  progress: @escaping ResourcePayloadFileDownloader.ProgressSink = { _ in })
        async throws -> VerifiedPayloadStagingResult {
        guard !operationInProgress else {
            throw ResourcePayloadDownloadError.operationInProgress
        }
        operationInProgress = true
        defer { operationInProgress = false }

        let plan = try ResourcePayloadDownloadPlanBuilder.build(
            verifiedManifest: verifiedManifest,
            resourceID: resourceID,
            applicationAllowedHosts: policy.applicationAllowedHosts,
            stagingRoot: stagingRoot,
            policy: policy
        )
        do {
            return try await downloader.download(plan: plan, progress: progress)
        } catch is CancellationError {
            throw ResourcePayloadDownloadError.cancelled
        } catch let error as ResourcePayloadDownloadError {
            throw error
        } catch {
            throw ResourcePayloadDownloadError.transportFailure
        }
    }
}
