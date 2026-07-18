import CryptoKit
import Foundation

struct ResourceManifestVerifier: Sendable {
    let trustStore: TrustedManifestKeyStore
    let policy: ManifestVerificationPolicy
    let clock: any ManifestClock

    init(trustStore: TrustedManifestKeyStore,
         policy: ManifestVerificationPolicy,
         clock: any ManifestClock = SystemManifestClock()) {
        self.trustStore = trustStore
        self.policy = policy
        self.clock = clock
    }

    /// Performs cryptographic, structural, semantic and rollback validation.
    /// This method is deliberately pure with respect to persistent state.
    func prepareVerification(signatureBytes: Data,
                             manifestBytes: Data,
                             priorState: VerifiedManifestState?) throws
        -> PreparedManifestVerification {
        let envelope = try ResourceManifestSignatureEnvelope.parse(
            signatureBytes,
            maximumBytes: min(policy.maximumSignatureBytes, 4_096)
        )
        guard let trustedKey = trustStore.key(for: envelope.keyID) else {
            throw ManifestVerificationError.unknownKeyID
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: trustedKey.publicKeyBytes
            )
        } catch {
            throw ManifestVerificationError.invalidTrustedPublicKey
        }
        guard publicKey.isValidSignature(envelope.signature, for: manifestBytes) else {
            throw ManifestVerificationError.invalidSignature
        }

        guard manifestBytes.count <= policy.maximumManifestBytes else {
            throw ManifestVerificationError.manifestTooLarge
        }
        let decoded = try StrictResourceManifestDecoder().decode(
            manifestBytes,
            limits: policy.jsonLimits
        )
        guard decoded.keyID == envelope.keyID else {
            throw ManifestVerificationError.invalidKeyID
        }
        let now = clock.now()
        let validated = try ResourceManifestValidator().validate(
            decoded,
            policy: policy,
            now: now
        )
        let digest = SHA256.hash(data: manifestBytes)
            .map { String(format: "%02x", $0) }.joined()
        if let priorState {
            try Self.validateRollback(candidateVersion: decoded.manifestVersion,
                                      candidateDigest: digest,
                                      candidateKeyID: envelope.keyID,
                                      priorState: priorState.validated())
        }
        let verified = VerifiedResourceManifest(
            validated: validated,
            manifestSHA256: digest,
            verifiedKeyID: envelope.keyID
        )
        let state = VerifiedManifestState(
            highestManifestVersion: decoded.manifestVersion,
            manifestSHA256: digest,
            verifiedKeyID: envelope.keyID,
            issuedAt: validated.issuedAt,
            verifiedAt: now
        )
        return PreparedManifestVerification(verifiedManifest: verified,
                                            stateCandidate: state)
    }

    static func validateRollback(candidate: VerifiedManifestState,
                                 priorState: VerifiedManifestState?) throws {
        guard let priorState else { return }
        try validateRollback(candidateVersion: candidate.highestManifestVersion,
                             candidateDigest: candidate.manifestSHA256,
                             candidateKeyID: candidate.verifiedKeyID,
                             priorState: priorState)
    }

    private static func validateRollback(candidateVersion: UInt64,
                                         candidateDigest: String,
                                         candidateKeyID: String,
                                         priorState: VerifiedManifestState) throws {
        if candidateVersion < priorState.highestManifestVersion {
            throw ManifestVerificationError.manifestRollback
        }
        guard candidateVersion == priorState.highestManifestVersion else { return }
        guard candidateKeyID == priorState.verifiedKeyID else {
            throw ManifestVerificationError.manifestVersionKeyChanged
        }
        guard candidateDigest == priorState.manifestSHA256 else {
            throw ManifestVerificationError.manifestVersionContentChanged
        }
    }
}
