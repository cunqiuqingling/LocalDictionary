import Foundation

private enum SmokeError: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeError.failed(message) }
}

private func descriptor(
    state: DictionaryState,
    enabled: Bool = true,
    source: DictionarySourceKind = .managedLocal,
    level: DictionaryQueryLevel = .normal
) -> DictionaryDescriptor {
    var value = DictionaryDescriptor(
        dictionaryID: "00000000-0000-0000-0000-000000000001",
        displayName: "A deliberately long dictionary name for tooltip coverage",
        sourceKind: source,
        queryLevel: level,
        sortPosition: 1,
        enabled: enabled,
        state: state,
        indexMetadata: DictionaryIndexMetadata(
            schemaVersion: 1,
            entryCount: 12_345,
            indexFileSize: 1_048_576,
            sourceFileSize: 2_097_152,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceSHA256: String(repeating: "a", count: 64),
            indexedAt: Date(timeIntervalSince1970: 1_700_000_100)
        ),
        formatterIdentifier: DictionaryFormatterIdentifier.genericMDictV1,
        capabilities: .unknown,
        relativePaths: .empty,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    if source == .openResource {
        value.storageOwnership = .appManagedOpenResource
    }
    return value
}

@main
private enum DictionaryManagerUIStateSmoke {
    static func main() throws {
        try expect(DictionaryManagerPresentation.sourceText(.legacyReference) == "旧配置词典",
                   "legacy source wording")
        try expect(DictionaryManagerPresentation.sourceText(.managedLocal) == "本地导入词典",
                   "managed source wording")
        try expect(DictionaryManagerPresentation.sourceText(.openResource) == "开放词库",
                   "open source wording")
        try expect(DictionaryManagerPresentation.queryLevelText(.preferred) == "默认词典",
                   "preferred wording")
        try expect(DictionaryManagerPresentation.queryLevelText(.normal) == "本地导入",
                   "normal wording")
        try expect(DictionaryManagerPresentation.queryLevelText(.fallback) == "开放资源",
                   "fallback wording")

        let expectedStates: [(DictionaryState, String)] = [
            (.pendingIndex, "等待建立索引"),
            (.indexing, "正在建立索引"),
            (.ready, "可用"),
            (.failed, "索引失败"),
            (.unavailable, "文件不可用"),
            (.invalid, "文件不可用")
        ]
        for (state, expected) in expectedStates {
            try expect(DictionaryManagerPresentation.statusText(for: descriptor(state: state)) == expected,
                       "state wording for \(state.rawValue)")
        }
        try expect(DictionaryManagerPresentation.statusText(
            for: descriptor(state: .ready, enabled: false)
        ) == "已停用", "disabled must override ready state")
        let staleOpen = descriptor(
            state: .missingResources, enabled: false,
            source: .openResource, level: .fallback
        )
        try expect(DictionaryManagerPresentation.statusText(for: staleOpen) ==
                   "需要重新安装",
                   "stale managed open resource must not become a generic disabled/file state")
        try expect(DictionaryManagerPresentation.statusDetail(for: staleOpen)
            .contains("资源中心重新安装"),
                   "stale managed open resource must explain recovery")
        try expect(DictionaryManagerPresentation.statusText(
            for: descriptor(state: .indexing), activity: .cancellingIndex
        ) == "正在取消", "cancelling state")
        try expect(DictionaryManagerPresentation.statusText(
            for: descriptor(state: .ready), activity: .removing
        ) == "正在移除", "removing state")

        let pending = DictionaryManagerPresentation.indexAction(
            for: descriptor(state: .pendingIndex)
        )
        try expect(pending?.action == .start && pending?.title == "建立索引" && pending?.isEnabled == true,
                   "pending index action")
        let failed = DictionaryManagerPresentation.indexAction(
            for: descriptor(state: .failed)
        )
        try expect(failed?.action == .retry && failed?.title == "重试索引",
                   "failed index action")
        let indexing = DictionaryManagerPresentation.indexAction(
            for: descriptor(state: .indexing)
        )
        try expect(indexing?.action == .cancel && indexing?.title == "取消索引",
                   "indexing action")
        let cancelling = DictionaryManagerPresentation.indexAction(
            for: descriptor(state: .indexing), activity: .cancellingIndex
        )
        try expect(cancelling?.title == "正在取消" && cancelling?.isEnabled == false,
                   "cooperative cancellation presentation")
        let ready = DictionaryManagerPresentation.indexAction(
            for: descriptor(state: .ready)
        )
        try expect(ready?.title == "索引已完成" && ready?.isEnabled == false,
                   "ready action presentation")
        try expect(DictionaryManagerPresentation.indexAction(
            for: descriptor(state: .ready, source: .legacyReference)
        ) == nil, "legacy dictionary must not expose managed index action")
        let openResource = DictionaryManagerPresentation.indexAction(
            for: descriptor(state: .pendingIndex, source: .openResource, level: .fallback)
        )
        try expect(openResource?.action == .start,
                   "open resource must reuse managed sealed-index action")

        try expect(DictionaryManagerPresentation.totalColumnWidth + 40 <=
            DictionaryManagerPresentation.defaultWindowWidth,
            "default window must fit normal table columns")
        try expect((DictionaryManagerPresentation.columnWidths["forwardState"] ?? 0) >= 90,
                   "forward-state column width")
        try expect((DictionaryManagerPresentation.columnWidths["reverseState"] ?? 0) >= 145,
                   "reverse-state column width")
        try expect((DictionaryManagerPresentation.columnWidths["action"] ?? 0) >= 145,
                   "action column width")
        try expect(DictionaryManagerPresentation.minimumWindowWidth >= 900,
                   "minimum width must keep the reverse action visible")

        for operation in [
            DictionaryManagerPresentation.ErrorOperation.inspect,
            .importDictionary, .saveOrdering, .restoreOrdering,
            .saveEnabledState, .removeDictionary
        ] {
            let message = DictionaryManagerPresentation.errorMessage(for: operation)
            try expect(!message.isEmpty, "error message must not be empty")
            for forbidden in ["SQLite", "Catalog", "Schema", "SHA-256", "UUID", "NSError"] {
                try expect(!message.localizedCaseInsensitiveContains(forbidden),
                           "user-facing error leaked technical detail: \(forbidden)")
            }
        }
        let safeIndexFailure = DictionaryManagerPresentation.safeIndexFailureMessage(
            "builder failed at SENSITIVE_PATH_TOKEN with SQLite exception"
        ) ?? ""
        try expect(!safeIndexFailure.contains("SENSITIVE_PATH_TOKEN") &&
                   !safeIndexFailure.localizedCaseInsensitiveContains("SQLite"),
                   "index failure detail must not leak raw implementation text")

        print("Dictionary manager C1 UI/state smoke: PASS")
    }
}
