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
private func layoutDescriptor(id: Int,
                              state: DictionaryState,
                              sourceKind: DictionarySourceKind = .managedLocal,
                              queryLevel: DictionaryQueryLevel = .normal,
                              enabled: Bool = true) -> DictionaryDescriptor {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identifier = String(format: "00000000-0000-0000-0000-%012d", id)
    return DictionaryDescriptor(
        dictionaryID: identifier,
        displayName: "Mixed source dictionary \(id) with a tooltip-worthy name",
        sourceKind: sourceKind,
        queryLevel: queryLevel,
        sortPosition: Int64(id),
        enabled: enabled,
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
        formatterIdentifier: sourceKind == .legacyReference
            ? DictionaryFormatterIdentifier.legacyGenericMDictV1
            : DictionaryFormatterIdentifier.genericMDictV1,
        capabilities: .unknown,
        relativePaths: DictionaryRelativePaths(
            dictionary: "Dictionaries/\(identifier)/test.mdx",
            resources: [],
            index: state == .ready
                ? "Dictionaries/\(identifier)/index/dictionary.sqlite"
                : nil
        ),
        createdAt: now,
        updatedAt: now
    )
}

@MainActor
private func reverseProbeDescriptor(id: Int) -> DictionaryDescriptor {
    var descriptor = layoutDescriptor(id: id, state: .ready)
    let publicationID = "11111111-1111-4111-8111-111111111111"
    let relativePath = "Dictionaries/\(descriptor.dictionaryID)/index/" +
        "dictionary.\(publicationID).sqlite"
    descriptor.relativePaths.index = relativePath
    descriptor.publishedIndexIdentity = PublishedIndexIdentity(
        indexPublicationID: publicationID,
        indexSHA256: String(repeating: "b", count: 64),
        indexFileSize: descriptor.indexMetadata.indexFileSize!,
        sourceSHA256: descriptor.indexMetadata.sourceSHA256!,
        sourceFileSize: descriptor.indexMetadata.sourceFileSize!,
        schemaVersion: descriptor.indexMetadata.schemaVersion!,
        entryCount: descriptor.indexMetadata.entryCount!,
        indexedAt: descriptor.indexMetadata.indexedAt!,
        relativePath: relativePath
    )
    descriptor.reverseCapabilityProbe = nil
    return descriptor
}

private func probeReport(
    _ result: DictionaryReverseCapabilityProbe,
    mode: ManagedReverseCapabilityProbeMode,
    processed: UInt64 = 513
) -> ManagedReverseCapabilityProbeReport {
    ManagedReverseCapabilityProbeReport(
        result: result, mode: mode,
        terminalReason: result == .supported ? .usableNativeGlossFound :
            result == .noUsableNativeGloss ? .endOfFileNoUsableNativeGloss :
            result == .unsupportedFormatter ? .unsupportedFormatter : .readFailed,
        processedEntryCount: processed, expectedEntryCount: 12_345,
        usableEntryCount: processed,
        usableNativeGlossCount: result == .supported ? 1 : 0,
        skippedMalformedEntryCount: 0,
        skippedNoUsableNativeGlossEntryCount: result == .supported ? processed - 1 : processed
    )
}

@main
private enum DictionaryManagerLayoutSmoke {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        AppLocalization.configureAtLaunch(.productionDefault)
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
        let resourceCenterController = ResourceCenterController(
            catalog: .empty(),
            catalogStore: catalogStore,
            installationCoordinator: OpenResourceInstallationCoordinator(
                lifecycleCoordinator: queryService.lifecycleCoordinator
            ),
            indexCoordinator: indexCoordinator,
            removalCoordinator: removalCoordinator,
            applicationSupportRoot: root,
            manifestStateStore: VerifiedManifestStateStore(
                directoryURL: root.appendingPathComponent(
                    "ManifestState", isDirectory: true
                )
            )
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
            removalCoordinator: removalCoordinator,
            resourceCenterController: resourceCenterController,
            reverseIndexCoordinator: ReverseIndexCoordinator(
                rootURL: root.appendingPathComponent("ReverseIndexes", isDirectory: true)
            ),
            reverseLookupService: ReverseLookupService(),
            reverseSources: [
                ReverseDictionarySource(
                    dictionaryID: "00000000-0000-0000-0000-000000000001",
                    dictionaryName: "Synthetic supported dictionary"
                )
            ]
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
        try layoutExpect(allSubviews(of: content).compactMap { $0 as? NSButton }
            .contains(where: { $0.title == "查找双语开放词典…" }),
            "Resource Center entry missing")

        var closeRequests = 0
        try layoutExpect(
            ResourceCenterViewController.sizeText(nil) == "安装时获取" &&
                !ResourceCenterViewController.sizeText(4_321_987).contains("Zero"),
            "live resource size rendered unknown bytes as Zero KB"
        )
        let resourceViewController = ResourceCenterViewController(
            controller: resourceCenterController,
            onClose: { closeRequests += 1 }
        )
        let resourceView = resourceViewController.view
        resourceView.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        resourceView.layoutSubtreeIfNeeded()
        let recommendation = allSubviews(of: resourceView).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() ==
                "resource-center-language-recommendation" }
        try layoutExpect(recommendation?.stringValue.contains("推荐给当前语言组合") == true &&
                         recommendation?.stringValue.contains("WordNet") == true &&
                         recommendation?.stringValue.contains("GCIDE") == true,
                         "pre-discovery Resource Center view omitted installed English supplements")
        let resourceScrollViews = allSubviews(of: resourceView).compactMap { $0 as? NSScrollView }
        guard let tableScroll = resourceScrollViews.first(where: { $0.documentView is NSTableView }),
              let detailScroll = resourceScrollViews.first(where: { scroll in
                  guard !(scroll.documentView is NSTableView), let document = scroll.documentView else {
                      return false
                  }
                  return allSubviews(of: document).compactMap { $0 as? NSTextField }
                      .contains(where: \.isSelectable)
              }) else {
            throw LayoutSmokeError.failed("Resource Center table/detail scroll regions missing")
        }
        try layoutExpect(!tableScroll.hasHorizontalScroller &&
                         !detailScroll.hasHorizontalScroller,
                         "Resource Center unexpectedly enables horizontal scrolling")
        for size in [NSSize(width: 900, height: 620), NSSize(width: 760, height: 500)] {
            resourceView.frame.size = size
            resourceView.layoutSubtreeIfNeeded()
            try layoutExpect(!allSubviews(of: resourceView).contains(where: \.hasAmbiguousLayout),
                             "Resource Center layout is ambiguous at \(size)")
            for button in allSubviews(of: resourceView).compactMap({ $0 as? NSButton }) {
                let frame = button.superview?.convert(button.frame, to: resourceView) ?? .zero
                try layoutExpect(!button.isHidden && frame.minY >= -1 &&
                                 frame.maxY <= resourceView.bounds.maxY + 1,
                                 "Resource Center button \(button.title) escaped the visible view at \(size)")
            }
            try layoutExpect(detailScroll.frame.height >= 72 &&
                             tableScroll.frame.height >= 150,
                             "Resource Center scroll region collapsed at \(size)")
        }
        guard let visibleClose = allSubviews(of: resourceView).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "关闭" }) else {
            throw LayoutSmokeError.failed("Resource Center visible close button missing")
        }
        visibleClose.performClick(nil)
        try layoutExpect(closeRequests == 1,
                         "Resource Center close button did not request closure")
        resourceViewController.cancelOperation(nil)
        try layoutExpect(closeRequests == 2,
                         "Resource Center Esc responder did not request closure")

        let sheetWindow = ResourceCenterSheetWindow(
            contentViewController: resourceViewController
        )
        var sheetCloseRequests = 0
        sheetWindow.requestClose = { sheetCloseRequests += 1 }
        sheetWindow.performClose(nil)
        try layoutExpect(sheetCloseRequests == 1,
                         "Resource Center performClose/Cmd-W path did not request closure")
        sheetWindow.cancelOperation(nil)
        try layoutExpect(sheetCloseRequests == 2,
                         "Resource Center sheet Esc path did not request closure")
        try layoutExpect(allSubviews(of: resourceView).compactMap { $0 as? NSButton }
            .contains(where: { $0.title == "关闭" }),
            "Resource Center visible close button missing")

        var englishPreferences = LanguagePreferences.productionDefault
        englishPreferences.uiLanguage = .english
        AppLocalization.configureAtLaunch(englishPreferences)
        let englishResourceController = ResourceCenterViewController(
            controller: resourceCenterController
        )
        let englishResourceView = englishResourceController.view
        try layoutExpect(allSubviews(of: englishResourceView).compactMap { $0 as? NSTextField }
            .contains(where: { $0.stringValue == "Resource Center" }) &&
            allSubviews(of: englishResourceView).compactMap { $0 as? NSButton }
            .contains(where: { $0.title == "Close" }),
            "real Resource Center window did not use English UI")
        AppLocalization.configureAtLaunch(.productionDefault)

        var catalog = DictionaryCatalog.empty(now: Date(timeIntervalSince1970: 1_700_000_000))
        catalog.dictionaries = [
            layoutDescriptor(id: 1, state: .pendingIndex),
            layoutDescriptor(id: 2, state: .ready, sourceKind: .legacyReference,
                             queryLevel: .preferred),
            layoutDescriptor(id: 3, state: .ready, sourceKind: .legacyReference,
                             queryLevel: .preferred, enabled: false),
            layoutDescriptor(id: 4, state: .ready, sourceKind: .openResource,
                             queryLevel: .preferred),
            layoutDescriptor(id: 5, state: .ready, enabled: false),
            layoutDescriptor(id: 6, state: .pendingIndex, sourceKind: .openResource)
        ]
        controller.update(catalog: catalog)
        content.layoutSubtreeIfNeeded()
        let populatedAmbiguous = allSubviews(of: content).filter(\.hasAmbiguousLayout)
        try layoutExpect(populatedAmbiguous.isEmpty,
                         "populated manager layout is ambiguous: \(populatedAmbiguous.map { "\(type(of: $0)) frame=\($0.frame)" })")
        guard let table = allSubviews(of: content).compactMap({ $0 as? NSTableView }).first else {
            throw LayoutSmokeError.failed("dictionary table missing")
        }
        let titles = Set(table.tableColumns.map(\.title))
        for title in ["词典名称", "来源", "词典类型", "启用", "正向状态", "中文反向索引", "操作"] {
            try layoutExpect(titles.contains(title), "missing table column: \(title)")
        }
        let actionColumn = table.column(withIdentifier: .init("action"))
        try layoutExpect(actionColumn >= 0, "index action column missing")
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let allActionButtons = (0..<catalog.dictionaries.count).compactMap { row in
            table.view(atColumn: actionColumn, row: row, makeIfNecessary: true)
        }.flatMap { cell in
            allSubviews(of: cell).compactMap { $0 as? NSButton }
        }
        try layoutExpect(allActionButtons.contains(where: { $0.title == "建立索引" }),
                         "full index action title missing")
        try layoutExpect(allActionButtons.contains(where: {
            $0.title == "建立反向索引"
        }), "reverse-index action title missing")

        let probeDescriptor = reverseProbeDescriptor(id: 7)
        var probeCatalog = DictionaryCatalog.empty(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        probeCatalog.dictionaries = [probeDescriptor]
        let probeStore = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("ProbeCatalog", isDirectory: true)
        )
        try probeStore.save(probeCatalog)
        let probeController = DictionaryManagerWindowController(
            catalog: probeCatalog,
            catalogStore: probeStore,
            importService: importService,
            indexCoordinator: indexCoordinator,
            removalCoordinator: removalCoordinator,
            resourceCenterController: resourceCenterController,
            reverseIndexCoordinator: ReverseIndexCoordinator(
                rootURL: root.appendingPathComponent("ProbeReverse", isDirectory: true)
            ),
            reverseLookupService: ReverseLookupService(),
            reverseSources: [ReverseDictionarySource(managed: probeDescriptor)],
            reverseCapabilityProbeRunner: { _, mode in
                probeReport(.supported, mode: mode)
            }
        )
        guard let probeContent = probeController.window?.contentView,
              let probeTable = allSubviews(of: probeContent).compactMap({ $0 as? NSTableView }).first
        else { throw LayoutSmokeError.failed("probe manager table missing") }
        probeContent.layoutSubtreeIfNeeded()
        let probeActionColumn = probeTable.column(withIdentifier: .init("action"))
        guard probeActionColumn >= 0,
              let initialProbeCell = probeTable.view(
                  atColumn: probeActionColumn, row: 0, makeIfNecessary: true
              ),
              let probeButton = allSubviews(of: initialProbeCell)
                .compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "检测中文释义" })
        else { throw LayoutSmokeError.failed("real reverse capability probe button missing") }
        try layoutExpect(probeButton.isEnabled,
                         "reverse capability probe button is not actionable")
        try layoutExpect(probeButton.toolTip?.contains("词典末尾") == true,
                         "manual reverse capability action did not explain its full read-only scan")
        probeButton.performClick(nil)
        await probeController.waitForReverseCapabilityProbeForTesting(
            dictionaryID: probeDescriptor.dictionaryID
        )
        let productionResultAlert = DictionaryManagerWindowController
            .reverseCapabilityProbeResultAlert(
                probeReport(.supported, mode: .full),
                dictionaryName: probeDescriptor.displayName
            )
        let probeResultButtons = productionResultAlert.buttons
        try layoutExpect(probeResultButtons.contains(where: {
            $0.title == "立即建立中文反向索引" && $0.isEnabled
        }), "supported probe result sheet omitted the immediate reverse-index action")
        try layoutExpect(probeResultButtons.contains(where: {
            $0.title == "稍后" && $0.isEnabled
        }), "supported probe result sheet omitted the defer action")
        let persistedProbe = probeStore.load().dictionaries.first {
            $0.dictionaryID == probeDescriptor.dictionaryID
        }
        try layoutExpect(persistedProbe?.reverseCapabilityProbe == .supported,
                         "reverse capability result was not persisted")
        probeTable.reloadData()
        guard let completedProbeCell = probeTable.view(
            atColumn: probeActionColumn, row: 0, makeIfNecessary: true
        ) else { throw LayoutSmokeError.failed("completed probe action cell missing") }
        try layoutExpect(allSubviews(of: completedProbeCell).compactMap({ $0 as? NSButton })
            .contains(where: { $0.title == "建立反向索引" && $0.isEnabled }),
            "supported probe did not transition to an actionable reverse-index build")
        var disabledProbed = probeStore.load()
        disabledProbed.dictionaries[0].enabled = false
        try probeStore.save(disabledProbed)
        probeController.update(catalog: disabledProbed)
        probeController.updateReverseSources([])
        probeTable.reloadData()
        guard let disabledProbeCell = probeTable.view(
            atColumn: probeActionColumn, row: 0, makeIfNecessary: true
        ) else { throw LayoutSmokeError.failed("disabled probe action cell missing") }
        let disabledProbeButtons = allSubviews(of: disabledProbeCell)
            .compactMap { $0 as? NSButton }
        try layoutExpect(!disabledProbeButtons.contains(where: {
            $0.title.contains("检测中文释义")
        }) && disabledProbeButtons.contains(where: {
            $0.title == "建立反向索引" && !$0.isEnabled
        }), "disabled dictionary forgot its persisted reverse capability")

        let unknownDescriptor = reverseProbeDescriptor(id: 8)
        var unknownCatalog = DictionaryCatalog.empty(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        unknownCatalog.dictionaries = [unknownDescriptor]
        let unknownStore = DictionaryCatalogStore(
            directoryURL: root.appendingPathComponent("UnknownProbeCatalog", isDirectory: true)
        )
        try unknownStore.save(unknownCatalog)
        let unknownController = DictionaryManagerWindowController(
            catalog: unknownCatalog,
            catalogStore: unknownStore,
            importService: importService,
            indexCoordinator: indexCoordinator,
            removalCoordinator: removalCoordinator,
            resourceCenterController: resourceCenterController,
            reverseIndexCoordinator: ReverseIndexCoordinator(
                rootURL: root.appendingPathComponent("UnknownProbeReverse", isDirectory: true)
            ),
            reverseLookupService: ReverseLookupService(),
            reverseSources: [ReverseDictionarySource(managed: unknownDescriptor)],
            reverseCapabilityProbeRunner: { _, mode in
                probeReport(.unknown, mode: mode)
            }
        )
        guard let unknownContent = unknownController.window?.contentView,
              let unknownTable = allSubviews(of: unknownContent)
                .compactMap({ $0 as? NSTableView }).first
        else { throw LayoutSmokeError.failed("unknown probe manager table missing") }
        unknownContent.layoutSubtreeIfNeeded()
        let unknownActionColumn = unknownTable.column(withIdentifier: .init("action"))
        guard unknownActionColumn >= 0,
              let unknownInitialCell = unknownTable.view(
                  atColumn: unknownActionColumn, row: 0, makeIfNecessary: true
              ),
              let unknownButton = allSubviews(of: unknownInitialCell)
                .compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "检测中文释义" })
        else { throw LayoutSmokeError.failed("unknown probe initial button missing") }
        unknownButton.performClick(nil)
        await unknownController.waitForReverseCapabilityProbeForTesting(
            dictionaryID: unknownDescriptor.dictionaryID
        )
        try layoutExpect(unknownStore.load().dictionaries.first?
            .reverseCapabilityProbe == .unknown,
            "inconclusive reverse probe was discarded instead of persisted")
        unknownTable.reloadData()
        guard let unknownCompletedCell = unknownTable.view(
            atColumn: unknownActionColumn, row: 0, makeIfNecessary: true
        ) else { throw LayoutSmokeError.failed("unknown probe completed cell missing") }
        try layoutExpect(allSubviews(of: unknownCompletedCell).compactMap({ $0 as? NSButton })
            .contains(where: { $0.title == "完整检测中文释义" && $0.isEnabled }),
            "inconclusive reverse probe did not expose a stable retry action")

        for width in [CGFloat(1_280), 900,
                      DictionaryManagerPresentation.minimumWindowWidth] {
            window.setContentSize(NSSize(width: width, height: 520))
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                content.appearance = NSAppearance(named: appearanceName)
                content.layoutSubtreeIfNeeded()
                try layoutExpect(!allSubviews(of: content).contains(where: \.hasAmbiguousLayout),
                    "manager ambiguous at width \(width), \(appearanceName.rawValue)")
                guard let actionCell = table.view(
                    atColumn: actionColumn, row: 0, makeIfNecessary: true
                ) else { throw LayoutSmokeError.failed("action cell unavailable") }
                let visible = table.visibleRect
                try layoutExpect(actionCell.frame.minX >= visible.minX - 1 &&
                    actionCell.frame.maxX <= visible.maxX + 1,
                    "action cell \(actionCell.frame) is outside visible \(visible) " +
                    "columns=\(table.tableColumns.map { ($0.identifier.rawValue, $0.width) }) " +
                    "at width \(width)")
                for button in allSubviews(of: actionCell).compactMap({ $0 as? NSButton }) {
                    try layoutExpect(!button.isHidden && button.frame.width > 0,
                                     "action button hidden at width \(width)")
                }
                let detailButtons = (0..<catalog.dictionaries.count).compactMap { row -> NSView? in
                    guard let cell = table.view(
                        atColumn: actionColumn, row: row, makeIfNecessary: true
                    ) else { return nil }
                    cell.layoutSubtreeIfNeeded()
                    return cell
                }.flatMap { cell in
                    allSubviews(of: cell).compactMap { $0 as? NSButton }
                        .filter { $0.title == "详情" }
                }
                try layoutExpect(detailButtons.count == 6,
                                 "not every mixed-source row has one detail button")
                let heights = detailButtons.map(\.frame.height)
                let widths = detailButtons.map(\.frame.width)
                try layoutExpect((heights.max() ?? 0) - (heights.min() ?? 0) < 0.5 &&
                                 heights.allSatisfy { $0 >= 20 && $0 <= 36 },
                                 "detail button heights are inconsistent: \(heights)")
                try layoutExpect((widths.max() ?? 0) - (widths.min() ?? 0) < 1,
                                 "detail button widths are inconsistent: \(widths)")
                for button in detailButtons {
                    try layoutExpect(button.bezelStyle == .rounded &&
                                     button.controlSize == .small,
                                     "detail button lost compact rounded styling")
                    try layoutExpect(button.frame.width > button.frame.height + 8,
                                     "detail button became circular or clipped: \(button.frame)")
                    try layoutExpect(button.intrinsicContentSize.width <= button.frame.width + 1,
                                     "detail title is horizontally clipped")
                    try layoutExpect(button.contentHuggingPriority(for: .horizontal) == .required &&
                                     button.contentCompressionResistancePriority(for: .horizontal)
                                        == .required,
                                     "detail button horizontal priorities differ")
                }
            }
        }

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

        let smallVisibleFrame = NSRect(x: 0, y: 0, width: 900, height: 560)
        var importedSelections: [DictionaryImportSelection] = []
        let previewWindowController = DictionaryImportPreviewWindowController(
            previews: [preview], parentWindow: window,
            visibleFrameOverride: smallVisibleFrame,
            onImport: { importedSelections = $0 }
        )
        guard let previewWindow = previewWindowController.window,
              let previewContent = previewWindow.contentView else {
            throw LayoutSmokeError.failed("screen-bounded import window missing")
        }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            previewContent.appearance = NSAppearance(named: appearanceName)
            for size in [previewWindow.frame.size, NSSize(width: 520, height: 360)] {
                previewWindow.setContentSize(size)
                previewContent.layoutSubtreeIfNeeded()
                try layoutExpect(previewWindow.frame.height <= smallVisibleFrame.height &&
                                 previewWindow.frame.width <= smallVisibleFrame.width,
                                 "import window exceeded the visible screen frame")
                let buttons = allSubviews(of: previewContent).compactMap { $0 as? NSButton }
                for title in ["取消", "导入"] {
                    guard let button = buttons.first(where: { $0.title == title }) else {
                        throw LayoutSmokeError.failed("import action missing: \(title)")
                    }
                    let frame = button.superview?.convert(button.frame, to: previewContent) ?? .zero
                    try layoutExpect(!button.isHidden && frame.minY >= 0 &&
                                     frame.maxY <= previewContent.bounds.maxY,
                                     "import action escaped the visible fixed action bar: \(title)")
                    try layoutExpect(!(button.superview is NSClipView),
                                     "import action was placed inside scrolling content")
                }
            }
        }
        allSubviews(of: previewContent).compactMap { $0 as? NSButton }
            .first(where: { $0.title == "导入" })?.performClick(nil)
        try layoutExpect(importedSelections.count == 1,
                         "single import click did not proceed without a rights modal")

        controller.showResourceCenter()
        try layoutExpect(controller.isResourceCenterPresented,
                         "Resource Center controller presentation state was not retained")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        try layoutExpect(!controller.isResourceCenterPresented,
                         "closing the parent did not safely close Resource Center")

        let validatingProgress = ReverseIndexDictionaryProgress(
            dictionaryID: "00000000-0000-0000-0000-000000000001",
            dictionaryName: "Large Chinese dictionary",
            stage: .validating,
            processedEntries: 500_000,
            totalEntries: 500_000,
            canCancel: true,
            failureReason: nil,
            isThermallyThrottled: false
        )
        try layoutExpect(validatingProgress.entryPercentage == nil,
                         "validation must not reuse the completed write percentage")
        let validatingStatus = DictionaryManagerPresentation.reverseStatusText(
            nil,
            progress: validatingProgress
        )
        try layoutExpect(validatingStatus == "验证" && !validatingStatus.contains("100%"),
                         "validation status must not display a fake 100 percent")
        let validatingDetail = DictionaryManagerPresentation.reverseStatusDetail(
            nil,
            progress: validatingProgress
        )
        try layoutExpect(validatingDetail.contains("可取消的快速安全验证") &&
                         validatingDetail.contains("不显示伪造百分比"),
                         "validation detail must explain the bounded progress model")

        var englishUI = LanguagePreferences.productionDefault
        englishUI.uiLanguage = .english
        AppLocalization.configureAtLaunch(englishUI)
        let englishManager = DictionaryManagerWindowController(
            catalog: .empty(),
            catalogStore: catalogStore,
            importService: importService,
            indexCoordinator: indexCoordinator,
            removalCoordinator: removalCoordinator,
            resourceCenterController: resourceCenterController,
            reverseIndexCoordinator: ReverseIndexCoordinator(
                rootURL: root.appendingPathComponent("EnglishReverse", isDirectory: true)
            ),
            reverseLookupService: ReverseLookupService()
        )
        let englishTable = englishManager.window?.contentView.flatMap {
            allSubviews(of: $0).compactMap { $0 as? NSTableView }.first
        }
        try layoutExpect(englishManager.window?.title == "Dictionary Manager" &&
                         englishTable?.tableColumns.first?.title == "Dictionary",
                         "real Dictionary Manager window did not use English UI")
        AppLocalization.configureAtLaunch(.productionDefault)

        print("Dictionary manager C1 AppKit layout smoke: PASS")
    }
}
