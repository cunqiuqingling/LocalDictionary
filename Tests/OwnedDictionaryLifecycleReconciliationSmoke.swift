import CryptoKit
import Darwin
import Foundation

private enum SmokeFailure: Error {
    case failed(String)
}

private struct Smoke {
    var assertions = 0
    var posix = 0
    var rename = 0
    var catalogTransactions = 0
    var sha = 0
    var faultInjection = 0
    var barriers = 0
    var helperOnly = 0

    mutating func check(_ name: String, category: WritableKeyPath<Smoke, Int>,
                        _ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { throw SmokeFailure.failed(name) }
        assertions += 1
        self[keyPath: category] += 1
    }
}

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func chmod600(_ url: URL) throws {
    guard Darwin.chmod(url.path, 0o600) == 0 else {
        throw SmokeFailure.failed("chmod 600")
    }
}

private func fileIdentity(_ url: URL) throws -> (UInt64, UInt64) {
    var value = stat()
    guard Darwin.lstat(url.path, &value) == 0 else {
        throw SmokeFailure.failed("lstat")
    }
    return (UInt64(value.st_dev), UInt64(value.st_ino))
}

private func makeIdentity(dictionaryID: String,
                          resourceID: String,
                          payload: Data,
                          expectedDigest: String? = nil)
    throws -> OpenResourceInstallationIdentity {
    try OpenResourceInstallationIdentity(
        dictionaryID: dictionaryID,
        resourceID: resourceID,
        resourceRevision: 1,
        resourceVersion: "1.0",
        manifestVersion: 1,
        manifestSHA256: String(repeating: "a", count: 64),
        verifiedKeyID: "test-key",
        payloadSHA256: expectedDigest ?? digest(payload),
        payloadBytes: UInt64(payload.count),
        languages: ["en"],
        license: OpenResourceLicenseMetadata(
            name: "Synthetic", version: "1",
            url: "https://example.test/license", attribution: "Synthetic"
        ),
        sourceProject: "https://example.test/project",
        officialPageReference: "https://example.test/page",
        expectedEntryCount: OpenResourceEntryCountMetadata(minimum: 1, maximum: 3),
        installedAt: fixedDate
    )
}

@discardableResult
private func writeOpenDirectory(parent: URL,
                                component: String,
                                identity: OpenResourceInstallationIdentity,
                                payload: Data,
                                includeSidecar: Bool = true,
                                unknownEntry: Bool = false) throws -> URL {
    let directory = parent.appendingPathComponent(component, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let payloadURL = directory.appendingPathComponent(
        OpenResourceInstallationIdentity.payloadComponent
    )
    try payload.write(to: payloadURL)
    try chmod600(payloadURL)
    if includeSidecar {
        let sidecarURL = directory.appendingPathComponent(
            OpenResourceInstallationIdentity.sidecarComponent
        )
        try OpenResourceInstallationSidecar(identity: identity)
            .encodedData().write(to: sidecarURL)
        try chmod600(sidecarURL)
    }
    if unknownEntry {
        let unknown = directory.appendingPathComponent("unexpected.bin")
        try Data("unknown".utf8).write(to: unknown)
        try chmod600(unknown)
    }
    return directory
}

private func openDescriptor(_ identity: OpenResourceInstallationIdentity,
                            state: DictionaryState = .pendingIndex,
                            enabled: Bool = true) -> DictionaryDescriptor {
    DictionaryDescriptor(
        dictionaryID: identity.dictionaryID,
        displayName: identity.resourceID,
        sourceKind: .openResource,
        queryLevel: .fallback,
        sortPosition: 1,
        enabled: enabled,
        state: state,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: state == .ready ? 1 : nil,
            entryCount: state == .ready ? 3 : nil,
            indexFileSize: state == .ready ? 6 : nil,
            sourceFileSize: identity.payloadBytes,
            sourceModifiedAt: nil,
            sourceSHA256: identity.payloadSHA256,
            indexedAt: state == .ready ? fixedDate : nil
        ),
        formatterIdentifier: identity.formatterIdentifier,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: "Dictionaries/\(identity.dictionaryID)/payload.mdx",
            resources: [],
            index: state == .ready
                ? "Dictionaries/\(identity.dictionaryID)/index/dictionary.sqlite"
                : nil
        ),
        createdAt: fixedDate,
        updatedAt: fixedDate,
        storageOwnership: .appManagedOpenResource,
        openResourceMetadata: identity.catalogMetadata
    )
}

private func managedDescriptor(_ dictionaryID: String,
                               state: DictionaryState,
                               source: Data) -> DictionaryDescriptor {
    DictionaryDescriptor(
        dictionaryID: dictionaryID,
        displayName: "Managed \(dictionaryID)",
        sourceKind: .managedLocal,
        queryLevel: .normal,
        sortPosition: 1,
        enabled: true,
        state: state,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: state == .ready ? 1 : nil,
            entryCount: state == .ready ? 2 : nil,
            indexFileSize: state == .ready ? 6 : nil,
            sourceFileSize: UInt64(source.count),
            sourceModifiedAt: fixedDate,
            sourceSHA256: digest(source),
            indexedAt: state == .ready ? fixedDate : nil
        ),
        formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: "Dictionaries/\(dictionaryID)/dictionary.mdx",
            resources: [],
            index: state == .ready
                ? "Dictionaries/\(dictionaryID)/index/dictionary.sqlite"
                : nil
        ),
        createdAt: fixedDate,
        updatedAt: fixedDate,
        storageOwnership: .appManagedImported,
        openResourceMetadata: nil
    )
}

private func catalog(_ descriptors: [DictionaryDescriptor]) -> DictionaryCatalog {
    DictionaryCatalog(
        schemaVersion: DictionaryCatalog.currentSchemaVersion,
        createdAt: fixedDate,
        updatedAt: fixedDate,
        dictionaries: descriptors
    )
}

private func writeManagedDirectory(root: URL,
                                   descriptor: DictionaryDescriptor,
                                   source: Data,
                                   indexFiles: [String] = []) throws {
    let directory = root.appendingPathComponent(
        "Dictionaries/\(descriptor.dictionaryID)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try source.write(to: directory.appendingPathComponent("dictionary.mdx"))
    if !indexFiles.isEmpty {
        let index = directory.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        for file in indexFiles {
            try Data("sqlite".utf8).write(to: index.appendingPathComponent(file))
        }
    }
}

@MainActor
private func testOperationIdentityAndIndexInventory(base: URL,
                                                    smoke: inout Smoke) async throws {
    let root = base.appendingPathComponent("operation-components", isDirectory: true)
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let invalid = [
        ".partial-arbitrary", ".partial-",
        ".partial-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        ".partial-123e4567-e89b-12d3-a456-426614174000-extra",
        "verified-arbitrary",
        "verified-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        "verified-123e4567-e89b-12d3-a456-426614174000-extra"
    ]
    var identities: [String: (UInt64, UInt64)] = [:]
    for component in invalid {
        let directory = staging.appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("marker")
        try Data("preserve".utf8).write(to: marker)
        try chmod600(marker)
        identities[component] = try fileIdentity(directory)
    }
    let store = DictionaryCatalogStore(directoryURL: root.appendingPathComponent("Catalog"))
    let first = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    try smoke.check("invalid operation component exact issue", category: \.posix,
                    first.report.issues.filter { $0.code == .invalidOwnedOperationComponent }.count == invalid.count)
    try smoke.check("invalid operation components retain catalog", category: \.catalogTransactions,
                    first.catalog.dictionaries.isEmpty)
    for component in invalid {
        let directory = staging.appendingPathComponent(component, isDirectory: true)
        try smoke.check("invalid operation preserved \(component)", category: \.posix,
                        FileManager.default.fileExists(atPath: directory.path) &&
                        (try fileIdentity(directory)) == identities[component]!)
    }
    let second = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    try smoke.check("invalid operation second pass remains inert", category: \.posix,
                    invalid.allSatisfy { FileManager.default.fileExists(
                        atPath: staging.appendingPathComponent($0).path
                    ) } && second.catalog.dictionaries.isEmpty)

    let indexRoot = base.appendingPathComponent("index-inventory", isDirectory: true)
    let source = Data("source".utf8)
    let descriptor = managedDescriptor(
        "61000000-0000-4000-8000-000000000001", state: .indexing, source: source
    )
    try writeManagedDirectory(root: indexRoot, descriptor: descriptor, source: source,
                              indexFiles: ["dictionary.sqlite.building", "unknown-file"])
    let building = indexRoot.appendingPathComponent(
        "Dictionaries/\(descriptor.dictionaryID)/index/dictionary.sqlite.building"
    )
    let indexStore = DictionaryCatalogStore(directoryURL: indexRoot.appendingPathComponent("Catalog"))
    try indexStore.save(catalog([descriptor]))
    let indexResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: indexStore, applicationSupportRootURL: indexRoot
    ).reconcile()
    try smoke.check("unknown index entry prevents building delete", category: \.posix,
                    FileManager.default.fileExists(atPath: building.path))
    try smoke.check("unknown index entry exact issue", category: \.faultInjection,
                    indexResult.report.issues.map(\.code).contains(.indexInventoryContainsUnknownEntries))

#if OWNED_LIFECYCLE_TESTING
    let enumRoot = base.appendingPathComponent("index-enumeration", isDirectory: true)
    let enumDescriptor = managedDescriptor(
        "61000000-0000-4000-8000-000000000002", state: .indexing, source: source
    )
    try writeManagedDirectory(root: enumRoot, descriptor: enumDescriptor, source: source,
                              indexFiles: ["dictionary.sqlite.building"])
    let enumBuilding = enumRoot.appendingPathComponent(
        "Dictionaries/\(enumDescriptor.dictionaryID)/index/dictionary.sqlite.building"
    )
    let enumStore = DictionaryCatalogStore(directoryURL: enumRoot.appendingPathComponent("Catalog"))
    try enumStore.save(catalog([enumDescriptor]))
    OwnedDictionaryLifecycleTestObserver.beforeIndexInventory = {
        throw OwnedDictionaryLifecycleErrorCode.directoryEnumerationFailure
    }
    defer { OwnedDictionaryLifecycleTestObserver.beforeIndexInventory = nil }
    let enumeration = await OwnedDictionaryLifecycleReconciler(
        catalogStore: enumStore, applicationSupportRootURL: enumRoot
    ).reconcile()
    try smoke.check("enumeration failure preserves building", category: \.faultInjection,
                    FileManager.default.fileExists(atPath: enumBuilding.path))
    try smoke.check("enumeration failure exact issue", category: \.faultInjection,
                    enumeration.report.issues.map(\.code).contains(.directoryEnumerationFailure))
#endif
}

@MainActor
private func testVerifiedPublicationIdentityRace(base: URL, smoke: inout Smoke) async throws {
#if OWNED_LIFECYCLE_TESTING
    let root = base.appendingPathComponent("verified-identity-race", isDirectory: true)
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let payload = Data("race payload".utf8)
    let dictionaryID = "62000000-0000-4000-8000-000000000001"
    let operation = "verified-62000000-0000-4000-8000-000000000099"
    let identity = try makeIdentity(dictionaryID: dictionaryID, resourceID: "race", payload: payload)
    let original = try writeOpenDirectory(parent: staging, component: operation,
                                          identity: identity, payload: payload)
    let retained = staging.appendingPathComponent("retained-original", isDirectory: true)
    let replacement = staging.appendingPathComponent(operation, isDirectory: true)
    OwnedDictionaryLifecycleTestObserver.beforeRenameBinding = { component in
        guard component == operation else { return }
        guard Darwin.rename(original.path, retained.path) == 0,
              Darwin.mkdir(replacement.path, 0o700) == 0 else {
            throw SmokeFailure.failed("race replacement setup")
        }
    }
    defer { OwnedDictionaryLifecycleTestObserver.beforeRenameBinding = nil }
    let store = DictionaryCatalogStore(directoryURL: root.appendingPathComponent("Catalog"))
    let result = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    try smoke.check("verified substitution preserves original and replacement", category: \.rename,
                    FileManager.default.fileExists(atPath: retained.path) &&
                    FileManager.default.fileExists(atPath: replacement.path))
    try smoke.check("verified substitution does not publish catalog", category: \.catalogTransactions,
                    result.catalog.dictionaries.isEmpty)
    try smoke.check("verified substitution exact identity issue", category: \.faultInjection,
                    result.report.issues.map(\.code).contains(.sourceIdentityChangedBeforeRename))
#endif
}

@MainActor
private func testPendingDeletionIdentityRace(base: URL, smoke: inout Smoke) async throws {
#if OWNED_LIFECYCLE_TESTING
    let root = base.appendingPathComponent("pending-identity-race", isDirectory: true)
    let pending = root.appendingPathComponent("PendingDeletion", isDirectory: true)
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    let payload = Data("pending race payload".utf8)
    let dictionaryID = "63000000-0000-4000-8000-000000000001"
    let identity = try makeIdentity(dictionaryID: dictionaryID,
                                    resourceID: "pending-race", payload: payload)
    let original = try writeOpenDirectory(parent: pending, component: dictionaryID,
                                          identity: identity, payload: payload)
    let retained = pending.appendingPathComponent("retained-pending", isDirectory: true)
    let replacement = pending.appendingPathComponent(dictionaryID, isDirectory: true)
    OwnedDictionaryLifecycleTestObserver.beforeRenameBinding = { component in
        guard component == dictionaryID else { return }
        guard Darwin.rename(original.path, retained.path) == 0,
              Darwin.mkdir(replacement.path, 0o700) == 0 else {
            throw SmokeFailure.failed("pending replacement setup")
        }
    }
    defer { OwnedDictionaryLifecycleTestObserver.beforeRenameBinding = nil }
    let store = DictionaryCatalogStore(directoryURL: root.appendingPathComponent("Catalog"))
    try store.save(catalog([openDescriptor(identity)]))
    let result = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    try smoke.check("pending substitution preserves original and replacement", category: \.rename,
                    FileManager.default.fileExists(atPath: retained.path) &&
                    FileManager.default.fileExists(atPath: replacement.path))
    try smoke.check("pending substitution does not restore final", category: \.catalogTransactions,
                    !FileManager.default.fileExists(atPath: root.appendingPathComponent(
                        "Dictionaries/\(dictionaryID)"
                    ).path))
    try smoke.check("pending substitution exact identity issue", category: \.faultInjection,
                    result.report.issues.map(\.code).contains(.pendingDeletionIdentityChanged))
#endif
}

private actor RemovalRuntime: ManagedDictionaryQueryRuntime {
    private var removed: [String] = []

    func lookup(descriptor: DictionaryDescriptor,
                query: String) async -> ManagedDictionaryRuntimeOutcome {
        .miss
    }

    func remove(dictionaryID: String) async {
        removed.append(dictionaryID)
    }

    func reset() async {}

    func removedIDs() -> [String] { removed }
}

@MainActor
private func testCatalogProvenance(base: URL, smoke: inout Smoke) async throws {
    for (name, schemaVersion, expected) in [
        ("corrupt", nil, OwnedDictionaryLifecycleErrorCode.lifecycleBlockedByCorruptCatalog),
        ("unsupported", 999, .lifecycleBlockedByUnsupportedCatalog)
    ] {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let marker = staging.appendingPathComponent("do-not-touch")
        try Data("preserve".utf8).write(to: marker)
        let store = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("Catalog", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: store.directoryURL,
                                                withIntermediateDirectories: true)
        if let schemaVersion {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            var unsupported = catalog([])
            unsupported.schemaVersion = schemaVersion
            try encoder.encode(unsupported).write(to: store.catalogURL)
        } else {
            try Data("{broken".utf8).write(to: store.catalogURL)
        }
        let before = try fileIdentity(marker)
        let result = await OwnedDictionaryLifecycleReconciler(
            catalogStore: store, applicationSupportRootURL: root
        ).reconcile()
        let after = try fileIdentity(marker)
        try smoke.check("\(name) blocked", category: \.catalogTransactions,
                        result.report.blocked)
        try smoke.check("\(name) exact error", category: \.catalogTransactions,
                        result.report.issues.map(\.code).contains(expected))
        try smoke.check("\(name) filesystem unchanged", category: \.posix,
                        before == after)
    }

    let primaryRoot = base.appendingPathComponent("loaded-primary", isDirectory: true)
    let primaryStore = DictionaryCatalogStore(
        directoryURL: primaryRoot.appendingPathComponent("Catalog")
    )
    try primaryStore.save(catalog([]))
    let primary = await OwnedDictionaryLifecycleReconciler(
        catalogStore: primaryStore, applicationSupportRootURL: primaryRoot
    ).reconcile()
    try smoke.check("loaded primary reconciliation allowed",
                    category: \.catalogTransactions,
                    primary.report.catalogProvenance == .loadedPrimary &&
                    !primary.report.blocked)

    let backupRoot = base.appendingPathComponent("loaded-backup", isDirectory: true)
    let backupStore = DictionaryCatalogStore(
        directoryURL: backupRoot.appendingPathComponent("Catalog")
    )
    let first = catalog([])
    try backupStore.save(first)
    var second = first
    second.updatedAt = first.updatedAt.addingTimeInterval(1)
    try backupStore.save(second)
    try Data("damaged-primary".utf8).write(to: backupStore.catalogURL)
    let backup = await OwnedDictionaryLifecycleReconciler(
        catalogStore: backupStore, applicationSupportRootURL: backupRoot
    ).reconcile()
    try smoke.check("loaded backup reconciliation allowed",
                    category: \.catalogTransactions,
                    backup.report.catalogProvenance == .loadedBackup &&
                    !backup.report.blocked)
}

@MainActor
private func testVerifiedRecovery(base: URL, smoke: inout Smoke) async throws {
    let root = base.appendingPathComponent("verified", isDirectory: true)
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let payload = Data("verified payload".utf8)
    let id = "10000000-0000-4000-8000-000000000001"
    let identity = try makeIdentity(
        dictionaryID: id, resourceID: "verified-resource", payload: payload
    )
    try writeOpenDirectory(
        parent: staging,
        component: "verified-11111111-1111-4111-8111-111111111111",
        identity: identity,
        payload: payload
    )
    let partial = staging.appendingPathComponent(
        ".partial-22222222-2222-4222-8222-222222222222", isDirectory: true
    )
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    let partialPayload = partial.appendingPathComponent("payload.mdx.part")
    try Data("partial".utf8).write(to: partialPayload)
    try chmod600(partialPayload)
    let unknown = staging.appendingPathComponent("foreign-entry")
    try Data("preserve".utf8).write(to: unknown)
    let store = DictionaryCatalogStore(
        directoryURL: root.appendingPathComponent("Catalog", isDirectory: true)
    )
    let result = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    let descriptor = result.catalog.dictionaries.first
    try smoke.check("verified published", category: \.rename,
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(
                            "Dictionaries/\(id)/payload.mdx"
                        ).path
                    ))
    try smoke.check("verified staging consumed", category: \.rename,
                    !FileManager.default.fileExists(
                        atPath: staging.appendingPathComponent(
                            "verified-11111111-1111-4111-8111-111111111111"
                        ).path
                    ))
    try smoke.check("recovered disabled fallback pending descriptor=\(String(describing: descriptor)) issues=\(result.report.issues)",
                    category: \.catalogTransactions,
                    descriptor?.enabled == false &&
                    descriptor?.queryLevel == .fallback &&
                    descriptor?.state == .pendingIndex)
    try smoke.check("recovery used real SHA", category: \.sha,
                    descriptor?.indexMetadata.sourceSHA256 == digest(payload))
    try smoke.check("partial safely removed", category: \.posix,
                    !FileManager.default.fileExists(atPath: partial.path))
    try smoke.check("unknown staging preserved", category: \.posix,
                    FileManager.default.fileExists(atPath: unknown.path))
    let second = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    try smoke.check("verified recovery idempotent", category: \.catalogTransactions,
                    second.catalog.dictionaries.count == 1 &&
                    second.catalog.dictionaries[0].dictionaryID == id)

    let invalidRoot = base.appendingPathComponent("invalid-verified", isDirectory: true)
    let invalidStaging = invalidRoot.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidStaging,
                                            withIntermediateDirectories: true)
    let expected = Data("expected".utf8)
    let actual = Data("changed!".utf8)
    let invalidIdentity = try makeIdentity(
        dictionaryID: "10000000-0000-4000-8000-000000000002",
        resourceID: "invalid-hash", payload: actual,
        expectedDigest: digest(expected)
    )
    let invalidDirectory = try writeOpenDirectory(
        parent: invalidStaging,
        component: "verified-33333333-3333-4333-8333-333333333333",
        identity: invalidIdentity,
        payload: actual
    )
    let invalidStore = DictionaryCatalogStore(
        directoryURL: invalidRoot.appendingPathComponent("Catalog")
    )
    let invalidResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: invalidStore, applicationSupportRootURL: invalidRoot
    ).reconcile()
    try smoke.check("invalid hash preserved", category: \.sha,
                    FileManager.default.fileExists(atPath: invalidDirectory.path))
    try smoke.check("invalid hash not registered", category: \.catalogTransactions,
                    invalidResult.catalog.dictionaries.isEmpty)
    try smoke.check("invalid hash exact issue", category: \.sha,
                    invalidResult.report.issues.map(\.code)
                        .contains(.payloadIdentityMismatch))

    let conflictRoot = base.appendingPathComponent("verified-conflicts", isDirectory: true)
    let conflictStaging = conflictRoot.appendingPathComponent("Staging", isDirectory: true)
    let conflictFinal = conflictRoot.appendingPathComponent("Dictionaries", isDirectory: true)
    try FileManager.default.createDirectory(at: conflictStaging,
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: conflictFinal,
                                            withIntermediateDirectories: true)
    let installedIdentity = try makeIdentity(
        dictionaryID: "10000000-0000-4000-8000-000000000003",
        resourceID: "installed-resource", payload: payload
    )
    try writeOpenDirectory(
        parent: conflictFinal, component: installedIdentity.dictionaryID,
        identity: installedIdentity, payload: payload
    )
    let duplicateResourceIdentity = try makeIdentity(
        dictionaryID: "10000000-0000-4000-8000-000000000004",
        resourceID: installedIdentity.resourceID, payload: payload
    )
    let resourceConflictComponent =
        "verified-44444444-4444-4444-8444-444444444444"
    let resourceConflict = try writeOpenDirectory(
        parent: conflictStaging, component: resourceConflictComponent,
        identity: duplicateResourceIdentity, payload: payload
    )
    let conflictStore = DictionaryCatalogStore(
        directoryURL: conflictRoot.appendingPathComponent("Catalog")
    )
    try conflictStore.save(catalog([openDescriptor(installedIdentity)]))
    let conflictResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: conflictStore, applicationSupportRootURL: conflictRoot
    ).reconcile()
    try smoke.check("verified resource conflict remains in staging",
                    category: \.posix,
                    FileManager.default.fileExists(atPath: resourceConflict.path))
    try smoke.check("verified resource conflict is exact",
                    category: \.catalogTransactions,
                    conflictResult.report.issues.map(\.code)
                        .contains(.duplicateResourceIdentity))
    try smoke.check("verified resource conflict does not publish final",
                    category: \.posix,
                    !FileManager.default.fileExists(
                        atPath: conflictFinal.appendingPathComponent(
                            duplicateResourceIdentity.dictionaryID
                        ).path
                    ))

    let matchingComponent = "verified-55555555-5555-4555-8555-555555555555"
    let matching = try writeOpenDirectory(
        parent: conflictStaging, component: matchingComponent,
        identity: installedIdentity, payload: payload
    )
    let matchingResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: conflictStore, applicationSupportRootURL: conflictRoot
    ).reconcile()
    try smoke.check("matching verified residue safely removed",
                    category: \.posix,
                    !FileManager.default.fileExists(atPath: matching.path))
    try smoke.check("matching verified residue keeps one descriptor",
                    category: \.catalogTransactions,
                    matchingResult.catalog.dictionaries.count == 1)
}

@MainActor
private func testFinalValidationFailures(base: URL, smoke: inout Smoke) async throws {
    let payload = Data("final validation payload".utf8)
    for (name, configure) in [
        ("missing-sidecar", { (directory: URL) throws in
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent(
                    OpenResourceInstallationIdentity.sidecarComponent
                )
            )
        }),
        ("missing-payload", { (directory: URL) throws in
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent(
                    OpenResourceInstallationIdentity.payloadComponent
                )
            )
        }),
        ("unknown-entry", { (directory: URL) throws in
            let unknown = directory.appendingPathComponent("foreign.bin")
            try Data("foreign".utf8).write(to: unknown)
            try chmod600(unknown)
        })
    ] {
        let root = base.appendingPathComponent("final-\(name)", isDirectory: true)
        let dictionaries = root.appendingPathComponent("Dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dictionaries, withIntermediateDirectories: true
        )
        let identity = try makeIdentity(
            dictionaryID: UUID().uuidString.lowercased(),
            resourceID: "final-\(name)", payload: payload
        )
        let directory = try writeOpenDirectory(
            parent: dictionaries, component: identity.dictionaryID,
            identity: identity, payload: payload
        )
        try configure(directory)
        let store = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("Catalog")
        )
        try store.save(catalog([openDescriptor(identity)]))
        let result = await OwnedDictionaryLifecycleReconciler(
            catalogStore: store, applicationSupportRootURL: root
        ).reconcile()
        let descriptor = result.catalog.dictionaries.first
        try smoke.check("\(name) disables descriptor",
                        category: \.catalogTransactions,
                        descriptor?.state == .corrupt && descriptor?.enabled == false)
        try smoke.check("\(name) preserves directory",
                        category: \.posix,
                        FileManager.default.fileExists(atPath: directory.path))
    }

    let mismatchRoot = base.appendingPathComponent("final-sidecar-mismatch",
                                                   isDirectory: true)
    let mismatchDictionaries = mismatchRoot.appendingPathComponent(
        "Dictionaries", isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: mismatchDictionaries, withIntermediateDirectories: true
    )
    let mismatchIdentity = try makeIdentity(
        dictionaryID: "18000000-0000-4000-8000-000000000001",
        resourceID: "sidecar-identity", payload: payload
    )
    try writeOpenDirectory(
        parent: mismatchDictionaries, component: mismatchIdentity.dictionaryID,
        identity: mismatchIdentity, payload: payload
    )
    var mismatchDescriptor = openDescriptor(mismatchIdentity)
    mismatchDescriptor.openResourceMetadata?.resourceID = "catalog-identity"
    let mismatchStore = DictionaryCatalogStore(
        directoryURL: mismatchRoot.appendingPathComponent("Catalog")
    )
    try mismatchStore.save(catalog([mismatchDescriptor]))
    let mismatchResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: mismatchStore, applicationSupportRootURL: mismatchRoot
    ).reconcile()
    try smoke.check("Catalog sidecar mismatch fails closed",
                    category: \.catalogTransactions,
                    mismatchResult.catalog.dictionaries.first?.state == .corrupt)

    let nameRoot = base.appendingPathComponent("final-name-mismatch", isDirectory: true)
    let nameDictionaries = nameRoot.appendingPathComponent("Dictionaries", isDirectory: true)
    try FileManager.default.createDirectory(
        at: nameDictionaries, withIntermediateDirectories: true
    )
    let sidecarIdentity = try makeIdentity(
        dictionaryID: "18000000-0000-4000-8000-000000000002",
        resourceID: "name-mismatch", payload: payload
    )
    let otherDirectoryID = "18000000-0000-4000-8000-000000000003"
    let mismatchedDirectory = try writeOpenDirectory(
        parent: nameDictionaries, component: otherDirectoryID,
        identity: sidecarIdentity, payload: payload
    )
    let nameStore = DictionaryCatalogStore(
        directoryURL: nameRoot.appendingPathComponent("Catalog")
    )
    let nameResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: nameStore, applicationSupportRootURL: nameRoot
    ).reconcile()
    try smoke.check("directory sidecar name mismatch not registered",
                    category: \.catalogTransactions,
                    nameResult.catalog.dictionaries.isEmpty)
    try smoke.check("directory sidecar name mismatch preserved",
                    category: \.posix,
                    FileManager.default.fileExists(atPath: mismatchedDirectory.path))

    let hardlinkRoot = base.appendingPathComponent("final-hardlink", isDirectory: true)
    let hardlinkDictionaries = hardlinkRoot.appendingPathComponent(
        "Dictionaries", isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: hardlinkDictionaries, withIntermediateDirectories: true
    )
    let hardlinkIdentity = try makeIdentity(
        dictionaryID: "18000000-0000-4000-8000-000000000004",
        resourceID: "hardlink-payload", payload: payload
    )
    let hardlinkDirectory = try writeOpenDirectory(
        parent: hardlinkDictionaries, component: hardlinkIdentity.dictionaryID,
        identity: hardlinkIdentity, payload: payload
    )
    try FileManager.default.linkItem(
        at: hardlinkDirectory.appendingPathComponent("payload.mdx"),
        to: hardlinkRoot.appendingPathComponent("linked-payload.mdx")
    )
    let hardlinkStore = DictionaryCatalogStore(
        directoryURL: hardlinkRoot.appendingPathComponent("Catalog")
    )
    try hardlinkStore.save(catalog([openDescriptor(hardlinkIdentity)]))
    let hardlinkResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: hardlinkStore, applicationSupportRootURL: hardlinkRoot
    ).reconcile()
    try smoke.check("hardlinked payload fails closed",
                    category: \.posix,
                    hardlinkResult.catalog.dictionaries.first?.state == .corrupt)

    let symlinkRoot = base.appendingPathComponent("final-symlink", isDirectory: true)
    let symlinkDictionaries = symlinkRoot.appendingPathComponent(
        "Dictionaries", isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: symlinkDictionaries, withIntermediateDirectories: true
    )
    let symlinkIdentity = try makeIdentity(
        dictionaryID: "18000000-0000-4000-8000-000000000005",
        resourceID: "symlink-sidecar", payload: payload
    )
    let symlinkDirectory = try writeOpenDirectory(
        parent: symlinkDictionaries, component: symlinkIdentity.dictionaryID,
        identity: symlinkIdentity, payload: payload
    )
    let sidecar = symlinkDirectory.appendingPathComponent(
        OpenResourceInstallationIdentity.sidecarComponent
    )
    let externalSidecar = symlinkRoot.appendingPathComponent("outside-sidecar.json")
    try FileManager.default.moveItem(at: sidecar, to: externalSidecar)
    try FileManager.default.createSymbolicLink(at: sidecar,
                                              withDestinationURL: externalSidecar)
    let symlinkStore = DictionaryCatalogStore(
        directoryURL: symlinkRoot.appendingPathComponent("Catalog")
    )
    try symlinkStore.save(catalog([openDescriptor(symlinkIdentity)]))
    let symlinkResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: symlinkStore, applicationSupportRootURL: symlinkRoot
    ).reconcile()
    try smoke.check("symlinked sidecar fails closed",
                    category: \.posix,
                    symlinkResult.catalog.dictionaries.first?.state == .corrupt)
}

@MainActor
private func testFinalAndIndexRecovery(base: URL, smoke: inout Smoke) async throws {
    let root = base.appendingPathComponent("final-index", isDirectory: true)
    let dictionaries = root.appendingPathComponent("Dictionaries", isDirectory: true)
    try FileManager.default.createDirectory(at: dictionaries, withIntermediateDirectories: true)
    let source = Data("managed source".utf8)
    let indexing = managedDescriptor(
        "20000000-0000-4000-8000-000000000001", state: .indexing, source: source
    )
    let readyMissing = managedDescriptor(
        "20000000-0000-4000-8000-000000000002", state: .ready, source: source
    )
    let pendingWithFinal = managedDescriptor(
        "20000000-0000-4000-8000-000000000003", state: .pendingIndex, source: source
    )
    try writeManagedDirectory(
        root: root, descriptor: indexing, source: source,
        indexFiles: ["dictionary.sqlite.building"]
    )
    try writeManagedDirectory(root: root, descriptor: readyMissing, source: source)
    try writeManagedDirectory(
        root: root, descriptor: pendingWithFinal, source: source,
        indexFiles: ["dictionary.sqlite"]
    )
    let missingPayload = Data("missing open".utf8)
    let missingIdentity = try makeIdentity(
        dictionaryID: "20000000-0000-4000-8000-000000000004",
        resourceID: "missing-open", payload: missingPayload
    )
    let missing = openDescriptor(missingIdentity)
    let openIndexingPayload = Data("open indexing".utf8)
    let openIndexingIdentity = try makeIdentity(
        dictionaryID: "20000000-0000-4000-8000-000000000005",
        resourceID: "open-indexing", payload: openIndexingPayload
    )
    let openIndexing = openDescriptor(openIndexingIdentity, state: .indexing)
    try writeOpenDirectory(
        parent: root.appendingPathComponent("Dictionaries", isDirectory: true),
        component: openIndexingIdentity.dictionaryID,
        identity: openIndexingIdentity,
        payload: openIndexingPayload
    )
    let openReadyPayload = Data("open ready missing index".utf8)
    let openReadyIdentity = try makeIdentity(
        dictionaryID: "20000000-0000-4000-8000-000000000006",
        resourceID: "open-ready-missing", payload: openReadyPayload
    )
    let openReady = openDescriptor(openReadyIdentity, state: .ready)
    try writeOpenDirectory(
        parent: root.appendingPathComponent("Dictionaries", isDirectory: true),
        component: openReadyIdentity.dictionaryID,
        identity: openReadyIdentity,
        payload: openReadyPayload
    )
    let store = DictionaryCatalogStore(
        directoryURL: root.appendingPathComponent("Catalog")
    )
    try store.save(catalog([
        indexing, readyMissing, pendingWithFinal, missing, openIndexing, openReady
    ]))
    let result = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    let values = Dictionary(uniqueKeysWithValues:
        result.catalog.dictionaries.map { ($0.dictionaryID, $0) }
    )
    try smoke.check("managed indexing reset", category: \.catalogTransactions,
                    values[indexing.dictionaryID]?.state == .pendingIndex)
    try smoke.check("building removed", category: \.posix,
                    !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(
                            "Dictionaries/\(indexing.dictionaryID)/index/dictionary.sqlite.building"
                        ).path
                    ))
    try smoke.check("ready missing index downgraded", category: \.catalogTransactions,
                    values[readyMissing.dictionaryID]?.state == .pendingIndex &&
                    values[readyMissing.dictionaryID]?.relativePaths.index == nil)
    try smoke.check("pending final not promoted", category: \.catalogTransactions,
                    values[pendingWithFinal.dictionaryID]?.state == .pendingIndex)
    try smoke.check("missing owned disabled", category: \.catalogTransactions,
                    values[missing.dictionaryID]?.state == .missingResources &&
                    values[missing.dictionaryID]?.enabled == false)
    try smoke.check("openResource indexing reset", category: \.catalogTransactions,
                    values[openIndexing.dictionaryID]?.state == .pendingIndex)
    try smoke.check("openResource ready missing index downgraded",
                    category: \.catalogTransactions,
                    values[openReady.dictionaryID]?.state == .pendingIndex)
}

@MainActor
private func testOrphanAndDuplicateRecovery(base: URL, smoke: inout Smoke) async throws {
    let root = base.appendingPathComponent("orphans", isDirectory: true)
    let dictionaries = root.appendingPathComponent("Dictionaries", isDirectory: true)
    try FileManager.default.createDirectory(at: dictionaries, withIntermediateDirectories: true)
    let payload = Data("orphan payload".utf8)
    let orphan = try makeIdentity(
        dictionaryID: "30000000-0000-4000-8000-000000000001",
        resourceID: "orphan-one", payload: payload
    )
    try writeOpenDirectory(parent: dictionaries, component: orphan.dictionaryID,
                           identity: orphan, payload: payload)
    let store = DictionaryCatalogStore(
        directoryURL: root.appendingPathComponent("Catalog")
    )
    let recovered = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: root
    ).reconcile()
    try smoke.check("final orphan recovered", category: \.catalogTransactions,
                    recovered.catalog.dictionaries.first?.dictionaryID == orphan.dictionaryID)
    try smoke.check("final orphan full SHA", category: \.sha,
                    recovered.catalog.dictionaries.first?.indexMetadata.sourceSHA256 ==
                        digest(payload))

    let duplicateRoot = base.appendingPathComponent("duplicate", isDirectory: true)
    let duplicateDictionaries = duplicateRoot.appendingPathComponent(
        "Dictionaries", isDirectory: true
    )
    try FileManager.default.createDirectory(at: duplicateDictionaries,
                                            withIntermediateDirectories: true)
    for suffix in ["001", "002"] {
        let id = "30000000-0000-4000-8000-000000000\(suffix)"
        let identity = try makeIdentity(
            dictionaryID: id, resourceID: "same-resource", payload: payload
        )
        try writeOpenDirectory(parent: duplicateDictionaries, component: id,
                               identity: identity, payload: payload)
    }
    let duplicateStore = DictionaryCatalogStore(
        directoryURL: duplicateRoot.appendingPathComponent("Catalog")
    )
    let duplicate = await OwnedDictionaryLifecycleReconciler(
        catalogStore: duplicateStore, applicationSupportRootURL: duplicateRoot
    ).reconcile()
    try smoke.check("duplicate resource not guessed", category: \.catalogTransactions,
                    duplicate.catalog.dictionaries.isEmpty)
    try smoke.check("duplicate resource exact issues", category: \.catalogTransactions,
                    duplicate.report.issues.filter {
                        $0.code == .duplicateResourceIdentity
                    }.count == 2)
}

@MainActor
private func testPendingDeletion(base: URL, smoke: inout Smoke) async throws {
    let payload = Data("pending payload".utf8)
    let restoreRoot = base.appendingPathComponent("pending-restore", isDirectory: true)
    let restoreID = "40000000-0000-4000-8000-000000000001"
    let restoreIdentity = try makeIdentity(
        dictionaryID: restoreID, resourceID: "pending-restore", payload: payload
    )
    let pendingRoot = restoreRoot.appendingPathComponent(
        "PendingDeletion", isDirectory: true
    )
    try FileManager.default.createDirectory(at: pendingRoot,
                                            withIntermediateDirectories: true)
    try writeOpenDirectory(parent: pendingRoot, component: restoreID,
                           identity: restoreIdentity, payload: payload)
    let store = DictionaryCatalogStore(
        directoryURL: restoreRoot.appendingPathComponent("Catalog")
    )
    try store.save(catalog([openDescriptor(restoreIdentity)]))
    let restored = await OwnedDictionaryLifecycleReconciler(
        catalogStore: store, applicationSupportRootURL: restoreRoot
    ).reconcile()
    try smoke.check("pending restored", category: \.rename,
                    FileManager.default.fileExists(
                        atPath: restoreRoot.appendingPathComponent(
                            "Dictionaries/\(restoreID)/payload.mdx"
                        ).path
                    ))
    try smoke.check("pending descriptor retained", category: \.catalogTransactions,
                    restored.catalog.dictionaries.count == 1)

    let cleanupRoot = base.appendingPathComponent("pending-cleanup", isDirectory: true)
    let cleanupPending = cleanupRoot.appendingPathComponent(
        "PendingDeletion", isDirectory: true
    )
    try FileManager.default.createDirectory(at: cleanupPending,
                                            withIntermediateDirectories: true)
    let cleanupID = "40000000-0000-4000-8000-000000000002"
    let cleanupIdentity = try makeIdentity(
        dictionaryID: cleanupID, resourceID: "pending-cleanup", payload: payload
    )
    try writeOpenDirectory(parent: cleanupPending, component: cleanupID,
                           identity: cleanupIdentity, payload: payload)
    let cleanupStore = DictionaryCatalogStore(
        directoryURL: cleanupRoot.appendingPathComponent("Catalog")
    )
    let cleaned = await OwnedDictionaryLifecycleReconciler(
        catalogStore: cleanupStore, applicationSupportRootURL: cleanupRoot
    ).reconcile()
    try smoke.check("pending committed removal cleaned", category: \.posix,
                    !FileManager.default.fileExists(
                        atPath: cleanupPending.appendingPathComponent(cleanupID).path
                    ))
    try smoke.check("pending cleanup catalog empty", category: \.catalogTransactions,
                    cleaned.catalog.dictionaries.isEmpty)

    let unknownRoot = base.appendingPathComponent("pending-unknown", isDirectory: true)
    let unknownPending = unknownRoot.appendingPathComponent(
        "PendingDeletion", isDirectory: true
    )
    let unknownID = "40000000-0000-4000-8000-000000000003"
    let unknownDirectory = unknownPending.appendingPathComponent(unknownID,
                                                                 isDirectory: true)
    try FileManager.default.createDirectory(at: unknownDirectory,
                                            withIntermediateDirectories: true)
    try Data("unknown".utf8).write(
        to: unknownDirectory.appendingPathComponent("foreign.bin")
    )
    let unknownStore = DictionaryCatalogStore(
        directoryURL: unknownRoot.appendingPathComponent("Catalog")
    )
    let unknown = await OwnedDictionaryLifecycleReconciler(
        catalogStore: unknownStore, applicationSupportRootURL: unknownRoot
    ).reconcile()
    try smoke.check("unknown pending preserved", category: \.posix,
                    FileManager.default.fileExists(atPath: unknownDirectory.path))
    try smoke.check("unknown pending exact issue", category: \.posix,
                    unknown.report.issues.map(\.code).contains(.pendingDeletionCleanupDeferred))

    let conflictRoot = base.appendingPathComponent("pending-target-conflict",
                                                   isDirectory: true)
    let conflictPending = conflictRoot.appendingPathComponent(
        "PendingDeletion", isDirectory: true
    )
    let conflictFinal = conflictRoot.appendingPathComponent(
        "Dictionaries", isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: conflictPending, withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: conflictFinal, withIntermediateDirectories: true
    )
    let conflictID = "40000000-0000-4000-8000-000000000004"
    let conflictIdentity = try makeIdentity(
        dictionaryID: conflictID, resourceID: "pending-conflict", payload: payload
    )
    let pendingDirectory = try writeOpenDirectory(
        parent: conflictPending, component: conflictID,
        identity: conflictIdentity, payload: payload
    )
    let finalDirectory = try writeOpenDirectory(
        parent: conflictFinal, component: conflictID,
        identity: conflictIdentity, payload: payload
    )
    let conflictStore = DictionaryCatalogStore(
        directoryURL: conflictRoot.appendingPathComponent("Catalog")
    )
    try conflictStore.save(catalog([openDescriptor(conflictIdentity)]))
    let conflict = await OwnedDictionaryLifecycleReconciler(
        catalogStore: conflictStore, applicationSupportRootURL: conflictRoot
    ).reconcile()
    try smoke.check("pending target conflict preserves both directories",
                    category: \.rename,
                    FileManager.default.fileExists(atPath: pendingDirectory.path) &&
                    FileManager.default.fileExists(atPath: finalDirectory.path))
    try smoke.check("pending target conflict exact issue",
                    category: \.rename,
                    conflict.report.issues.map(\.code)
                        .contains(.pendingDeletionConflict))
    let conflictAgain = await OwnedDictionaryLifecycleReconciler(
        catalogStore: conflictStore, applicationSupportRootURL: conflictRoot
    ).reconcile()
    try smoke.check("pending target conflict is idempotent",
                    category: \.catalogTransactions,
                    conflictAgain.catalog == conflict.catalog)
}

@MainActor
private func testOwnedRemoval(base: URL, smoke: inout Smoke) async throws {
    let root = base.appendingPathComponent("owned-removal", isDirectory: true)
    let dictionaries = root.appendingPathComponent("Dictionaries", isDirectory: true)
    try FileManager.default.createDirectory(at: dictionaries, withIntermediateDirectories: true)
    let payload = Data("owned removal payload".utf8)
    let identity = try makeIdentity(
        dictionaryID: "45000000-0000-4000-8000-000000000001",
        resourceID: "owned-removal", payload: payload
    )
    try writeOpenDirectory(parent: dictionaries, component: identity.dictionaryID,
                           identity: identity, payload: payload)
    let descriptor = openDescriptor(identity)
    let initial = catalog([descriptor])
    let store = DictionaryCatalogStore(
        directoryURL: root.appendingPathComponent("Catalog")
    )
    try store.save(initial)
    let runtime = RemovalRuntime()
    let service = ManagedDictionaryQueryService(catalog: initial, runtime: runtime)
    let coordinator = ManagedDictionaryRemovalCoordinator(
        catalog: initial,
        catalogStore: store,
        applicationSupportRootURL: root,
        queryService: service,
        isIndexing: { _ in false }
    )
    let result = await coordinator.remove(dictionaryID: identity.dictionaryID)
    try smoke.check("open resource owned removal succeeds", category: \.posix,
                    result == .removed(cleanupDeferred: false))
    try smoke.check("open resource directory removed", category: \.posix,
                    !FileManager.default.fileExists(
                        atPath: dictionaries.appendingPathComponent(identity.dictionaryID).path
                    ))
    try smoke.check("open resource Catalog removed", category: \.catalogTransactions,
                    coordinator.catalog.dictionaries.isEmpty)
    let removedIDs = await runtime.removedIDs()
    try smoke.check("runtime suspended before removal", category: \.barriers,
                    removedIDs == [identity.dictionaryID])

    var external = descriptor
    external.sourceKind = .externalReference
    external.storageOwnership = .externalReference
    external.openResourceMetadata = nil
    let externalCatalog = catalog([external])
    let externalCoordinator = ManagedDictionaryRemovalCoordinator(
        catalog: externalCatalog,
        catalogStore: DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("ExternalCatalog")
        ),
        applicationSupportRootURL: root,
        queryService: ManagedDictionaryQueryService(
            catalog: externalCatalog, runtime: RemovalRuntime()
        ),
        isIndexing: { _ in false }
    )
    let externalResult = await externalCoordinator.remove(
        dictionaryID: external.dictionaryID
    )
    try smoke.check("external ownership removal rejected", category: \.posix,
                    externalResult == .failed(.notManagedLocal))

    let deferredRoot = base.appendingPathComponent("owned-removal-deferred",
                                                   isDirectory: true)
    let deferredDictionaries = deferredRoot.appendingPathComponent(
        "Dictionaries", isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: deferredDictionaries, withIntermediateDirectories: true
    )
    let deferredIdentity = try makeIdentity(
        dictionaryID: "45000000-0000-4000-8000-000000000002",
        resourceID: "owned-removal-deferred", payload: payload
    )
    try writeOpenDirectory(
        parent: deferredDictionaries, component: deferredIdentity.dictionaryID,
        identity: deferredIdentity, payload: payload
    )
    let deferredDescriptor = openDescriptor(deferredIdentity)
    let deferredCatalog = catalog([deferredDescriptor])
    let deferredStore = DictionaryCatalogStore(
        directoryURL: deferredRoot.appendingPathComponent("Catalog")
    )
    try deferredStore.save(deferredCatalog)
    let deferredRuntime = RemovalRuntime()
    let deferredCoordinator = ManagedDictionaryRemovalCoordinator(
        catalog: deferredCatalog,
        catalogStore: deferredStore,
        applicationSupportRootURL: deferredRoot,
        queryService: ManagedDictionaryQueryService(
            catalog: deferredCatalog, runtime: deferredRuntime
        ),
        isIndexing: { _ in false },
        hooks: ManagedDictionaryRemovalHooks(
            removeItem: { _ in throw SmokeFailure.failed("injected cleanup failure") }
        )
    )
    let deferredResult = await deferredCoordinator.remove(
        dictionaryID: deferredIdentity.dictionaryID
    )
    let deferredPending = deferredRoot.appendingPathComponent(
        "PendingDeletion/\(deferredIdentity.dictionaryID)", isDirectory: true
    )
    try smoke.check("committed removal reports deferred cleanup",
                    category: \.faultInjection,
                    deferredResult == .removed(cleanupDeferred: true))
    try smoke.check("deferred cleanup retains PendingDeletion",
                    category: \.posix,
                    FileManager.default.fileExists(atPath: deferredPending.path) &&
                    deferredCoordinator.catalog.dictionaries.isEmpty)
    let deferredRecovered = await OwnedDictionaryLifecycleReconciler(
        catalogStore: deferredStore, applicationSupportRootURL: deferredRoot
    ).reconcile()
    try smoke.check("startup completes deferred OpenResource deletion",
                    category: \.posix,
                    !FileManager.default.fileExists(atPath: deferredPending.path) &&
                    deferredRecovered.catalog.dictionaries.isEmpty)

    let rollbackRoot = base.appendingPathComponent("owned-removal-rollback",
                                                   isDirectory: true)
    let rollbackDictionaries = rollbackRoot.appendingPathComponent(
        "Dictionaries", isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: rollbackDictionaries, withIntermediateDirectories: true
    )
    let rollbackIdentity = try makeIdentity(
        dictionaryID: "45000000-0000-4000-8000-000000000003",
        resourceID: "owned-removal-rollback", payload: payload
    )
    try writeOpenDirectory(
        parent: rollbackDictionaries, component: rollbackIdentity.dictionaryID,
        identity: rollbackIdentity, payload: payload
    )
    let rollbackDescriptor = openDescriptor(rollbackIdentity)
    let rollbackCatalog = catalog([rollbackDescriptor])
    let rollbackCoordinator = ManagedDictionaryRemovalCoordinator(
        catalog: rollbackCatalog,
        catalogStore: DictionaryCatalogStore(
            directoryURL: rollbackRoot.appendingPathComponent("Catalog")
        ),
        applicationSupportRootURL: rollbackRoot,
        queryService: ManagedDictionaryQueryService(
            catalog: rollbackCatalog, runtime: RemovalRuntime()
        ),
        isIndexing: { _ in false },
        saveCatalog: { _ in throw SmokeFailure.failed("injected Catalog failure") }
    )
    let rollbackResult = await rollbackCoordinator.remove(
        dictionaryID: rollbackIdentity.dictionaryID
    )
    try smoke.check("OpenResource Catalog failure reports rollback",
                    category: \.faultInjection,
                    rollbackResult == .failed(.catalogWriteFailed))
    try smoke.check("OpenResource Catalog failure restores final directory",
                    category: \.rename,
                    FileManager.default.fileExists(
                        atPath: rollbackDictionaries.appendingPathComponent(
                            rollbackIdentity.dictionaryID
                        ).path
                    ))
}

@MainActor
private func testFaultsCancellationAndBarrier(base: URL,
                                             smoke: inout Smoke) async throws {
    let cancelRoot = base.appendingPathComponent("cancel", isDirectory: true)
    let cancelStore = DictionaryCatalogStore(
        directoryURL: cancelRoot.appendingPathComponent("Catalog")
    )
    let token = OwnedDictionaryLifecycleCancellationToken()
    token.cancel()
    let cancelled = await OwnedDictionaryLifecycleReconciler(
        catalogStore: cancelStore,
        applicationSupportRootURL: cancelRoot,
        cancellationToken: token
    ).reconcile()
    try smoke.check("cooperative cancellation", category: \.faultInjection,
                    cancelled.report.issues.map(\.code).contains(.cancelled))

    let faultRoot = base.appendingPathComponent("fsync-fault", isDirectory: true)
    let staging = faultRoot.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let payload = Data("fault payload".utf8)
    let identity = try makeIdentity(
        dictionaryID: "50000000-0000-4000-8000-000000000001",
        resourceID: "fsync-fault", payload: payload
    )
    try writeOpenDirectory(
        parent: staging,
        component: "verified-55555555-5555-4555-8555-555555555555",
        identity: identity,
        payload: payload
    )
    let hooks = OwnedDictionaryLifecycleHooks(
        renameNoReplaceAt: { sourceFD, source, destinationFD, destination in
            let result = source.withCString { sourceName in
                destination.withCString { destinationName in
                    Darwin.renameatx_np(sourceFD, sourceName, destinationFD,
                                        destinationName, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw SmokeFailure.failed("rename fault fixture") }
        },
        synchronize: { _ in throw SmokeFailure.failed("fsync fault") },
        beforeDelete: { _ in }
    )
    let faultStore = DictionaryCatalogStore(
        directoryURL: faultRoot.appendingPathComponent("Catalog")
    )
    let fault = await OwnedDictionaryLifecycleReconciler(
        catalogStore: faultStore,
        applicationSupportRootURL: faultRoot,
        hooks: hooks
    ).reconcile()
    try smoke.check("fsync failure visible", category: \.faultInjection,
                    fault.report.issues.map(\.code).contains(.ioFailure))
    try smoke.check("published object retained after fsync failure", category: \.faultInjection,
                    FileManager.default.fileExists(
                        atPath: faultRoot.appendingPathComponent(
                            "Dictionaries/\(identity.dictionaryID)"
                        ).path
                    ))
    try smoke.check("durability failure does not publish Catalog trust",
                    category: \.catalogTransactions,
                    fault.catalog.dictionaries.isEmpty)
    let recovered = await OwnedDictionaryLifecycleReconciler(
        catalogStore: faultStore, applicationSupportRootURL: faultRoot
    ).reconcile()
    try smoke.check("retry after durability uncertainty", category: \.catalogTransactions,
                    recovered.catalog.dictionaries.first?.dictionaryID ==
                        identity.dictionaryID)

    let renameRoot = base.appendingPathComponent("rename-conflict", isDirectory: true)
    let renameStaging = renameRoot.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(
        at: renameStaging, withIntermediateDirectories: true
    )
    let renameIdentity = try makeIdentity(
        dictionaryID: "50000000-0000-4000-8000-000000000002",
        resourceID: "rename-conflict", payload: payload
    )
    let renameDirectory = try writeOpenDirectory(
        parent: renameStaging,
        component: "verified-66666666-6666-4666-8666-666666666666",
        identity: renameIdentity,
        payload: payload
    )
    let renameHooks = OwnedDictionaryLifecycleHooks(
        renameNoReplaceAt: { _, _, _, _ in
            throw OwnedDictionaryLifecycleErrorCode.pendingDeletionConflict
        },
        synchronize: { _ in },
        beforeDelete: { _ in }
    )
    let renameStore = DictionaryCatalogStore(
        directoryURL: renameRoot.appendingPathComponent("Catalog")
    )
    let renameResult = await OwnedDictionaryLifecycleReconciler(
        catalogStore: renameStore,
        applicationSupportRootURL: renameRoot,
        hooks: renameHooks
    ).reconcile()
    try smoke.check("rename conflict preserves verified candidate",
                    category: \.faultInjection,
                    FileManager.default.fileExists(atPath: renameDirectory.path))
    try smoke.check("rename conflict does not publish Catalog",
                    category: \.catalogTransactions,
                    renameResult.catalog.dictionaries.isEmpty)

    var events: [String] = []
    events.append("reconcile-start")
    let barrierRoot = base.appendingPathComponent("barrier", isDirectory: true)
    let barrierStore = DictionaryCatalogStore(
        directoryURL: barrierRoot.appendingPathComponent("Catalog")
    )
    _ = await OwnedDictionaryLifecycleReconciler(
        catalogStore: barrierStore, applicationSupportRootURL: barrierRoot
    ).reconcile()
    events.append("reconcile-complete")
    events.append("runtime-published")
    try smoke.check("startup publication barrier", category: \.barriers,
                    events == ["reconcile-start", "reconcile-complete",
                               "runtime-published"])
}

@main
struct OwnedDictionaryLifecycleReconciliationSmoke {
    @MainActor
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-OwnedLifecycle-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var smoke = Smoke()
        try await testCatalogProvenance(base: base, smoke: &smoke)
        try await testVerifiedRecovery(base: base, smoke: &smoke)
        try await testFinalValidationFailures(base: base, smoke: &smoke)
        try await testFinalAndIndexRecovery(base: base, smoke: &smoke)
        try await testOperationIdentityAndIndexInventory(base: base, smoke: &smoke)
        try await testVerifiedPublicationIdentityRace(base: base, smoke: &smoke)
        try await testPendingDeletionIdentityRace(base: base, smoke: &smoke)
        try await testOrphanAndDuplicateRecovery(base: base, smoke: &smoke)
        try await testPendingDeletion(base: base, smoke: &smoke)
        try await testOwnedRemoval(base: base, smoke: &smoke)
        try await testFaultsCancellationAndBarrier(base: base, smoke: &smoke)
        print("Owned lifecycle reconciliation smoke passed " +
              "(\(smoke.assertions) total runtime assertions)")
        print("categories: POSIX=\(smoke.posix) renameatx_np=\(smoke.rename) " +
              "Catalog=\(smoke.catalogTransactions) SHA=\(smoke.sha) " +
              "fault=\(smoke.faultInjection) barrier=\(smoke.barriers) " +
              "helper-only=\(smoke.helperOnly)")
    }
}
