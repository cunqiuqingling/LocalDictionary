import Foundation

actor ResourceManifestRemoteLoader {
    private let verifier: any ResourceManifestPreparing
    private let fetcher: BoundedHTTPSDataFetcher
    private var refreshInProgress = false

    init(verifier: any ResourceManifestPreparing,
         maximumRedirects: Int = 5,
         requestTimeout: TimeInterval = 15,
         resourceTimeout: TimeInterval = 30,
         configurationFactory: BoundedHTTPSDataFetcher.ConfigurationFactory? = nil) throws {
        self.verifier = verifier
        let networkPolicy = try ResourceNetworkPolicy(
            verificationPolicy: verifier.manifestVerificationPolicy,
            maximumRedirects: maximumRedirects,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout
        )
        fetcher = BoundedHTTPSDataFetcher(
            policy: networkPolicy,
            configurationFactory: configurationFactory
        )
    }

    func fetchAndPrepare(endpoint: ResourceManifestEndpoint?,
                         priorState: VerifiedManifestState?) async throws
        -> PreparedManifestVerification {
        guard let endpoint else { throw ResourceNetworkError.disabledConfiguration }
        guard !refreshInProgress else { throw ResourceNetworkError.operationInProgress }
        refreshInProgress = true
        defer { refreshInProgress = false }

        do {
            let urlPolicy = try ResourceNetworkURLPolicy(
                pinnedAllowedHosts: endpoint.pinnedAllowedHosts
            )
            let signature = try await fetcher.fetch(
                endpoint.signatureURL,
                kind: .signature,
                urlPolicy: urlPolicy
            )
            try Task.checkCancellation()
            let manifest = try await fetcher.fetch(
                endpoint.manifestURL,
                kind: .manifest,
                urlPolicy: urlPolicy
            )
            try Task.checkCancellation()
            do {
                return try verifier.prepareVerification(
                    signatureBytes: signature,
                    manifestBytes: manifest,
                    priorState: priorState
                )
            } catch let error as ManifestVerificationError {
                throw ResourceNetworkError.verificationFailure(error)
            }
        } catch is CancellationError {
            throw ResourceNetworkError.cancelled
        } catch let error as ResourceNetworkError {
            throw error
        } catch {
            throw ResourceNetworkError.transportFailure
        }
    }
}
