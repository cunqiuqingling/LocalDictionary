import AppKit

final class AISettingsWindowController: NSWindowController, NSWindowDelegate {
    private let configurationStore: AIConfigurationStore
    private let keychain: AIKeychainStoring
    private let service: AIExplanationService
    private let onConfigurationChanged: () -> Void

    private let enabledButton = NSButton(checkboxWithTitle: "启用 AI 查询", target: nil, action: nil)
    private let providerPopup = NSPopUpButton()
    private let displayNameField = NSTextField()
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let thinkingButton = NSButton(checkboxWithTitle: "启用思考模式", target: nil, action: nil)
    private let automaticSentenceButton = NSButton(
        checkboxWithTitle: "自动解析完整英文句子", target: nil, action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let clearKeyButton = NSButton(title: "清除密钥", target: nil, action: nil)
    private let clearCacheButton = NSButton(title: "清除 AI 缓存", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private var operationTask: Task<Void, Never>?
    private var hasStoredKey = false

    init(configurationStore: AIConfigurationStore,
         keychain: AIKeychainStoring,
         service: AIExplanationService,
         onConfigurationChanged: @escaping () -> Void) {
        self.configurationStore = configurationStore
        self.keychain = keychain
        self.service = service
        self.onConfigurationChanged = onConfigurationChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 575),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: true)
        super.init(window: window)
        configureWindow(window)
    }

    required init?(coder: NSCoder) { nil }

    deinit { operationTask?.cancel() }

    func show() {
        loadConfiguration()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "AI 服务设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        AIProviderType.allCases.forEach { providerPopup.addItem(withTitle: $0.title) }
        providerPopup.target = self
        providerPopup.action = #selector(providerDidChange)
        keyField.placeholderString = "输入 API 密钥"
        keyField.setAccessibilityLabel("API 密钥")
        thinkingButton.toolTip = "智谱预设支持此字段；自定义接口不会发送该字段。"
        automaticSentenceButton.controlSize = .small

        let automaticSentenceHelp = NSTextField(wrappingLabelWithString:
            "启用后，选中的完整英文句子会自动发送到所配置的 AI 服务，用于翻译和语法分析。")
        automaticSentenceHelp.textColor = .secondaryLabelColor
        automaticSentenceHelp.font = .systemFont(ofSize: 11)
        let automaticSentenceStack = NSStackView(views: [automaticSentenceButton,
                                                          automaticSentenceHelp])
        automaticSentenceStack.orientation = .vertical
        automaticSentenceStack.alignment = .leading
        automaticSentenceStack.spacing = 3

        let form = NSGridView(views: [
            [label("服务类型"), providerPopup],
            [label("服务名称"), displayNameField],
            [label("Base URL"), baseURLField],
            [label("模型名称"), modelField],
            [label("API 密钥"), keyField],
            [label("思考模式"), thinkingButton]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.column(at: 1).width = 390
        form.rowSpacing = 10

        let privacy = NSTextField(wrappingLabelWithString:
            "AI 查询会将当前搜索词发送到所配置的第三方服务，本地词典内容和笔记不会上传。")
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 12)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail

        testButton.target = self
        testButton.action = #selector(testConnection)
        clearKeyButton.target = self
        clearKeyButton.action = #selector(clearKey)
        clearCacheButton.target = self
        clearCacheButton.action = #selector(clearCache)
        saveButton.target = self
        saveButton.action = #selector(saveConfiguration)
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let utilityButtons = NSStackView(views: [testButton, clearKeyButton, clearCacheButton])
        utilityButtons.orientation = .horizontal
        utilityButtons.spacing = 8
        let spacer = NSView()
        let commitButtons = NSStackView(views: [spacer, cancelButton, saveButton])
        commitButtons.orientation = .horizontal
        commitButtons.spacing = 8
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [enabledButton, automaticSentenceStack, form, privacy, statusLabel,
                                        utilityButtons, commitButtons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        privacy.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        automaticSentenceHelp.translatesAutoresizingMaskIntoConstraints = false
        commitButtons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            privacy.widthAnchor.constraint(equalToConstant: 510),
            automaticSentenceHelp.widthAnchor.constraint(equalToConstant: 510),
            statusLabel.widthAnchor.constraint(equalToConstant: 510),
            commitButtons.widthAnchor.constraint(equalToConstant: 510)
        ])
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.alignment = .right
        return field
    }

    private func loadConfiguration() {
        operationTask?.cancel()
        let configuration = configurationStore.load()
        enabledButton.state = configuration.enabled ? .on : .off
        selectProvider(configuration.providerType)
        displayNameField.stringValue = configuration.providerDisplayName
        baseURLField.stringValue = configuration.baseURL
        modelField.stringValue = configuration.model
        thinkingButton.state = configuration.thinkingEnabled ? .on : .off
        automaticSentenceButton.state = configurationStore.loadAutomaticSentenceAnalysisEnabled()
            ? .on : .off
        keyField.stringValue = ""
        keyField.placeholderString = "正在检查钥匙串…"
        statusLabel.stringValue = ""
        operationTask = Task { [weak self] in
            guard let self else { return }
            let stored = (try? await keychain.readKey(account: configuration.keychainAccount)) != nil
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.hasStoredKey = stored
                self.keyField.placeholderString = stored ? "已配置（输入新值才会替换）" : "输入 API 密钥"
                self.clearKeyButton.isEnabled = stored
            }
        }
    }

    @objc private func providerDidChange() {
        guard selectedProvider == .zhipu else {
            thinkingButton.isEnabled = false
            if displayNameField.stringValue == AIProviderConfiguration.zhipuPreset.providerDisplayName {
                displayNameField.stringValue = AIProviderType.openAICompatible.title
            }
            refreshStoredKeyState()
            return
        }
        let preset = AIProviderConfiguration.zhipuPreset
        displayNameField.stringValue = preset.providerDisplayName
        baseURLField.stringValue = preset.baseURL
        modelField.stringValue = preset.model
        thinkingButton.state = .off
        thinkingButton.isEnabled = true
        refreshStoredKeyState()
    }

    private var selectedProvider: AIProviderType {
        let index = max(0, providerPopup.indexOfSelectedItem)
        return AIProviderType.allCases[index]
    }

    private func selectProvider(_ type: AIProviderType) {
        if let index = AIProviderType.allCases.firstIndex(of: type) {
            providerPopup.selectItem(at: index)
        }
        thinkingButton.isEnabled = type == .zhipu
    }

    private func currentConfiguration() -> AIProviderConfiguration {
        AIProviderConfiguration(
            enabled: enabledButton.state == .on,
            providerType: selectedProvider,
            providerDisplayName: displayNameField.stringValue,
            baseURL: baseURLField.stringValue,
            model: modelField.stringValue,
            thinkingEnabled: thinkingButton.state == .on
        )
    }

    private func refreshStoredKeyState() {
        let configuration = currentConfiguration()
        keyField.stringValue = ""
        keyField.placeholderString = "正在检查钥匙串…"
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let stored = (try? await keychain.readKey(account: configuration.keychainAccount)) != nil
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.hasStoredKey = stored
                self.keyField.placeholderString = stored ? "已配置（输入新值才会替换）" : "输入 API 密钥"
                self.clearKeyButton.isEnabled = stored
            }
        }
    }

    @objc private func saveConfiguration() {
        let configuration = currentConfiguration()
        do { try configuration.validate() }
        catch { showStatus(error.localizedDescription, isError: true); return }
        setBusy(true)
        let replacement = keyField.stringValue
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await keychain.storeKey(replacement, account: configuration.keychainAccount)
                }
                await MainActor.run {
                    self.configurationStore.save(configuration)
                    self.configurationStore.saveAutomaticSentenceAnalysisEnabled(
                        self.automaticSentenceButton.state == .on
                    )
                    self.onConfigurationChanged()
                    self.setBusy(false)
                    self.window?.close()
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false)
                    self.showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @objc private func testConnection() {
        let configuration = currentConfiguration()
        do { try configuration.validate() }
        catch { showStatus(error.localizedDescription, isError: true); return }
        setBusy(true)
        showStatus("正在测试连接…", isError: false)
        let replacement = keyField.stringValue
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.testConnection(
                    configuration: configuration,
                    replacementKey: replacement.isEmpty ? nil : replacement
                )
                await MainActor.run {
                    self.setBusy(false)
                    self.showStatus("连接成功", isError: false)
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false)
                    self.showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @objc private func clearKey() {
        let configuration = currentConfiguration()
        setBusy(true)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await keychain.deleteKey(account: configuration.keychainAccount)
                await MainActor.run {
                    self.hasStoredKey = false
                    self.keyField.stringValue = ""
                    self.keyField.placeholderString = "输入 API 密钥"
                    self.setBusy(false)
                    self.showStatus("密钥已清除", isError: false)
                    self.onConfigurationChanged()
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false)
                    self.showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @objc private func clearCache() {
        setBusy(true)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.clearCache()
                await MainActor.run {
                    self.setBusy(false)
                    self.showStatus("AI 缓存已清除", isError: false)
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false)
                    self.showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @objc private func cancel() { window?.close() }

    private func setBusy(_ busy: Bool) {
        testButton.isEnabled = !busy
        clearKeyButton.isEnabled = !busy && hasStoredKey
        clearCacheButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        automaticSentenceButton.isEnabled = !busy
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }
}
