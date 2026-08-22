import AppKit

@MainActor
final class AISettingsWindowController: NSWindowController, NSWindowDelegate,
                                        NSTextFieldDelegate {
    private let profileManager: AIProviderProfileManager
    private let service: AIExplanationService
    private let onConfigurationChanged: () -> Void

    private let profileSelector = NSPopUpButton()
    private let addButton = NSButton(title: "添加服务…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除服务", target: nil, action: nil)
    private let profileStatusLabel = NSTextField(labelWithString: "状态：—")
    private let priorityPopup = NSPopUpButton()
    private let enabledButton = NSButton(checkboxWithTitle: "启用此服务", target: nil, action: nil)
    private let providerTypePopup = NSPopUpButton()
    private let displayNameField = NSTextField()
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyStatusLabel = NSTextField(labelWithString: "密钥状态：未配置")
    private let providerOptionsStack = NSStackView()
    private let zhipuThinkingButton = NSButton(
        checkboxWithTitle: "思考模式（结构化请求中固定关闭）", target: nil, action: nil
    )
    private let providerOptionsLabel = NSTextField(labelWithString: "无额外选项")
    private let automaticFallbackButton = NSButton(
        checkboxWithTitle: "自动切换备用服务", target: nil, action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let clearKeyButton = NSButton(title: "清除密钥", target: nil, action: nil)
    private let clearCacheButton = NSButton(title: "清除 AI 缓存", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    private var session: AIProviderSettingsSession?
    private var operationTask: Task<Void, Never>?
    private var connectionTestTask: Task<Void, Never>?
    private var suppressControlActions = false
    private var connectionTestGate = AIConnectionTestGate()

    private var isTestingConnection: Bool { connectionTestGate.isRunning }

    init(profileManager: AIProviderProfileManager,
         service: AIExplanationService,
         onConfigurationChanged: @escaping () -> Void) {
        self.profileManager = profileManager
        self.service = service
        self.onConfigurationChanged = onConfigurationChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: true)
        super.init(window: window)
        configureWindow(window)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        operationTask?.cancel()
        connectionTestTask?.cancel()
    }

    func show() {
        discardEditingSession()
        setBusy(true)
        showStatus("正在读取服务配置…", isError: false)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                let snapshot = try await profileManager.snapshot()
                guard !Task.isCancelled else { return }
                self.session = AIProviderSettingsSession(snapshot: snapshot)
                self.automaticFallbackButton.state = snapshot.catalog.automaticFallbackEnabled
                    ? .on : .off
                self.rebuildProfileSelector()
                self.loadSelectedDraftAtomically()
                self.setBusy(false)
                self.showStatus("", isError: false)
            } catch {
                self.setBusy(false)
                self.showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        discardEditingSession()
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = t("AI 服务设置", "AI Service Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 680, height: 590)
        window.maxSize = NSSize(width: 820, height: 700)

        profileSelector.target = self
        profileSelector.action = #selector(profileSelectionChanged)
        profileSelector.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addButton.target = self
        addButton.action = #selector(showAddMenu(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteProvider)
        addButton.title = t("添加服务…", "Add Service…")
        deleteButton.title = t("删除服务", "Delete Service")
        enabledButton.title = t("启用此服务", "Enable This Service")
        automaticFallbackButton.title = t("自动切换备用服务", "Automatically Use Backup Service")
        testButton.title = t("测试连接", "Test Connection")
        clearKeyButton.title = t("清除密钥", "Clear Key")
        clearCacheButton.title = t("清除 AI 缓存", "Clear AI Cache")
        saveButton.title = t("保存", "Save")
        let selectorRow = NSStackView(views: [label(t("当前服务：", "Current Service:")), profileSelector,
                                               addButton, deleteButton])
        selectorRow.orientation = .horizontal
        selectorRow.alignment = .centerY
        selectorRow.spacing = 8

        priorityPopup.addItems(withTitles: ["主服务", "备用服务"])
        priorityPopup.target = self
        priorityPopup.action = #selector(priorityChanged)
        profileStatusLabel.textColor = .secondaryLabelColor
        profileStatusLabel.lineBreakMode = .byTruncatingTail
        let priorityRow = NSStackView(views: [profileStatusLabel, flexibleSpacer(),
                                              label(t("优先级：", "Priority:")), priorityPopup])
        priorityRow.orientation = .horizontal
        priorityRow.alignment = .centerY
        priorityRow.spacing = 6

        AIProviderType.allCases.forEach { providerTypePopup.addItem(withTitle: $0.title) }
        providerTypePopup.target = self
        providerTypePopup.action = #selector(editorValueChanged)
        enabledButton.target = self
        enabledButton.action = #selector(editorValueChanged)
        for field in [displayNameField, baseURLField, modelField, keyField] {
            field.delegate = self
            field.cell?.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
        }
        displayNameField.placeholderString = "服务名称"
        baseURLField.placeholderString = "https://example.com/v1"
        modelField.placeholderString = "模型 ID"
        keyField.placeholderString = "输入新密钥以替换现有密钥"
        keyField.setAccessibilityLabel("API 密钥")
        keyStatusLabel.textColor = .secondaryLabelColor
        keyStatusLabel.font = .systemFont(ofSize: 11)

        let keyStack = NSStackView(views: [keyField, keyStatusLabel])
        keyStack.orientation = .vertical
        keyStack.alignment = .leading
        keyStack.spacing = 3
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 480).isActive = true

        providerOptionsStack.orientation = .vertical
        providerOptionsStack.alignment = .leading
        providerOptionsStack.spacing = 3
        zhipuThinkingButton.state = .off
        zhipuThinkingButton.isEnabled = false
        zhipuThinkingButton.controlSize = .small
        providerOptionsLabel.textColor = .secondaryLabelColor
        providerOptionsLabel.font = .systemFont(ofSize: 11)

        let form = NSGridView(views: [
            [label(""), enabledButton],
            [label(t("服务类型", "Service Type")), providerTypePopup],
            [label(t("服务名称", "Service Name")), displayNameField],
            [label("Base URL"), baseURLField],
            [label(t("模型名称", "Model")), modelField],
            [label(t("API 密钥", "API Key")), keyStack],
            [label(t("特有选项", "Provider Options")), providerOptionsStack]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.column(at: 1).width = 480
        form.rowSpacing = 9

        automaticFallbackButton.controlSize = .small
        let automaticSentenceHelp = NSTextField(wrappingLabelWithString: t(
            "AI 不会自动发送单词或句子；只有点击对应的 AI 按钮后，当前内容才会发送到所配置的服务。",
            "Words and sentences are never sent automatically. Content is sent only after you " +
                "click the corresponding AI button."
        ))
        automaticSentenceHelp.textColor = .secondaryLabelColor
        automaticSentenceHelp.font = .systemFont(ofSize: 11)
        automaticSentenceHelp.maximumNumberOfLines = 2

        let privacy = NSTextField(wrappingLabelWithString: t(
            "AI 查询只发送当前搜索词或句子；本地词典内容、笔记、文件路径和查询历史不会上传。",
            "AI requests send only the current query or sentence. Local dictionaries, notes, " +
                "file paths, and query history are not uploaded."
        ))
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 11)
        privacy.maximumNumberOfLines = 2

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isSelectable = true
        statusLabel.isEditable = false
        statusLabel.drawsBackground = false
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progressIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true

        testButton.target = self
        testButton.action = #selector(testConnection)
        clearKeyButton.target = self
        clearKeyButton.action = #selector(clearKey)
        clearCacheButton.target = self
        clearCacheButton.action = #selector(clearCache)
        let utilityRow = NSStackView(views: [testButton, progressIndicator,
                                             clearKeyButton, clearCacheButton])
        utilityRow.orientation = .horizontal
        utilityRow.alignment = .centerY
        utilityRow.spacing = 8

        saveButton.target = self
        saveButton.action = #selector(saveConfiguration)
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [utilityRow, flexibleSpacer(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [selectorRow, priorityRow, separator, form,
                                        automaticFallbackButton,
                                        automaticSentenceHelp, privacy, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [selectorRow, priorityRow, separator, automaticSentenceHelp,
                     privacy, statusLabel, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            selectorRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            priorityRow.widthAnchor.constraint(equalTo: selectorRow.widthAnchor),
            separator.widthAnchor.constraint(equalTo: selectorRow.widthAnchor),
            automaticSentenceHelp.widthAnchor.constraint(equalTo: selectorRow.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: selectorRow.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: selectorRow.widthAnchor),
            footer.widthAnchor.constraint(equalTo: selectorRow.widthAnchor)
        ])
    }

    @objc private func profileSelectionChanged() {
        guard !suppressControlActions else { return }
        syncEditorIntoSelectedDraft()
        guard let id = representedProviderID(of: profileSelector.selectedItem),
              session?.select(id) == true else {
            showStatus("无法切换到所选服务。", isError: true)
            return
        }
        loadSelectedDraftAtomically()
    }

    @objc private func editorValueChanged() {
        guard !suppressControlActions else { return }
        syncEditorIntoSelectedDraft()
        refreshSelectedProfileMenuTitle()
        refreshProfileSummary()
        refreshProviderOptions()
    }

    @objc private func priorityChanged() {
        guard !suppressControlActions,
              let id = session?.selectedProviderID else { return }
        syncEditorIntoSelectedDraft()
        if priorityPopup.indexOfSelectedItem == 0 { session?.setAsPrimary(id) }
        else { session?.setAsBackup(id) }
        rebuildProfileSelector()
        loadSelectedDraftAtomically()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !suppressControlActions else { return }
        if notification.object as AnyObject === displayNameField {
            let cleaned = AIConfigurationInput.cleanSingleLine(displayNameField.stringValue)
            if cleaned.count > 48 {
                suppressControlActions = true
                displayNameField.stringValue = String(cleaned.prefix(48))
                suppressControlActions = false
                showStatus("服务名称过长", isError: true)
            } else if cleaned != displayNameField.stringValue {
                displayNameField.stringValue = cleaned
            }
        }
        syncEditorIntoSelectedDraft()
        refreshSelectedProfileMenuTitle()
        refreshProfileSummary()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) ||
            commandSelector == #selector(NSResponder.insertTab(_:)) {
            NSSound.beep()
            return true
        }
        return false
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("Google Gemini", #selector(addGoogle)),
                                ("智谱 AI", #selector(addZhipu)),
                                ("自定义 OpenAI 兼容服务", #selector(addCustom))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func addGoogle() { addProfile(.googlePreset) }
    @objc private func addZhipu() { addProfile(.zhipuPreset) }
    @objc private func addCustom() {
        addProfile(AIProviderConfiguration(enabled: false,
                                           providerType: .openAICompatible,
                                           providerDisplayName: "自定义 AI 服务",
                                           baseURL: "https://example.com/v1",
                                           model: "model-id"))
    }

    private func addProfile(_ template: AIProviderConfiguration) {
        syncEditorIntoSelectedDraft()
        _ = session?.add(template)
        rebuildProfileSelector()
        loadSelectedDraftAtomically()
    }

    @objc private func deleteProvider() {
        guard let profile = session?.selectedDraft,
              session?.profilesInPriorityOrder.count ?? 0 > 1,
              let window else { return }
        let alert = NSAlert()
        alert.messageText = "删除“\(profile.providerDisplayName)”？"
        alert.informativeText = "默认仅删除服务配置，钥匙串密钥会继续保留。"
        alert.addButton(withTitle: "删除配置，保留密钥")
        alert.addButton(withTitle: "同时删除密钥")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response != .alertThirdButtonReturn else { return }
            let deleteKey = response == .alertSecondButtonReturn
            guard self.session?.remove(profile.providerID, deleteKey: deleteKey) == true else {
                self.showStatus("至少需要保留一个 AI 服务。", isError: true)
                return
            }
            self.rebuildProfileSelector()
            self.loadSelectedDraftAtomically()
        }
    }

    @objc private func testConnection() {
        guard connectionTestGate.begin() else { return }
        syncEditorIntoSelectedDraft()
        guard let profile = session?.selectedDraft,
              let providerID = session?.selectedProviderID else {
            connectionTestGate.finish()
            showStatus("连接失败：没有可测试的服务。", isError: true)
            return
        }
        do { _ = try profile.normalizedForSave() }
        catch {
            connectionTestGate.finish()
            showStatus("连接失败：\(error.localizedDescription)", isError: true)
            return
        }
        let replacementKey = session?.pendingAPIKey(for: providerID)
        setTesting(true)
        showStatus("正在验证传输、模型与响应兼容性…", isError: false)
        connectionTestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await service.testCompatibility(
                    configuration: profile, replacementKey: replacementKey
                )
                guard !Task.isCancelled else { return }
                self.connectionTestTask = nil
                self.finishTesting()
                self.showStatus(report.summary, isError: !report.hasRecommendedEnglish)
            } catch {
                guard !Task.isCancelled else { return }
                self.connectionTestTask = nil
                self.finishTesting()
                self.showStatus("兼容性测试失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    @objc private func clearKey() {
        guard let id = session?.selectedProviderID else { return }
        session?.markKeyForDeletion(id)
        suppressControlActions = true
        keyField.stringValue = ""
        suppressControlActions = false
        refreshProfileSummary()
        showStatus("保存后将清除此服务的密钥。", isError: false)
    }

    @objc private func clearCache() {
        guard operationTask == nil else { return }
        setBusy(true)
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                try await service.clearCache()
                self.setBusy(false)
                self.showStatus("AI 缓存已清除", isError: false)
            } catch {
                self.setBusy(false)
                self.showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    @objc private func saveConfiguration() {
        syncEditorIntoSelectedDraft()
        session?.automaticFallbackEnabled = automaticFallbackButton.state == .on
        session?.automaticSentenceAnalysisEnabled = false
        let proposed: AIProviderCatalog
        do {
            guard let value = try session?.catalogForSaving() else {
                throw AIConfigurationError.emptyProviderList
            }
            proposed = value
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return
        }
        let replacements = session?.nonemptyReplacementKeys ?? [:]
        let deletions = session?.keyDeletionIDs ?? []
        setBusy(true)
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                _ = try await profileManager.save(catalog: proposed,
                                                  replacementKeys: replacements,
                                                  deletingKeys: deletions)
                guard !Task.isCancelled else { return }
                self.onConfigurationChanged()
                self.setBusy(false)
                self.window?.close()
            } catch {
                self.setBusy(false)
                self.showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    private func syncEditorIntoSelectedDraft() {
        guard !suppressControlActions,
              var profile = session?.selectedDraft,
              let providerID = session?.selectedProviderID else { return }
        let typeIndex = max(0, providerTypePopup.indexOfSelectedItem)
        profile.providerType = AIProviderType.allCases[typeIndex]
        profile.enabled = enabledButton.state == .on
        profile.providerDisplayName = AIConfigurationInput.cleanSingleLine(displayNameField.stringValue)
        profile.baseURL = baseURLField.stringValue
        profile.model = modelField.stringValue
        session?.updateDraft(profile)
        session?.setPendingAPIKey(keyField.stringValue, for: providerID)
    }

    private func loadSelectedDraftAtomically() {
        guard let profile = session?.selectedDraft else { return }
        suppressControlActions = true
        if let index = AIProviderType.allCases.firstIndex(of: profile.providerType) {
            providerTypePopup.selectItem(at: index)
        }
        enabledButton.state = profile.enabled ? .on : .off
        displayNameField.stringValue = profile.providerDisplayName
        baseURLField.stringValue = profile.baseURL
        modelField.stringValue = profile.model
        keyField.stringValue = session?.pendingAPIKey(for: profile.providerID) ?? ""
        priorityPopup.selectItem(at: session?.isPrimary(profile.providerID) == true ? 0 : 1)
        suppressControlActions = false
        refreshProviderOptions()
        refreshProfileSummary()
        deleteButton.isEnabled = (session?.profilesInPriorityOrder.count ?? 0) > 1
    }

    private func rebuildProfileSelector() {
        guard let session else { return }
        suppressControlActions = true
        profileSelector.removeAllItems()
        for profile in session.profilesInPriorityOrder {
            let item = NSMenuItem(title: profileMenuTitle(profile), action: nil, keyEquivalent: "")
            item.representedObject = profile.providerID.uuidString
            item.toolTip = profile.normalizedBaseURL
            profileSelector.menu?.addItem(item)
        }
        if let selectedID = session.selectedProviderID,
           let index = session.orderedProviderIDs.firstIndex(of: selectedID) {
            profileSelector.selectItem(at: index)
        }
        suppressControlActions = false
    }

    private func refreshSelectedProfileMenuTitle() {
        guard let profile = session?.selectedDraft else { return }
        profileSelector.selectedItem?.title = profileMenuTitle(profile)
        profileSelector.selectedItem?.toolTip = profile.normalizedBaseURL
    }

    private func profileMenuTitle(_ profile: AIProviderConfiguration) -> String {
        let enabled = profile.enabled ? "已启用" : "已停用"
        let keyConfigured: Bool
        switch session?.keyState(for: profile.providerID) {
        case .configured, .pendingReplacement: keyConfigured = true
        default: keyConfigured = false
        }
        return "\(profile.providerDisplayName) · \(enabled) · \(keyConfigured ? "已配置" : "未配置")"
    }

    private func refreshProfileSummary() {
        guard let profile = session?.selectedDraft else {
            profileStatusLabel.stringValue = "状态：—"
            return
        }
        let enabled = profile.enabled ? "已启用" : "已停用"
        let keyText: String
        switch session?.keyState(for: profile.providerID) {
        case .configured: keyText = "已配置"
        case .pendingReplacement: keyText = "待替换"
        case .pendingDeletion: keyText = "待清除"
        default: keyText = "未配置"
        }
        profileStatusLabel.stringValue = "状态：\(enabled) · 密钥\(keyText)"
        keyStatusLabel.stringValue = "密钥状态：\(keyText)"
        keyField.placeholderString = keyText == "已配置"
            ? "输入新密钥以替换现有密钥" : "输入 API 密钥"
        clearKeyButton.isEnabled = keyText != "未配置" && !isTestingConnection
        refreshSelectedProfileMenuTitle()
    }

    private func refreshProviderOptions() {
        providerOptionsStack.arrangedSubviews.forEach {
            providerOptionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if session?.selectedDraft?.providerType == .zhipu {
            zhipuThinkingButton.state = .off
            providerOptionsStack.addArrangedSubview(zhipuThinkingButton)
        } else {
            providerOptionsStack.addArrangedSubview(providerOptionsLabel)
        }
    }

    private func representedProviderID(of item: NSMenuItem?) -> UUID? {
        guard let value = item?.representedObject as? String else { return nil }
        return UUID(uuidString: value)
    }

    private func setTesting(_ testing: Bool) {
        testButton.isEnabled = !testing
        testButton.title = testing ? t("测试中…", "Testing…") : t("测试连接", "Test Connection")
        if testing { progressIndicator.startAnimation(nil) }
        else { progressIndicator.stopAnimation(nil) }
        profileSelector.isEnabled = !testing
        addButton.isEnabled = !testing
        deleteButton.isEnabled = !testing && (session?.profilesInPriorityOrder.count ?? 0) > 1
        providerTypePopup.isEnabled = !testing
        enabledButton.isEnabled = !testing
        displayNameField.isEnabled = !testing
        baseURLField.isEnabled = !testing
        modelField.isEnabled = !testing
        keyField.isEnabled = !testing
        priorityPopup.isEnabled = !testing
        saveButton.isEnabled = !testing
        clearKeyButton.isEnabled = !testing
        if !testing { refreshProfileSummary() }
    }

    private func finishTesting() {
        connectionTestGate.finish()
        setTesting(false)
    }

    private func setBusy(_ busy: Bool) {
        profileSelector.isEnabled = !busy
        addButton.isEnabled = !busy
        deleteButton.isEnabled = !busy && (session?.profilesInPriorityOrder.count ?? 0) > 1
        priorityPopup.isEnabled = !busy
        providerTypePopup.isEnabled = !busy
        enabledButton.isEnabled = !busy
        displayNameField.isEnabled = !busy
        baseURLField.isEnabled = !busy
        modelField.isEnabled = !busy
        keyField.isEnabled = !busy
        automaticFallbackButton.isEnabled = !busy
        testButton.isEnabled = !busy && !isTestingConnection
        clearKeyButton.isEnabled = !busy
        clearCacheButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        if !busy { refreshProfileSummary() }
    }

    private func discardEditingSession() {
        operationTask?.cancel()
        operationTask = nil
        connectionTestTask?.cancel()
        connectionTestTask = nil
        connectionTestGate.finish()
        progressIndicator.stopAnimation(nil)
        testButton.title = t("测试连接", "Test Connection")
        session = nil
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.alignment = .right
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func t(_ chinese: String, _ english: String) -> String {
        AppLocalization.text(chinese, english)
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }
}

@MainActor
final class LanguageSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: LanguagePreferencesStore
    private let nativePopup = NSPopUpButton()
    private let learningPopup = NSPopUpButton()
    private let uiPopup = NSPopUpButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(store: LanguagePreferencesStore = .shared) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        super.init(window: window)
        configureWindow(window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        let preferences = store.load()
        select(preferences.nativeLanguage, in: nativePopup)
        select(preferences.learningLanguage, in: learningPopup)
        uiPopup.selectItem(at: uiIndex(preferences.uiLanguage))
        updatePairStatus(preferences)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = AppLocalization.text("语言设置", "Language Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 520, height: 330)

        addSupportedLanguages(to: nativePopup)
        nativePopup.isEnabled = true
        nativePopup.setAccessibilityIdentifier("language-settings-native")
        nativePopup.toolTip = AppLocalization.text(
            "选择你最容易理解说明和译文的语言。当前版本提供简体中文和 English。",
            "Choose the language you understand best. This release provides Simplified Chinese and English."
        )

        addSupportedLanguages(to: learningPopup)
        learningPopup.isEnabled = true
        learningPopup.setAccessibilityIdentifier("language-settings-learning")
        learningPopup.toolTip = AppLocalization.text(
            "选择要学习和进行语法分析的语言；不能与母语相同。",
            "Choose the language to study and analyze; it must differ from the native language."
        )

        uiPopup.addItems(withTitles: [
            AppLocalization.text("跟随母语", "Follow Native Language"),
            AppLocalization.languageName(.simplifiedChinese),
            AppLocalization.languageName(.english)
        ])
        uiPopup.setAccessibilityIdentifier("language-settings-ui")

        let form = NSGridView(views: [
            [label(AppLocalization.text("母语", "Native Language")), nativePopup],
            [label(AppLocalization.text("学习语言", "Learning Language")), learningPopup],
            [label(AppLocalization.text("界面语言", "UI Language")), uiPopup]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.rowSpacing = 14

        let explanation = NSTextField(wrappingLabelWithString: AppLocalization.text(
            "母语与学习语言会立即决定 Apple 离线翻译方向和 AI 学习对象。界面语言可以独立覆盖，并在重新打开应用后生效。",
            "Native and Learning languages immediately control Apple offline translation direction and the AI study object. UI language can be overridden and applies after reopening the app."
        ))
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setAccessibilityIdentifier("language-settings-status")

        let save = NSButton(
            title: AppLocalization.text("保存", "Save"),
            target: self, action: #selector(savePreferences)
        )
        save.keyEquivalent = "\r"
        save.toolTip = save.title
        save.setAccessibilityIdentifier("language-settings-save")
        let cancel = NSButton(
            title: AppLocalization.text("取消", "Cancel"),
            target: self, action: #selector(cancel)
        )
        cancel.keyEquivalent = "\u{1b}"
        cancel.toolTip = cancel.title
        let footer = NSStackView(views: [flexibleSpacer(), cancel, save])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [form, explanation, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        explanation.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56),
            statusLabel.widthAnchor.constraint(equalTo: explanation.widthAnchor),
            footer.widthAnchor.constraint(equalTo: explanation.widthAnchor)
        ])
    }

    @objc private func savePreferences() {
        let ui: UILanguagePreference
        switch uiPopup.indexOfSelectedItem {
        case 1: ui = .simplifiedChinese
        case 2: ui = .english
        default: ui = .followNative
        }
        guard let native = selectedLanguage(in: nativePopup),
              let learning = selectedLanguage(in: learningPopup) else {
            statusLabel.stringValue = AppLocalization.text(
                "请选择母语和学习语言。", "Choose both Native and Learning languages."
            )
            return
        }
        guard native != learning else {
            statusLabel.stringValue = AppLocalization.text(
                "母语和学习语言不能相同。", "Native and Learning languages must differ."
            )
            return
        }
        let value = LanguagePreferences(
            nativeLanguage: native, learningLanguage: learning, uiLanguage: ui
        )
        if store.save(value) {
            statusLabel.stringValue = AppLocalization.text(
                "已保存；Apple 离线翻译方向已更新。重新打开应用后界面语言生效。",
                "Saved; Apple offline translation directions are updated. Reopen the app to apply the UI language."
            )
        } else {
            statusLabel.stringValue = AppLocalization.text(
                "语言设置未能保存，原设置保持不变。",
                "Language settings could not be saved; the previous settings remain unchanged."
            )
        }
    }

    @objc private func cancel() { close() }

    private func addSupportedLanguages(to popup: NSPopUpButton) {
        for language in [LanguageIdentifier.simplifiedChinese, .english] {
            popup.addItem(withTitle: AppLocalization.languageName(language))
            popup.lastItem?.representedObject = language.rawValue
        }
    }

    private func selectedLanguage(in popup: NSPopUpButton) -> LanguageIdentifier? {
        guard let raw = popup.selectedItem?.representedObject as? String else { return nil }
        return LanguageIdentifier(rawValue: raw)
    }

    private func select(_ language: LanguageIdentifier, in popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == language.rawValue
        }) {
            popup.select(item)
        }
    }

    private func updatePairStatus(_ preferences: LanguagePreferences) {
        let native = AppLocalization.languageName(preferences.nativeLanguage)
        let learning = AppLocalization.languageName(preferences.learningLanguage)
        statusLabel.stringValue = AppLocalization.text(
            "当前 Apple 离线翻译语言对：\(native) ⇄ \(learning)。",
            "Current Apple offline translation pair: \(native) ⇄ \(learning)."
        )
    }

    private func uiIndex(_ value: UILanguagePreference) -> Int {
        switch value {
        case .followNative: return 0
        case .simplifiedChinese: return 1
        case .english: return 2
        }
    }


    private func label(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.alignment = .right
        return field
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}
