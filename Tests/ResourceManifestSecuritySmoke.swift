import CryptoKit
import Darwin
import Foundation

private struct FixedClock: ManifestClock {
    let value: Date
    func now() -> Date { value }
}

private struct Harness {
    private(set) var passed = 0

    mutating func recordPass() { passed += 1 }

    mutating func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
        guard condition() else { throw TestFailure(name) }
        passed += 1
    }

    mutating func expectManifestError(
        _ name: String,
        matching: (ManifestVerificationError) -> Bool,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw TestFailure("\(name): unexpectedly succeeded")
        } catch let error as ManifestVerificationError {
            guard matching(error) else { throw TestFailure("\(name): wrong error \(error)") }
            passed += 1
        }
    }

    mutating func expectStoreError(
        _ name: String,
        matching: (VerifiedManifestStateStoreError) -> Bool,
        _ operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw TestFailure("\(name): unexpectedly succeeded")
        } catch let error as VerifiedManifestStateStoreError {
            guard matching(error) else { throw TestFailure("\(name): wrong error \(error)") }
            passed += 1
        }
    }
}

private struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private let testKeyID = "TEST-ONLY-d1b1-manifest"
private let fixedNow = date("2030-01-15T00:00:00Z")

private func date(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.isLenient = false
    return formatter.date(from: value)!
}

private func policy() throws -> ManifestVerificationPolicy {
    var value = ManifestVerificationPolicy(currentAppVersion: try ManifestAppVersion("1.0.0"))
    value.maximumDownloadedResourceBytes = 8 * 1024 * 1024
    value.maximumExpandedResourceBytes = 16 * 1024 * 1024
    return value
}

private func mirroredResource(id: String = "org.example.invalid.dictionary",
                              revision: UInt64 = 1,
                              minimumAppVersion: String = "1.0.0") -> String {
    """
    {
      "resourceID":"\(id)",
      "resourceRevision":\(revision),
      "displayName":"Synthetic Test Dictionary",
      "version":"1.0",
      "languages":["en","zh-Hans"],
      "description":"Synthetic test resource only.",
      "category":"general",
      "queryLevel":"fallback",
      "distributionMode":"mirroredDownload",
      "sourceProjectURL":"https://project.example.invalid/source",
      "officialDownloadPage":"https://project.example.invalid/downloads",
      "downloadURL":"https://downloads.example.invalid/dictionary.mdx",
      "allowedDownloadHosts":["downloads.example.invalid"],
      "fileName":"dictionary.mdx",
      "archiveFormat":"none",
      "compressedSize":1024,
      "maximumDownloadedSize":2048,
      "maximumExpandedSize":4096,
      "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "licenseName":"Synthetic-License",
      "licenseVersion":"1.0",
      "licenseURL":"https://project.example.invalid/license",
      "attribution":"Synthetic attribution.",
      "notice":{"kind":"inline","text":"Synthetic notice."},
      "redistributionAllowed":true,
      "mirroringAllowed":true,
      "modificationAllowed":true,
      "formatConversionAllowed":true,
      "commercialUseAllowed":true,
      "shareAlikeRequired":false,
      "minimumAppVersion":"\(minimumAppVersion)",
      "dictionaryFormat":"generic-mdict-v1",
      "expectedEntryCount":{"minimum":1,"maximum":1000},
      "status":"active",
      "reviewedAt":"2030-01-01T00:00:00Z",
      "reviewEvidence":[{"kind":"official-license","url":"https://project.example.invalid/license","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]
    }
    """
}

private func officialPageResource(id: String = "org.example.invalid.official") -> String {
    let directFieldNames = [
        "\"downloadURL\":", "\"allowedDownloadHosts\":", "\"fileName\":",
        "\"archiveFormat\":", "\"compressedSize\":", "\"maximumDownloadedSize\":",
        "\"maximumExpandedSize\":", "\"sha256\":"
    ]
    let converted = mirroredResource(id: id)
        .replacingOccurrences(of: "\"distributionMode\":\"mirroredDownload\"",
                              with: "\"distributionMode\":\"officialPageOnly\"")
        .replacingOccurrences(of: "\"redistributionAllowed\":true",
                              with: "\"redistributionAllowed\":false")
        .replacingOccurrences(of: "\"mirroringAllowed\":true",
                              with: "\"mirroringAllowed\":false")
    return converted.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { line in
            let field = line.trimmingCharacters(in: .whitespaces)
            return !directFieldNames.contains(where: { field.hasPrefix($0) })
        }
        .joined(separator: "\n")
}

private func revocation(id: String = "org.example.invalid.retired",
                        minimum: UInt64 = 1, maximum: UInt64 = 2) -> String {
    """
    {"resourceID":"\(id)","minimumRevision":\(minimum),"maximumRevision":\(maximum),"reasonCode":"upstream-withdrawn","effectiveAt":"2030-01-01T00:00:00Z"}
    """
}

private func manifest(version: UInt64 = 1,
                      keyID: String = testKeyID,
                      issuedAt: String = "2030-01-01T00:00:00Z",
                      expiresAt: String = "2030-02-01T00:00:00Z",
                      minimumAppVersion: String = "1.0.0",
                      resources: [String] = [mirroredResource()],
                      revocations: [String] = []) -> Data {
    Data("""
    {
      "schemaVersion":1,
      "manifestVersion":\(version),
      "issuedAt":"\(issuedAt)",
      "expiresAt":"\(expiresAt)",
      "keyID":"\(keyID)",
      "minimumAppVersion":"\(minimumAppVersion)",
      "resources":[\(resources.joined(separator: ","))],
      "revokedResources":[\(revocations.joined(separator: ","))]
    }
    """.utf8)
}

private func signedEnvelope(for manifest: Data,
                            privateKey: Curve25519.Signing.PrivateKey,
                            keyID: String = testKeyID) throws -> Data {
    let signature = try privateKey.signature(for: manifest)
    return try ResourceManifestSignatureEnvelope(keyID: keyID,
                                                 signature: signature).serialized()
}

private func makeVerifier(privateKey: Curve25519.Signing.PrivateKey,
                          customPolicy: ManifestVerificationPolicy? = nil,
                          keyID: String = testKeyID) throws -> ResourceManifestVerifier {
    let trusted = try TrustedManifestKey(
        keyID: keyID,
        publicKeyBytes: privateKey.publicKey.rawRepresentation
    )
    return ResourceManifestVerifier(
        trustStore: try TrustedManifestKeyStore(keys: [trusted]),
        policy: try customPolicy ?? policy(),
        clock: FixedClock(value: fixedNow)
    )
}

private func prepare(_ data: Data,
                     privateKey: Curve25519.Signing.PrivateKey,
                     verifier: ResourceManifestVerifier,
                     prior: VerifiedManifestState? = nil,
                     envelopeKeyID: String = testKeyID) throws -> PreparedManifestVerification {
    try verifier.prepareVerification(
        signatureBytes: signedEnvelope(for: data, privateKey: privateKey,
                                       keyID: envelopeKeyID),
        manifestBytes: data,
        priorState: prior
    )
}

private func replace(_ source: String, with replacement: String, in data: Data) -> Data {
    Data(String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: source, with: replacement).utf8)
}

private func removingObjectLine(_ fieldPrefix: String, from data: Data) -> Data {
    let text = String(decoding: data, as: UTF8.self)
    return Data(text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(fieldPrefix) }
        .joined(separator: "\n").utf8)
}

@main
private struct ResourceManifestSecuritySmoke {
    static func main() async throws {
        var harness = Harness()
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let activeVerifier = try makeVerifier(privateKey: privateKey)
        let validData = manifest()

        try testSignatureEnvelope(&harness, privateKey: privateKey, verifier: activeVerifier,
                                  validData: validData, otherKey: otherKey)
        try testStrictJSON(&harness, privateKey: privateKey, verifier: activeVerifier,
                           validData: validData)
        try testManifestSemantics(&harness, privateKey: privateKey, verifier: activeVerifier,
                                  validData: validData)
        try await testRollbackStore(&harness, privateKey: privateKey,
                                    verifier: activeVerifier)
        try testBoundaries(&harness, privateKey: privateKey, verifier: activeVerifier)
        print("ResourceManifestSecuritySmoke PASS (\(harness.passed) checks)")
    }

    private static func testSignatureEnvelope(
        _ harness: inout Harness,
        privateKey: Curve25519.Signing.PrivateKey,
        verifier: ResourceManifestVerifier,
        validData: Data,
        otherKey: Curve25519.Signing.PrivateKey
    ) throws {
        let envelopeData = try signedEnvelope(for: validData, privateKey: privateKey)
        let envelope = try ResourceManifestSignatureEnvelope.parse(envelopeData)
        try harness.check("valid envelope", envelope.keyID == testKeyID &&
                          envelope.signature.count == 64)

        var wrongMagic = envelopeData; wrongMagic[0] ^= 1
        try harness.expectManifestError("wrong magic", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(wrongMagic) }
        var wrongVersion = envelopeData; wrongVersion[9] = 2
        try harness.expectManifestError("unknown envelope version", matching: {
            $0 == .unknownSignatureVersion
        }) { _ = try ResourceManifestSignatureEnvelope.parse(wrongVersion) }
        var wrongAlgorithm = envelopeData; wrongAlgorithm[11] = 2
        try harness.expectManifestError("unknown algorithm", matching: {
            $0 == .unknownSignatureAlgorithm
        }) { _ = try ResourceManifestSignatureEnvelope.parse(wrongAlgorithm) }
        try harness.expectManifestError("truncated header", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(Data(envelopeData.prefix(10))) }
        var emptyKey = envelopeData; emptyKey[12] = 0; emptyKey[13] = 0
        try harness.expectManifestError("empty key id", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(emptyKey) }
        var longKey = envelopeData; longKey[12] = 0; longKey[13] = 65
        try harness.expectManifestError("long key id", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(longKey) }
        var invalidKey = envelopeData
        invalidKey[ResourceManifestSignatureEnvelope.headerLength] = 0x2f
        try harness.expectManifestError("invalid key id", matching: {
            $0 == .invalidKeyID
        }) { _ = try ResourceManifestSignatureEnvelope.parse(invalidKey) }
        try harness.expectManifestError("truncated key id", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(Data(envelopeData.dropLast(65))) }
        try harness.expectManifestError("truncated signature", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(Data(envelopeData.dropLast())) }
        var badSignatureLength = envelopeData
        badSignatureLength[14] = 0; badSignatureLength[15] = 63
        try harness.expectManifestError("signature length", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(badSignatureLength) }
        var overflowLength = envelopeData
        overflowLength[12] = 0xff; overflowLength[13] = 0xff
        try harness.expectManifestError("declared length overflow", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(overflowLength) }
        var trailing = envelopeData; trailing.append(0)
        try harness.expectManifestError("trailing sidecar bytes", matching: {
            $0 == .invalidSignatureEnvelope
        }) { _ = try ResourceManifestSignatureEnvelope.parse(trailing) }
        try harness.expectManifestError("sidecar hard limit", matching: {
            $0 == .signatureEnvelopeTooLarge
        }) { _ = try ResourceManifestSignatureEnvelope.parse(Data(repeating: 0, count: 4097)) }
        var looseSidecarPolicy = try policy()
        looseSidecarPolicy.maximumSignatureBytes = 8_192
        let looseSidecarVerifier = try makeVerifier(
            privateKey: privateKey, customPolicy: looseSidecarPolicy
        )
        try harness.expectManifestError("verifier preserves sidecar hard limit", matching: {
            $0 == .signatureEnvelopeTooLarge
        }) {
            _ = try looseSidecarVerifier.prepareVerification(
                signatureBytes: Data(repeating: 0, count: 4_097),
                manifestBytes: validData,
                priorState: nil
            )
        }

        _ = try prepare(validData, privateKey: privateKey, verifier: verifier)
        harness.recordPass()
        let wrongVerifier = try makeVerifier(privateKey: otherKey)
        try harness.expectManifestError("wrong public key", matching: { $0 == .invalidSignature }) {
            _ = try wrongVerifier.prepareVerification(signatureBytes: envelopeData,
                                                      manifestBytes: validData,
                                                      priorState: nil)
        }
        let unknownVerifier = ResourceManifestVerifier(
            trustStore: .productionDefault,
            policy: try policy(),
            clock: FixedClock(value: fixedNow)
        )
        try harness.expectManifestError("unknown key id", matching: { $0 == .unknownKeyID }) {
            _ = try unknownVerifier.prepareVerification(signatureBytes: envelopeData,
                                                        manifestBytes: validData,
                                                        priorState: nil)
        }
        try harness.expectManifestError("signature checked before malformed JSON", matching: {
            $0 == .invalidSignature
        }) {
            _ = try verifier.prepareVerification(signatureBytes: envelopeData,
                                                  manifestBytes: Data("{".utf8),
                                                  priorState: nil)
        }
        for (name, changed) in [
            ("manifest byte changed", replace("Synthetic test resource", with: "Synthetic test Xesource", in: validData)),
            ("newline added", validData + Data("\n".utf8)),
            ("newline removed", Data(validData.dropLast())),
            ("spacing changed", replace("\"schemaVersion\":1", with: "\"schemaVersion\" : 1", in: validData)),
            ("key order changed", replace("\"schemaVersion\":1,\n  \"manifestVersion\":1", with: "\"manifestVersion\":1,\n  \"schemaVersion\":1", in: validData))
        ] {
            try harness.expectManifestError(name, matching: { $0 == .invalidSignature }) {
                _ = try verifier.prepareVerification(signatureBytes: envelopeData,
                                                      manifestBytes: changed,
                                                      priorState: nil)
            }
        }
        var changedSignature = envelopeData; changedSignature[changedSignature.count - 1] ^= 1
        try harness.expectManifestError("signature changed", matching: {
            $0 == .invalidSignature
        }) {
            _ = try verifier.prepareVerification(signatureBytes: changedSignature,
                                                  manifestBytes: validData, priorState: nil)
        }
        let empty = Data()
        try harness.expectManifestError("empty manifest", matching: { $0 == .emptyManifest }) {
            _ = try prepare(empty, privateKey: privateKey, verifier: verifier)
        }
        var tinyPolicy = try policy(); tinyPolicy.maximumManifestBytes = 16
        let tinyVerifier = try makeVerifier(
            privateKey: privateKey, customPolicy: tinyPolicy
        )
        try harness.expectManifestError("manifest size limit", matching: {
            $0 == .manifestTooLarge
        }) { _ = try prepare(validData, privateKey: privateKey, verifier: tinyVerifier) }
        let verifier2 = try makeVerifier(privateKey: privateKey)
        let firstCandidate = try prepare(validData, privateKey: privateKey,
                                         verifier: verifier2).stateCandidate
        let secondCandidate = try prepare(validData, privateKey: privateKey,
                                          verifier: verifier).stateCandidate
        try harness.check("independent verifiers",
                          firstCandidate == secondCandidate)
    }

    private static func testStrictJSON(_ harness: inout Harness,
                                       privateKey: Curve25519.Signing.PrivateKey,
                                       verifier: ResourceManifestVerifier,
                                       validData: Data) throws {
        let cases: [(String, Data, (ManifestVerificationError) -> Bool)] = [
            ("unknown top field", replace("\"schemaVersion\":1,", with: "\"unexpected\":1,\"schemaVersion\":1,", in: validData), { if case .unknownJSONField = $0 { true } else { false } }),
            ("unknown resource field", replace("\"resourceID\":", with: "\"unexpected\":1,\"resourceID\":", in: validData), { if case .unknownJSONField = $0 { true } else { false } }),
            ("unknown notice field", replace("\"kind\":\"inline\"", with: "\"kind\":\"inline\",\"unexpected\":1", in: validData), { if case .unknownJSONField = $0 { true } else { false } }),
            ("unknown entry count field", replace("\"minimum\":1,\"maximum\":1000", with: "\"minimum\":1,\"maximum\":1000,\"unexpected\":1", in: validData), { if case .unknownJSONField = $0 { true } else { false } }),
            ("unknown evidence field", replace("\"kind\":\"official-license\"", with: "\"kind\":\"official-license\",\"unexpected\":1", in: validData), { if case .unknownJSONField = $0 { true } else { false } }),
            ("duplicate top key", replace("\"schemaVersion\":1,", with: "\"schemaVersion\":1,\"schemaVersion\":1,", in: validData), { if case .duplicateJSONKey = $0 { true } else { false } }),
            ("duplicate escaped key", replace("\"schemaVersion\":1,", with: "\"schemaVersion\":1,\"\\u0073chemaVersion\":1,", in: validData), { if case .duplicateJSONKey = $0 { true } else { false } }),
            ("duplicate resource key", replace("\"resourceRevision\":1,", with: "\"resourceRevision\":1,\"resourceRevision\":1,", in: validData), { if case .duplicateJSONKey = $0 { true } else { false } }),
            ("duplicate nested key", replace("\"minimum\":1,\"maximum\":1000", with: "\"minimum\":1,\"minimum\":1,\"maximum\":1000", in: validData), { if case .duplicateJSONKey = $0 { true } else { false } }),
            ("top array", Data("[]".utf8), { if case .invalidJSONType = $0 { true } else { false } }),
            ("top null", Data("null".utf8), { if case .invalidJSONType = $0 { true } else { false } }),
            ("trailing JSON", validData + Data("{}".utf8), { if case .malformedJSON = $0 { true } else { false } }),
            ("manifest version float", replace("\"manifestVersion\":1", with: "\"manifestVersion\":1.0", in: validData), { if case .invalidJSONType = $0 { true } else { false } }),
            ("negative version", replace("\"manifestVersion\":1", with: "\"manifestVersion\":-1", in: validData), { if case .invalidJSONType = $0 { true } else { false } }),
            ("uint overflow", replace("\"manifestVersion\":1", with: "\"manifestVersion\":18446744073709551616", in: validData), { if case .invalidJSONType = $0 { true } else { false } }),
            ("null required", replace("\"keyID\":\"\(testKeyID)\"", with: "\"keyID\":null", in: validData), { if case .invalidJSONType = $0 { true } else { false } }),
            ("unpaired unicode surrogate", replace("Synthetic Test Dictionary", with: "\\uD800", in: validData), { if case .malformedJSON = $0 { true } else { false } }),
            ("JSON string byte limit", replace("Synthetic Test Dictionary", with: String(repeating: "x", count: 17_000), in: validData), { if case .JSONLimitExceeded = $0 { true } else { false } }),
            ("long resource id", replace("org.example.invalid.dictionary", with: String(repeating: "x", count: 129), in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("long display name", replace("Synthetic Test Dictionary", with: String(repeating: "x", count: 600), in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("long description", replace("Synthetic test resource only.", with: String(repeating: "x", count: 5000), in: validData), { if case .invalidSemanticValue = $0 { true } else { false } })
        ]
        for item in cases {
            try harness.expectManifestError(item.0, matching: item.2) {
                _ = try prepare(item.1, privateKey: privateKey, verifier: verifier)
            }
        }
        let nonUTF8 = Data([0xff])
        try harness.expectManifestError("non utf8", matching: { $0 == .invalidUTF8 }) {
            _ = try prepare(nonUTF8, privateKey: privateKey, verifier: verifier)
        }
        let bom = Data([0xef, 0xbb, 0xbf]) + validData
        try harness.expectManifestError("bom", matching: { $0 == .utf8BOMNotAllowed }) {
            _ = try prepare(bom, privateKey: privateKey, verifier: verifier)
        }
        let deep = Data(("{" + (0..<40).map { "\"x\($0)\":{" }.joined() +
            "\"value\":1" + String(repeating: "}", count: 41)).utf8)
        try harness.expectManifestError("deep nesting", matching: {
            if case .JSONLimitExceeded = $0 { true } else { false }
        }) { _ = try prepare(deep, privateKey: privateKey, verifier: verifier) }
        var smallArrayPolicy = try policy(); smallArrayPolicy.jsonLimits.maximumArrayElements = 2
        let smallArrayVerifier = try makeVerifier(
            privateKey: privateKey, customPolicy: smallArrayPolicy
        )
        let threeLanguages = replace("[\"en\",\"zh-Hans\"]",
                                     with: "[\"en\",\"zh-Hans\",\"fr\"]", in: validData)
        try harness.expectManifestError("array limit", matching: {
            if case .JSONLimitExceeded = $0 { true } else { false }
        }) { _ = try prepare(threeLanguages, privateKey: privateKey,
                            verifier: smallArrayVerifier) }

        let revokedUnknown = manifest(revocations: [revocation()])
        let changedRevocation = replace("\"reasonCode\":", with: "\"unexpected\":1,\"reasonCode\":", in: revokedUnknown)
        try harness.expectManifestError("unknown revocation field", matching: {
            if case .unknownJSONField = $0 { true } else { false }
        }) { _ = try prepare(changedRevocation, privateKey: privateKey, verifier: verifier) }
    }

    private static func testManifestSemantics(_ harness: inout Harness,
                                              privateKey: Curve25519.Signing.PrivateKey,
                                              verifier: ResourceManifestVerifier,
                                              validData: Data) throws {
        let semanticCases: [(String, Data, (ManifestVerificationError) -> Bool)] = [
            ("unsupported schema", replace("\"schemaVersion\":1", with: "\"schemaVersion\":2", in: validData), { $0 == .unsupportedSchemaVersion }),
            ("zero manifest version", replace("\"manifestVersion\":1", with: "\"manifestVersion\":0", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("zero resource revision", replace("\"resourceRevision\":1", with: "\"resourceRevision\":0", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("duplicate resource id", manifest(resources: [mirroredResource(), mirroredResource()]), { $0 == .duplicateResourceID }),
            ("duplicate hosts", replace("[\"downloads.example.invalid\"]", with: "[\"downloads.example.invalid\",\"downloads.example.invalid\"]", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("issued after expires", manifest(issuedAt: "2030-03-01T00:00:00Z"), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("issued too far future", manifest(issuedAt: "2030-01-16T00:00:00Z", expiresAt: "2030-02-01T00:00:00Z"), { $0 == .manifestIssuedInFuture }),
            ("minimum app too high", manifest(minimumAppVersion: "2.0.0"), { $0 == .incompatibleAppVersion }),
            ("resource minimum app too high", manifest(resources: [mirroredResource(minimumAppVersion: "2.0.0")]), { $0 == .incompatibleAppVersion }),
            ("preferred forbidden", replace("\"queryLevel\":\"fallback\"", with: "\"queryLevel\":\"preferred\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("normal forbidden", replace("\"queryLevel\":\"fallback\"", with: "\"queryLevel\":\"normal\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("archive forbidden", replace("\"archiveFormat\":\"none\"", with: "\"archiveFormat\":\"zip\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("distribution mode unknown", replace("\"distributionMode\":\"mirroredDownload\"", with: "\"distributionMode\":\"peerToPeer\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("status unknown", replace("\"status\":\"active\"", with: "\"status\":\"unreviewed\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("notice kind unknown", replace("\"kind\":\"inline\"", with: "\"kind\":\"remoteFile\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("legacy formatter alias forbidden", replace("\"dictionaryFormat\":\"generic-mdict-v1\"", with: "\"dictionaryFormat\":\"generic-mdict.v1\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("arbitrary formatter forbidden", replace("\"dictionaryFormat\":\"generic-mdict-v1\"", with: "\"dictionaryFormat\":\"OxfordEntryFormatter\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("http download", replace("https://downloads.example.invalid/dictionary.mdx", with: "http://downloads.example.invalid/dictionary.mdx", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("url userinfo", replace("https://downloads.example.invalid/dictionary.mdx", with: "https://user@downloads.example.invalid/dictionary.mdx", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("url fragment", replace("https://downloads.example.invalid/dictionary.mdx", with: "https://downloads.example.invalid/dictionary.mdx#x", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("ip literal", replace("downloads.example.invalid", with: "127.0.0.1", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("nondefault port", replace("https://downloads.example.invalid/dictionary.mdx", with: "https://downloads.example.invalid:8443/dictionary.mdx", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("download host missing", replace("[\"downloads.example.invalid\"]", with: "[\"other.example.invalid\"]", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("filename slash", replace("\"fileName\":\"dictionary.mdx\"", with: "\"fileName\":\"dir/dictionary.mdx\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("filename dotdot", replace("\"fileName\":\"dictionary.mdx\"", with: "\"fileName\":\"..\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("filename unicode", replace("dictionary.mdx", with: "词典.mdx", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("filename leading dot", replace("\"fileName\":\"dictionary.mdx\"", with: "\"fileName\":\".dictionary.mdx\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("filename trailing dot", replace("\"fileName\":\"dictionary.mdx\"", with: "\"fileName\":\"dictionary.mdx.\"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("filename trailing space", replace("\"fileName\":\"dictionary.mdx\"", with: "\"fileName\":\"dictionary.mdx \"", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("sha length", replace(String(repeating: "a", count: 64), with: "abc", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("sha uppercase", replace(String(repeating: "a", count: 64), with: String(repeating: "A", count: 64), in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("compressed exceeds max", replace("\"compressedSize\":1024", with: "\"compressedSize\":4096", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("download policy hard limit", replace("\"maximumDownloadedSize\":2048", with: "\"maximumDownloadedSize\":9000000", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("expanded policy hard limit", replace("\"maximumExpandedSize\":4096", with: "\"maximumExpandedSize\":17000000", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("entry range inverted", replace("\"minimum\":1,\"maximum\":1000", with: "\"minimum\":1000,\"maximum\":1", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("license inconsistent", replace("\"mirroringAllowed\":true", with: "\"mirroringAllowed\":false", in: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("mirrored download field missing", removingObjectLine("\"downloadURL\":", from: validData), { if case .invalidSemanticValue = $0 { true } else { false } }),
            ("manifest and sidecar key mismatch", manifest(keyID: "TEST-ONLY-other-key"), { $0 == .invalidKeyID }),
            ("externalReference forbidden", replace("\"resourceID\":", with: "\"sourceKind\":\"externalReference\",\"resourceID\":", in: validData), { if case .unknownJSONField = $0 { true } else { false } })
        ]
        for item in semanticCases {
            try harness.expectManifestError(item.0, matching: item.2) {
                _ = try prepare(item.1, privateKey: privateKey, verifier: verifier)
            }
        }
        let official = manifest(resources: [officialPageResource()])
        _ = try prepare(official, privateKey: privateKey, verifier: verifier)
        harness.recordPass()
        let officialWithDirect = replace("\"distributionMode\":\"mirroredDownload\"",
                                         with: "\"distributionMode\":\"officialPageOnly\"",
                                         in: validData)
        try harness.expectManifestError("official page direct fields", matching: {
            if case .invalidSemanticValue = $0 { true } else { false }
        }) { _ = try prepare(officialWithDirect, privateKey: privateKey, verifier: verifier) }

        let expired = try prepare(manifest(issuedAt: "2029-01-01T00:00:00Z",
                                           expiresAt: "2029-02-01T00:00:00Z"),
                                  privateKey: privateKey, verifier: verifier)
        try harness.check("expired manifest is identified",
                          expired.verifiedManifest.validated.freshness == .expired)
        let duplicateRevokes = manifest(revocations: [revocation(), revocation()])
        try harness.expectManifestError("duplicate revocation", matching: {
            $0 == .duplicateRevocation
        }) { _ = try prepare(duplicateRevokes, privateKey: privateKey, verifier: verifier) }
        let overlappingRevokes = manifest(revocations: [
            revocation(minimum: 1, maximum: 3), revocation(minimum: 3, maximum: 5)
        ])
        try harness.expectManifestError("overlapping revocation", matching: {
            $0 == .duplicateRevocation
        }) { _ = try prepare(overlappingRevokes, privateKey: privateKey, verifier: verifier) }
        let activeRevoked = manifest(revocations: [
            revocation(id: "org.example.invalid.dictionary", minimum: 1, maximum: 1)
        ])
        try harness.expectManifestError("active resource revoked", matching: {
            $0 == .activeResourceRevoked
        }) { _ = try prepare(activeRevoked, privateKey: privateKey, verifier: verifier) }
    }

    private static func testRollbackStore(_ harness: inout Harness,
                                          privateKey: Curve25519.Signing.PrivateKey,
                                          verifier: ResourceManifestVerifier) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-D1B1-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VerifiedManifestStateStore(directoryURL: root)
        let version1 = try prepare(manifest(version: 1), privateKey: privateKey,
                                   verifier: verifier)
        try harness.check("prepare does not write state",
                          !FileManager.default.fileExists(atPath: store.stateURL.path))
        let saved1 = try await store.commitVerifiedState(version1)
        try harness.check("first state save", saved1.highestManifestVersion == 1)
        let version2 = try prepare(manifest(version: 2), privateKey: privateKey,
                                   verifier: verifier, prior: saved1)
        let saved2 = try await store.commitVerifiedState(version2)
        try harness.check("higher state save", saved2.highestManifestVersion == 2)
        let version2Again = try prepare(manifest(version: 2), privateKey: privateKey,
                                        verifier: verifier, prior: saved2)
        _ = try await store.commitVerifiedState(version2Again)
        harness.recordPass()

        let changed = replace("Synthetic test resource only.",
                              with: "Changed synthetic resource.", in: manifest(version: 2))
        try harness.expectManifestError("same version changed digest", matching: {
            $0 == .manifestVersionContentChanged
        }) { _ = try prepare(changed, privateKey: privateKey, verifier: verifier, prior: saved2) }
        try harness.expectManifestError("lower version rejected", matching: {
            $0 == .manifestRollback
        }) { _ = try prepare(manifest(version: 1), privateKey: privateKey,
                            verifier: verifier, prior: saved2) }
        let changedKeyState = VerifiedManifestState(
            highestManifestVersion: saved2.highestManifestVersion,
            manifestSHA256: saved2.manifestSHA256,
            verifiedKeyID: "TEST-ONLY-other-key",
            issuedAt: saved2.issuedAt,
            verifiedAt: saved2.verifiedAt
        )
        try harness.expectManifestError("same version key change", matching: {
            $0 == .manifestVersionKeyChanged
        }) { try ResourceManifestVerifier.validateRollback(candidate: changedKeyState,
                                                            priorState: saved2) }

        try Data("corrupt".utf8).write(to: store.stateURL)
        let recovered = try await store.load()
        try harness.check("backup recovery", recovered?.highestManifestVersion == 2)
        try Data("corrupt".utf8).write(to: store.backupURL)
        try await harness.expectStoreError("both states corrupt", matching: {
            $0 == .corruptState
        }) { _ = try await store.load() }

        let residualRoot = root.appendingPathComponent("residual", isDirectory: true)
        let residualStore = VerifiedManifestStateStore(directoryURL: residualRoot)
        try FileManager.default.createDirectory(at: residualRoot,
                                                withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: residualRoot.appendingPathComponent(".state.tmp"))
        let residualState = try await residualStore.load()
        try harness.check("temporary residue ignored", residualState == nil)

        let failureRoot = root.appendingPathComponent("failure", isDirectory: true)
        let failedStore = VerifiedManifestStateStore(
            directoryURL: failureRoot,
            hooks: VerifiedManifestStateStoreHooks(beforeReplace: { _ in
                throw VerifiedManifestStateStoreError.writeFailed
            })
        )
        try await harness.expectStoreError("atomic save failure", matching: {
            $0 == .writeFailed
        }) { _ = try await failedStore.commitVerifiedState(version1) }
        try harness.check("failed save has no primary",
                          !FileManager.default.fileExists(atPath: failedStore.stateURL.path))

        let permissionRoot = root.appendingPathComponent("permissions", isDirectory: true)
        let permissionStore = VerifiedManifestStateStore(directoryURL: permissionRoot)
        _ = try await permissionStore.commitVerifiedState(version1)
        let directoryMode = try fileMode(at: permissionRoot)
        let stateMode = try fileMode(at: permissionStore.stateURL)
        try harness.check("directory permission 0700", directoryMode == 0o700)
        try harness.check("state permission 0600", stateMode == 0o600)

        let concurrentRoot = root.appendingPathComponent("concurrent", isDirectory: true)
        let concurrentStore = VerifiedManifestStateStore(directoryURL: concurrentRoot)
        let version3 = try prepare(manifest(version: 3), privateKey: privateKey,
                                   verifier: verifier)
        let version4 = try prepare(manifest(version: 4), privateKey: privateKey,
                                   verifier: verifier)
        async let commit3 = commit(version3, to: concurrentStore)
        async let commit4 = commit(version4, to: concurrentStore)
        _ = await (commit3, commit4)
        let final = try await concurrentStore.load()
        try harness.check("concurrent commits serialize", final?.highestManifestVersion == 4)
    }

    private static func testBoundaries(_ harness: inout Harness,
                                       privateKey: Curve25519.Signing.PrivateKey,
                                       verifier: ResourceManifestVerifier) throws {
        try harness.check("production trust store empty",
                          TrustedManifestKeyStore.productionDefault.key(for: testKeyID) == nil)
        let prepared = try prepare(manifest(), privateKey: privateKey, verifier: verifier)
        try harness.check("canonical formatter only",
                          prepared.verifiedManifest.validated.manifest.resources.first?
                            .dictionaryFormat == .genericMDictV1)
        try harness.check("fallback only",
                          prepared.verifiedManifest.validated.manifest.resources.first?
                            .queryLevel == .fallback)
    }

    private static func fileMode(at url: URL) throws -> mode_t {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else {
            throw TestFailure("permissions missing")
        }
        return mode.uint16Value & 0o777
    }

    private static func commit(_ prepared: PreparedManifestVerification,
                               to store: VerifiedManifestStateStore) async
        -> Result<VerifiedManifestState, Error> {
        do { return .success(try await store.commitVerifiedState(prepared)) }
        catch { return .failure(error) }
    }
}
