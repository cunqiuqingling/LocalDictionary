import Foundation

/// User-facing presentation rules for the dictionary manager. This type owns
/// no Catalog state and performs no file, index, or query operation.
enum DictionaryManagerPresentation {
    enum Activity: Equatable, Sendable {
        case idle
        case cancellingIndex
        case removing
    }

    enum IndexAction: Equatable, Sendable {
        case start
        case retry
        case cancel
        case none
    }

    struct IndexActionPresentation: Equatable, Sendable {
        let action: IndexAction
        let title: String
        let toolTip: String
        let isEnabled: Bool
    }

    enum ErrorOperation: Sendable {
        case inspect
        case importDictionary
        case saveOrdering
        case restoreOrdering
        case saveEnabledState
        case removeDictionary
    }

    static let defaultWindowWidth: CGFloat = 1_280
    static let defaultWindowHeight: CGFloat = 520
    static let minimumWindowWidth: CGFloat = 900
    static let minimumWindowHeight: CGFloat = 400

    static let columnWidths: [String: CGFloat] = [
        "name": 230,
        "source": 112,
        "level": 78,
        "position": 58,
        "enabled": 60,
        "state": 128,
        "entries": 96,
        "indexSize": 92,
        "indexedAt": 160,
        "action": 150
    ]

    static var totalColumnWidth: CGFloat {
        columnWidths.values.reduce(0, +)
    }

    static func sourceText(_ source: DictionarySourceKind) -> String {
        switch source {
        case .legacyReference: return "旧配置词典"
        case .managedLocal: return "本地导入词典"
        case .externalReference: return "外部引用词典"
        case .openResource: return "开放词库"
        }
    }

    static func queryLevelText(_ level: DictionaryQueryLevel) -> String {
        switch level {
        case .preferred: return "首选"
        case .normal: return "普通"
        case .fallback: return "后备"
        }
    }

    static func statusText(for dictionary: DictionaryDescriptor,
                           activity: Activity = .idle) -> String {
        if activity == .removing { return "正在移除" }
        if activity == .cancellingIndex { return "正在取消" }
        if !dictionary.enabled { return "已停用" }
        switch dictionary.state {
        case .waitingForImport: return "等待导入"
        case .copying: return "正在复制"
        case .scanning: return "正在检查"
        case .pendingIndex: return "等待建立索引"
        case .indexing: return "正在建立索引"
        case .ready: return "可用"
        case .disabled: return "已停用"
        case .missingResources, .unavailable, .invalid, .corrupt:
            return "文件不可用"
        case .staleIndex: return "索引需要更新"
        case .importFailed: return "导入失败"
        case .failed: return "索引失败"
        }
    }

    static func statusDetail(for dictionary: DictionaryDescriptor,
                             activity: Activity = .idle) -> String {
        if activity == .removing {
            return "正在安全移除 App 托管的词典副本和索引；用户原始导入文件不会被修改。"
        }
        if activity == .cancellingIndex {
            return "正在安全停止，当前步骤完成后取消。取消后不会发布半成品索引。"
        }
        if !dictionary.enabled || dictionary.state == .disabled {
            return "该词典已停用，不参与本地查询；托管文件和已有索引仍会保留。"
        }
        switch dictionary.state {
        case .pendingIndex:
            return "词典已导入，需要建立索引后才能查询。"
        case .indexing:
            return "正在后台建立本地索引。当前显示为不确定进度，不代表伪造百分比。"
        case .ready:
            return "索引已完成，可参与本地查询。"
        case .failed:
            return "索引未完成，原始导入文件未被修改；可以使用“重试索引”再次尝试。"
        case .missingResources, .unavailable, .invalid, .corrupt:
            return "词典文件当前不可用，不会参与查询；请检查托管文件后重试或重新导入。"
        case .staleIndex:
            return "词典内容与现有索引不一致，当前不会参与查询。"
        case .importFailed:
            return "导入未完成，原始文件未被修改；请重新选择文件后再试。"
        case .waitingForImport:
            return "正在等待用户确认导入。"
        case .copying:
            return "正在安全复制词典文件；取消或失败不会发布半成品。"
        case .scanning:
            return "正在读取必要的词典元数据，不会展示完整词条正文。"
        case .disabled:
            return "该词典已停用。"
        }
    }

    static func indexAction(for dictionary: DictionaryDescriptor,
                            activity: Activity = .idle) -> IndexActionPresentation? {
        guard dictionary.sourceKind == .managedLocal ||
              dictionary.sourceKind == .openResource else { return nil }
        if activity == .removing {
            return IndexActionPresentation(
                action: .none,
                title: "正在移除",
                toolTip: "该词典正在安全移除，当前不能执行索引操作。",
                isEnabled: false
            )
        }
        if activity == .cancellingIndex {
            return IndexActionPresentation(
                action: .none,
                title: "正在取消",
                toolTip: "正在安全停止，当前步骤完成后取消。",
                isEnabled: false
            )
        }
        switch dictionary.state {
        case .pendingIndex:
            return IndexActionPresentation(
                action: .start,
                title: "建立索引",
                toolTip: "为该托管词典建立本地索引，不删除或修改源 MDX。",
                isEnabled: true
            )
        case .failed:
            return IndexActionPresentation(
                action: .retry,
                title: "重试索引",
                toolTip: "重新建立本地索引；原始导入文件不会被修改。",
                isEnabled: true
            )
        case .indexing:
            return IndexActionPresentation(
                action: .cancel,
                title: "取消索引",
                toolTip: "请求安全取消当前索引任务；当前步骤完成后停止。",
                isEnabled: true
            )
        case .ready:
            return IndexActionPresentation(
                action: .none,
                title: "索引已完成",
                toolTip: "该词典索引已完成，可参与本地查询。",
                isEnabled: false
            )
        default:
            return IndexActionPresentation(
                action: .none,
                title: "当前不可操作",
                toolTip: statusDetail(for: dictionary, activity: activity),
                isEnabled: false
            )
        }
    }

    static func errorMessage(for operation: ErrorOperation) -> String {
        switch operation {
        case .inspect:
            return "无法读取所选词典的必要信息。原始文件未被修改；请确认文件可读且格式受支持后重试。"
        case .importDictionary:
            return "未能安全复制词典。原始文件未被修改，也未发布半成品记录；请检查文件权限和可用磁盘空间后重试。"
        case .saveOrdering:
            return "未能保存新的词典顺序，原有顺序保持不变；请稍后重试。"
        case .restoreOrdering:
            return "未能恢复默认顺序，当前顺序保持不变；请稍后重试。"
        case .saveEnabledState:
            return "未能保存启用状态，原有设置保持不变；请稍后重试。"
        case .removeDictionary:
            return "未能安全移除词典。用户原始导入文件未受影响；请重新打开词典管理后重试。"
        }
    }

    static func safeIndexFailureMessage(_ rawMessage: String?) -> String? {
        guard let rawMessage, !rawMessage.isEmpty else { return nil }
        if rawMessage.contains("磁盘空间不足") {
            return "原因：可用磁盘空间不足。请释放空间后重试。"
        }
        if rawMessage.contains("MDX 文件已不存在") || rawMessage.contains("源文件已不存在") {
            return "原因：托管的词典文件已不存在。请重新导入该词典。"
        }
        if rawMessage.contains("MDX 文件不可读") || rawMessage.contains("源文件不可读") {
            return "原因：托管的词典文件当前不可读。请检查文件权限后重试。"
        }
        if rawMessage.contains("内容摘要不一致") || rawMessage.contains("内容发生变化") {
            return "原因：托管词典内容发生变化。为避免错误索引，请重新导入该词典。"
        }
        if rawMessage.contains("完整性检查") || rawMessage.contains("有效的 SQLite") ||
            rawMessage.contains("索引为空") || rawMessage.contains("索引版本") {
            return "原因：生成的索引未通过安全验证。请重试；若持续失败，该词典格式可能暂不受支持。"
        }
        return "索引未完成，未发布任何半成品。请重试；若问题持续，请重新导入该词典。"
    }
}
