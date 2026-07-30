import Foundation

private enum ResourceCenterSmokeFailure: Error { case failed(String) }

private func check(_ condition: @autoclosure () -> Bool,
                   _ message: String) throws {
    guard condition() else { throw ResourceCenterSmokeFailure.failed(message) }
}

private let digestA = String(repeating: "a", count: 64)
private let digestB = String(repeating: "b", count: 64)
private let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)

private func resource(revision: UInt64 = 1,
                      version: String = "1.0",
                      digest: String = digestA) -> ResourceManifestResource {
    ResourceManifestResource(
        resourceID: "synthetic-open-dictionary",
        resourceRevision: revision,
        displayName: "Synthetic Open Dictionary",
        version: version,
        languages: ["en", "zh-Hans"],
        description: "Synthetic metadata only.",
        category: "bilingual",
        queryLevel: .fallback,
        distributionMode: .mirroredDownload,
        sourceProjectURL: "https://source.example.test/project",
        officialDownloadPage: "https://source.example.test/download",
        downloadURL: "https://payload.example.test/dictionary.mdx",
        allowedDownloadHosts: ["payload.example.test"],
        fileName: "dictionary.mdx",
        archiveFormat: ResourceArchiveFormat.none,
        compressedSize: 4_096,
        maximumDownloadedSize: 4_096,
        maximumExpandedSize: 4_096,
        sha256: digest,
        licenseName: "Synthetic License",
        licenseVersion: "1.0",
        licenseURL: "https://source.example.test/license",
        attribution: "Synthetic publisher",
        notice: ResourceManifestNotice(kind: .inline, text: "Synthetic fixture"),
        redistributionAllowed: true,
        mirroringAllowed: true,
        modificationAllowed: true,
        formatConversionAllowed: true,
        commercialUseAllowed: false,
        shareAlikeRequired: false,
        minimumAppVersion: "0.1",
        dictionaryFormat: .genericMDictV1,
        expectedEntryCount: ResourceManifestEntryCountRange(minimum: 1, maximum: 2),
        status: .active,
        reviewedAt: "2026-01-01T00:00:00Z",
        reviewEvidence: [
            ResourceManifestReviewEvidence(
                kind: "license",
                url: "https://source.example.test/evidence",
                sha256: digestA
            )
        ]
    )
}

private func verified(_ resource: ResourceManifestResource)
    -> VerifiedResourceManifest {
    let manifest = ResourceManifestV1(
        schemaVersion: 1,
        manifestVersion: 1,
        issuedAt: "2026-01-01T00:00:00Z",
        expiresAt: "2027-01-01T00:00:00Z",
        keyID: "synthetic-key",
        minimumAppVersion: "0.1",
        resources: [resource],
        revokedResources: []
    )
    return VerifiedResourceManifest(
        validated: ValidatedResourceManifest(
            manifest: manifest,
            issuedAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(3600),
            minimumAppVersion: try! ManifestAppVersion("0.1"),
            freshness: .current
        ),
        manifestSHA256: digestA,
        verifiedKeyID: "synthetic-key"
    )
}

private func openDescriptor(
    dictionaryID: String,
    revision: UInt64,
    version: String,
    payloadDigest: String,
    state: DictionaryState,
    enabled: Bool
) -> DictionaryDescriptor {
    let publicationID = dictionaryID == "00000000-0000-0000-0000-000000000001"
        ? "10000000-0000-0000-0000-000000000001"
        : "10000000-0000-0000-0000-000000000002"
    let ready = state == .ready
    let relativeIndex = ready
        ? "Dictionaries/\(dictionaryID)/index/dictionary.\(publicationID).sqlite"
        : nil
    let published = ready ? PublishedIndexIdentity(
        indexPublicationID: publicationID,
        indexSHA256: digestB,
        indexFileSize: 8_192,
        sourceSHA256: payloadDigest,
        sourceFileSize: 4_096,
        schemaVersion: 1,
        entryCount: 1,
        indexedAt: fixedDate,
        relativePath: relativeIndex!
    ) : nil
    return DictionaryDescriptor(
        dictionaryID: dictionaryID,
        displayName: "Synthetic Open Dictionary",
        sourceKind: .openResource,
        queryLevel: .fallback,
        sortPosition: 1,
        enabled: enabled,
        state: state,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: ready ? 1 : nil,
            entryCount: ready ? 1 : nil,
            indexFileSize: ready ? 8_192 : nil,
            sourceFileSize: 4_096,
            sourceModifiedAt: nil,
            sourceSHA256: payloadDigest,
            indexedAt: ready ? fixedDate : nil
        ),
        formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: "Dictionaries/\(dictionaryID)/payload.mdx",
            resources: [],
            index: relativeIndex
        ),
        createdAt: fixedDate,
        updatedAt: fixedDate,
        storageOwnership: .appManagedOpenResource,
        openResourceMetadata: OpenResourceInstallationMetadata(
            resourceID: "synthetic-open-dictionary",
            resourceRevision: revision,
            resourceVersion: version,
            manifestVersion: revision,
            manifestSHA256: digestA,
            verifiedKeyID: "synthetic-key",
            payloadSHA256: payloadDigest,
            payloadBytes: 4_096,
            sidecarRelativePath:
                "Dictionaries/\(dictionaryID)/resource-installation.json",
            languages: ["en"],
            license: OpenResourceLicenseMetadata(
                name: "Synthetic License",
                version: "1.0",
                url: "https://source.example.test/license",
                attribution: "Synthetic publisher"
            ),
            sourceProject: "https://source.example.test/project",
            officialPageReference: "https://source.example.test/download",
            expectedEntryCount: OpenResourceEntryCountMetadata(minimum: 1, maximum: 2),
            installedAt: fixedDate
        ),
        publishedIndexIdentity: published
    )
}

@main
private enum ResourceCenterSmoke {
    static func main() throws {
        let empty = DictionaryCatalog.empty(now: fixedDate)
        let unavailable = ResourceCenterSnapshot.unavailable(catalog: empty)
        try check(unavailable.catalogState == .catalogUnavailable &&
                  unavailable.resources.isEmpty,
                  "empty production configuration did not fail closed")
        try check(ResourceCenterProductionConfiguration.current.manifestEndpoint == nil &&
                  ResourceCenterProductionConfiguration.current.payloadAllowedHosts.isEmpty &&
                  ResourceCenterProductionConfiguration.current.trustedManifestKeys.isEmpty,
                  "production Resource Center trust must remain empty")

        let available = ResourceCenterPresentation.snapshot(
            verifiedManifest: verified(resource()),
            catalog: empty,
            catalogState: .available,
            catalogMessage: "verified"
        )
        try check(available.resources.count == 1 &&
                  available.resources[0].canInstall &&
                  available.resources[0].licenseName.contains("Synthetic License"),
                  "verified resource was not presented with license metadata")
        let retry = ResourceCenterPresentation.snapshot(
            verifiedManifest: verified(resource()),
            catalog: empty,
            catalogState: .available,
            catalogMessage: "verified",
            operations: ["synthetic-open-dictionary": .failed],
            failures: ["synthetic-open-dictionary": "synthetic failure"]
        )
        try check(retry.resources[0].canInstall &&
                  retry.resources[0].failureMessage == "synthetic failure",
                  "failed installation did not expose a safe retry")

        let old = openDescriptor(
            dictionaryID: "00000000-0000-0000-0000-000000000001",
            revision: 1,
            version: "1.0",
            payloadDigest: digestA,
            state: .ready,
            enabled: true
        )
        let installedCatalog = DictionaryCatalog(
            schemaVersion: 3,
            createdAt: fixedDate,
            updatedAt: fixedDate,
            dictionaries: [old]
        )
        let update = ResourceCenterPresentation.snapshot(
            verifiedManifest: verified(resource(revision: 2, version: "2.0", digest: digestB)),
            catalog: installedCatalog,
            catalogState: .available,
            catalogMessage: "verified"
        )
        try check(update.resources[0].operationState == .updateAvailable &&
                  update.resources[0].canUpdate,
                  "higher signed revision did not become an explicit update")

        let anomaly = ResourceCenterPresentation.snapshot(
            verifiedManifest: verified(resource(revision: 1, version: "1.0", digest: digestB)),
            catalog: installedCatalog,
            catalogState: .available,
            catalogMessage: "verified"
        )
        try check(anomaly.resources[0].operationState == .failed &&
                  !anomaly.resources[0].canInstall && !anomaly.resources[0].canUpdate,
                  "same revision with different SHA was not rejected")

        let pending = openDescriptor(
            dictionaryID: "00000000-0000-0000-0000-000000000002",
            revision: 2,
            version: "2.0",
            payloadDigest: digestB,
            state: .pendingIndex,
            enabled: false
        )
        var transition = installedCatalog
        transition.dictionaries.append(pending)
        _ = try transition.validated()

        var disabledTransition = installedCatalog
        disabledTransition.dictionaries[0].enabled = false
        disabledTransition.dictionaries.append(pending)
        _ = try disabledTransition.validated()

        var reorderedTransition = transition
        reorderedTransition.dictionaries[1].sortPosition = 2
        do {
            _ = try reorderedTransition.validated()
            throw ResourceCenterSmokeFailure.failed(
                "update transition changed the installed sort position"
            )
        } catch DictionaryCatalogValidationError.duplicateOpenResourceID {
            // Expected.
        }

        transition.dictionaries[0].enabled = false
        transition.dictionaries[1] = openDescriptor(
            dictionaryID: "00000000-0000-0000-0000-000000000002",
            revision: 2,
            version: "2.0",
            payloadDigest: digestB,
            state: .ready,
            enabled: true
        )
        _ = try transition.validated()

        var invalid = transition
        invalid.dictionaries[0].enabled = true
        do {
            _ = try invalid.validated()
            throw ResourceCenterSmokeFailure.failed(
                "two query-eligible revisions were accepted"
            )
        } catch DictionaryCatalogValidationError.duplicateOpenResourceID {
            // Expected.
        }

        try check(DictionaryCatalogOrdering.legacyDefaultOrder == [
            DictionarySourceID.oxfordOALD8.rawValue,
            DictionarySourceID.century21.rawValue,
            DictionarySourceID.newOxford.rawValue,
            DictionarySourceID.medicalEnglishChinese.rawValue,
            DictionarySourceID.affixRootA.rawValue
        ], "Resource Center changed preferred ordering")

        print("ResourceCenterSmoke PASS (12/12)")
    }
}
