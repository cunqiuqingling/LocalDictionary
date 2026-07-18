import Foundation

enum ResourceManifestValidation {
    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

struct ResourceManifestValidator: Sendable {
    func validate(_ manifest: ResourceManifestV1,
                  policy: ManifestVerificationPolicy,
                  now: Date) throws -> ValidatedResourceManifest {
        guard manifest.schemaVersion == 1 else {
            throw ManifestVerificationError.unsupportedSchemaVersion
        }
        guard manifest.manifestVersion > 0 else {
            throw ManifestVerificationError.invalidSemanticValue(path: "$.manifestVersion")
        }
        guard ResourceManifestSignatureEnvelope.isValidKeyID(manifest.keyID) else {
            throw ManifestVerificationError.invalidKeyID
        }
        guard manifest.resources.count <= policy.maximumResources else {
            throw ManifestVerificationError.JSONLimitExceeded(path: "$.resources")
        }
        guard manifest.revokedResources.count <= policy.maximumRevocations else {
            throw ManifestVerificationError.JSONLimitExceeded(path: "$.revokedResources")
        }

        let issuedAt = try strictRFC3339UTC(manifest.issuedAt, path: "$.issuedAt")
        let expiresAt = try strictRFC3339UTC(manifest.expiresAt, path: "$.expiresAt")
        guard expiresAt > issuedAt else {
            throw ManifestVerificationError.invalidSemanticValue(path: "$.expiresAt")
        }
        guard issuedAt <= now.addingTimeInterval(policy.allowedFutureClockSkew) else {
            throw ManifestVerificationError.manifestIssuedInFuture
        }
        let minimumAppVersion = try ManifestAppVersion(manifest.minimumAppVersion)
        guard minimumAppVersion <= policy.currentAppVersion else {
            throw ManifestVerificationError.incompatibleAppVersion
        }

        var resourceIDs: Set<String> = []
        for (index, resource) in manifest.resources.enumerated() {
            guard resourceIDs.insert(resource.resourceID).inserted else {
                throw ManifestVerificationError.duplicateResourceID
            }
            try validate(resource, path: "$.resources[\(index)]", policy: policy)
        }
        try validateRevocations(manifest.revokedResources,
                                resources: manifest.resources)

        return ValidatedResourceManifest(
            manifest: manifest,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            minimumAppVersion: minimumAppVersion,
            freshness: expiresAt <= now ? .expired : .current
        )
    }

    private func validate(_ resource: ResourceManifestResource, path: String,
                          policy: ManifestVerificationPolicy) throws {
        try requireToken(resource.resourceID, path: path + ".resourceID", maximum: 128)
        guard resource.resourceRevision > 0 else {
            throw ManifestVerificationError.invalidSemanticValue(
                path: path + ".resourceRevision"
            )
        }
        try requireText(resource.displayName, path: path + ".displayName", maximum: 512)
        try requireToken(resource.version, path: path + ".version", maximum: 64,
                         extraAllowed: [43])
        try requireText(resource.description, path: path + ".description", maximum: 4_096,
                        allowNewlines: true)
        try requireToken(resource.category, path: path + ".category", maximum: 64)
        guard resource.queryLevel == .fallback else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".queryLevel")
        }
        guard resource.dictionaryFormat == .genericMDictV1 else {
            throw ManifestVerificationError.invalidSemanticValue(
                path: path + ".dictionaryFormat"
            )
        }
        guard !resource.languages.isEmpty,
              resource.languages.count <= policy.maximumLanguagesPerResource else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".languages")
        }
        var languages: Set<String> = []
        for language in resource.languages {
            try requireLanguage(language, path: path + ".languages")
            guard languages.insert(language.lowercased()).inserted else {
                throw ManifestVerificationError.invalidSemanticValue(path: path + ".languages")
            }
        }

        _ = try validatedHTTPSURL(resource.sourceProjectURL,
                                  path: path + ".sourceProjectURL")
        _ = try validatedHTTPSURL(resource.officialDownloadPage,
                                  path: path + ".officialDownloadPage")
        _ = try validatedHTTPSURL(resource.licenseURL, path: path + ".licenseURL")
        try requireText(resource.licenseName, path: path + ".licenseName", maximum: 256)
        try requireText(resource.licenseVersion, path: path + ".licenseVersion", maximum: 128)
        try requireText(resource.attribution, path: path + ".attribution", maximum: 4_096,
                        allowNewlines: true)
        guard resource.notice.kind == .inline else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".notice.kind")
        }
        try requireText(resource.notice.text, path: path + ".notice.text", maximum: 16_384,
                        allowNewlines: true)
        let resourceMinimumAppVersion = try ManifestAppVersion(resource.minimumAppVersion)
        guard resourceMinimumAppVersion <= policy.currentAppVersion else {
            throw ManifestVerificationError.incompatibleAppVersion
        }
        guard resource.expectedEntryCount.minimum > 0,
              resource.expectedEntryCount.minimum <= resource.expectedEntryCount.maximum else {
            throw ManifestVerificationError.invalidSemanticValue(
                path: path + ".expectedEntryCount"
            )
        }
        _ = try strictRFC3339UTC(resource.reviewedAt, path: path + ".reviewedAt")
        guard !resource.reviewEvidence.isEmpty,
              resource.reviewEvidence.count <= policy.maximumEvidenceItemsPerResource else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".reviewEvidence")
        }
        for (index, evidence) in resource.reviewEvidence.enumerated() {
            let evidencePath = "\(path).reviewEvidence[\(index)]"
            try requireToken(evidence.kind, path: evidencePath + ".kind", maximum: 64)
            _ = try validatedHTTPSURL(evidence.url, path: evidencePath + ".url")
            guard ResourceManifestValidation.isLowercaseSHA256(evidence.sha256) else {
                throw ManifestVerificationError.invalidSemanticValue(
                    path: evidencePath + ".sha256"
                )
            }
        }
        guard !resource.mirroringAllowed || resource.redistributionAllowed else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".mirroringAllowed")
        }

        switch resource.distributionMode {
        case .mirroredDownload:
            try validateMirroredResource(resource, path: path, policy: policy)
        case .officialPageOnly:
            let directValuesAreAbsent = resource.downloadURL == nil &&
                resource.allowedDownloadHosts == nil && resource.fileName == nil &&
                resource.archiveFormat == nil && resource.compressedSize == nil &&
                resource.maximumDownloadedSize == nil && resource.maximumExpandedSize == nil &&
                resource.sha256 == nil
            guard directValuesAreAbsent else {
                throw ManifestVerificationError.invalidSemanticValue(
                    path: path + ".distributionMode"
                )
            }
        }
    }

    private func validateMirroredResource(_ resource: ResourceManifestResource, path: String,
                                          policy: ManifestVerificationPolicy) throws {
        guard resource.redistributionAllowed, resource.mirroringAllowed,
              let downloadURL = resource.downloadURL,
              let allowedHosts = resource.allowedDownloadHosts,
              let fileName = resource.fileName,
              let archiveFormat = resource.archiveFormat,
              let compressedSize = resource.compressedSize,
              let maximumDownloadedSize = resource.maximumDownloadedSize,
              let maximumExpandedSize = resource.maximumExpandedSize,
              let sha256 = resource.sha256 else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".distributionMode")
        }
        guard archiveFormat == .none else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".archiveFormat")
        }
        let downloadHost = try validatedHTTPSURL(downloadURL, path: path + ".downloadURL")
        guard !allowedHosts.isEmpty, allowedHosts.count <= policy.maximumHostsPerResource else {
            throw ManifestVerificationError.invalidSemanticValue(
                path: path + ".allowedDownloadHosts"
            )
        }
        var normalizedHosts: Set<String> = []
        for host in allowedHosts {
            let normalized = try validatedHost(host, path: path + ".allowedDownloadHosts")
            guard normalizedHosts.insert(normalized).inserted else {
                throw ManifestVerificationError.invalidSemanticValue(
                    path: path + ".allowedDownloadHosts"
                )
            }
        }
        guard normalizedHosts.contains(downloadHost) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".downloadURL")
        }
        try validateFileName(fileName, path: path + ".fileName")
        guard URL(fileURLWithPath: fileName).pathExtension
            .caseInsensitiveCompare("mdx") == .orderedSame else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".fileName")
        }
        guard compressedSize > 0,
              compressedSize <= maximumDownloadedSize,
              maximumDownloadedSize <= policy.maximumDownloadedResourceBytes,
              maximumExpandedSize >= maximumDownloadedSize,
              maximumExpandedSize <= policy.maximumExpandedResourceBytes else {
            throw ManifestVerificationError.invalidSemanticValue(
                path: path + ".maximumDownloadedSize"
            )
        }
        guard ResourceManifestValidation.isLowercaseSHA256(sha256) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path + ".sha256")
        }
    }

    private func validateRevocations(_ revocations: [RevokedResourceRange],
                                     resources: [ResourceManifestResource]) throws {
        var rangesByResource: [String: [(UInt64, UInt64)]] = [:]
        for (index, revocation) in revocations.enumerated() {
            let path = "$.revokedResources[\(index)]"
            try requireToken(revocation.resourceID, path: path + ".resourceID", maximum: 128)
            try requireToken(revocation.reasonCode, path: path + ".reasonCode", maximum: 64)
            guard revocation.minimumRevision > 0,
                  revocation.minimumRevision <= revocation.maximumRevision else {
                throw ManifestVerificationError.invalidSemanticValue(path: path)
            }
            _ = try strictRFC3339UTC(revocation.effectiveAt, path: path + ".effectiveAt")
            var existingRanges = rangesByResource[revocation.resourceID, default: []]
            guard !existingRanges.contains(where: {
                max($0.0, revocation.minimumRevision) <=
                    min($0.1, revocation.maximumRevision)
            }) else {
                throw ManifestVerificationError.duplicateRevocation
            }
            existingRanges.append((revocation.minimumRevision, revocation.maximumRevision))
            rangesByResource[revocation.resourceID] = existingRanges
        }
        for resource in resources {
            if rangesByResource[resource.resourceID, default: []].contains(where: {
                $0.0 <= resource.resourceRevision && resource.resourceRevision <= $0.1
            }) {
                throw ManifestVerificationError.activeResourceRevoked
            }
        }
    }

    private func strictRFC3339UTC(_ value: String, path: String) throws -> Date {
        let bytes = Array(value.utf8)
        let digitPositions = Set([0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18])
        guard bytes.count == 20,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58, bytes[19] == 90,
              digitPositions.allSatisfy({ (48...57).contains(bytes[$0]) }) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
        return date
    }

    private func validatedHTTPSURL(_ value: String, path: String) throws -> String {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              let host = components.host else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
        return try validatedHost(host, path: path)
    }

    private func validatedHost(_ value: String, path: String) throws -> String {
        let host = value.lowercased()
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty, bytes.count <= 253, bytes.count == host.count,
              !host.hasSuffix("."), !host.contains(":"), !host.contains("/"),
              !host.contains("@"), !isIPv4Literal(host) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            let labelBytes = Array(label.utf8)
            return !labelBytes.isEmpty && labelBytes.count <= 63 &&
                labelBytes.first != 45 && labelBytes.last != 45 && labelBytes.allSatisfy {
                    ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
                }
        }) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
        return host
    }

    private func isIPv4Literal(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy(\.isNumber) &&
                label.count <= 3 && (Int(label).map { $0 <= 255 } ?? false)
        }
    }

    private func validateFileName(_ value: String, path: String) throws {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), bytes.count == value.count,
              bytes.first != 46, bytes.last != 46, bytes.last != 32,
              value != "..", bytes.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                    ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 45
              }) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
    }

    private func requireLanguage(_ value: String, path: String) throws {
        let bytes = Array(value.utf8)
        guard (1...35).contains(bytes.count), bytes.count == value.count,
              bytes.first != 45, bytes.last != 45, bytes.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                    ($0 >= 48 && $0 <= 57) || $0 == 45
              }) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
    }

    private func requireToken(_ value: String, path: String, maximum: Int,
                              extraAllowed: Set<UInt8> = []) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximum, bytes.count == value.count,
              bytes.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                    ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 45 ||
                    extraAllowed.contains($0)
              }) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
    }

    private func requireText(_ value: String, path: String, maximum: Int,
                             allowNewlines: Bool = false) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximum,
              value.unicodeScalars.allSatisfy({ scalar in
                  if scalar.value >= 0x20 { return true }
                  return allowNewlines && (scalar.value == 0x0a || scalar.value == 0x09)
              }) else {
            throw ManifestVerificationError.invalidSemanticValue(path: path)
        }
    }
}
