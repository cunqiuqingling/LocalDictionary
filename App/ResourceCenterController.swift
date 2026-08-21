import Foundation

@MainActor
final class ResourceCenterController {
    typealias SnapshotObserver = (ResourceCenterSnapshot) -> Void
    typealias CatalogObserver = (DictionaryCatalog) -> Void

    private let configuration: ResourceCenterProductionConfiguration
    private let catalogStore: DictionaryCatalogStore
    private let manifestStateStore: VerifiedManifestStateStore
    private let manifestLoader: ResourceManifestRemoteLoader?
    private let payloadDownloader: ResourcePayloadDownloadCoordinator?
    private let installationCoordinator: OpenResourceInstallationCoordinator
    private let freeDictInstallationCoordinator = FreeDictStarDictInstallationCoordinator()
    private let auditedInstallationCoordinator =
        AuditedOpenResourceInstallationCoordinator()
    private let officialDiscoveryClient: OfficialOpenResourceDiscoveryClient
    private let officialPayloadDownloader: OfficialOpenResourcePayloadDownloader
    private let indexCoordinator: ManagedDictionaryIndexCoordinator
    private let backgroundWorkCoordinator: LocalHeavyWorkCoordinator
    private var nativeLanguageCode: String
    private var learningLanguageCode: String
    private var removalCoordinator: ManagedDictionaryRemovalCoordinator?
    private let dictionariesRoot: URL
    private let onCatalogChanged: CatalogObserver

    private(set) var catalog: DictionaryCatalog
    private(set) var snapshot: ResourceCenterSnapshot
    private var verifiedManifest: VerifiedResourceManifest?
    private var discoveredResources: [BundledOpenResourceDefinition] = []
    private var verifiedAt: Date?
    private var operations: [String: ResourceCenterOperationState] = [:]
    private var failures: [String: String] = [:]
    private var diagnostics: [String: String] = [:]
    private var activeTask: Task<Void, Never>?
    private var activeTaskID: UUID?
    private var finalizingResourceIDs: Set<String> = []
    private var finalizationTasks: [String: Task<Void, Never>] = [:]
    private var pendingAutoEnableDictionaryIDs: Set<String> = []
    var onSnapshotChanged: SnapshotObserver?

    init(
        configuration: ResourceCenterProductionConfiguration = .current,
        catalog: DictionaryCatalog,
        catalogStore: DictionaryCatalogStore,
        installationCoordinator: OpenResourceInstallationCoordinator,
        indexCoordinator: ManagedDictionaryIndexCoordinator,
        backgroundWorkCoordinator: LocalHeavyWorkCoordinator = LocalHeavyWorkCoordinator(),
        nativeLanguageCode: String = "zh-Hans",
        learningLanguageCode: String = "en",
        removalCoordinator: ManagedDictionaryRemovalCoordinator? = nil,
        applicationSupportRoot: URL = DictionaryImportService.defaultApplicationSupportRootURL(),
        manifestStateStore: VerifiedManifestStateStore = VerifiedManifestStateStore(),
        onCatalogChanged: @escaping CatalogObserver = { _ in }
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.catalogStore = catalogStore
        self.installationCoordinator = installationCoordinator
        self.indexCoordinator = indexCoordinator
        self.backgroundWorkCoordinator = backgroundWorkCoordinator
        self.nativeLanguageCode = nativeLanguageCode
        self.learningLanguageCode = learningLanguageCode
        self.removalCoordinator = removalCoordinator
        self.manifestStateStore = manifestStateStore
        self.onCatalogChanged = onCatalogChanged
        dictionariesRoot = applicationSupportRoot.appendingPathComponent(
            "Dictionaries", isDirectory: true
        )
        // Keep the fd-bound staging root as one direct child of the already-established App
        // support root. The former nested ResourceCenter/Staging path failed before request
        // creation when ResourceCenter did not yet exist: a single mkdir(Staging) returned ENOENT.
        let stagingRoot = applicationSupportRoot.appendingPathComponent(
            "ResourceCenter-Staging", isDirectory: true
        )
        officialDiscoveryClient = OfficialOpenResourceDiscoveryClient()
        officialPayloadDownloader = OfficialOpenResourcePayloadDownloader(
            stagingRoot: stagingRoot
        )

        if let appVersion = try? ManifestAppVersion(configuration.currentAppVersion),
           let trustStore = try? configuration.trustedKeyStore() {
            let verifier = ResourceManifestVerifier(
                trustStore: trustStore,
                policy: ManifestVerificationPolicy(currentAppVersion: appVersion)
            )
            manifestLoader = try? ResourceManifestRemoteLoader(verifier: verifier)
        } else {
            manifestLoader = nil
        }
        if let policy = try? ResourcePayloadDownloadPolicy(
            applicationAllowedHosts: configuration.payloadAllowedHosts
        ), !configuration.payloadAllowedHosts.isEmpty {
            payloadDownloader = ResourcePayloadDownloadCoordinator(
                policy: policy,
                stagingRoot: stagingRoot
            )
        } else {
            payloadDownloader = nil
        }
        snapshot = .unavailable(catalog: catalog)
        rebuildSnapshot()
    }

    func synchronize(catalog: DictionaryCatalog) {
        self.catalog = catalog
        rebuildSnapshot()
        enableCompletedNewInstallIfNeeded()
        finalizeReadyUpdatesIfNeeded()
    }

    func setRemovalCoordinator(_ coordinator: ManagedDictionaryRemovalCoordinator) {
        removalCoordinator = coordinator
        finalizeReadyUpdatesIfNeeded()
    }

    func updateLanguagePair(nativeLanguageCode: String,
                            learningLanguageCode: String) {
        guard self.nativeLanguageCode != nativeLanguageCode ||
                self.learningLanguageCode != learningLanguageCode else { return }
        activeTask?.cancel()
        activeTask = nil
        activeTaskID = nil
        self.nativeLanguageCode = nativeLanguageCode
        self.learningLanguageCode = learningLanguageCode
        discoveredResources = []
        verifiedAt = nil
        rebuildSnapshot()
    }

    func refresh() {
        guard activeTask == nil else { return }
        ManualEvidenceRecorder.shared.record(
            "openResourceDiscoveryStarted",
            strings: [
                "nativeLanguage": nativeLanguageCode,
                "learningLanguage": learningLanguageCode,
                "discoveryMode": "officialLiveCatalog"
            ]
        )
        setCatalogState(
            .loading,
            message: "正在按母语与学习语言从官方目录匹配双语词典…"
        )
        let taskID = UUID()
        activeTaskID = taskID
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTask(taskID) }
            do {
                let matching = try await officialDiscoveryClient.discover(
                    nativeLanguageCode: nativeLanguageCode,
                    learningLanguageCode: learningLanguageCode
                )
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                discoveredResources = matching
                ManualEvidenceRecorder.shared.record(
                    "openResourceDiscoveryCompleted",
                    strings: [
                        "nativeLanguage": nativeLanguageCode,
                        "learningLanguage": learningLanguageCode,
                        "discoveryMode": "officialLiveCatalog",
                        "resourceIDs": matching.map(\.resourceID).sorted().joined(separator: ",")
                    ],
                    integers: ["matchingResourceCount": Int64(matching.count)]
                )
                if configuration.isRemoteCatalogConfigured,
                   let manifestLoader {
                    let prior = try await manifestStateStore.load()
                    let prepared = try await manifestLoader.fetchAndPrepare(
                        endpoint: configuration.manifestEndpoint,
                        priorState: prior
                    )
                    _ = try await manifestStateStore.commitVerifiedState(prepared)
                    verifiedManifest = prepared.verifiedManifest
                }
                verifiedAt = Date()
                setCatalogState(
                    .available,
                    message: "已按当前语言组合实时匹配 \(matching.count) 本双语词典；" +
                        "只有点击安装时才下载词典文件。"
                )
            } catch is CancellationError {
                guard activeTaskID == taskID else { return }
                setCatalogState(.catalogUnavailable, message: "资源目录刷新已取消。")
            } catch let error as OfficialOpenResourceDiscoveryError {
                guard activeTaskID == taskID else { return }
                ManualEvidenceRecorder.shared.record(
                    "openResourceDiscoveryFailed",
                    strings: [
                        "nativeLanguage": nativeLanguageCode,
                        "learningLanguage": learningLanguageCode,
                        "typedReason": String(describing: error)
                    ]
                )
                setCatalogState(
                    error == .noMatchingResource ? .available : .catalogUnavailable,
                    message: error.errorDescription ?? "未匹配到双语词典。"
                )
            } catch {
                guard activeTaskID == taskID else { return }
                setCatalogState(
                    .catalogInvalid,
                    message: ResourceCenterPresentation.safeFailureMessage(error)
                )
            }
        }
    }

    func install(resourceID: String) {
        if let starter = presentedResources.first(where: { $0.resourceID == resourceID }) {
            installStarter(starter)
            return
        }
        guard activeTask == nil else { return }
        guard let verifiedManifest, let payloadDownloader else {
            failures[resourceID] = "开放词典下载尚未配置。"
            operations[resourceID] = .failed
            rebuildSnapshot()
            return
        }
        let current = catalog.dictionaries.first {
            $0.openResourceMetadata?.resourceID == resourceID
        }
        let mode: OpenResourceInstallationMode
        if let current, ResourceCenterPresentation.requiresReinstallation(current) {
            guard retireStaleRecordForReinstallation(current, resourceID: resourceID) else {
                return
            }
            mode = .newInstallation
        } else if let current {
            guard let candidate = verifiedManifest.validated.manifest.resources.first(where: {
                $0.resourceID == resourceID
            }), let metadata = current.openResourceMetadata,
                  candidate.resourceRevision > metadata.resourceRevision,
                  candidate.sha256 != metadata.payloadSHA256 else {
                failures[resourceID] =
                    "签名目录没有可安全安装的更高版本；同版本不同内容会被拒绝。"
                operations[resourceID] = .failed
                rebuildSnapshot()
                return
            }
            mode = .update(replacingDictionaryID: current.dictionaryID)
        } else {
            mode = .newInstallation
        }
        failures[resourceID] = nil
        diagnostics[resourceID] = "stage=preparing"
        operations[resourceID] = .downloading(received: 0, expected: nil)
        rebuildSnapshot()
        let taskID = UUID()
        activeTaskID = taskID
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTask(taskID) }
            do {
                let staged = try await payloadDownloader.download(
                    verifiedManifest: verifiedManifest,
                    resourceID: resourceID
                ) { [weak self] progress in
                    Task { @MainActor in
                        guard self?.activeTaskID == taskID else { return }
                        self?.operations[resourceID] = progress.phase == .verifying
                            ? .verifying
                            : .downloading(
                                received: progress.receivedBytes,
                                expected: progress.expectedBytes
                            )
                        if !progress.diagnosticLines.isEmpty {
                            self?.diagnostics[resourceID] =
                                progress.diagnosticLines.joined(separator: "\n")
                        }
                        self?.rebuildSnapshot()
                    }
                }
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                operations[resourceID] = .installing
                rebuildSnapshot()
                let permit = try await backgroundWorkCoordinator.acquire(
                    .resourceInstallationFinalization
                )
                let descriptor: DictionaryDescriptor
                do {
                    try Task.checkCancellation()
                    descriptor = try await installationCoordinator.install(
                        staged,
                        dictionariesRoot: dictionariesRoot,
                        catalogStore: catalogStore,
                        mode: mode
                    )
                    await permit.release()
                } catch {
                    await permit.release()
                    throw error
                }
                guard activeTaskID == taskID else { return }
                catalog = catalogStore.load()
                if case .newInstallation = mode {
                    pendingAutoEnableDictionaryIDs.insert(descriptor.dictionaryID)
                }
                onCatalogChanged(catalog)
                operations[resourceID] = .indexing
                rebuildSnapshot()
                switch indexCoordinator.start(dictionaryID: descriptor.dictionaryID) {
                case .started:
                    break
                case .busy:
                    failures[resourceID] =
                        "词典已安全安装并等待索引；当前另一本词典正在建立索引。"
                    operations[resourceID] = .failed
                case .unavailable:
                    failures[resourceID] =
                        "词典已安全安装，但索引尚未开始；可在已安装列表中重试。"
                    operations[resourceID] = .failed
                }
                rebuildSnapshot()
            } catch is CancellationError {
                guard activeTaskID == taskID else { return }
                operations[resourceID] = .cancelled
                rebuildSnapshot()
            } catch {
                guard activeTaskID == taskID else { return }
                failures[resourceID] = ResourceCenterPresentation.safeFailureMessage(error)
                appendDiagnostic(resourceID,
                                 "stage=failed error=\(Self.safeDiagnosticCode(error))")
                operations[resourceID] = .failed
                rebuildSnapshot()
            }
        }
    }

    private func installStarter(_ resource: BundledOpenResourceDefinition) {
        guard activeTask == nil else { return }
        guard resource.isLiveDiscoveredResource || payloadDownloader != nil else {
            failures[resource.resourceID] = "开放资源官方主机未通过生产配置。"
            operations[resource.resourceID] = .failed
            rebuildSnapshot()
            return
        }
        let current = catalog.dictionaries.filter {
            $0.openResourceMetadata?.resourceID == resource.resourceID
        }.max {
            ($0.openResourceMetadata?.resourceRevision ?? 0) <
                ($1.openResourceMetadata?.resourceRevision ?? 0)
        }
        let mode: OpenResourceInstallationMode
        if let current, ResourceCenterPresentation.requiresReinstallation(current) {
            guard retireStaleRecordForReinstallation(
                current, resourceID: resource.resourceID
            ) else { return }
            mode = .newInstallation
        } else if let current {
            guard let metadata = current.openResourceMetadata,
                  resource.resourceRevision > metadata.resourceRevision else {
                failures[resource.resourceID] = "当前目录版本已经安装。"
                operations[resource.resourceID] = .failed
                rebuildSnapshot()
                return
            }
            mode = .update(replacingDictionaryID: current.dictionaryID)
        } else {
            mode = .newInstallation
        }
        failures[resource.resourceID] = nil
        diagnostics[resource.resourceID] = "stage=preparing\ninitial_url=\(resource.downloadURL.absoluteString)"
        operations[resource.resourceID] = .downloading(
            received: 0,
            expected: resource.downloadBytes > 0 ? resource.downloadBytes : nil
        )
        rebuildSnapshot()
        let taskID = UUID()
        activeTaskID = taskID
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTask(taskID) }
            do {
                let staged: VerifiedPayloadStagingResult
                let installResource: BundledOpenResourceDefinition
                if resource.isLiveDiscoveredResource {
                    let downloaded = try await officialPayloadDownloader.download(resource)
                    staged = downloaded.0
                    installResource = downloaded.1
                    operations[resource.resourceID] = .downloaded
                    appendDiagnostic(
                        resource.resourceID,
                        "stage=download_verified sha256=recorded_locally"
                    )
                    rebuildSnapshot()
                } else {
                    guard let payloadDownloader else {
                        throw ResourcePayloadDownloadError.disabledConfiguration
                    }
                    staged = try await payloadDownloader.download(starter: resource) {
                        [weak self] download in
                        Task { @MainActor in
                            guard self?.activeTaskID == taskID else { return }
                            switch download.phase {
                            case .verifying, .publishingToStaging:
                                self?.operations[resource.resourceID] = .verifying
                            case .completed:
                                self?.operations[resource.resourceID] = .downloaded
                            case .failed:
                                break
                            case .preparing, .downloading:
                                self?.operations[resource.resourceID] = .downloading(
                                    received: download.receivedBytes,
                                    expected: download.expectedBytes
                                )
                            }
                            if !download.diagnosticLines.isEmpty {
                                self?.diagnostics[resource.resourceID] =
                                    download.diagnosticLines.joined(separator: "\n")
                            }
                            self?.rebuildSnapshot()
                        }
                    }
                    installResource = resource
                }
                try Task.checkCancellation()
                operations[resource.resourceID] = .installing
                rebuildSnapshot()
                let permit = try await backgroundWorkCoordinator.acquire(
                    .resourceInstallationFinalization
                )
                let result: FreeDictInstallationResult
                do {
                    let stageHandler: @Sendable (FreeDictInstallationStage) -> Void = {
                        [weak self] stage in
                        Task { @MainActor in
                            guard self?.activeTaskID == taskID else { return }
                            switch stage {
                            case .validatingSource:
                                self?.operations[resource.resourceID] = .verifying
                                self?.appendDiagnostic(resource.resourceID,
                                                       "stage=archive_validation")
                            case .converting(let processed, let total):
                                self?.operations[resource.resourceID] = .converting(
                                    processed: processed, total: total
                                )
                                self?.appendDiagnostic(resource.resourceID,
                                                       "stage=conversion processed=\(processed)")
                            case .buildingIndex(let processed, let total):
                                self?.operations[resource.resourceID] = .indexing
                                _ = (processed, total)
                                self?.appendDiagnostic(resource.resourceID,
                                                       "stage=sqlite_build")
                            case .validatingIndex:
                                self?.operations[resource.resourceID] = .validatingIndex
                                self?.appendDiagnostic(resource.resourceID,
                                                       "stage=sqlite_integrity_check")
                            case .publishing:
                                self?.operations[resource.resourceID] = .publishing
                                self?.appendDiagnostic(resource.resourceID,
                                                       "stage=atomic_publish")
                            }
                            self?.rebuildSnapshot()
                        }
                    }
                    if installResource.sourceFormat == .freeDictStarDictTarXZ {
                        result = try await freeDictInstallationCoordinator.install(
                            staged, resource: installResource,
                            dictionariesRoot: dictionariesRoot,
                            catalogStore: catalogStore, mode: mode, progress: stageHandler
                        )
                    } else {
                        result = try await auditedInstallationCoordinator.install(
                            staged, resource: installResource,
                            dictionariesRoot: dictionariesRoot,
                            catalogStore: catalogStore, mode: mode, progress: stageHandler
                        )
                    }
                    await permit.release()
                } catch {
                    await permit.release()
                    throw error
                }
                guard activeTaskID == taskID else { return }
                catalog = catalogStore.load()
                operations[resource.resourceID] = .installed
                appendDiagnostic(
                    resource.resourceID,
                    installResource.officialDigest.isEmpty
                        ? "sha256=recorded_in_installation_receipt"
                        : "\(installResource.officialDigestAlgorithm.lowercased())=verified"
                )
                appendDiagnostic(resource.resourceID, "stage=completed")
                onCatalogChanged(catalog)
                rebuildSnapshot()
                if case .update = mode { finalizeReadyUpdatesIfNeeded() }
                _ = result
            } catch is CancellationError {
                guard activeTaskID == taskID else { return }
                operations[resource.resourceID] = .cancelled
                rebuildSnapshot()
            } catch let error as FreeDictResourceError where error == .cancelled {
                guard activeTaskID == taskID else { return }
                operations[resource.resourceID] = .cancelled
                rebuildSnapshot()
            } catch let error as AuditedOpenResourceError where error == .cancelled {
                guard activeTaskID == taskID else { return }
                operations[resource.resourceID] = .cancelled
                rebuildSnapshot()
            } catch {
                guard activeTaskID == taskID else { return }
                failures[resource.resourceID] =
                    (error as? FreeDictResourceError)?.errorDescription ??
                    (error as? AuditedOpenResourceError)?.errorDescription ??
                    ResourceCenterPresentation.safeFailureMessage(error)
                appendDiagnostic(resource.resourceID,
                    "stage=failed error=\(Self.safeDiagnosticCode(error))")
                operations[resource.resourceID] = .failed
                rebuildSnapshot()
            }
        }
    }

    /// Same-revision reinstall first retires only the stale Catalog authority. The old managed
    /// directory is deliberately preserved when its identity is uncertain; the new installation
    /// receives a fresh dictionary UUID and is published independently.
    private func retireStaleRecordForReinstallation(
        _ descriptor: DictionaryDescriptor,
        resourceID: String
    ) -> Bool {
        do {
            let mutation = try catalogStore.mutate { latest, _ in
                latest = try DictionaryCatalogOrdering.removingAndCompacting(
                    descriptor.dictionaryID, from: latest
                )
            }
            catalog = mutation.catalog
            onCatalogChanged(catalog)
            return true
        } catch {
            failures[resourceID] = "无法保存重新安装状态；原有文件未被修改。"
            operations[resourceID] = .failed
            rebuildSnapshot()
            return false
        }
    }

    func cancelCurrentOperation() {
        activeTask?.cancel()
    }

    func presentationWillClose() {
        activeTask?.cancel()
    }

    var terminationActivity: (activeDownloadCount: Int, activeConversionCount: Int) {
        var downloads = 0
        var conversions = finalizationTasks.count
        for operation in operations.values {
            switch operation {
            case .downloading, .downloaded, .verifying, .installing:
                downloads += 1
            case .converting, .indexing, .validatingIndex, .publishing:
                conversions += 1
            case .available, .installed, .updateAvailable, .needsReinstall, .removing,
                 .failed, .cancelled:
                break
            }
        }
        return (downloads, conversions)
    }

    #if TERMINATION_INTEGRATION_TESTING
    func installSyntheticTerminationOperation(_ kind: String) {
        let resourceID = "synthetic-termination-resource"
        let taskID = UUID()
        activeTaskID = taskID
        switch kind {
        case "download", "heavy-wait":
            operations[resourceID] = .downloading(received: 1, expected: 10)
        case "conversion":
            operations[resourceID] = .converting(processed: 1, total: 10)
        default:
            return
        }
        if kind == "heavy-wait" {
            activeTask = Task { @MainActor [weak self, backgroundWorkCoordinator] in
                do {
                    let blocker = try await backgroundWorkCoordinator.acquire(.reverseIndex)
                    guard let self else {
                        await blocker.release()
                        return
                    }
                    finalizationTasks[resourceID] = Task { [backgroundWorkCoordinator] in
                        do {
                            let permit = try await backgroundWorkCoordinator.acquire(
                                .resourceInstallationFinalization
                            )
                            await permit.release()
                        } catch {}
                    }
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {}
                    await blocker.release()
                    finishActiveTask(taskID)
                } catch {
                    self?.finishActiveTask(taskID)
                }
            }
            rebuildSnapshot()
            return
        }
        activeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            await MainActor.run { self?.finishActiveTask(taskID) }
        }
        rebuildSnapshot()
    }
    #endif

    func prepareForTermination() {
        activeTask?.cancel()
        activeTask = nil
        activeTaskID = nil
        finalizationTasks.values.forEach { $0.cancel() }
        finalizationTasks.removeAll()
        finalizingResourceIDs.removeAll()
        onSnapshotChanged = nil
    }

    private func finishActiveTask(_ taskID: UUID) {
        guard activeTaskID == taskID else { return }
        activeTask = nil
        activeTaskID = nil
    }

    private func setCatalogState(_ state: ResourceCenterCatalogState,
                                 message: String) {
        snapshot = ResourceCenterPresentation.snapshot(
            verifiedManifest: verifiedManifest,
            bundledResources: presentedResources,
            catalog: catalog,
            catalogState: state,
            catalogMessage: message,
            operations: operations,
            failures: failures,
            diagnostics: diagnostics,
            nativeLanguageCode: nativeLanguageCode,
            learningLanguageCode: learningLanguageCode,
            verifiedAt: verifiedAt
        )
        publishSnapshot()
    }

    private func rebuildSnapshot() {
        let state: ResourceCenterCatalogState
        let message: String
        if discoveredResources.isEmpty {
            state = .catalogUnavailable
            message = "打开或刷新资源中心后，将按当前母语与学习语言实时匹配双语词典。"
        } else if verifiedManifest == nil {
            state = .available
            message = "已按当前语言组合实时匹配 \(discoveredResources.count) 本双语词典；" +
                "只有点击安装时才下载词典文件。"
        } else {
            state = .available
            message = verifiedManifest?.validated.manifest.resources.isEmpty == true
                ? "已验证的开放资源目录当前为空。"
                : "资源目录签名和许可证元数据已验证。"
        }
        snapshot = ResourceCenterPresentation.snapshot(
            verifiedManifest: verifiedManifest,
            bundledResources: presentedResources,
            catalog: catalog,
            catalogState: state,
            catalogMessage: message,
            operations: operations,
            failures: failures,
            diagnostics: diagnostics,
            nativeLanguageCode: nativeLanguageCode,
            learningLanguageCode: learningLanguageCode,
            verifiedAt: verifiedAt
        )
        publishSnapshot()
    }

    private func publishSnapshot() {
        onSnapshotChanged?(snapshot)
    }

    private var presentedResources: [BundledOpenResourceDefinition] {
        let dynamicIDs = Set(discoveredResources.map(\.resourceID))
        return discoveredResources + BundledOpenResourceCatalog.resources.filter {
            !dynamicIDs.contains($0.resourceID) && $0.isRecommended(
                nativeLanguageCode: nativeLanguageCode,
                learningLanguageCode: learningLanguageCode
            )
        }
    }

    private func appendDiagnostic(_ resourceID: String, _ line: String) {
        let prior = diagnostics[resourceID].map { $0 + "\n" } ?? ""
        let combined = prior + line
        diagnostics[resourceID] = combined.split(separator: "\n")
            .suffix(80).joined(separator: "\n")
    }

    private static func safeDiagnosticCode(_ error: Error) -> String {
        if let value = error as? ResourcePayloadDownloadError {
            return String(describing: value)
        }
        if let value = error as? FreeDictResourceError {
            switch value {
            case .unsafeArchive, .unsupportedSource, .malformedIndex:
                return "archiveInvalid(\(String(describing: value)))"
            case .publicationConflict:
                return "publicationFailed(\(String(describing: value)))"
            case .invalidStarterMetadata, .sourceDigestMismatch, .invalidEntry,
                 .sqliteFailure, .integrityFailure:
                return "converterFailed(\(String(describing: value)))"
            case .cancelled:
                return "cancelled"
            }
        }
        if let value = error as? AuditedOpenResourceError {
            switch value {
            case .unsafeArchive, .malformedSource:
                return "archiveInvalid(\(String(describing: value)))"
            case .publicationConflict:
                return "publicationFailed(\(String(describing: value)))"
            case .invalidMetadata, .digestMismatch, .entryLimit, .sqliteFailure,
                 .integrityFailure:
                return "converterFailed(\(String(describing: value)))"
            case .cancelled:
                return "cancelled"
            }
        }
        if let value = error as? OpenResourceInstallationError {
            return String(describing: value)
        }
        return String(reflecting: type(of: error))
    }

    private func enableCompletedNewInstallIfNeeded() {
        for dictionaryID in pendingAutoEnableDictionaryIDs {
            guard let descriptor = catalog.dictionaries.first(where: {
                $0.dictionaryID == dictionaryID
            }), descriptor.state == .ready, !descriptor.enabled else { continue }
            do {
                let mutation = try catalogStore.mutate { latest, _ in
                    guard let index = latest.dictionaries.firstIndex(where: {
                        $0.dictionaryID == dictionaryID &&
                            $0.state == .ready && !$0.enabled
                    }) else {
                        throw OpenResourceInstallationError.invalidIdentity
                    }
                    latest.dictionaries[index].enabled = true
                    latest.dictionaries[index].updatedAt = Date()
                    latest.updatedAt = Date()
                }
                pendingAutoEnableDictionaryIDs.remove(dictionaryID)
                catalog = mutation.catalog
                if let resourceID = descriptor.openResourceMetadata?.resourceID {
                    operations[resourceID] = .installed
                }
                onCatalogChanged(catalog)
            } catch {
                failures[descriptor.openResourceMetadata?.resourceID ?? dictionaryID] =
                    "索引已完成，但启用状态未能保存；可在已安装列表中手动启用。"
            }
        }
    }

    private func finalizeReadyUpdatesIfNeeded() {
        guard let removalCoordinator else { return }
        let groups = Dictionary(grouping: catalog.dictionaries.filter {
            $0.openResourceMetadata != nil
        }) { $0.openResourceMetadata!.resourceID }
        for (resourceID, values) in groups where values.count == 2 &&
            !finalizingResourceIDs.contains(resourceID) {
            let ordered = values.sorted {
                $0.openResourceMetadata!.resourceRevision <
                    $1.openResourceMetadata!.resourceRevision
            }
            guard ordered.count == 2 else { continue }
            let older = ordered[0]
            let newer = ordered[1]
            if newer.state == .ready && !newer.enabled {
                finalizingResourceIDs.insert(resourceID)
                do {
                    if older.enabled {
                        let mutation = try catalogStore.mutate { latest, _ in
                            guard let oldIndex = latest.dictionaries.firstIndex(where: {
                                $0.dictionaryID == older.dictionaryID && $0.enabled
                            }), let newIndex = latest.dictionaries.firstIndex(where: {
                                $0.dictionaryID == newer.dictionaryID &&
                                    $0.state == .ready && !$0.enabled
                            }) else {
                                throw OpenResourceInstallationError.invalidIdentity
                            }
                            let now = Date()
                            latest.dictionaries[oldIndex].enabled = false
                            latest.dictionaries[oldIndex].updatedAt = now
                            latest.dictionaries[newIndex].enabled = true
                            latest.dictionaries[newIndex].sortPosition =
                                latest.dictionaries[oldIndex].sortPosition
                            latest.dictionaries[newIndex].updatedAt = now
                            latest.updatedAt = now
                        }
                        catalog = mutation.catalog
                        onCatalogChanged(catalog)
                    }
                    operations[resourceID] = .removing
                    rebuildSnapshot()
                    finalizationTasks[resourceID] = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await Task.yield()
                        guard !Task.isCancelled else {
                            finalizationTasks[resourceID] = nil
                            finalizingResourceIDs.remove(resourceID)
                            return
                        }
                        let result = await removalCoordinator.remove(
                            dictionaryID: older.dictionaryID
                        )
                        guard !Task.isCancelled else { return }
                        finalizationTasks[resourceID] = nil
                        finalizingResourceIDs.remove(resourceID)
                        switch result {
                        case .removed:
                            operations[resourceID] = .installed
                        case .failed:
                            // The new version is already the sole query-eligible descriptor.
                            // Keep the identity-bound old object for a later safe cleanup retry.
                            failures[resourceID] =
                                "更新已切换；旧版本清理已安全延后。"
                            operations[resourceID] = .failed
                        }
                        rebuildSnapshot()
                    }
                } catch {
                    finalizingResourceIDs.remove(resourceID)
                    failures[resourceID] =
                        ResourceCenterPresentation.safeFailureMessage(error)
                    operations[resourceID] = .failed
                    rebuildSnapshot()
                }
            } else if !older.enabled && newer.enabled && newer.state == .ready {
                // A prior launch already committed the safe switch. Resume only the identity-
                // checked removal; never infer deletion authority from a path.
                finalizingResourceIDs.insert(resourceID)
                finalizationTasks[resourceID] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled else {
                        finalizationTasks[resourceID] = nil
                        finalizingResourceIDs.remove(resourceID)
                        return
                    }
                    let result = await removalCoordinator.remove(
                        dictionaryID: older.dictionaryID
                    )
                    guard !Task.isCancelled else { return }
                    finalizationTasks[resourceID] = nil
                    finalizingResourceIDs.remove(resourceID)
                    if case .failed = result {
                        failures[resourceID] = "旧版本清理已安全延后。"
                    }
                    rebuildSnapshot()
                }
            }
        }
    }
}
