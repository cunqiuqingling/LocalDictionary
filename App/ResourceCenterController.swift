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
    private let indexCoordinator: ManagedDictionaryIndexCoordinator
    private var removalCoordinator: ManagedDictionaryRemovalCoordinator?
    private let dictionariesRoot: URL
    private let onCatalogChanged: CatalogObserver

    private(set) var catalog: DictionaryCatalog
    private(set) var snapshot: ResourceCenterSnapshot
    private var verifiedManifest: VerifiedResourceManifest?
    private var verifiedAt: Date?
    private var operations: [String: ResourceCenterOperationState] = [:]
    private var failures: [String: String] = [:]
    private var activeTask: Task<Void, Never>?
    private var activeTaskID: UUID?
    private var finalizingResourceIDs: Set<String> = []
    private var pendingAutoEnableDictionaryIDs: Set<String> = []
    var onSnapshotChanged: SnapshotObserver?

    init(
        configuration: ResourceCenterProductionConfiguration = .current,
        catalog: DictionaryCatalog,
        catalogStore: DictionaryCatalogStore,
        installationCoordinator: OpenResourceInstallationCoordinator,
        indexCoordinator: ManagedDictionaryIndexCoordinator,
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
        self.removalCoordinator = removalCoordinator
        self.manifestStateStore = manifestStateStore
        self.onCatalogChanged = onCatalogChanged
        dictionariesRoot = applicationSupportRoot.appendingPathComponent(
            "Dictionaries", isDirectory: true
        )
        let stagingRoot = applicationSupportRoot.appendingPathComponent(
            "ResourceCenter/Staging", isDirectory: true
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

    func refresh() {
        guard activeTask == nil else { return }
        guard configuration.isRemoteCatalogConfigured,
              let manifestLoader else {
            verifiedManifest = nil
            snapshot = .unavailable(catalog: catalog)
            publishSnapshot()
            return
        }
        setCatalogState(.loading, message: "正在安全验证资源目录…")
        let taskID = UUID()
        activeTaskID = taskID
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTask(taskID) }
            do {
                let prior = try await manifestStateStore.load()
                let prepared = try await manifestLoader.fetchAndPrepare(
                    endpoint: configuration.manifestEndpoint,
                    priorState: prior
                )
                _ = try await manifestStateStore.commitVerifiedState(prepared)
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                verifiedManifest = prepared.verifiedManifest
                verifiedAt = Date()
                setCatalogState(
                    .available,
                    message: prepared.verifiedManifest.validated.manifest.resources.isEmpty
                        ? "已验证的开放资源目录当前为空。"
                        : "资源目录签名和许可证元数据已验证。"
                )
            } catch is CancellationError {
                guard activeTaskID == taskID else { return }
                setCatalogState(.catalogUnavailable, message: "资源目录刷新已取消。")
            } catch {
                guard activeTaskID == taskID else { return }
                verifiedManifest = nil
                setCatalogState(
                    .catalogInvalid,
                    message: ResourceCenterPresentation.safeFailureMessage(error)
                )
            }
        }
    }

    func install(resourceID: String) {
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
        if let current {
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
                        self?.rebuildSnapshot()
                    }
                }
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                operations[resourceID] = .installing
                rebuildSnapshot()
                let descriptor = try await installationCoordinator.install(
                    staged,
                    dictionariesRoot: dictionariesRoot,
                    catalogStore: catalogStore,
                    mode: mode
                )
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
                operations[resourceID] = .failed
                rebuildSnapshot()
            }
        }
    }

    func cancelCurrentOperation() {
        activeTask?.cancel()
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
            catalog: catalog,
            catalogState: state,
            catalogMessage: message,
            operations: operations,
            failures: failures,
            verifiedAt: verifiedAt
        )
        publishSnapshot()
    }

    private func rebuildSnapshot() {
        let state: ResourceCenterCatalogState
        let message: String
        if !configuration.isRemoteCatalogConfigured {
            state = .catalogUnavailable
            message = "尚未配置经过审核的开放资源目录；手动导入和已有词典不受影响。"
        } else if verifiedManifest == nil {
            state = .catalogUnavailable
            message = "资源目录尚未加载。"
        } else {
            state = .available
            message = verifiedManifest?.validated.manifest.resources.isEmpty == true
                ? "已验证的开放资源目录当前为空。"
                : "资源目录签名和许可证元数据已验证。"
        }
        snapshot = ResourceCenterPresentation.snapshot(
            verifiedManifest: verifiedManifest,
            catalog: catalog,
            catalogState: state,
            catalogMessage: message,
            operations: operations,
            failures: failures,
            verifiedAt: verifiedAt
        )
        publishSnapshot()
    }

    private func publishSnapshot() {
        onSnapshotChanged?(snapshot)
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
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await Task.yield()
                        let result = await removalCoordinator.remove(
                            dictionaryID: older.dictionaryID
                        )
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
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = await removalCoordinator.remove(
                        dictionaryID: older.dictionaryID
                    )
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
