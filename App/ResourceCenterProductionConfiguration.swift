import Foundation

/// The only production injection point for the remote Resource Center trust boundary.
///
/// Shipping with no dynamic endpoint or trust keys is intentional. The v0.1 payload hosts below
/// belong only to immutable, release-reviewed starter definitions. Enabling a remote catalog must
/// supply a reviewed endpoint and trust keys; UI input and environment variables are never trusted.
struct ResourceCenterProductionConfiguration: Sendable {
    static let current = ResourceCenterProductionConfiguration(
        manifestEndpoint: nil,
        payloadAllowedHosts: [
            "download.freedict.org",
            "wordnetcode.princeton.edu",
            "ftp.gnu.org"
        ],
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
