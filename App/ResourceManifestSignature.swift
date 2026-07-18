import CryptoKit
import Foundation

enum ResourceManifestSignatureAlgorithm: UInt16, Equatable, Sendable {
    case ed25519 = 1
}

struct ResourceManifestSignatureEnvelope: Equatable, Sendable {
    static let magic = Array("LDMSIG01".utf8)
    static let currentVersion: UInt16 = 1
    static let ed25519SignatureLength = 64
    static let maximumKeyIDLength = 64
    static let headerLength = 16

    let version: UInt16
    let algorithm: ResourceManifestSignatureAlgorithm
    let keyID: String
    let signature: Data

    init(keyID: String, signature: Data,
         version: UInt16 = Self.currentVersion,
         algorithm: ResourceManifestSignatureAlgorithm = .ed25519) throws {
        guard Self.isValidKeyID(keyID) else {
            throw ManifestVerificationError.invalidKeyID
        }
        guard signature.count == Self.ed25519SignatureLength else {
            throw ManifestVerificationError.invalidSignatureEnvelope
        }
        self.version = version
        self.algorithm = algorithm
        self.keyID = keyID
        self.signature = signature
    }

    static func parse(_ bytes: Data, maximumBytes: Int = 4_096) throws
        -> ResourceManifestSignatureEnvelope {
        guard bytes.count <= maximumBytes else {
            throw ManifestVerificationError.signatureEnvelopeTooLarge
        }
        guard bytes.count >= headerLength else {
            throw ManifestVerificationError.invalidSignatureEnvelope
        }
        let input = [UInt8](bytes)
        guard Array(input[0..<8]) == magic else {
            throw ManifestVerificationError.invalidSignatureEnvelope
        }
        let version = readUInt16(input, at: 8)
        guard version == currentVersion else {
            throw ManifestVerificationError.unknownSignatureVersion
        }
        let rawAlgorithm = readUInt16(input, at: 10)
        guard let algorithm = ResourceManifestSignatureAlgorithm(rawValue: rawAlgorithm) else {
            throw ManifestVerificationError.unknownSignatureAlgorithm
        }
        let keyIDLength = Int(readUInt16(input, at: 12))
        let signatureLength = Int(readUInt16(input, at: 14))
        guard (1...maximumKeyIDLength).contains(keyIDLength),
              signatureLength == ed25519SignatureLength else {
            throw ManifestVerificationError.invalidSignatureEnvelope
        }
        let expectedLength = headerLength.addingReportingOverflow(keyIDLength)
        guard !expectedLength.overflow else {
            throw ManifestVerificationError.invalidSignatureEnvelope
        }
        let totalLength = expectedLength.partialValue.addingReportingOverflow(signatureLength)
        guard !totalLength.overflow, totalLength.partialValue == input.count else {
            throw ManifestVerificationError.invalidSignatureEnvelope
        }
        let keyRange = headerLength..<(headerLength + keyIDLength)
        guard let keyID = String(bytes: input[keyRange], encoding: .ascii),
              isValidKeyID(keyID) else {
            throw ManifestVerificationError.invalidKeyID
        }
        let signatureStart = keyRange.upperBound
        let signature = Data(input[signatureStart..<input.count])
        return try ResourceManifestSignatureEnvelope(
            keyID: keyID,
            signature: signature,
            version: version,
            algorithm: algorithm
        )
    }

    func serialized() -> Data {
        var output = Data(Self.magic)
        output.appendUInt16(version)
        output.appendUInt16(algorithm.rawValue)
        output.appendUInt16(UInt16(keyID.utf8.count))
        output.appendUInt16(UInt16(signature.count))
        output.append(contentsOf: keyID.utf8)
        output.append(signature)
        return output
    }

    static func isValidKeyID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maximumKeyIDLength).contains(bytes.count), bytes.count == value.count else {
            return false
        }
        return bytes.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}

struct TrustedManifestKey: Equatable, Sendable {
    let keyID: String
    let publicKeyBytes: Data

    init(keyID: String, publicKeyBytes: Data) throws {
        guard ResourceManifestSignatureEnvelope.isValidKeyID(keyID) else {
            throw ManifestVerificationError.invalidKeyID
        }
        guard publicKeyBytes.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)) != nil else {
            throw ManifestVerificationError.invalidTrustedPublicKey
        }
        self.keyID = keyID
        self.publicKeyBytes = publicKeyBytes
    }
}

struct TrustedManifestKeyStore: Equatable, Sendable {
    /// D1b-1 intentionally ships with no production trust root. A later reviewed
    /// App version must inject production public keys explicitly.
    static let productionDefault = TrustedManifestKeyStore(keysByID: [:])

    private let keysByID: [String: TrustedManifestKey]

    init(keys: [TrustedManifestKey]) throws {
        var values: [String: TrustedManifestKey] = [:]
        for key in keys {
            guard values.updateValue(key, forKey: key.keyID) == nil else {
                throw ManifestVerificationError.invalidKeyID
            }
        }
        keysByID = values
    }

    private init(keysByID: [String: TrustedManifestKey]) {
        self.keysByID = keysByID
    }

    func key(for keyID: String) -> TrustedManifestKey? { keysByID[keyID] }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
