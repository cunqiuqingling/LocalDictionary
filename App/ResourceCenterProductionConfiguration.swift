import Foundation

/// The only production injection point for the remote Resource Center trust boundary.
///
/// Shipping with no endpoint, hosts, or keys is intentional. A reviewed application release
/// must replace all three values together; UI input and environment variables are never trusted.
struct ResourceCenterProductionConfiguration: Sendable {
    static let current = ResourceCenterProductionConfiguration(
        manifestEndpoint: nil,
        payloadAllowedHosts: [],
        trustedManifestKeys: [],
        currentAppVersion: "0.1"
    )

    let manifestEndpoint: ResourceManifestEndpoint?
    let payloadAllowedHosts: [String]
    let trustedManifestKeys: [TrustedManifestKey]
    let currentAppVersion: String

    func trustedKeyStore() throws -> TrustedManifestKeyStore {
        try TrustedManifestKeyStore(keys: trustedManifestKeys)
    }

    var isRemoteCatalogConfigured: Bool {
        manifestEndpoint != nil &&
            !payloadAllowedHosts.isEmpty &&
            !trustedManifestKeys.isEmpty
    }
}
