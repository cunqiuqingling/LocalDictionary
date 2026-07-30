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
    case verifying
    case installing
    case indexing
    case installed
    case updateAvailable
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
    let operationState: ResourceCenterOperationState
    let failureMessage: String?
    let canInstall: Bool
    let canUpdate: Bool
}

struct ResourceCenterSnapshot: Equatable, Sendable {
    let catalogState: ResourceCenterCatalogState
    let catalogMessage: String
    let resources: [ResourceCenterResourceRow]
    let installedOpenResourceCount: Int
    let importedDictionaryCount: Int
    let preferredDictionaryCount: Int
    let catalogVerifiedAt: Date?

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
        catalog: DictionaryCatalog,
        catalogState: ResourceCenterCatalogState,
        catalogMessage: String,
        operations: [String: ResourceCenterOperationState] = [:],
        failures: [String: String] = [:],
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
        let resources = verifiedManifest?.validated.manifest.resources
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
                    case .downloading, .verifying, .installing, .indexing, .removing:
                        canInstall = false
                        canUpdate = false
                    default:
                        break
                    }
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
                    operationState: inferredState,
                    failureMessage: failures[resource.resourceID],
                    canInstall: canInstall,
                    canUpdate: canUpdate
                )
            }
            .sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedStandardCompare($1.displayName)
                        == .orderedAscending
                }
                return $0.id < $1.id
            } ?? []
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
