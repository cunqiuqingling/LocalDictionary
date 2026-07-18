import Foundation

struct StrictResourceManifestDecoder: Sendable {
    func decode(_ data: Data, limits: StrictJSONLimits) throws -> ResourceManifestV1 {
        let root = try StrictJSONDocument.parse(data, limits: limits)
        let object = try ObjectReader(value: root, path: "$", allowedFields: [
            "schemaVersion", "manifestVersion", "issuedAt", "expiresAt", "keyID",
            "minimumAppVersion", "resources", "revokedResources"
        ])
        return ResourceManifestV1(
            schemaVersion: try object.requiredUInt64("schemaVersion"),
            manifestVersion: try object.requiredUInt64("manifestVersion"),
            issuedAt: try object.requiredString("issuedAt"),
            expiresAt: try object.requiredString("expiresAt"),
            keyID: try object.requiredString("keyID"),
            minimumAppVersion: try object.requiredString("minimumAppVersion"),
            resources: try object.requiredArray("resources").enumerated().map {
                try decodeResource($0.element, path: "$.resources[\($0.offset)]")
            },
            revokedResources: try object.requiredArray("revokedResources").enumerated().map {
                try decodeRevocation($0.element, path: "$.revokedResources[\($0.offset)]")
            }
        )
    }

    private func decodeResource(_ value: StrictJSONValue, path: String) throws
        -> ResourceManifestResource {
        let object = try ObjectReader(value: value, path: path, allowedFields: [
            "resourceID", "resourceRevision", "displayName", "version", "languages",
            "description", "category", "queryLevel", "distributionMode",
            "sourceProjectURL", "officialDownloadPage", "downloadURL",
            "allowedDownloadHosts", "fileName", "archiveFormat", "compressedSize",
            "maximumDownloadedSize", "maximumExpandedSize", "sha256", "licenseName",
            "licenseVersion", "licenseURL", "attribution", "notice",
            "redistributionAllowed", "mirroringAllowed", "modificationAllowed",
            "formatConversionAllowed", "commercialUseAllowed", "shareAlikeRequired",
            "minimumAppVersion", "dictionaryFormat", "expectedEntryCount", "status",
            "reviewedAt", "reviewEvidence"
        ])
        return ResourceManifestResource(
            resourceID: try object.requiredString("resourceID"),
            resourceRevision: try object.requiredUInt64("resourceRevision"),
            displayName: try object.requiredString("displayName"),
            version: try object.requiredString("version"),
            languages: try object.requiredStringArray("languages"),
            description: try object.requiredString("description"),
            category: try object.requiredString("category"),
            queryLevel: try object.requiredEnum("queryLevel", as: ResourceManifestQueryLevel.self),
            distributionMode: try object.requiredEnum(
                "distributionMode", as: ResourceDistributionMode.self
            ),
            sourceProjectURL: try object.requiredString("sourceProjectURL"),
            officialDownloadPage: try object.requiredString("officialDownloadPage"),
            downloadURL: try object.optionalString("downloadURL"),
            allowedDownloadHosts: try object.optionalStringArray("allowedDownloadHosts"),
            fileName: try object.optionalString("fileName"),
            archiveFormat: try object.optionalEnum("archiveFormat", as: ResourceArchiveFormat.self),
            compressedSize: try object.optionalUInt64("compressedSize"),
            maximumDownloadedSize: try object.optionalUInt64("maximumDownloadedSize"),
            maximumExpandedSize: try object.optionalUInt64("maximumExpandedSize"),
            sha256: try object.optionalString("sha256"),
            licenseName: try object.requiredString("licenseName"),
            licenseVersion: try object.requiredString("licenseVersion"),
            licenseURL: try object.requiredString("licenseURL"),
            attribution: try object.requiredString("attribution"),
            notice: try decodeNotice(object.requiredValue("notice"), path: path + ".notice"),
            redistributionAllowed: try object.requiredBool("redistributionAllowed"),
            mirroringAllowed: try object.requiredBool("mirroringAllowed"),
            modificationAllowed: try object.requiredBool("modificationAllowed"),
            formatConversionAllowed: try object.requiredBool("formatConversionAllowed"),
            commercialUseAllowed: try object.requiredBool("commercialUseAllowed"),
            shareAlikeRequired: try object.requiredBool("shareAlikeRequired"),
            minimumAppVersion: try object.requiredString("minimumAppVersion"),
            dictionaryFormat: try object.requiredEnum(
                "dictionaryFormat", as: ResourceDictionaryFormat.self
            ),
            expectedEntryCount: try decodeEntryCount(
                object.requiredValue("expectedEntryCount"), path: path + ".expectedEntryCount"
            ),
            status: try object.requiredEnum("status", as: ResourceManifestStatus.self),
            reviewedAt: try object.requiredString("reviewedAt"),
            reviewEvidence: try object.requiredArray("reviewEvidence").enumerated().map {
                try decodeEvidence($0.element, path: "\(path).reviewEvidence[\($0.offset)]")
            }
        )
    }

    private func decodeNotice(_ value: StrictJSONValue, path: String) throws
        -> ResourceManifestNotice {
        let object = try ObjectReader(value: value, path: path,
                                      allowedFields: ["kind", "text"])
        return ResourceManifestNotice(
            kind: try object.requiredEnum("kind", as: ResourceNoticeKind.self),
            text: try object.requiredString("text")
        )
    }

    private func decodeEntryCount(_ value: StrictJSONValue, path: String) throws
        -> ResourceManifestEntryCountRange {
        let object = try ObjectReader(value: value, path: path,
                                      allowedFields: ["minimum", "maximum"])
        return ResourceManifestEntryCountRange(
            minimum: try object.requiredUInt64("minimum"),
            maximum: try object.requiredUInt64("maximum")
        )
    }

    private func decodeEvidence(_ value: StrictJSONValue, path: String) throws
        -> ResourceManifestReviewEvidence {
        let object = try ObjectReader(value: value, path: path,
                                      allowedFields: ["kind", "url", "sha256"])
        return ResourceManifestReviewEvidence(
            kind: try object.requiredString("kind"),
            url: try object.requiredString("url"),
            sha256: try object.requiredString("sha256")
        )
    }

    private func decodeRevocation(_ value: StrictJSONValue, path: String) throws
        -> RevokedResourceRange {
        let object = try ObjectReader(value: value, path: path, allowedFields: [
            "resourceID", "minimumRevision", "maximumRevision", "reasonCode", "effectiveAt"
        ])
        return RevokedResourceRange(
            resourceID: try object.requiredString("resourceID"),
            minimumRevision: try object.requiredUInt64("minimumRevision"),
            maximumRevision: try object.requiredUInt64("maximumRevision"),
            reasonCode: try object.requiredString("reasonCode"),
            effectiveAt: try object.requiredString("effectiveAt")
        )
    }
}

private struct ObjectReader {
    let values: [String: StrictJSONValue]
    let path: String

    init(value: StrictJSONValue, path: String, allowedFields: Set<String>) throws {
        guard case .object(let values) = value else {
            throw ManifestVerificationError.invalidJSONType(path: path)
        }
        guard Set(values.keys).isSubset(of: allowedFields) else {
            throw ManifestVerificationError.unknownJSONField(path: path)
        }
        self.values = values
        self.path = path
    }

    init(value: StrictJSONValue, path: String, allowedFields: [String]) throws {
        try self.init(value: value, path: path, allowedFields: Set(allowedFields))
    }

    func requiredValue(_ key: String) throws -> StrictJSONValue {
        guard let value = values[key] else {
            throw ManifestVerificationError.missingJSONField(path: fieldPath(key))
        }
        guard value != .null else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard case .string(let value) = try requiredValue(key) else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let string) = value else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return string
    }

    func requiredUInt64(_ key: String) throws -> UInt64 {
        guard case .number(let raw) = try requiredValue(key),
              !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(raw) else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return value
    }

    func optionalUInt64(_ key: String) throws -> UInt64? {
        guard let rawValue = values[key] else { return nil }
        guard case .number(let raw) = rawValue,
              !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(raw) else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return value
    }

    func requiredBool(_ key: String) throws -> Bool {
        guard case .boolean(let value) = try requiredValue(key) else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return value
    }

    func requiredArray(_ key: String) throws -> [StrictJSONValue] {
        guard case .array(let value) = try requiredValue(key) else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return value
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        try requiredArray(key).enumerated().map { index, value in
            guard case .string(let string) = value else {
                throw ManifestVerificationError.invalidJSONType(
                    path: "\(fieldPath(key))[\(index)]"
                )
            }
            return string
        }
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard case .array(let array) = value else {
            throw ManifestVerificationError.invalidJSONType(path: fieldPath(key))
        }
        return try array.enumerated().map { index, item in
            guard case .string(let string) = item else {
                throw ManifestVerificationError.invalidJSONType(
                    path: "\(fieldPath(key))[\(index)]"
                )
            }
            return string
        }
    }

    func requiredEnum<T>(_ key: String, as type: T.Type) throws -> T
        where T: RawRepresentable, T.RawValue == String {
        let raw = try requiredString(key)
        guard let value = T(rawValue: raw) else {
            throw ManifestVerificationError.invalidSemanticValue(path: fieldPath(key))
        }
        return value
    }

    func optionalEnum<T>(_ key: String, as type: T.Type) throws -> T?
        where T: RawRepresentable, T.RawValue == String {
        guard let raw = try optionalString(key) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw ManifestVerificationError.invalidSemanticValue(path: fieldPath(key))
        }
        return value
    }

    private func fieldPath(_ key: String) -> String { path + "." + key }
}
