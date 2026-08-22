import Foundation

enum ResourceCenterCatalogState: Equatable, Sendable {
    case catalogUnavailable
    case loading
    case catalogInvalid
    case available
    case offlineVerified
}

enum ResourceCenterOperationState: Equatable, Sendable {
    case available
    case downloading(received: UInt64, expected: UInt64?)
    case downloaded
    case verifying
    case installing
    case converting(processed: UInt64, total: UInt64?)
    case indexing
    case validatingIndex
    case publishing
    case installed
    case updateAvailable
    case needsReinstall
    case removing
    case failed
    case cancelled
}

struct ResourceCenterResourceRow: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let summary: String
    let languages: String
    let category: String
    let version: String
    let installedVersion: String?
    let installedSize: UInt64?
    let licenseName: String
    let licenseURL: String
    let publisher: String
    let sourceURL: String
    let redistributionStatement: String
    let sourceFormat: String
    let checksumSummary: String
    let attribution: String
    let localConversionStatement: String
    let operationState: ResourceCenterOperationState
    let failureMessage: String?
    let diagnosticText: String?
    let canInstall: Bool
    let canUpdate: Bool
    let isRecommendedForLanguagePair: Bool
}

struct ResourceCenterSnapshot: Equatable, Sendable {
    let catalogState: ResourceCenterCatalogState
    let catalogMessage: String
    let resources: [ResourceCenterResourceRow]
    let installedOpenResourceCount: Int
    let importedDictionaryCount: Int
    let preferredDictionaryCount: Int
    let catalogVerifiedAt: Date?

    var recommendedResources: [ResourceCenterResourceRow] {
        Array(resources.filter(\.isRecommendedForLanguagePair).prefix(3))
    }

    static func unavailable(catalog: DictionaryCatalog,
                            message: String = "尚未配置经过审核的开放资源目录。") -> Self {
        ResourceCenterSnapshot(
            catalogState: .catalogUnavailable,
            catalogMessage: message,
            resources: [],
            installedOpenResourceCount: catalog.dictionaries.filter {
                $0.sourceKind == .openResource
            }.count,
            importedDictionaryCount: catalog.dictionaries.filter {
                $0.sourceKind == .managedLocal
            }.count,
            preferredDictionaryCount: catalog.dictionaries.filter {
                $0.queryLevel == .preferred
            }.count,
            catalogVerifiedAt: nil
        )
    }
}

enum ResourceCenterPresentation {
    static func snapshot(
        verifiedManifest: VerifiedResourceManifest?,
        bundledResources: [BundledOpenResourceDefinition] = [],
        catalog: DictionaryCatalog,
        catalogState: ResourceCenterCatalogState,
        catalogMessage: String,
        operations: [String: ResourceCenterOperationState] = [:],
        failures: [String: String] = [:],
        diagnostics: [String: String] = [:],
        nativeLanguageCode: String = "zh-Hans",
        learningLanguageCode: String = "en",
        verifiedAt: Date? = nil
    ) -> ResourceCenterSnapshot {
        let openDescriptors = catalog.dictionaries.filter {
            $0.openResourceMetadata != nil
        }
        let installed = Dictionary(grouping: openDescriptors) {
            $0.openResourceMetadata!.resourceID
        }.compactMapValues { values in
            values.max {
                $0.openResourceMetadata!.resourceRevision <
                    $1.openResourceMetadata!.resourceRevision
            }
        }
        let starterRows = bundledResources.map { resource -> ResourceCenterResourceRow in
            let descriptor = installed[resource.resourceID]
            let metadata = descriptor?.openResourceMetadata
            var canInstall = metadata == nil
            var canUpdate = metadata.map { resource.resourceRevision > $0.resourceRevision } ?? false
            let state: ResourceCenterOperationState
            if let explicit = operations[resource.resourceID] {
                state = explicit
                switch explicit {
                case .downloading, .downloaded, .verifying, .installing, .converting,
                     .indexing, .validatingIndex, .publishing, .removing:
                    canInstall = false; canUpdate = false
                default: break
                }
            } else if let descriptor, requiresReinstallation(descriptor) {
                state = .needsReinstall
                canInstall = true
                canUpdate = false
            } else if let metadata {
                state = resource.resourceRevision > metadata.resourceRevision
                    ? .updateAvailable : .installed
            } else {
                state = .available
            }
            return ResourceCenterResourceRow(
                id: resource.resourceID,
                displayName: resource.title,
                summary: resource.summary,
                languages: resource.languageDisplay,
                category: resource.category,
                version: resource.version,
                installedVersion: metadata?.resourceVersion,
                // A live official endpoint may use chunked transfer and therefore cannot
                // advertise a byte count during discovery.  Once installed, the durable
                // receipt is authoritative for the payload that was actually downloaded.
                installedSize: metadata?.payloadBytes ??
                    (resource.downloadBytes > 0 ? resource.downloadBytes : nil),
                licenseName: resource.licenseIdentifier,
                licenseURL: resource.licenseURL.absoluteString,
                publisher: resource.publisher,
                sourceURL: resource.downloadURL.absoluteString,
                redistributionStatement: resource.redistributionStatement,
                sourceFormat: resource.sourceFormat.rawValue,
                checksumSummary: resource.isLiveDiscoveredResource
                    ? (resource.officialDigest.isEmpty
                        ? "下载后在本机计算 SHA-256 并写入安装凭据。"
                        : "使用官方实时目录的 \(resource.officialDigestAlgorithm) 校验；" +
                            "SHA-256 在下载后本机记录。")
                    : "SHA-256 \(resource.sha256)；\(resource.digestProvenance) " +
                        "\(resource.officialDigestAlgorithm) \(resource.officialDigest)",
                attribution: resource.attribution,
                localConversionStatement:
                    "下载后在本机转换为 LocalDictionary 内部 SQLite 索引，仅供本地查询。",
                operationState: state,
                failureMessage: failures[resource.resourceID],
                diagnosticText: diagnostics[resource.resourceID],
                canInstall: canInstall,
                canUpdate: canUpdate,
                isRecommendedForLanguagePair: resource.isRecommended(
                    nativeLanguageCode: nativeLanguageCode,
                    learningLanguageCode: learningLanguageCode
                )
            )
        }
        let remoteRows = verifiedManifest?.validated.manifest.resources
            .filter { $0.status == .active && $0.distributionMode == .mirroredDownload }
            .map { resource -> ResourceCenterResourceRow in
                let descriptor = installed[resource.resourceID]
                let metadata = descriptor?.openResourceMetadata
                let inferredState: ResourceCenterOperationState
                var canInstall = metadata == nil
                var canUpdate = metadata.map {
                    resource.resourceRevision > $0.resourceRevision
                } ?? false
                let sameRevisionChanged = metadata.map {
                    resource.resourceRevision == $0.resourceRevision &&
                        resource.sha256 != $0.payloadSHA256
                } ?? false
                if let explicit = operations[resource.resourceID] {
                    inferredState = explicit
                    switch explicit {
                    case .downloading, .downloaded, .verifying, .installing, .converting,
                         .indexing, .validatingIndex, .publishing, .removing:
                        canInstall = false
                        canUpdate = false
                    default:
                        break
                    }
                } else if let descriptor, requiresReinstallation(descriptor) {
                    inferredState = .needsReinstall
                    canInstall = true
                    canUpdate = false
                } else if let metadata {
                    if resource.resourceRevision > metadata.resourceRevision {
                        inferredState = .updateAvailable
                    } else if sameRevisionChanged {
                        inferredState = .failed
                    } else {
                        inferredState = descriptor?.state == .indexing ? .indexing : .installed
                    }
                } else {
                    inferredState = .available
                }
                if sameRevisionChanged {
                    canInstall = false
                    canUpdate = false
                }
                let sourceHost = URL(string: resource.sourceProjectURL)?.host
                    ?? resource.sourceProjectURL
                return ResourceCenterResourceRow(
                    id: resource.resourceID,
                    displayName: resource.displayName,
                    summary: resource.description,
                    languages: resource.languages.joined(separator: " · "),
                    category: resource.category,
                    version: resource.version,
                    installedVersion: metadata?.resourceVersion,
                    installedSize: resource.compressedSize,
                    licenseName: [resource.licenseName, resource.licenseVersion]
                        .filter { !$0.isEmpty }.joined(separator: " "),
                    licenseURL: resource.licenseURL,
                    publisher: sourceHost,
                    sourceURL: resource.sourceProjectURL,
                    redistributionStatement: resource.redistributionAllowed &&
                        resource.mirroringAllowed
                        ? "许可证证据允许镜像再分发；安装前可查看来源与许可证。"
                        : "不可由 Resource Center 分发。",
                    sourceFormat: resource.dictionaryFormat.rawValue,
                    checksumSummary: resource.sha256.map { "SHA-256 \($0)" } ?? "—",
                    attribution: resource.attribution,
                    localConversionStatement: "已签名远程目录的兼容安装路径。",
                    operationState: inferredState,
                    failureMessage: failures[resource.resourceID],
                    diagnosticText: diagnostics[resource.resourceID],
                    canInstall: canInstall,
                    canUpdate: canUpdate,
                    isRecommendedForLanguagePair: false
                )
            }
            .sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedStandardCompare($1.displayName)
                        == .orderedAscending
                }
                return $0.id < $1.id
            } ?? []
        let starterIDs = Set(starterRows.map(\.id))
        let resources = (starterRows + remoteRows.filter { !starterIDs.contains($0.id) })
            .sorted {
                if $0.isRecommendedForLanguagePair != $1.isRecommendedForLanguagePair {
                    return $0.isRecommendedForLanguagePair
                }
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedStandardCompare($1.displayName) ==
                        .orderedAscending
                }
                return $0.id < $1.id
            }
        return ResourceCenterSnapshot(
            catalogState: catalogState,
            catalogMessage: catalogMessage,
            resources: resources,
            installedOpenResourceCount: installed.count,
            importedDictionaryCount: catalog.dictionaries.filter {
                $0.sourceKind == .managedLocal
            }.count,
            preferredDictionaryCount: catalog.dictionaries.filter {
                $0.queryLevel == .preferred
            }.count,
            catalogVerifiedAt: verifiedAt
        )
    }

    static func requiresReinstallation(_ descriptor: DictionaryDescriptor) -> Bool {
        descriptor.storageOwnership == .appManagedOpenResource &&
            [.missingResources, .unavailable, .invalid, .corrupt, .staleIndex]
                .contains(descriptor.state)
    }

    static func safeFailureMessage(_ error: Error) -> String {
        switch error {
        case let error as ResourceNetworkError:
            return error.errorDescription ?? "资源目录不可用。"
        case let error as ResourcePayloadDownloadError:
            return error.errorDescription ?? "开放词典下载失败。"
        case let error as OpenResourceInstallationError:
            return error.errorDescription ?? "开放词典安装失败。"
        case let error as VerifiedManifestStateStoreError:
            return error.errorDescription ?? "资源目录状态无效。"
        default:
            return "操作未完成；未验证的内容没有被安装。"
        }
    }
}
