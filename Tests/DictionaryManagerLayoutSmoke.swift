import AppKit
import Foundation

private enum LayoutSmokeError: Error { case failed(String) }

private func layoutExpect(_ condition: @autoclosure () -> Bool,
                          _ message: String) throws {
    if !condition() { throw LayoutSmokeError.failed(message) }
}

private actor EmptyManagedRuntime: ManagedDictionaryQueryRuntime {
    func lookup(descriptor: DictionaryDescriptor,
                generation: UInt64,
                query: String) async -> ManagedDictionaryRuntimeOutcome { .miss }
    func remove(dictionaryID: String) async {}
    func remove(dictionaryID: String, generation: UInt64) async {}
    func reset() async {}
}

@MainActor
private func allSubviews(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allSubviews(of:))
}

@MainActor
private func layoutDescriptor(state: DictionaryState) -> DictionaryDescriptor {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return DictionaryDescriptor(
        dictionaryID: "00000000-0000-0000-0000-000000000001",
        displayName: "A very long imported dictionary name that requires a tooltip",
        sourceKind: .managedLocal,
        queryLevel: .normal,
        sortPosition: 1,
        enabled: true,
        state: state,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: state == .ready ? 1 : nil,
            entryCount: state == .ready ? 12_345 : nil,
            indexFileSize: state == .ready ? 1_048_576 : nil,
            sourceFileSize: 4_096,
            sourceModifiedAt: now,
            sourceSHA256: String(repeating: "a", count: 64),
            indexedAt: state == .ready ? now : nil
        ),
        formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: "Dictionaries/00000000-0000-0000-0000-000000000001/test.mdx",
            resources: [],
            index: state == .ready
                ? "Dictionaries/00000000-0000-0000-0000-000000000001/index/dictionary.sqlite"
                : nil
        ),
        createdAt: now,
        updatedAt: now
    )
}

@main
private enum DictionaryManagerLayoutSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-C1-layout-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogStore = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("Catalog", isDirectory: true)
        )
        let queryService = ManagedDictionaryQueryService(runtime: EmptyManagedRuntime())
        let indexCoordinator = ManagedDictionaryIndexCoordinator(
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            openSource: { _, _, size, digest, _ in
                DictionaryIndexSourceCapability(
                    sourceFileSize: size,
                    sourceSHA256: digest,
                    validation: { true }
                )
            },
            buildIndex: { _, _, _ in .failure("not used by layout smoke") },
            createCandidate: { _ in
                throw DictionaryIndexError.candidateCreationFailed
            },
            expectedSchemaVersion: 1
        )
        let removalCoordinator = ManagedDictionaryRemovalCoordinator(
            catalogStore: catalogStore,
            applicationSupportRootURL: root,
            queryService: queryService,
            isIndexing: { _ in false }
        )
        let importService = DictionaryImportService(
            dictionariesRootURL: root.appendingPathComponent("Dictionaries", isDirectory: true),
            catalogStore: catalogStore
        )
        let controller = DictionaryManagerWindowController(
            catalog: .empty(),
            catalogStore: catalogStore,
            importService: importService,
            indexCoordinator: indexCoordinator,
            removalCoordinator: removalCoordinator
        )
        guard let window = controller.window, let content = window.contentView else {
            throw LayoutSmokeError.failed("manager window missing")
        }
        content.layoutSubtreeIfNeeded()
        let emptyAmbiguous = allSubviews(of: content).filter(\.hasAmbiguousLayout)
        try layoutExpect(emptyAmbiguous.isEmpty,
                         "empty manager layout is ambiguous: \(emptyAmbiguous.map { "\(type(of: $0)) frame=\($0.frame)" })")
        try layoutExpect(allSubviews(of: content).compactMap { $0 as? NSTextField }
            .contains(where: { $0.stringValue == "当前没有可用的本地词典" }),
            "friendly empty state missing")

        var catalog = DictionaryCatalog.empty(now: Date(timeIntervalSince1970: 1_700_000_000))
        catalog.dictionaries = [layoutDescriptor(state: .pendingIndex)]
        controller.update(catalog: catalog)
        content.layoutSubtreeIfNeeded()
        let populatedAmbiguous = allSubviews(of: content).filter(\.hasAmbiguousLayout)
        try layoutExpect(populatedAmbiguous.isEmpty,
                         "populated manager layout is ambiguous: \(populatedAmbiguous.map { "\(type(of: $0)) frame=\($0.frame)" })")
        guard let table = allSubviews(of: content).compactMap({ $0 as? NSTableView }).first else {
            throw LayoutSmokeError.failed("dictionary table missing")
        }
        let titles = Set(table.tableColumns.map(\.title))
        for title in ["词典名称", "来源类型", "查询级别", "状态", "最近索引时间", "索引操作"] {
            try layoutExpect(titles.contains(title), "missing table column: \(title)")
        }
        let actionColumn = table.column(withIdentifier: .init("action"))
        try layoutExpect(actionColumn >= 0, "index action column missing")
        let actionView = table.view(atColumn: actionColumn, row: 0, makeIfNecessary: true)
        let actionButtons = actionView.map(allSubviews(of:))?.compactMap { $0 as? NSButton } ?? []
        try layoutExpect(actionButtons.contains(where: { $0.title == "建立索引" }),
                         "full index action title missing")

        let preview = DictionaryImportPreview(
            sourceMDXURL: root.appendingPathComponent("preview.mdx"),
            displayName: "Preview Dictionary",
            originalFileName: "preview.mdx",
            mdxFileSize: 4_096,
            sourceModifiedAt: nil,
            header: MDictHeaderSummary(
                title: "Preview Dictionary",
                engineVersion: "2.0",
                encoding: "UTF-8",
                compression: .compressed,
                isEncrypted: false
            ),
            mdxSHA256: String(repeating: "b", count: 64),
            mddCandidates: [],
            automaticallySelectedMDDIDs: []
        )
        let previewAccessory = DictionaryImportPreviewAccessory(previews: [preview])
        previewAccessory.view.layoutSubtreeIfNeeded()
        try layoutExpect(!allSubviews(of: previewAccessory.view)
            .contains(where: \.hasAmbiguousLayout), "import preview layout is ambiguous")

        print("Dictionary manager C1 AppKit layout smoke: PASS")
    }
}
