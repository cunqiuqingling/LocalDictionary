import AppKit
import Foundation

private enum SmokeFailure: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.failed(message) }
}

private func syntheticInlineSnapshot(_ text: String, kind: InlineLookupSelectionKind,
                                     pageID: UUID, blockID: UUID = UUID())
    -> InlineSelectionSnapshot {
    let length = text.utf16.count
    let normalized = InlineSelectionSnapshotFactory.normalizedIdentity(text, kind: kind) ?? text
    return InlineSelectionSnapshot(
        pageGenerationID: pageID,
        selectedRange: NSRange(location: 0, length: length),
        selectedText: text,
        normalizedText: normalized,
        containingParagraphRange: NSRange(location: 0, length: length),
        anchor: InlineLookupAnchor(
            blockID: blockID,
            selectionUTF16RangeInBlock: NSRange(location: 0, length: length)
        ),
        selectionKind: kind,
        contextBefore: "",
        contextAfter: "",
        currentEntryID: "test"
    )
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            var headers = ["Content-Type": "application/json"]
            headers.merge(Self.responseHeaders) { _, new in new }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class StubKeychain: AIKeychainStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    var failWrites = false
    var failReads = false
    private(set) var readCounts: [String: Int] = [:]
    init(_ value: String?) {
        if let value { values[AIProviderConfiguration.zhipuPreset.keychainAccount] = value }
    }
    init(values: [String: String]) { self.values = values }
    func readKey(account: String) async throws -> String? {
        readCounts[account, default: 0] += 1
        if failReads { throw AIKeychainError.accessDenied }
        return values[account]
    }
    func storeKey(_ key: String, account: String) async throws {
        if failWrites { throw AIKeychainError.operationFailed }
        values[account] = key
    }
    func deleteKey(account: String) async throws { values.removeValue(forKey: account) }
    func listAccounts() async throws -> [String] { Array(values.keys).sorted() }
}

private final class MemoryDefaults: AIConfigurationPersisting, LanguagePreferencesPersisting {
    var values: [String: Any] = [:]
    var rejectWrites = false

    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectWrites else { return }
        values[defaultName] = value
    }
    func removeObject(forKey defaultName: String) {
        guard !rejectWrites else { return }
        values.removeValue(forKey: defaultName)
    }
}

private final class StubClient: AIProviderClient {
    var calls = 0
    var sentenceCalls = 0
    var translationCalls = 0
    var result: Result<AIExplanation, Error>
    var sentenceResult: Result<AISentenceAnalysis, Error> = .failure(AIClientError.offline)
    var translationResult: Result<AITextTranslation, Error> = .failure(AIClientError.offline)
    var resultsByProvider: [UUID: Result<AIExplanation, Error>] = [:]
    var sentenceResultsByProvider: [UUID: Result<AISentenceAnalysis, Error>] = [:]
    var requestedProviderIDs: [UUID] = []
    var sentenceInputs: [String] = []
    var testedProviderIDs: [UUID] = []
    var testedConfigurations: [AIProviderConfiguration] = []
    var sentenceConfigurations: [AIProviderConfiguration] = []
    var connectionResult: Result<Void, Error> = .success(())
    var inlineWordQuickResult = InlineWordQuickAIResult(
        partOfSpeech: "noun", definitionsZH: ["提示"]
    )
    var inlineSentenceQuickResult = InlineSentenceQuickAIResult(translation: "自然翻译。")
    var inlineWordQuickCalls = 0
    var inlineSentenceQuickCalls = 0
    var inlineWordExpansionCalls = 0
    var inlineSentenceExpansionCalls = 0
    init(result: Result<AIExplanation, Error>) { self.result = result }
    func explain(query: String, domain: String,
                 configuration: AIProviderConfiguration, apiKey: String) async throws -> AIExplanation {
        calls += 1
        requestedProviderIDs.append(configuration.providerID)
        return try (resultsByProvider[configuration.providerID] ?? result).get()
    }
    func analyzeSentence(_ sentence: String,
                         configuration: AIProviderConfiguration,
                         apiKey: String) async throws -> AISentenceAnalysis {
        sentenceCalls += 1
        requestedProviderIDs.append(configuration.providerID)
        sentenceInputs.append(sentence)
        sentenceConfigurations.append(configuration)
        return try (sentenceResultsByProvider[configuration.providerID] ?? sentenceResult).get()
    }
    func translateText(_ text: String,
                       configuration: AIProviderConfiguration,
                       apiKey: String) async throws -> AITextTranslation {
        translationCalls += 1
        requestedProviderIDs.append(configuration.providerID)
        return try translationResult.get()
    }
    func testConnection(configuration: AIProviderConfiguration, apiKey: String) async throws {
        testedProviderIDs.append(configuration.providerID)
        testedConfigurations.append(configuration)
        try connectionResult.get()
    }
    func inlineWordQuick(_ query: String, configuration: AIProviderConfiguration,
                         apiKey: String) async throws -> InlineWordQuickAIResult {
        inlineWordQuickCalls += 1
        requestedProviderIDs.append(configuration.providerID)
        return inlineWordQuickResult
    }
    func inlineSentenceQuick(_ sentence: String, configuration: AIProviderConfiguration,
                             apiKey: String) async throws -> InlineSentenceQuickAIResult {
        inlineSentenceQuickCalls += 1
        requestedProviderIDs.append(configuration.providerID)
        return inlineSentenceQuickResult
    }
    func inlineWordExpansion(_ query: String, configuration: AIProviderConfiguration,
                             apiKey: String) async throws -> AIExplanation {
        inlineWordExpansionCalls += 1
        requestedProviderIDs.append(configuration.providerID)
        return try result.get()
    }
    func inlineSentenceExpansion(_ sentence: String,
                                 configuration: AIProviderConfiguration,
                                 apiKey: String) async throws -> AISentenceAnalysis {
        inlineSentenceExpansionCalls += 1
        requestedProviderIDs.append(configuration.providerID)
        return try sentenceResult.get()
    }
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { throw SmokeFailure.failed("missing request body") }
    stream.open()
    defer { stream.close() }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        output.append(buffer, count: count)
    }
    return output
}

private let sample = AIExplanation(
    headword: "prompt",
    pronunciations: ["/prɒmpt/"],
    partsOfSpeech: [
        AIExplanationPartOfSpeech(partOfSpeech: "noun", senses: [
            AIExplanationSense(definitionEN: "A cue for action.",
                               definitionZH: "促使行动的提示。",
                               usageNoteZH: "常用于技术语境。",
                               examples: [AIExplanationExample(en: "Enter a prompt.",
                                                               zh: "输入一条提示。")],
                               collocations: ["system prompt"])
        ])
    ],
    domain: "technology",
    caution: ""
)

private let sampleSentenceText = "Although the results were statistically significant, they did not necessarily imply a clinically meaningful benefit."

private let sampleSentenceAnalysis = AISentenceAnalysis(
    sourceText: sampleSentenceText,
    translationZH: "尽管结果具有统计学显著性，但它们并不一定意味着具有临床意义的获益。",
    sentenceType: "complex sentence",
    coreStructure: AISentenceCoreStructure(
        subject: "they",
        predicate: "did not imply",
        objectOrComplement: "a clinically meaningful benefit",
        structureSummaryZH: "让步状语从句加主句"
    ),
    clauses: [
        AISentenceClause(text: "Although the results were statistically significant",
                         type: "subordinate", functionZH: "让步状语从句",
                         translationZH: "尽管结果具有统计学显著性"),
        AISentenceClause(text: "they did not necessarily imply a clinically meaningful benefit",
                         type: "main", functionZH: "主句",
                         translationZH: "它们并不一定意味着具有临床意义的获益")
    ],
    grammarPoints: [
        AISentenceGrammarPoint(fragment: "Although ...", grammarName: "让步状语从句",
                               explanationZH: "although 引出与主句结论相对的事实。",
                               pattern: "Although A, B.")
    ],
    collocations: [
        AISentenceCollocation(expression: "clinically meaningful",
                              meaningZH: "具有临床意义的", pattern: "clinically meaningful + noun",
                              exampleEN: "The change was clinically meaningful.",
                              exampleZH: "这一变化具有临床意义。")
    ],
    difficultExpressions: [
        AISentenceDifficultExpression(expression: "not necessarily",
                                      meaningZH: "不一定", usageZH: "用于弱化推断。")
    ],
    paraphraseEN: "The statistical result does not always mean that patients receive a meaningful benefit.",
    learningNoteZH: "注意区分统计学显著性与临床意义。"
)

private let sampleTextTranslation = AITextTranslation(
    sourceText: sampleSentenceText,
    translation: "尽管结果具有统计学显著性，但这并不必然代表有临床意义的获益。"
)

private func envelope(_ explanation: AIExplanation) throws -> Data {
    let content = String(data: try JSONEncoder().encode(explanation), encoding: .utf8)!
    return try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": content]]]
    ])
}

private func sentenceEnvelope(_ analysis: AISentenceAnalysis) throws -> Data {
    let content = String(data: try JSONEncoder().encode(analysis), encoding: .utf8)!
    return try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": content]]]
    ])
}

private func inlineEnvelope<T: Encodable>(_ value: T, outputTokens: Int = 24) throws -> Data {
    let content = String(data: try JSONEncoder().encode(value), encoding: .utf8)!
    return try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": content], "finish_reason": "stop"]],
        "usage": ["completion_tokens": outputTokens]
    ])
}

@main
private struct AIServiceSmoke {
    static func main() async throws {
        try testQueryIntentAndNormalization()
        try testConfigurationAndUserDefaults()
        try await testProviderProfilesAndMigration()
        try await testTransactionalProviderSave()
        try testProviderEditingSession()
        try await testCredentialSession()
        if ProcessInfo.processInfo.environment["LOCALDICTIONARY_SKIP_KEYCHAIN_SMOKE"] != "1" {
            try await testKeychain()
        }
        try await testClientAndErrors()
        try testCanonicalResponseFixtures()
        try await testProviderEnvelopeCompatibility()
        try await testProviderProductionCompatibilityFixtures()
        try await testVisibleContentNormalizerAndBoundedRetry()
        try await testConnectionAndProductionRequestShareTransportConfiguration()
        try await testInlineLookupRequestsAndCache()
        try await testInlineLocalLookupAndFormatting()
        try await testInlineSelectionSnapshotsAndAnchors()
        try await testCacheAndService()
        try await testProviderFallback()
        try await testProviderSwitchRetryAndScopedCacheClear()
        try await testSingleProviderConnectionSequence()
        try testTolerantWordExplanationSchema()
        try testEnglishWordChineseDefinitionPriority()
        try testChineseRecommendedEnglishSchemaAndRendering()
        try testFormatter()
        try testSafeCompatibilityMarkdownRendering()
        try await Task { @MainActor in try testLanguageSettingsWindow() }.value
        try testSentenceFormatterAndGenerationGate()
        try testRequestLifecycleAndUserMessages()
        try await testLocalSentenceGlossary()
        try testAINoteExport()
        try testSentenceNoteExport()
        try testInlineLookupNoteExport()
        print("AI service smoke: PASS")
    }

    private static func testQueryIntentAndNormalization() throws {
        try expect(QueryIntentClassifier.classify("prompt").intent == .word,
                   "single word intent")
        try expect(QueryIntentClassifier.classify("machine learning").intent == .phrase,
                   "short phrase intent")
        try expect(QueryIntentClassifier.classify("Industrial and Physical Pharmacy").intent == .phrase,
                   "terminology phrase remains a phrase")
        try expect(QueryIntentClassifier.classify("time, is, she").intent == .sentence &&
                   QueryIntentClassifier.classify("你说，书，没时间").intent == .sentence,
                   "punctuation-separated prose reaches the sentence route")
        let sentences = [
            sampleSentenceText,
            "The drug, which was initially developed to treat diabetes, was later found to reduce cardiovascular risk.",
            "Because I smoke every day, my lungs are in poor health.",
            "Researchers have suggested that the observed effect may be associated with changes in gut microbiota.",
            "Not only did the treatment improve symptoms, but it also reduced the risk of relapse.",
            "“If the hypothesis is correct,” the author argues, “the findings could change how the disease is treated.”"
        ]
        for sentence in sentences {
            try expect(QueryIntentClassifier.classify(sentence).intent == .sentence,
                       "sentence intent")
        }
        let punctuation = "  “If it doesn't work,” she said, “we'll try again.”  "
        let normalized = SentenceTextNormalizer.normalize(punctuation)
        try expect(normalized == "“If it doesn't work,” she said, “we'll try again.”",
                   "sentence punctuation and apostrophes preserved")
        try expect(QueryIntentClassifier.classify(
            String(repeating: "a", count: SentenceTextNormalizer.maximumCharacters + 1)
        ).intent == .textTooLong, "character safety limit")
        try expect(QueryIntentClassifier.classify(
            "First sentence. Second sentence. Third sentence. Fourth sentence."
        ).intent == .sentence, "multi-sentence local analysis route")
        try expect(QueryIntentClassifier.classify(
            "First sentence.\n\nSecond paragraph."
        ).intent == .sentence, "multiple paragraphs local analysis route")
        try expect(QueryIntentClassifier.classify(
            "这是一个主要为中文的句子。英文很少"
        ).intent == .sentence, "Chinese local analysis route")
        let pollutedPhrase = QueryIntentClassifier.classify(
            "multiple__organisms__indirectly_"
        )
        try expect(pollutedPhrase.intent == .phrase &&
                   pollutedPhrase.language == .english &&
                   pollutedPhrase.normalizedText == "multiple organisms indirectly",
                   "repeated Markdown/OCR underscores did not become a translatable phrase")
        let pollutedSentence = QuerySurfaceNormalizer.translationReadyText(
            "The bees may switch as a way of _coping with_ " +
                "_the build-up of__minuscule__construction_ errors."
        )
        try expect(!pollutedSentence.contains("__") &&
                   QueryIntentClassifier.classify(pollutedSentence).intent == .sentence,
                   "polluted sentence was not conservatively repaired")
        try expect(QuerySurfaceNormalizer.translationReadyText("snake_case") == "snake_case",
                   "ordinary single-underscore identifier was rewritten")

        var gesture = TripleReturnAITrigger(maximumInterval: 1.5)
        try expect(gesture.register(query: "framework", at: 1.0) == .firstReturn &&
                   gesture.register(query: "framework", at: 1.4) == .secondReturn &&
                   gesture.register(query: "framework", at: 1.8) == .triggerAI,
                   "three Returns trigger the explicit AI action once")
        try expect(gesture.register(query: "framework", at: 3.0) == .firstReturn &&
                   gesture.register(query: "changed", at: 3.2) == .firstReturn &&
                   gesture.register(query: "changed", at: 5.0) == .firstReturn,
                   "query edits and a slow Return reset the AI gesture")
    }

    private static func testConfigurationAndUserDefaults() throws {
        let preset = AIProviderConfiguration.zhipuPreset
        let builtIn = AIProviderCatalog.builtIn
        try expect(builtIn.profiles.first?.providerID ==
                   AIProviderConfiguration.googleProviderID &&
                   builtIn.profiles.first?.enabled == true &&
                   builtIn.profiles.first(where: { $0.providerType == .zhipu })?.enabled == false &&
                   !builtIn.automaticFallbackEnabled,
                   "Google is primary, Zhipu defaults off, fallback defaults off")
        try expect(preset.baseURL == "https://open.bigmodel.cn/api/paas/v4", "zhipu base URL")
        try expect(preset.model == "glm-4.7-flash", "zhipu model")
        let appendedEndpoint = try preset.validatedEndpointURL().absoluteString
        try expect(appendedEndpoint ==
                   "https://open.bigmodel.cn/api/paas/v4/chat/completions", "endpoint append")
        var full = preset
        full.baseURL += "/chat/completions"
        let fullEndpoint = try full.validatedEndpointURL().absoluteString
        try expect(fullEndpoint ==
                   "https://open.bigmodel.cn/api/paas/v4/chat/completions", "endpoint deduplicate")

        let suite = "LocalDictionary.AISmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults)
        try expect(!store.loadAutomaticSentenceAnalysisEnabled(),
                   "automatic sentence analysis defaults off")
        store.saveAutomaticSentenceAnalysisEnabled(true)
        try expect(store.loadAutomaticSentenceAnalysisEnabled(),
                   "automatic sentence setting round trip")
        var saved = preset
        saved.enabled = true
        saved.priority = 1
        store.save(saved)
        let secret = "test-secret-must-not-enter-defaults"
        try expect(!defaults.dictionaryRepresentation().values.contains {
            String(describing: $0).contains(secret)
        }, "API key leaked to UserDefaults")
        try expect(store.load() == saved, "configuration round trip")

        let v2Defaults = MemoryDefaults()
        var v2Catalog = AIProviderCatalog.builtIn
        v2Catalog.schemaVersion = 2
        v2Catalog.profiles[1].enabled = true
        v2Catalog.automaticFallbackEnabled = true
        v2Defaults.values["LocalDictionary.AI.providerCatalog.v2"] =
            try JSONEncoder().encode(v2Catalog)
        let migratedV2 = try AIConfigurationStore(defaults: v2Defaults).loadCatalog()
        try expect(migratedV2?.schemaVersion == AIProviderCatalog.currentSchemaVersion &&
                   migratedV2?.profiles.first?.providerType == .googleGemini &&
                   migratedV2?.profiles.first?.enabled == true &&
                   migratedV2?.profiles.first(where: { $0.providerType == .zhipu })?.enabled == false &&
                   migratedV2?.automaticFallbackEnabled == false,
                   "v2 catalog applies the Google-only default without deleting Zhipu")
    }

    private static func testProviderProfilesAndMigration() async throws {
        let defaults = MemoryDefaults()
        defaults.values["LocalDictionary.AI.enabled"] = true
        defaults.values["LocalDictionary.AI.providerType"] = AIProviderType.zhipu.rawValue
        defaults.values["LocalDictionary.AI.providerDisplayName"] = "智谱AI（北京智谱华章）"
        defaults.values["LocalDictionary.AI.baseURL"] =
            "https://open.bigmodel.cn/api/paas/v4"
        defaults.values["LocalDictionary.AI.model"] = "GLM-4.7-Flash"
        defaults.values["LocalDictionary.AI.automaticSentenceAnalysis"] = true
        let oldGoogle = "openai-compatible|https://generativelanguage.googleapis.com/v1beta/openai"
        let oldZhipu = "zhipu|https://open.bigmodel.cn/api/paas/v4"
        let keychain = StubKeychain(values: [oldGoogle: "google-key", oldZhipu: "zhipu-key"])
        let store = AIConfigurationStore(defaults: defaults)
        let manager = AIProviderProfileManager(store: store, keychain: keychain)
        let catalog = try await manager.catalog()
        try expect(catalog.profiles.count == 2 &&
                   !catalog.automaticSentenceAnalysisEnabled,
                   "legacy automatic analysis is migrated to explicit-click only")
        let google = catalog.profiles.first { $0.providerType == .googleGemini }!
        let zhipu = catalog.profiles.first { $0.providerType == .zhipu }!
        try expect(google.providerID == AIProviderConfiguration.googleProviderID &&
                   zhipu.providerID == AIProviderConfiguration.zhipuProviderID,
                   "built-in provider IDs are stable")
        try expect(google.priority == 1 && zhipu.priority == 2 &&
                   google.enabled && !zhipu.enabled &&
                   !catalog.automaticFallbackEnabled &&
                   zhipu.model == "glm-4.7-flash",
                   "provider ordering and exact Zhipu model migration")
        var secondGoogleProfile = google
        secondGoogleProfile.providerID = UUID()
        try expect(AIExplanationCache.cacheKey(query: "prompt", configuration: google) !=
                   AIExplanationCache.cacheKey(query: "prompt",
                                               configuration: secondGoogleProfile),
                   "provider UUID isolates cache identity")
        let migratedGoogleKey = try await keychain.readKey(account: google.keychainAccount)
        let migratedZhipuKey = try await keychain.readKey(account: zhipu.keychainAccount)
        try expect(migratedGoogleKey == "google-key" && migratedZhipuKey == "zhipu-key",
                   "legacy keys copied to independent UUID accounts")
        let retainedGoogleKey = try await keychain.readKey(account: oldGoogle)
        let retainedZhipuKey = try await keychain.readKey(account: oldZhipu)
        try expect(retainedGoogleKey == "google-key" && retainedZhipuKey == "zhipu-key",
                   "legacy keychain items retained")
        let second = try await manager.catalog()
        try expect(second == catalog, "migration is idempotent")

        let unknownDefaults = MemoryDefaults()
        let unknownAccount = "custom|https://legacy.example/v1"
        let unknownKeychain = StubKeychain(values: [unknownAccount: "unknown-key"])
        let unknownManager = AIProviderProfileManager(
            store: AIConfigurationStore(defaults: unknownDefaults), keychain: unknownKeychain
        )
        let unknownCatalog = try await unknownManager.catalog()
        let recovery = unknownCatalog.profiles.first { $0.options.requiresUserReview }
        try expect(recovery?.providerDisplayName.hasPrefix("待恢复的旧服务") == true &&
                   recovery?.enabled == false,
                   "unknown legacy account is not assigned to a guessed provider")
        let retainedUnknownKey = try await unknownKeychain.readKey(account: unknownAccount)
        try expect(retainedUnknownKey == "unknown-key",
                   "unknown legacy key retained")

        do {
            var invalid = AIProviderConfiguration.googlePreset
            invalid.providerDisplayName = String(repeating: "网页内容", count: 20)
            _ = try invalid.normalizedForSave()
            throw SmokeFailure.failed("oversized display name accepted")
        } catch let error as AIConfigurationError {
            try expect(error == .displayNameTooLong, "oversized pasted name rejected")
        }
    }

    private static func testTransactionalProviderSave() async throws {
        let defaults = MemoryDefaults()
        let store = AIConfigurationStore(defaults: defaults)
        try store.saveCatalog(.builtIn)
        let google = AIProviderConfiguration.googlePreset
        let zhipu = AIProviderConfiguration.zhipuPreset
        let keychain = StubKeychain(values: [google.keychainAccount: "google-old",
                                             zhipu.keychainAccount: "zhipu-old"])
        let manager = AIProviderProfileManager(store: store, keychain: keychain)

        var edited = AIProviderCatalog.builtIn
        edited.profiles[1].providerDisplayName = "智谱 AI（北京）"
        edited.profiles[1].model = "glm-4.7-flash"
        let snapshot = try await manager.save(catalog: edited, replacementKeys: [:])
        let unchangedGoogleKey = try await keychain.readKey(account: google.keychainAccount)
        let unchangedZhipuKey = try await keychain.readKey(account: zhipu.keychainAccount)
        try expect(snapshot.catalog.profiles[1].providerID == zhipu.providerID &&
                   unchangedGoogleKey == "google-old" && unchangedZhipuKey == "zhipu-old",
                   "editing metadata preserves stable IDs and both keys")

        var invalid = edited
        invalid.profiles[0].baseURL = "http://unsafe.example/v1"
        do {
            _ = try await manager.save(catalog: invalid, replacementKeys: [:])
            throw SmokeFailure.failed("invalid URL saved")
        } catch let error as AIConfigurationError {
            try expect(error == .invalidBaseURL, "invalid URL rejected before persistence")
        }
        let afterInvalid = try store.loadCatalog()
        try expect(afterInvalid == snapshot.catalog,
                   "invalid profile leaves prior catalog intact")

        keychain.failWrites = true
        var keyFailureCatalog = snapshot.catalog
        keyFailureCatalog.profiles[0].providerDisplayName = "Google Edited"
        do {
            _ = try await manager.save(catalog: keyFailureCatalog,
                                       replacementKeys: [google.providerID: "google-new"])
            throw SmokeFailure.failed("keychain write failure accepted")
        } catch {}
        keychain.failWrites = false
        let googleAfterKeyFailure = try await keychain.readKey(account: google.keychainAccount)
        let afterKeyFailure = try store.loadCatalog()
        try expect(afterKeyFailure == snapshot.catalog &&
                   googleAfterKeyFailure == "google-old",
                   "keychain failure leaves catalog and key intact")

        defaults.rejectWrites = true
        do {
            _ = try await manager.save(catalog: keyFailureCatalog,
                                       replacementKeys: [google.providerID: "google-new"])
            throw SmokeFailure.failed("defaults write failure accepted")
        } catch {}
        defaults.rejectWrites = false
        let googleAfterDefaultsFailure = try await keychain.readKey(account: google.keychainAccount)
        let afterDefaultsFailure = try store.loadCatalog()
        try expect(afterDefaultsFailure == snapshot.catalog &&
                   googleAfterDefaultsFailure == "google-old",
                   "catalog write failure rolls back replacement key")
    }

    private static func testProviderEditingSession() throws {
        let google = AIProviderConfiguration.googlePreset
        let zhipu = AIProviderConfiguration.zhipuPreset
        let snapshot = AIProviderCatalogSnapshot(
            catalog: .builtIn,
            configuredProviderIDs: [google.providerID]
        )
        var session = AIProviderSettingsSession(snapshot: snapshot)
        try expect(session.selectedDraft?.providerID == google.providerID &&
                   session.selectedDraft?.providerType == .googleGemini &&
                   session.selectedDraft?.baseURL == google.baseURL &&
                   session.selectedDraft?.model == google.model,
                   "Google selection atomically exposes one draft")

        var editedGoogle = session.selectedDraft!
        editedGoogle.providerDisplayName = "Google Draft"
        editedGoogle.model = "gemini-draft-model"
        session.updateDraft(editedGoogle)
        session.setPendingAPIKey("google-window-key", for: google.providerID)
        try expect(session.select(zhipu.providerID), "select Zhipu by stable ID")
        try expect(session.selectedDraft?.providerID == zhipu.providerID &&
                   session.selectedDraft?.providerType == .zhipu &&
                   session.selectedDraft?.providerDisplayName == "智谱 AI" &&
                   session.selectedDraft?.baseURL == zhipu.baseURL &&
                   session.selectedDraft?.model == "glm-4.7-flash",
                   "Zhipu fields never mix with Google")
        try expect(session.pendingAPIKey(for: zhipu.providerID).isEmpty &&
                   session.keyState(for: zhipu.providerID) == .notConfigured &&
                   session.keyState(for: google.providerID) == .pendingReplacement,
                   "provider key input and state are isolated")

        var editedZhipu = session.selectedDraft!
        editedZhipu.providerDisplayName = "智谱 Draft"
        editedZhipu.model = "glm-4.7-flash"
        session.updateDraft(editedZhipu)
        session.setPendingAPIKey("zhipu-window-key", for: zhipu.providerID)
        for index in 0..<50 {
            let id = index.isMultiple(of: 2) ? google.providerID : zhipu.providerID
            try expect(session.select(id), "repeated provider selection")
            let expectedType: AIProviderType = id == google.providerID ? .googleGemini : .zhipu
            try expect(session.selectedDraft?.providerID == id &&
                       session.selectedDraft?.providerType == expectedType,
                       "50 switches remain ID-consistent")
        }
        _ = session.select(google.providerID)
        try expect(session.selectedDraft?.providerDisplayName == "Google Draft" &&
                   session.selectedDraft?.model == "gemini-draft-model" &&
                   session.pendingAPIKey(for: google.providerID) == "google-window-key",
                   "unsaved Google draft survives switching")
        _ = session.select(zhipu.providerID)
        try expect(session.selectedDraft?.providerDisplayName == "智谱 Draft" &&
                   session.pendingAPIKey(for: zhipu.providerID) == "zhipu-window-key",
                   "unsaved Zhipu draft survives switching")

        var deletionSession = AIProviderSettingsSession(snapshot: snapshot)
        try expect(deletionSession.remove(google.providerID, deleteKey: false) &&
                   !deletionSession.keyDeletionIDs.contains(google.providerID) &&
                   deletionSession.selectedProviderID == zhipu.providerID,
                   "deleting profile keeps key by default and selects another provider")

        let freshSession = AIProviderSettingsSession(snapshot: snapshot)
        try expect(freshSession.selectedDraft == google &&
                   freshSession.pendingAPIKeys.isEmpty,
                   "cancelling discards all editing drafts and pending keys")

        var gate = AIConnectionTestGate()
        try expect(gate.begin() && !gate.begin(),
                   "connection test gate blocks duplicate clicks")
        gate.finish()
        try expect(gate.begin(), "connection test gate resets after completion")
    }

    private static func testCredentialSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-CredentialSession-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIConfigurationStore(defaults: MemoryDefaults())
        try store.saveCatalog(.builtIn)
        let google = AIProviderConfiguration.googlePreset
        let zhipu = AIProviderConfiguration.zhipuPreset
        let keychain = StubKeychain(values: [google.keychainAccount: "google-session-key",
                                             zhipu.keychainAccount: "zhipu-session-key"])
        let credentials = AIProviderCredentialSession(keychain: keychain)
        let manager = AIProviderProfileManager(store: store, keychain: keychain,
                                               credentialSession: credentials)

        let statusSnapshot = try await manager.snapshot()
        try expect(statusSnapshot.configuredProviderIDs.contains(google.providerID) &&
                   keychain.readCounts.isEmpty,
                   "settings status checks account metadata without reading secrets")

        for _ in 0..<20 {
            _ = try await manager.apiKey(for: google)
        }
        try expect(keychain.readCounts[google.keychainAccount] == 1,
                   "20 Google uses read Keychain once per process")

        let client = StubClient(result: .success(sample))
        client.sentenceResult = .success(sampleSentenceAnalysis)
        let service = AIExplanationService(
            configurationStore: store,
            keychain: keychain,
            cache: AIExplanationCache(databaseURL: root.appendingPathComponent("cache.sqlite")),
            profileManager: manager,
            clientFactory: { client }
        )
        try await service.testConnection(configuration: google, replacementKey: nil)
        _ = try await service.explain(query: "credential-session-word", domain: "general")
        _ = try await service.analyzeSentence(sampleSentenceText)
        try expect(keychain.readCounts[google.keychainAccount] == 1,
                   "test, word, and sentence modes share one credential read")

        await credentials.invalidate(google.providerID)
        _ = try await service.explain(query: "credential-session-word", domain: "general")
        try expect(keychain.readCounts[google.keychainAccount] == 1,
                   "cache restoration does not read the Keychain")
        _ = try await manager.apiKey(for: google)
        try expect(keychain.readCounts[google.keychainAccount] == 2,
                   "explicit invalidation causes exactly one later read")

        _ = try await manager.apiKey(for: zhipu)
        try expect(keychain.readCounts[zhipu.keychainAccount] == 1 &&
                   keychain.readCounts[google.keychainAccount] == 2,
                   "provider credential caches are isolated")

        let currentCatalog = try await manager.catalog()
        _ = try await manager.save(catalog: currentCatalog,
                                   replacementKeys: [google.providerID: "google-replacement"])
        let replacement = try await manager.apiKey(for: google)
        try expect(replacement == "google-replacement" &&
                   keychain.readCounts[google.keychainAccount] == 2,
                   "replacement immediately replaces the in-memory credential")

        _ = try await manager.save(catalog: currentCatalog,
                                   replacementKeys: [:],
                                   deletingKeys: [google.providerID])
        let removed = try await manager.apiKey(for: google)
        try expect(removed == nil && keychain.readCounts[google.keychainAccount] == 2,
                   "clearing a key immediately clears its in-memory value")

        let deniedKeychain = StubKeychain(values: [google.keychainAccount: "denied-key"])
        deniedKeychain.failReads = true
        let deniedCredentials = AIProviderCredentialSession(keychain: deniedKeychain)
        let deniedManager = AIProviderProfileManager(
            store: AIConfigurationStore(defaults: MemoryDefaults()),
            keychain: deniedKeychain,
            credentialSession: deniedCredentials
        )
        for _ in 0..<2 {
            do {
                _ = try await deniedManager.apiKey(for: google)
                throw SmokeFailure.failed("denied credential read accepted")
            } catch let error as AIProviderCredentialError {
                try expect(error == .unavailable(providerDisplayName: "Google Gemini"),
                           "credential denial maps to a provider-specific error")
            }
        }
        try expect(deniedKeychain.readCounts[google.keychainAccount] == 1,
                   "denied credential is not requested repeatedly in one process")

        var deniedCatalog = AIProviderCatalog.builtIn
        deniedCatalog.profiles[1].enabled = true
        deniedCatalog.automaticFallbackEnabled = true
        let deniedStore = AIConfigurationStore(defaults: MemoryDefaults())
        try deniedStore.saveCatalog(deniedCatalog)
        let deniedFallbackManager = AIProviderProfileManager(
            store: deniedStore,
            keychain: deniedKeychain,
            credentialSession: deniedCredentials
        )
        let deniedService = AIExplanationService(
            configurationStore: deniedStore,
            keychain: deniedKeychain,
            cache: AIExplanationCache(
                databaseURL: root.appendingPathComponent("denied-cache.sqlite")
            ),
            profileManager: deniedFallbackManager,
            clientFactory: { StubClient(result: .success(sample)) }
        )
        do {
            _ = try await deniedService.explain(query: "denied-query", domain: "general")
            throw SmokeFailure.failed("credential denial reached the provider client")
        } catch let failure as AIProviderRequestFailure {
            try expect(failure.providerID == google.providerID &&
                       failure.underlying is AIProviderCredentialError,
                       "credential denial identifies the attempted provider")
        }
        try expect(deniedKeychain.readCounts[google.keychainAccount] == 1 &&
                   deniedKeychain.readCounts[zhipu.keychainAccount] == nil,
                   "credential denial stops the query without reading the backup provider")
    }

    private static func testKeychain() async throws {
        let keychain = AIKeychainStore(service: "LocalDictionary.AISmoke.\(UUID().uuidString)")
        let account = UUID().uuidString
        defer { Task { try? await keychain.deleteKey(account: account) } }
        try await keychain.storeKey("dummy-test-key-one", account: account)
        let first = try await keychain.readKey(account: account)
        try expect(first == "dummy-test-key-one",
                   "keychain insert/read")
        let accounts = try await keychain.listAccounts()
        try expect(accounts == [account], "keychain account listing excludes secret data")
        try await keychain.storeKey("dummy-test-key-two", account: account)
        let second = try await keychain.readKey(account: account)
        try expect(second == "dummy-test-key-two",
                   "keychain update")
        try await keychain.deleteKey(account: account)
        let deleted = try await keychain.readKey(account: account)
        try expect(deleted == nil, "keychain delete")
    }

    private static func testClientAndErrors() async throws {
        let client = OpenAICompatibleClient(session: session())
        let configuration = AIProviderConfiguration(
            enabled: true, providerType: .zhipu, providerDisplayName: "Mock",
            baseURL: "https://mock.invalid/v1", model: "mock-model", thinkingEnabled: false
        )
        MockURLProtocol.handler = { request in
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-key",
                       "authorization header")
            let requestData = try requestBody(request)
            let body = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
            let thinking = body["thinking"] as? [String: String]
            try expect(thinking?["type"] == "disabled", "zhipu thinking disabled")
            try expect(String(data: requestData, encoding: .utf8)?.contains("本地词典") == false,
                       "local dictionary content sent")
            return (200, try envelope(sample))
        }
        let result = try await client.explain(query: "prompt", domain: "technology",
                                              configuration: configuration, apiKey: "dummy-key")
        try expect(result == sample, "strict JSON decode")

        MockURLProtocol.handler = { request in
            let requestData = try requestBody(request)
            let requestText = String(data: requestData, encoding: .utf8) ?? ""
            try expect(requestText.contains("Input language: Simplified Chinese") &&
                       requestText.contains("recommended_english_expressions"),
                       "Chinese production prompt omitted language/schema contract")
            let chinese = AIExplanation(
                headword: "下载", recommendedEnglishExpressions: ["download"],
                partsOfSpeech: [AIExplanationPartOfSpeech(
                    partOfSpeech: "verb",
                    senses: [AIExplanationSense(
                        definitionEN: "To transfer data to a local device.",
                        definitionZH: "把数据传输到本地设备。"
                    )]
                )]
            )
            return (200, try envelope(chinese))
        }
        let chineseProduction = try await client.explain(
            query: "下载", domain: "technology",
            configuration: configuration, apiKey: "dummy-key"
        )
        try expect(chineseProduction.recommendedEnglishExpressions == ["download"],
                   "Chinese production response parser lost top English expression")

        MockURLProtocol.handler = { request in
            let requestData = try requestBody(request)
            let requestText = String(data: requestData, encoding: .utf8) ?? ""
            try expect(requestText.contains("Input language: English") &&
                       requestText.contains("natural definition_zh") &&
                       requestText.contains("faithful compositional Chinese meaning"),
                       "English bilingual prompt did not require a model-selected native meaning")
            let english = AIExplanation(
                headword: "This is a more",
                partsOfSpeech: [AIExplanationPartOfSpeech(
                    partOfSpeech: "phrase fragment",
                    senses: [AIExplanationSense(
                        definitionEN: "An incomplete comparative phrase.",
                        definitionZH: "这是一个未完成的比较结构，意思取决于后续比较对象。"
                    )]
                )]
            )
            return (200, try envelope(english))
        }
        let englishProduction = try await client.explain(
            query: "This is a more", domain: "general",
            configuration: configuration, apiKey: "dummy-key"
        )
        try expect(englishProduction.partsOfSpeech.first?.senses.first?.definitionZH
            .contains("未完成的比较结构") == true,
                   "English production response lost the native-language counterpart")

        MockURLProtocol.handler = { request in
            let requestData = try requestBody(request)
            let requestText = String(data: requestData, encoding: .utf8) ?? ""
            try expect(requestText.contains(sampleSentenceText), "sentence source sent")
            try expect(!requestText.contains("Obsidian") &&
                       !requestText.contains("/Users/") &&
                       !requestText.contains("牛津高阶"), "sentence request excludes local data")
            let body = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
            try expect(body["max_tokens"] as? Int == 2_600,
                       "sentence response budget")
            try expect(body["response_format"] == nil &&
                       body.description.contains(
                        "Target translation language: Simplified Chinese"
                       ) && body.description.contains("Learning language: English") &&
                       body.description.contains("Analysis object: the English source text") &&
                       body.description.contains("explanations mainly in Simplified Chinese"),
                       "English sentence analysis direction is explicit without JSON mode")
            return (200, try sentenceEnvelope(sampleSentenceAnalysis))
        }
        let sentenceResult = try await client.analyzeSentence(sampleSentenceText,
                                                              configuration: configuration,
                                                              apiKey: "dummy-key")
        try expect(sentenceResult == sampleSentenceAnalysis,
                   "sentence strict JSON decode")

        MockURLProtocol.handler = { _ in
            let json = String(data: try JSONEncoder().encode(sampleSentenceAnalysis),
                              encoding: .utf8)!
            return (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "```json\n\(json)\n```"]]]
            ]))
        }
        let fencedResult = try await client.analyzeSentence(sampleSentenceText,
                                                            configuration: configuration,
                                                            apiKey: "dummy-key")
        try expect(fencedResult.sourceText == sampleSentenceAnalysis.sourceText &&
                   fencedResult.translationZH == sampleSentenceAnalysis.translationZH &&
                   fencedResult.responseParseMode == .compatibleJSON,
                   "outer JSON code fence is safely removed and reported as compatible")

        MockURLProtocol.handler = { _ in
            let invalid = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "```json\n{}\n```"]]]
            ])
            return (200, invalid)
        }
        do {
            _ = try await client.analyzeSentence(sampleSentenceText,
                                                 configuration: configuration,
                                                 apiKey: "dummy-key")
            throw SmokeFailure.failed("sentence code fence accepted")
        } catch let error as AIClientError {
            try expect(error == .schemaInvalid(field: "translation_zh"),
                       "empty sentence object is not treated as readable fallback")
        }

        MockURLProtocol.handler = { _ in
            let content = "{\"status\":\"ok\"}"
            return (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": content]]]
            ]))
        }
        try await client.testConnection(configuration: configuration, apiKey: "dummy-key")
        MockURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "not json"]]]
            ]))
        }
        do {
            try await client.testConnection(configuration: configuration, apiKey: "dummy-key")
            throw SmokeFailure.failed("invalid connection response accepted")
        } catch let error as AIClientError {
            try expect(error == .schemaInvalid(field: "status"), "connection response validation")
        }

        var custom = configuration
        custom.providerType = .openAICompatible
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(body["thinking"] == nil, "custom provider thinking field")
            return (200, try envelope(sample))
        }
        _ = try await client.explain(query: "prompt", domain: "general",
                                     configuration: custom, apiKey: "dummy-key")

        for (status, expected) in [(401, AIClientError.unauthorized),
                                   (429, AIClientError.rateLimited(retryAfter: nil)),
                                   (500, AIClientError.serverError)] {
            MockURLProtocol.responseHeaders = [:]
            MockURLProtocol.handler = { _ in (status, Data("{}".utf8)) }
            do {
                _ = try await client.explain(query: "prompt", domain: "general",
                                             configuration: custom, apiKey: "dummy-key")
                throw SmokeFailure.failed("HTTP \(status) did not fail")
            } catch let error as AIClientError {
                try expect(error == expected, "HTTP \(status) mapping")
            }
        }
        MockURLProtocol.responseHeaders = ["Retry-After": "7"]
        MockURLProtocol.handler = { _ in (429, Data("{\"error\":{\"code\":\"1302\",\"message\":\"rate limit\"}}".utf8)) }
        do {
            _ = try await client.explain(query: "prompt", domain: "general",
                                         configuration: custom, apiKey: "dummy-key")
            throw SmokeFailure.failed("rate limit accepted")
        } catch let error as AIClientError {
            try expect(error == .rateLimited(retryAfter: "7"), "Retry-After classification")
        }
        MockURLProtocol.responseHeaders = [:]
        MockURLProtocol.handler = { _ in
            (429, Data("{\"error\":{\"code\":\"1113\",\"message\":\"余额不足\"}}".utf8))
        }
        do {
            _ = try await client.explain(query: "prompt", domain: "general",
                                         configuration: configuration, apiKey: "dummy-key")
            throw SmokeFailure.failed("quota exhaustion accepted")
        } catch let error as AIClientError {
            try expect(error == .insufficientQuota(code: "1113"),
                       "Zhipu quota business error classification")
        }
        MockURLProtocol.handler = { _ in
            let readable = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "A prompt is a concise instruction."]]]
            ])
            return (200, readable)
        }
        let readableFallback = try await client.explain(
            query: "prompt", domain: "general", configuration: custom, apiKey: "dummy-key"
        )
        try expect(readableFallback.responseParseMode == .plainTextFallback &&
                   readableFallback.rawFallbackText?.contains("concise instruction") == true,
                   "readable non-JSON response is preserved")
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await client.explain(query: "prompt", domain: "general",
                                         configuration: custom, apiKey: "dummy-key")
            throw SmokeFailure.failed("timeout accepted")
        } catch let error as AIClientError {
            try expect(error == .timeout, "timeout mapping")
        }
        MockURLProtocol.handler = { _ in
            (200, Data(repeating: 65, count: OpenAICompatibleClient.maximumResponseBytes + 1))
        }
        do {
            _ = try await client.explain(query: "prompt", domain: "general",
                                         configuration: custom, apiKey: "dummy-key")
            throw SmokeFailure.failed("oversize response accepted")
        } catch let error as AIClientError {
            try expect(error == .responseTooLarge, "response size limit")
        }
    }

    private static func testVisibleContentNormalizerAndBoundedRetry() async throws {
        func normalized(_ object: Any) throws -> ProviderVisibleContentNormalization {
            ProviderVisibleContentNormalizer.normalize(
                try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
            )
        }
        let plain = try normalized("Plain visible text")
        try expect(plain.content == "Plain visible text" && plain.failureReason == nil,
                   "plain string normalization")
        let markdown = try normalized([
            "choices": [["message": ["content": "**结构分析**\n- visible"]]]
        ])
        try expect(markdown.content?.contains("**结构分析**") == true,
                   "Markdown visible content normalization")
        let array = try normalized([
            "choices": [["message": ["content": [
                ["type": "text", "text": "First visible part"],
                ["type": "output_text", "text": "Second visible part"]
            ]]]]
        ])
        try expect(array.content?.contains("First visible part") == true &&
                   array.content?.contains("Second visible part") == true &&
                   array.metadata.contentArrayItemCount == 2,
                   "content-array normalization preserves every visible text part")
        let partial = try normalized(["translation": "自然翻译", "note": "学习提示"])
        try expect(partial.content?.contains("translation") == true &&
                   partial.metadata.responseEnvelopeKind == "direct_object",
                   "partial structured normalization")
        let compatibleTopLevel = try normalized(["content": "Top-level visible result"])
        try expect(compatibleTopLevel.content == "Top-level visible result" &&
                   compatibleTopLevel.metadata.contentType == "top_level_content",
                   "compatible top-level content envelope")
        let empty = try normalized([
            "choices": [["message": ["content": NSNull()], "finish_reason": "stop"]]
        ])
        try expect(empty.failureReason == .providerEmptyResponse,
                   "null content is provider empty")
        let reasoningOnly = try normalized([
            "choices": [["message": ["content": "", "reasoning_content": "hidden"],
                         "finish_reason": "stop"]]
        ])
        try expect(reasoningOnly.failureReason == .providerReasoningOnly &&
                   reasoningOnly.metadata.reasoningFieldPresent &&
                   reasoningOnly.content == nil,
                   "reasoning-only is typed and never exposed")
        let dropped = try normalized([
            "choices": [["message": ["content": [["type": "image", "image": "x"]]]]]
        ])
        try expect(dropped.failureReason == .normalizationDroppedVisibleContent,
                   "unsupported potential visible content is typed as dropped")
        let malformed = try normalized(["id": "only-metadata", "model": "mock"])
        try expect(malformed.failureReason == .malformedProviderEnvelope,
                   "unknown envelope is typed malformed")

        let client = OpenAICompatibleClient(session: session())
        let configuration = AIProviderConfiguration(
            enabled: true, providerType: .openAICompatible,
            providerDisplayName: "Mock Plain", baseURL: "https://mock.invalid/v1",
            model: "mock-model", options: AIProviderOptions(usesJSONResponseFormat: false),
            thinkingEnabled: false
        )
        var attempts = 0
        MockURLProtocol.handler = { request in
            attempts += 1
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(body["response_format"] == nil && body["thinking"] == nil,
                       "bounded retry remains plain-text compatible")
            if attempts == 1 {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": [
                        "content": "", "reasoning_content": "hidden reasoning"
                    ], "finish_reason": "stop"]]
                ]))
            }
            return (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": [
                    "content": "自然翻译：尽管如此，团队仍确认了主句。\n**结构分析**\n- the team established"
                ], "finish_reason": "stop"]]
            ]))
        }
        let context = AIProviderDiagnosticContext(
            action: "sentenceAnalysis", queryGeneration: 7,
            aiStudyTextIdentityHash: "synthetic-study", sentenceID: "sentence-0001"
        )
        let recovered = try await AIProviderDiagnosticScope.$current.withValue(context) {
            try await client.analyzeSentence(
                sampleSentenceText, configuration: configuration, apiKey: "dummy-key"
            )
        }
        try expect(attempts == 2 && recovered.rawFallbackText?.contains("结构分析") == true,
                   "reasoning-only performs exactly one fresh visible-content retry")

        let deepSeekFlash = AIProviderConfiguration(
            enabled: true, providerType: .openAICompatible,
            providerDisplayName: "DeepSeek", baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            options: AIProviderOptions(usesJSONResponseFormat: false)
        )
        var deepSeekAttempts = 0
        MockURLProtocol.handler = { request in
            deepSeekAttempts += 1
            let body = try JSONSerialization.jsonObject(
                with: requestBody(request)
            ) as! [String: Any]
            let thinking = body["thinking"] as? [String: String]
            try expect(
                body["response_format"] == nil && body["temperature"] == nil &&
                thinking?["type"] == "disabled" && body["enable_thinking"] == nil,
                "DeepSeek V4 retry dropped the explicit non-thinking plain-text policy"
            )
            if deepSeekAttempts == 1 {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": [
                        "content": "", "reasoning_content": "hidden reasoning"
                    ], "finish_reason": "stop"]]
                ]))
            }
            return (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": [
                    "content": "Natural translation: The team established the result.\n" +
                        "### Structure\n- the team established"
                ], "finish_reason": "stop"]]
            ]))
        }
        let deepSeekRecovered = try await AIProviderDiagnosticScope.$current.withValue(context) {
            try await client.analyzeSentence(
                sampleSentenceText, configuration: deepSeekFlash, apiKey: "dummy-key"
            )
        }
        try expect(
            deepSeekAttempts == 2 &&
            deepSeekRecovered.rawFallbackText?.contains("### Structure") == true,
            "DeepSeek V4 plain-text retry did not recover exactly once"
        )

        attempts = 0
        MockURLProtocol.handler = { _ in
            attempts += 1
            return (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": [
                    "content": "", "reasoning_content": "hidden reasoning"
                ], "finish_reason": "stop"]]
            ]))
        }
        do {
            _ = try await AIProviderDiagnosticScope.$current.withValue(context) {
                try await client.analyzeSentence(
                    sampleSentenceText, configuration: configuration, apiKey: "dummy-key"
                )
            }
            throw SmokeFailure.failed("second reasoning-only response accepted")
        } catch let error as AIClientError {
            try expect(error == .providerReasoningOnly && attempts == 2,
                       "empty-content recovery is bounded to one retry")
        }
    }

    private static func testCanonicalResponseFixtures() throws {
        let wordData = try JSONEncoder().encode(sample)
        let wordJSON = String(data: wordData, encoding: .utf8)!

        let strict = try AIProviderCanonicalParser.word(content: wordJSON, query: "prompt")
        try expect(strict.responseParseMode == .strictJSON && strict.partsOfSpeech.count == 1,
                   "fixture A strict JSON")

        let fenced = try AIProviderCanonicalParser.word(
            content: "```json\n\(wordJSON)\n```", query: "prompt"
        )
        try expect(fenced.responseParseMode == .compatibleJSON,
                   "fixture B Markdown fenced JSON")

        let prefixed = try AIProviderCanonicalParser.word(
            content: "Result follows:\n\(wordJSON)\nDone.", query: "prompt"
        )
        try expect(prefixed.responseParseMode == .compatibleJSON,
                   "fixture C prefixed unique JSON object")

        let plain = try AIProviderCanonicalParser.word(
            content: "推荐英文：download\n含义：把远端数据保存到本地设备。", query: "下载"
        )
        try expect(plain.responseParseMode == .plainTextFallback &&
                   plain.recommendedEnglishExpressions.first == "download" &&
                   plain.rawFallbackText?.contains("含义") == true,
                   "fixture D readable plain text and safe recommendation recovery")

        let malformedReadable = try AIProviderCanonicalParser.word(
            content: "部分一 {\"answer\":1} 部分二 {\"answer\":2}", query: "prompt"
        )
        try expect(malformedReadable.responseParseMode == .plainTextFallback &&
                   malformedReadable.rawFallbackText?.contains("部分二") == true,
                   "fixture E malformed but readable content")

        let sanitized = try AIProviderCanonicalParser.word(
            content: "<script>steal()</script><b>A safe readable explanation.</b>", query: "prompt"
        )
        try expect(sanitized.rawFallbackText == "A safe readable explanation." &&
                   !sanitized.rawFallbackText!.contains("script"),
                   "fixture F HTML/script sanitization")

        do {
            _ = try AIProviderCanonicalParser.word(content: " \n\t ", query: "prompt")
            throw SmokeFailure.failed("fixture G empty content accepted")
        } catch let error as AIClientError {
            try expect(error == .emptyResponse, "fixture G empty response classification")
        }

        let translated = try AIProviderCanonicalParser.textTranslation(
            content: "这是可直接显示的完整译文。", sourceText: sampleSentenceText
        )
        try expect(translated.responseParseMode == .plainTextFallback &&
                   translated.translation.contains("完整译文"),
                   "fixture H plain-text long translation")
    }

    private static func testProviderEnvelopeCompatibility() async throws {
        let client = OpenAICompatibleClient(session: session())
        let configuration = AIProviderConfiguration(
            enabled: true, providerType: .openAICompatible,
            providerDisplayName: "Compatible Fixture",
            baseURL: "https://fixture.invalid/v1", model: "fixture-model"
        )
        MockURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: ["choices": []]))
        }
        do {
            _ = try await client.explain(query: "prompt", domain: "general",
                                         configuration: configuration, apiKey: "dummy")
            throw SmokeFailure.failed("choices-missing response accepted")
        } catch let error as AIClientError {
            try expect(error == .malformedProviderEnvelope,
                       "choices missing is a malformed provider envelope")
        }

        MockURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": [
                    "content": "", "refusal": "<b>Policy refused this input.</b>"
                ]]]
            ]))
        }
        do {
            _ = try await client.explain(query: "prompt", domain: "general",
                                         configuration: configuration, apiKey: "dummy")
            throw SmokeFailure.failed("refusal response accepted")
        } catch let error as AIClientError {
            try expect(error == .refused(reason: "Policy refused this input."),
                       "refusal is distinct and sanitized")
        }

        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(sample)) }
        let direct = try await client.explain(query: "prompt", domain: "general",
                                              configuration: configuration, apiKey: "dummy")
        try expect(direct.responseParseMode == .strictJSON,
                   "direct canonical object without choices")

        let content = String(data: try JSONEncoder().encode(sample), encoding: .utf8)!
        MockURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "choices": [[
                    "message": ["content": [["type": "text", "text": content]]],
                    "finish_reason": "length"
                ]]
            ]))
        }
        let parts = try await client.explain(query: "prompt", domain: "general",
                                             configuration: configuration, apiKey: "dummy")
        try expect(parts.partsOfSpeech.count == 1,
                   "content parts and non-stop finish reason retain readable output")

        MockURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": [
                    ["type": "reasoning", "text": "HIDDEN_CHAIN_OF_THOUGHT"],
                    ["type": "text", "text": "Visible final answer."]
                ]]]]
            ]))
        }
        let visibleOnly = try await client.explain(
            query: "prompt", domain: "general", configuration: configuration, apiKey: "dummy"
        )
        try expect(visibleOnly.rawFallbackText == "Visible final answer." &&
                   visibleOnly.rawFallbackText?.contains("HIDDEN_CHAIN_OF_THOUGHT") == false,
                   "content-array reasoning leaked into visible provider text")
    }

    private static func testProviderProductionCompatibilityFixtures() async throws {
        let client = OpenAICompatibleClient(session: session())
        let gemini = AIProviderConfiguration(
            enabled: true, providerType: .googleGemini,
            providerDisplayName: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
            model: "gemini-fixture"
        )
        let deepSeek = AIProviderConfiguration(
            enabled: true, providerType: .openAICompatible,
            providerDisplayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1/chat/completions",
            model: "deepseek-chat"
        )
        let wordJSON = String(data: try JSONEncoder().encode(sample), encoding: .utf8)!
        func geminiEnvelope(_ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "candidates": [[
                    "content": ["parts": [["text": text]]],
                    "finishReason": "STOP"
                ]]
            ])
        }

        MockURLProtocol.handler = { _ in (200, try geminiEnvelope(wordJSON)) }
        let geminiWord = try await client.explain(
            query: "prompt", domain: "general", configuration: gemini, apiKey: "dummy"
        )
        try expect(geminiWord.partsOfSpeech.count == 1,
                   "Gemini native word envelope normalization")

        let chineseLong = """
        写入完成后验证是否真正秒级/短时间结束；不能再‘验证100%’挂五分钟；
        建立过程中普通英文查询还能用；取消、退出都正常。
        """
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(body["response_format"] == nil,
                       "Gemini long translation must not require JSON mode")
            try expect(body.description.contains("Simplified Chinese") &&
                       body.description.contains("English"),
                       "Chinese long translation direction is explicit")
            return (200, try geminiEnvelope(
                "After writing, verify that it finishes within seconds or a short time."
            ))
        }
        let geminiTranslation = try await client.translateText(
            chineseLong, configuration: gemini, apiKey: "dummy"
        )
        try expect(geminiTranslation.translation.hasPrefix("After writing"),
                   "Gemini plain-text translation display path")

        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(body["response_format"] == nil,
                       "Gemini sentence analysis must not require JSON mode")
            try expect(body.description.contains("Target translation language: English") &&
                       body.description.contains("Learning language: English") &&
                       body.description.contains(
                        "Analysis object: the natural English translation produced from the source text"
                       ) && body.description.contains(
                        "Chinese source may be quoted only as reference"
                       ),
                       "Chinese sentence must translate to and analyze the English learning object")
            return (200, try geminiEnvelope(
                "### Analysis\n自然翻译：After writing, verify that it finishes quickly.\n" +
                "- The sentence asks for a bounded verification step."
            ))
        }
        let geminiSentence = try await client.analyzeSentence(
            chineseLong, configuration: gemini, apiKey: "dummy"
        )
        try expect(geminiSentence.translationZH.hasPrefix("After writing") &&
                   geminiSentence.responseParseMode == .plainTextFallback,
                   "Gemini sentence Markdown remains readable in the requested direction")

        MockURLProtocol.handler = { _ in
            (200, try geminiEnvelope(
                "Readable explanation before malformed JSON {\"definition\": "
            ))
        }
        let geminiMalformed = try await client.explain(
            query: "prompt", domain: "general", configuration: gemini, apiKey: "dummy"
        )
        try expect(geminiMalformed.rawFallbackText?.contains("Readable explanation") == true,
                   "Gemini malformed JSON with safe text has a display path")

        let deepSeekFixtures: [(String, Data)] = [
            ("string-json", try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": wordJSON]]]
            ])),
            ("content-array", try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": [["type": "text", "text": wordJSON]]]]]
            ])),
            ("plain-text", try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "A prompt is a concise instruction."]]]
            ])),
            ("markdown", try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "```json\n\(wordJSON)\n```"]]]
            ])),
            ("malformed-readable", try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content":
                    "Readable final answer despite malformed JSON {\"answer\":"
                ]]]
            ]))
        ]
        for (name, envelope) in deepSeekFixtures {
            MockURLProtocol.handler = { _ in (200, envelope) }
            let value = try await client.explain(
                query: "prompt", domain: "general", configuration: deepSeek, apiKey: "dummy"
            )
            try expect(!value.partsOfSpeech.isEmpty ||
                       value.rawFallbackText.map(AIProviderResponseTextSanitizer.isReadable) == true,
                       "DeepSeek \(name) fixture has no display path")
        }
        MockURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": ""]]]
            ]))
        }
        do {
            _ = try await client.explain(
                query: "prompt", domain: "general", configuration: deepSeek, apiKey: "dummy"
            )
            throw SmokeFailure.failed("DeepSeek empty content accepted")
        } catch let error as AIClientError {
            try expect(error == .providerEmptyResponse,
                       "DeepSeek empty content classification")
        }
        for (status, expected) in [
            (429, AIClientError.rateLimited(retryAfter: nil)),
            (500, AIClientError.serverError)
        ] {
            MockURLProtocol.responseHeaders = [:]
            MockURLProtocol.handler = { _ in (status, Data("{}".utf8)) }
            do {
                _ = try await client.explain(
                    query: "prompt", domain: "general", configuration: deepSeek,
                    apiKey: "dummy"
                )
                throw SmokeFailure.failed("DeepSeek HTTP \(status) accepted")
            } catch let error as AIClientError {
                try expect(error == expected, "DeepSeek HTTP \(status) classification")
            }
        }
    }

    private static func testConnectionAndProductionRequestShareTransportConfiguration()
        async throws {
        let client = OpenAICompatibleClient(session: session())
        let profile = AIProviderConfiguration(
            providerID: UUID(), enabled: true, providerType: .openAICompatible,
            providerDisplayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1/chat/completions",
            model: "deepseek-chat", priority: 1
        )
        let testKey = "unit-test-placeholder"
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": "{\"status\":\"ok\"}"]]]
                ]))
            }
            return (200, try envelope(sample))
        }
        try await client.testConnection(configuration: profile, apiKey: testKey)
        _ = try await client.explain(query: "fallback", domain: "general",
                                     configuration: profile, apiKey: testKey)
        try expect(requests.count == 2, "connection and production query each send one request")
        let connection = requests[0]
        let production = requests[1]
        try expect(connection.url == production.url &&
                   connection.url?.absoluteString ==
                    "https://api.deepseek.com/v1/chat/completions",
                   "connection and production query share normalized endpoint")
        try expect(connection.value(forHTTPHeaderField: "Authorization") ==
                    production.value(forHTTPHeaderField: "Authorization") &&
                   connection.value(forHTTPHeaderField: "Authorization") ==
                    ["Bearer", testKey].joined(separator: " "),
                   "connection and production query share credential/header construction")
        let connectionBody = try JSONSerialization.jsonObject(
            with: requestBody(connection)
        ) as! [String: Any]
        let productionBody = try JSONSerialization.jsonObject(
            with: requestBody(production)
        ) as! [String: Any]
        try expect(connectionBody["model"] as? String == "deepseek-chat" &&
                   productionBody["model"] as? String == "deepseek-chat",
                   "connection and production query use the same persisted model")
        try expect(connectionBody["stream"] == nil && productionBody["stream"] == nil,
                   "both request paths are non-streaming")
        try expect((connectionBody["response_format"] as? [String: String])?["type"] ==
                    "json_object" &&
                   (productionBody["response_format"] as? [String: String])?["type"] ==
                   "json_object",
                   "both request paths share strict JSON response policy")

        var flashProfile = profile
        flashProfile.model = "deepseek-v4-flash"
        try expect(flashProfile.responseCapability == .plainTextOnly,
                   "DeepSeek v4 flash uses tolerant plain-text capability")
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            let thinking = body["thinking"] as? [String: String]
            try expect(body["response_format"] == nil && body["temperature"] == nil &&
                       thinking?["type"] == "disabled" && body["enable_thinking"] == nil &&
                       body["tools"] == nil && body["functions"] == nil &&
                       body["stream"] == nil,
                       "DeepSeek v4 flash plain-text request did not disable default thinking")
            return (200, try JSONSerialization.data(withJSONObject: [
                "choices": [["message": [
                    "content": "A fallback is an alternative used when the first option fails."
                ]]]
            ]))
        }
        let flash = try await client.explain(query: "fallback", domain: "general",
                                             configuration: flashProfile, apiKey: testKey)
        try expect(flash.responseParseMode == .plainTextFallback &&
                   flash.rawFallbackText?.contains("alternative") == true,
                   "DeepSeek v4 flash readable response survives parsing")
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            let thinking = body["thinking"] as? [String: String]
            try expect(body["response_format"] == nil && body["temperature"] == nil &&
                       thinking?["type"] == "disabled" && body["enable_thinking"] == nil &&
                       body["tools"] == nil && body["stream"] == nil,
                       "sentence analysis did not use non-thinking plain-text protocol")
            return (200, try sentenceEnvelope(sampleSentenceAnalysis))
        }
        _ = try await client.analyzeSentence(
            sampleSentenceText, configuration: flashProfile, apiKey: testKey
        )
    }

    private static func testInlineLookupRequestsAndCache() async throws {
        let client = OpenAICompatibleClient(session: session())
        var deepSeek = AIProviderConfiguration(
            enabled: true, providerType: .openAICompatible, providerDisplayName: "DeepSeek",
            baseURL: "https://api.deepseek.com", model: "deepseek-chat"
        )
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            let thinking = body["thinking"] as? [String: String]
            try expect(thinking?["type"] == "disabled", "DeepSeek quick thinking disabled")
            try expect(body["enable_thinking"] == nil, "DeepSeek excludes SiliconFlow flag")
            try expect(body["max_tokens"] as? Int == 512, "inline word quick token budget")
            let messages = body["messages"] as? [[String: String]] ?? []
            try expect(messages.description.contains("Native language") &&
                       messages.description.contains("Learning language"),
                       "inline word request carries language roles")
            return (200, try inlineEnvelope(InlineWordQuickAIResult(
                partOfSpeech: "noun", definitionsZH: ["提示；提示语"],
                learningEquivalent: "prompt",
                learningDefinition: "A cue that elicits a response.",
                nativeExplanation: "常指促使用户或系统作出反应的提示。",
                exampleLearning: "The app displays a prompt.",
                exampleNative: "应用会显示一条提示。"
            )))
        }
        let deepSeekQuick = try await client.inlineWordQuick(
            "prompt", configuration: deepSeek, apiKey: "dummy-key"
        )
        try expect(deepSeekQuick.definitionsZH == ["提示；提示语"] &&
                   deepSeekQuick.learningEquivalent == "prompt" &&
                   deepSeekQuick.learningDefinition?.contains("elicits") == true &&
                   deepSeekQuick.nativeExplanation?.contains("反应") == true &&
                   deepSeekQuick.exampleNative?.contains("提示") == true,
                   "inline word quick strict JSON")

        var requestCount = 0
        deepSeek.model = "deepseek-reasoner"
        MockURLProtocol.handler = { _ in requestCount += 1; return (500, Data()) }
        do {
            _ = try await client.inlineWordQuick("prompt", configuration: deepSeek,
                                                apiKey: "dummy-key")
            throw SmokeFailure.failed("reasoner used for quick lookup")
        } catch let error as AIClientError {
            try expect(error == .invalidRequest(code: "reasoner_not_allowed_for_quick") &&
                       requestCount == 0, "DeepSeek reasoner rejected before quick request")
        }

        let silicon = AIProviderConfiguration(
            enabled: true, providerType: .openAICompatible, providerDisplayName: "硅基流动",
            baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen3-8B"
        )
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(body["enable_thinking"] as? Bool == false,
                       "SiliconFlow quick thinking disabled")
            try expect(body["thinking"] == nil, "SiliconFlow excludes GLM/DeepSeek flag")
            return (200, try inlineEnvelope(InlineWordQuickAIResult(
                partOfSpeech: "verb", definitionsZH: ["促使"]
            )))
        }
        _ = try await client.inlineWordQuick("prompt", configuration: silicon,
                                             apiKey: "dummy-key")

        let gemini = AIProviderConfiguration(
            enabled: true, providerType: .googleGemini, providerDisplayName: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
            model: "gemini-3.1-flash-lite"
        )
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(body["thinking"] == nil && body["enable_thinking"] == nil,
                       "Gemini quick request has no foreign thinking flags")
            try expect(body["max_tokens"] as? Int == 512,
                       "inline sentence quick token budget")
            let messages = body["messages"] as? [[String: String]] ?? []
            try expect(!messages.description.contains("core_structure"),
                       "sentence quick does not request full analysis")
            return (200, try inlineEnvelope(InlineSentenceQuickAIResult(
                translation: "这是一句自然的中文翻译。"
            )))
        }
        let sentenceQuick = try await client.inlineSentenceQuick(
            sampleSentenceText, configuration: gemini, apiKey: "dummy-key"
        )
        try expect(sentenceQuick.translation == "这是一句自然的中文翻译。",
                   "sentence quick maps translation only")

        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(body["max_tokens"] as? Int == 2_600,
                       "sentence expansion uses full-analysis budget")
            return (200, try sentenceEnvelope(sampleSentenceAnalysis))
        }
        let expansion = try await client.inlineSentenceExpansion(
            sampleSentenceText, configuration: gemini, apiKey: "dummy-key"
        )
        try expect(expansion == sampleSentenceAnalysis,
                   "sentence expansion reuses validated full analysis")

        let intents = AIRequestIntent.allCases
        let keys = Set(intents.map {
            AIExplanationCache.inlineCacheKey(query: "Prompt", intent: $0,
                                              configuration: gemini)
        })
        try expect(keys.count == 4, "four inline request intents have isolated cache keys")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-InlineCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        let store = AIConfigurationStore(defaults: defaults)
        try store.saveCatalog(AIProviderCatalog(profiles: [gemini]))
        let keychain = StubKeychain(values: [gemini.keychainAccount: "dummy-key"])
        let manager = AIProviderProfileManager(store: store, keychain: keychain)
        let stub = StubClient(result: .success(sample))
        stub.sentenceResult = .success(sampleSentenceAnalysis)
        let service = AIExplanationService(
            configurationStore: store, keychain: keychain,
            cache: AIExplanationCache(databaseURL: root.appendingPathComponent("cache.sqlite")),
            profileManager: manager, clientFactory: { stub }
        )
        _ = try await service.inlineWordQuick("uncached-inline-word")
        let cachedWord = try await service.inlineWordQuick("uncached-inline-word")
        _ = try await service.inlineSentenceQuick(sampleSentenceText)
        let cachedSentence = try await service.inlineSentenceQuick(sampleSentenceText)
        try expect(stub.inlineWordQuickCalls == 1 && cachedWord.fromCache &&
                   stub.inlineSentenceQuickCalls == 1 && cachedSentence.fromCache,
                   "quick requests use isolated persistent cache without repeat network")
        try expect(keychain.readCounts[gemini.keychainAccount] == 1,
                   "word and sentence inline requests reuse one process credential")
    }

    @MainActor
    private static func testInlineLocalLookupAndFormatting() async throws {
        var localQueryCount = 0
        let service = InlineLocalLookupService(sources: [
            InlineLocalLookupSource(name: "English", priority: 1) { _ in
                localQueryCount += 1
                return InlineLocalDictionaryHit(source: "English", partOfSpeech: "noun",
                    chineseDefinitions: [], additionalDefinitions: ["English definition"],
                    examples: [], collocations: [], inflections: [], roots: [],
                    isRootDictionary: false)
            },
            InlineLocalLookupSource(name: "医学", priority: 2) { _ in
                localQueryCount += 1
                return InlineLocalDictionaryHit(source: "英中医学辞海", partOfSpeech: "noun",
                    chineseDefinitions: ["医学释义一", "医学释义二", "医学释义三", "医学释义四"],
                    additionalDefinitions: ["医学释义四"], examples: ["A local example."],
                    collocations: ["medical term"], inflections: [], roots: [],
                    isRootDictionary: false)
            },
            InlineLocalLookupSource(name: "词根", priority: 3) { _ in
                localQueryCount += 1
                return InlineLocalDictionaryHit(source: "词根词缀", partOfSpeech: "",
                    chineseDefinitions: ["构词说明"], additionalDefinitions: [], examples: [],
                    collocations: [], inflections: [], roots: ["bio-：生命"],
                    isRootDictionary: true)
            }
        ], managedFallback: nil)
        let local = await service.lookup("cardiology")
        try expect(local.quick?.source == "英中医学辞海" &&
                   local.quick?.definitions.count == 3,
                   "local quick chooses first real Chinese definitions and caps at three")
        try expect(local.quick?.source != "词根词缀" && local.expansion?.roots == ["bio-：生命"],
                   "root source is expansion, not ordinary definition")
        let managedOnly = InlineLocalLookupService(
            sources: [],
            managedFallback: { query in
                guard query == "managed-term" else { return [] }
                return [InlineLocalDictionaryHit(
                    source: "用户词典", partOfSpeech: "",
                    chineseDefinitions: ["托管词典释义"], additionalDefinitions: [],
                    examples: [], collocations: [], inflections: [], roots: [],
                    isRootDictionary: false
                )]
            }
        )
        let managed = await managedOnly.lookup("managed-term")
        try expect(managed.quick?.source == "用户词典" &&
                   managed.quick?.isAI == false,
                   "managed local hit is used before inline AI fallback")
        let preferredFirst = InlineLocalLookupService(
            sources: [InlineLocalLookupSource(name: "首选", priority: 1) { _ in
                InlineLocalDictionaryHit(
                    source: "首选", partOfSpeech: "noun",
                    chineseDefinitions: ["首选释义"], additionalDefinitions: [],
                    examples: [], collocations: [], inflections: [], roots: [],
                    isRootDictionary: false
                )
            }],
            managedFallback: { _ in [InlineLocalDictionaryHit(
                source: "不应查询", partOfSpeech: "",
                chineseDefinitions: ["错误后备释义"],
                additionalDefinitions: ["不应出现"], examples: [], collocations: [],
                inflections: [], roots: [], isRootDictionary: false
            )] }
        )
        let preferred = await preferredFirst.lookup("preferred-term")
        try expect(preferred.quick?.source == "首选" && preferred.hits.count == 1 &&
                   preferred.expansion == nil,
                   "preferred inline hit must not query managed dictionaries")
        try expect(localQueryCount == 3, "local inline lookup is bounded to configured sources")

        let id = UUID()
        let pageID = UUID()
        let snapshot = syntheticInlineSnapshot("cardiology", kind: .word,
                                               pageID: pageID)
        var supplement = InlineLookupSupplement(
            supplementID: id, parentEntryID: pageID, selectionSnapshot: snapshot,
            quickResult: .word(local.quick!), expandedResult: nil,
            preparedLocalExpansion: local.expansion, localSource: local.quick?.source,
            aiProvider: nil, aiModel: nil, state: .success, generation: 1
        )
        let formatter = InlineLookupAttributedFormatter()
        let inlineLayout = InlineLayoutMetrics.calculate(
            textContainerWidth: 360, textViewWidth: 404, lineFragmentPadding: 5,
            pageInsetLeft: 22, pageInsetRight: 22
        )
        try expect(inlineLayout.isUsable && inlineLayout.availableWidth == 350 &&
                   inlineLayout.blockContentWidth == 324,
                   "inline width comes from text container, padding, and page insets")
        let quick = formatter.format(supplement, layout: inlineLayout)
        try expect(quick.string.contains("医学释义一") &&
                   !quick.string.contains("A local example") &&
                   !quick.string.contains("│") &&
                   quick.attribute(.inlineSupplementID, at: 1, effectiveRange: nil) != nil,
                   "initial word block is concise, uses real text-block styling, and is non-nestable")
        let quickTitleRange = (quick.string as NSString).range(of: "cardiology")
        let quickParagraph = quick.attribute(.paragraphStyle, at: quickTitleRange.location,
                                             effectiveRange: nil) as? NSParagraphStyle
        try expect(quickParagraph?.textBlocks.isEmpty == false,
                   "inline block uses NSTextBlock background and border instead of glyphs")
        let block = quickParagraph?.textBlocks.first
        try expect(quickParagraph?.headIndent == 0 && quickParagraph?.tailIndent == 0 &&
                   quickParagraph?.firstLineHeadIndent == 0 &&
                   quickParagraph?.tabStops.isEmpty == true &&
                   block?.contentWidth == inlineLayout.blockContentWidth &&
                   (block?.contentWidth ?? 0) >= InlineLayoutMetrics.minimumAvailableWidth,
                   "inline paragraphs reset inherited layout and block width exceeds minimum")

        let phraseSnapshot = syntheticInlineSnapshot(
            "a structure supporting or containing something", kind: .phrase,
            pageID: pageID
        )
        var actionCard = InlineLookupSupplement(
            supplementID: UUID(), parentEntryID: pageID,
            selectionSnapshot: phraseSnapshot, quickResult: nil,
            expandedResult: nil, preparedLocalExpansion: nil, localSource: nil,
            aiProvider: nil, aiModel: nil,
            state: .aiActionAvailable(localMiss: false), generation: 1
        )
        let actionText = formatter.format(actionCard, layout: inlineLayout).string
        try expect(actionText.contains("未点击不会联网") &&
                   !actionText.contains("AI 服务返回了空内容"),
                   "phrase selection presents an opt-in action without a failed AI result")
        let nativePhraseSnapshot = syntheticInlineSnapshot(
            "搞怪的墨镜", kind: .phrase, pageID: pageID
        )
        let nativePair = OfflineTranslationPair(
            source: .simplifiedChinese, target: .english
        )
        let nativeInlineOperation = InlineOfflineTranslationPlanner.operation(
            for: "搞怪的墨镜",
            preferences: .productionDefault
        )
        let swappedPreferences = LanguagePreferences(
            nativeLanguage: .english,
            learningLanguage: .simplifiedChinese,
            uiLanguage: .followNative
        )
        let swappedInlineOperation = InlineOfflineTranslationPlanner.operation(
            for: "quirky sunglasses",
            preferences: swappedPreferences
        )
        try expect(
            nativeInlineOperation == PlannedOfflineTranslation(
                outputRole: .learningVersion,
                pair: nativePair
            ) &&
                swappedInlineOperation == PlannedOfflineTranslation(
                    outputRole: .learningVersion,
                    pair: OfflineTranslationPair(
                        source: .english, target: .simplifiedChinese
                    )
                ) &&
                InlineOfflineTranslationPlanner.operation(
                    for: "quirky sunglasses",
                    preferences: .productionDefault
                ) == PlannedOfflineTranslation(
                    outputRole: .nativeVersion,
                    pair: OfflineTranslationPair(
                        source: .english, target: .simplifiedChinese
                    )
                ) &&
                InlineOfflineTranslationPlanner.automaticallyTranslates(
                    availability: .installed
                ) &&
                !InlineOfflineTranslationPlanner.automaticallyTranslates(
                    availability: .supportedNeedsDownload
                ),
            "inline Apple planner must follow Native/Learning roles and auto-run installed packs only"
        )
        let nativeAppleCard = InlineLookupSupplement(
            supplementID: UUID(), parentEntryID: pageID,
            selectionSnapshot: nativePhraseSnapshot, quickResult: nil,
            expandedResult: nil, preparedLocalExpansion: nil, localSource: nil,
            aiProvider: nil, aiModel: nil,
            offlineTranslationState: .translated(
                text: "quirky sunglasses", pair: nativePair
            ),
            state: .aiActionAvailable(localMiss: false), generation: 1
        )
        let nativeAppleText = formatter.format(
            nativeAppleCard, layout: inlineLayout
        ).string
        let appleRange = (nativeAppleText as NSString).range(
            of: "Apple 系统离线翻译（简体中文 → English）"
        )
        let translationRange = (nativeAppleText as NSString).range(
            of: "quirky sunglasses"
        )
        let aiOptInRange = (nativeAppleText as NSString).range(
            of: "可按需使用 AI 双语解释"
        )
        try expect(
            appleRange.location != NSNotFound &&
                translationRange.location > appleRange.location &&
                aiOptInRange.location > translationRange.location &&
                nativeAppleText.contains("来源：Apple 系统离线翻译"),
            "native inline card does not show installed Apple translation before AI opt-in"
        )
        var nativeNeedsPackCard = nativeAppleCard
        nativeNeedsPackCard.offlineTranslationState = .languagePackRequired(nativePair)
        let nativeNeedsPackText = formatter.format(
            nativeNeedsPackCard, layout: inlineLayout
        ).string
        try expect(
            nativeNeedsPackText.contains("语言包尚未准备") &&
                nativeNeedsPackText.contains("主动准备") &&
                nativeNeedsPackText.contains("未点击不会联网"),
            "inline language-pack state must remain explicit and keep AI opt-in"
        )
        var oneCard = [actionCard]
        oneCard[0].generation = 2
        oneCard[0].state = .loadingAI
        oneCard[0].state = .compactFailure("AI 本次未返回可显示内容")
        let failureText = formatter.format(oneCard[0], layout: inlineLayout).string
        try expect(oneCard.count == 1 &&
                   oneCard[0].supplementID == actionCard.supplementID &&
                   failureText.contains("AI 本次未返回可显示内容") &&
                   failureText.components(separatedBy: "\n").count <= 6 &&
                   !failureText.contains("AI 服务返回了空内容"),
                   "inline failure reuses one compact card")
        oneCard[0].generation = 3
        oneCard[0].state = .loadingAI
        oneCard[0].quickResult = .word(InlineWordQuickResult(
            partOfSpeech: "", definitions: ["支撑或容纳某物的结构"],
            source: "AI", providerDisplayName: "Mock AI", model: "mock",
            fromCache: false,
            learningEquivalent: "supporting structure",
            learningDefinition: "A structure that supports or contains something.",
            nativeExplanation: "强调其支撑或容纳功能。",
            exampleLearning: "The framework is a supporting structure.",
            exampleNative: "这个框架是一种支撑结构。"
        ))
        oneCard[0].state = .success
        let detailedAIText = formatter.format(oneCard[0], layout: inlineLayout).string
        try expect(oneCard.count == 1 &&
                   detailedAIText.contains("学习语言表达") &&
                   detailedAIText.contains("supporting structure") &&
                   detailedAIText.contains("母语核心释义") &&
                   detailedAIText.contains("学习语言释义") &&
                   detailedAIText.contains("用法说明") &&
                   detailedAIText.contains("这个框架是一种支撑结构"),
                   "failure-retry-success did not append a duplicate inline card")
        actionCard.generation = 4
        try expect(oneCard[0].generation != actionCard.generation,
                   "selection generation gate fixture did not reject a stale callback")

        let harbourSnapshot = syntheticInlineSnapshot("harbour", kind: .word, pageID: pageID)
        let harbour = InlineLookupSupplement(
            supplementID: UUID(), parentEntryID: pageID, selectionSnapshot: harbourSnapshot,
            quickResult: .word(InlineWordQuickResult(
                partOfSpeech: "noun", definitions: ["港口", "海港", "港湾"],
                source: "牛津高阶8", providerDisplayName: nil, model: nil, fromCache: false
            )), expandedResult: nil, preparedLocalExpansion: nil, localSource: "牛津高阶8",
            aiProvider: nil, aiModel: nil, state: .success, generation: 1
        )
        let harbourBlock = formatter.format(harbour, layout: inlineLayout)
        try expect(harbourBlock.string.contains("harbour\nnoun\n• 港口\n• 海港\n• 港湾") &&
                   harbourBlock.string.contains("来源：牛津高阶8"),
                   "harbour title, POS, three Chinese definitions, and source stay horizontal")
        var paragraphReset = true
        harbourBlock.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: harbourBlock.length)
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            paragraphReset = paragraphReset && style.firstLineHeadIndent == 0 &&
                style.headIndent == 0 && style.tailIndent == 0 && style.tabStops.isEmpty &&
                style.baseWritingDirection == .leftToRight
        }
        try expect(paragraphReset, "every inline paragraph has an independent reset style")
        let storage = NSTextStorage(attributedString: harbourBlock)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 360, height: 2_000))
        container.lineFragmentPadding = 5
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let harbourCharacters = (harbourBlock.string as NSString).range(of: "harbour")
        let harbourGlyphs = manager.glyphRange(forCharacterRange: harbourCharacters,
                                               actualCharacterRange: nil)
        var harbourLines = 0
        manager.enumerateLineFragments(forGlyphRange: harbourGlyphs) { _, _, _, line, _ in
            if NSIntersectionRange(line, harbourGlyphs).length > 0 { harbourLines += 1 }
        }
        try expect(harbourLines == 1,
                   "harbour lays out on one horizontal line at normal panel width")
        supplement.expandedResult = local.expansion.map(InlineLookupExpandedResult.local)
        let expanded = formatter.format(supplement, layout: inlineLayout).string
        try expect(expanded.contains("A local example") && expanded.contains("bio-：生命"),
                   "local more view uses prepared MDX expansion")

        let sentenceQuick = InlineSentenceQuickResult(
            translation: sampleSentenceAnalysis.translationZH,
            providerDisplayName: "Mock AI", model: "mock", fromCache: false
        )
        let sentencePageID = UUID()
        supplement = InlineLookupSupplement(
            supplementID: UUID(), parentEntryID: sentencePageID,
            selectionSnapshot: syntheticInlineSnapshot(sampleSentenceText, kind: .sentence,
                                                       pageID: sentencePageID),
            quickResult: .sentence(sentenceQuick), expandedResult: nil,
            preparedLocalExpansion: nil, localSource: nil, aiProvider: "Mock AI", aiModel: "mock",
            state: .success, generation: 1
        )
        let quickSentenceText = formatter.format(supplement, layout: inlineLayout).string
        try expect(quickSentenceText.contains(sampleSentenceAnalysis.translationZH) &&
                   !quickSentenceText.contains("句子主干"),
                   "initial sentence block contains translation only")
        supplement.expandedResult = .aiSentence(AISentenceAnalysisPresentation(
            analysis: sampleSentenceAnalysis, providerDisplayName: "Mock AI",
            model: "mock", fromCache: false
        ))
        let fullSentenceText = formatter.format(supplement, layout: inlineLayout).string
        try expect(fullSentenceText.components(separatedBy: sampleSentenceAnalysis.translationZH).count == 2 &&
                   fullSentenceText.contains("句子主干"),
                   "sentence expansion upgrades without duplicate translation")

        let resizedLayout = InlineLayoutMetrics.calculate(
            textContainerWidth: 456, textViewWidth: 500, lineFragmentPadding: 5,
            pageInsetLeft: 22, pageInsetRight: 22
        )
        try expect(resizedLayout.blockContentWidth > inlineLayout.blockContentWidth &&
                   InlineLookupAttributedFormatter().format(harbour, layout: resizedLayout)
                    .string == harbourBlock.string,
                   "resize recalculates display width without changing or re-querying content")

        let visible = NSRect(x: 0, y: 0, width: 360, height: 240)
        let buttonSize = NSSize(width: 52, height: 23)
        let wordRect = NSRect(x: 100, y: 100, width: 48, height: 18)
        let rightButton = InlineFloatingButtonLayout.place(
            buttonSize: buttonSize, selectionLineRects: [wordRect], visibleRect: visible
        )
        try expect(rightButton?.placement == .right &&
                   rightButton?.frame.intersects(wordRect) == false &&
                   visible.insetBy(dx: 8, dy: 8).contains(rightButton!.frame),
                   "word lookup button uses right-side whitespace without covering selection")
        let nearEdge = NSRect(x: 295, y: 100, width: 45, height: 18)
        let belowText = NSRect(x: 8, y: 124, width: 344, height: 24)
        let alternate = InlineFloatingButtonLayout.place(
            buttonSize: buttonSize, selectionLineRects: [nearEdge], visibleRect: visible,
            selectionLineUsedRects: [nearEdge], anchorBlockRect: nearEdge,
            occupiedTextRects: [nearEdge, belowText]
        )
        try expect(alternate?.placement == .above &&
                   alternate?.frame.intersects(nearEdge) == false,
                   "line-end selection falls back above when right side is insufficient")
        let multiline = [NSRect(x: 30, y: 80, width: 300, height: 18),
                         NSRect(x: 30, y: 100, width: 310, height: 18)]
        let translated = InlineFloatingButtonLayout.place(
            buttonSize: buttonSize, selectionLineRects: multiline, visibleRect: visible
        )
        try expect(translated?.placement == .below &&
                   multiline.allSatisfy { translated?.frame.intersects($0) == false },
                   "multiline translation button falls below the full selection")

        let crowded = [NSRect(x: 8, y: 124, width: 344, height: 28),
                       NSRect(x: 8, y: 68, width: 344, height: 24)]
        let actionRow = InlineFloatingButtonLayout.place(
            buttonSize: buttonSize, selectionLineRects: [nearEdge], visibleRect: visible,
            selectionLineUsedRects: [nearEdge], anchorBlockRect: nearEdge,
            occupiedTextRects: [nearEdge] + crowded
        )
        try expect(actionRow?.placement == .actionRow &&
                   ([nearEdge] + crowded).allSatisfy {
                       actionRow?.frame.intersects($0) == false
                   }, "crowded text uses an independent safe action row")
    }

    @MainActor
    private static func testInlineSelectionSnapshotsAndAnchors() async throws {
        let base = NSMutableAttributedString()
        func append(_ text: String, font: NSFont = .systemFont(ofSize: 13)) {
            base.append(NSAttributedString(string: text, attributes: [.font: font]))
        }
        append("section\n")
        append("sections  sectioned  sectioning\n")
        append("The shed comes in sections that you assemble yourself.\n",
               font: NSFontManager.shared.convert(.systemFont(ofSize: 13),
                                                  toHaveTrait: .italicFontMask))
        append("棚屋以组件形式提供，需要你自行组装。\n")
        append("A later paragraph mentions sections and section.\n")
        append("“Quoted”— /ˈsekʃn/ 中文不会改变 UTF-16 位置。\n")

        let blocks = InlineBaseBlockBuilder.build(from: base)
        let renderer = InlinePageRenderer()
        let pageID = UUID()
        let entryID = "word|section"
        let inlineLayout = InlineLayoutMetrics.calculate(
            textContainerWidth: 360, textViewWidth: 404, lineFragmentPadding: 5,
            pageInsetLeft: 22, pageInsetRight: 22
        )
        let initial = renderer.render(baseBlocks: blocks, supplements: [], layout: inlineLayout)
        let initialNSString = initial.string as NSString
        let assembleRange = initialNSString.range(of: "assemble")
        let snapshot = InlineSelectionSnapshotFactory.capture(
            from: initial, selectedRange: assembleRange,
            pageGenerationID: pageID, currentEntryID: entryID
        )
        try expect(snapshot?.selectedText == "assemble" &&
                   snapshot?.normalizedText == "assemble",
                   "UTF-16 selection snapshot captures assemble exactly")
        try expect(snapshot?.selectedText != "section" && snapshot?.selectedText != "ctions se",
                   "selection snapshot never substitutes adjacent main-entry text")
        let anchorBlock = blocks.first { $0.blockID == snapshot?.anchor.blockID }
        try expect(anchorBlock?.kind == .exampleWithTranslation &&
                   anchorBlock?.content.string.contains("棚屋以组件形式") == true,
                   "English example and following Chinese translation share a stable block")
        try expect(InlineSelectionSnapshotFactory.validate(
            snapshot!, in: initial, pageGenerationID: pageID, currentEntryID: entryID
        ), "unchanged UTF-16 snapshot validates before lookup")
        let changedPage = NSMutableAttributedString(attributedString: initial)
        changedPage.replaceCharacters(in: assembleRange, with: "sections")
        try expect(!InlineSelectionSnapshotFactory.validate(
            snapshot!, in: changedPage, pageGenerationID: pageID, currentEntryID: entryID
        ), "changed page text invalidates selection instead of querying adjacent content")

        var queried: [String] = []
        let localService = InlineLocalLookupService(sources: [
            InlineLocalLookupSource(name: "21世纪大英汉词典", priority: 1) { query in
                queried.append(query)
                guard query == "assemble" else { return nil }
                return InlineLocalDictionaryHit(
                    source: "21世纪大英汉词典", partOfSpeech: "v.",
                    chineseDefinitions: ["组装；装配；集合"], additionalDefinitions: [],
                    examples: ["assemble the parts"], collocations: [], inflections: [],
                    roots: [], isRootDictionary: false
                )
            }
        ], managedFallback: nil)
        let local = await localService.lookup(snapshot!.selectedText)
        try expect(queried == ["assemble"] && local.quick?.partOfSpeech == "v." &&
                   local.quick?.definitions == ["组装；装配；集合"],
                   "assemble local lookup preserves query, verb POS, and Chinese definition")

        let supplement = InlineLookupSupplement(
            supplementID: UUID(), parentEntryID: pageID, selectionSnapshot: snapshot!,
            quickResult: local.quick.map(InlineLookupQuickResult.word), expandedResult: nil,
            preparedLocalExpansion: local.expansion, localSource: local.quick?.source,
            aiProvider: nil, aiModel: nil, state: .success, generation: 1
        )
        let noteItem = InlineLookupMarkdownFormatter().items(from: [supplement]).first
        try expect(noteItem?.selectedText == "assemble" &&
                   noteItem?.normalizedText == "assemble",
                   "collection exports the immutable assemble selection snapshot")
        let rendered = renderer.render(baseBlocks: blocks, supplements: [supplement],
                                       layout: inlineLayout)
        let renderedText = rendered.string as NSString
        let english = renderedText.range(of: "The shed comes in sections")
        let chinese = renderedText.range(of: "棚屋以组件形式")
        let inlineTitle = renderedText.range(of: "assemble", options: [],
                                             range: NSRange(location: NSMaxRange(chinese),
                                                            length: renderedText.length -
                                                                NSMaxRange(chinese)))
        let later = renderedText.range(of: "A later paragraph")
        try expect(english.location < chinese.location && chinese.location < inlineTitle.location &&
                   inlineTitle.location < later.location,
                   "inline result is anchored after example translation, not page inflections")

        let sectionsRange = initialNSString.range(of: "sections", options: .backwards)
        let sectionRange = initialNSString.range(of: "section", options: .backwards)
        let sectionsSnapshot = InlineSelectionSnapshotFactory.capture(
            from: initial, selectedRange: sectionsRange,
            pageGenerationID: pageID, currentEntryID: entryID
        )
        let sectionSnapshot = InlineSelectionSnapshotFactory.capture(
            from: initial, selectedRange: sectionRange,
            pageGenerationID: pageID, currentEntryID: entryID
        )
        try expect(sectionsSnapshot?.selectedText == "sections" &&
                   sectionSnapshot?.selectedText == "section" &&
                   sectionsRange.location != sectionRange.location,
                   "adjacent UTF-16 ranges preserve sections and section independently")

        let unicodeRange = initialNSString.range(of: "/ˈsekʃn/")
        let unicodeSnapshot = InlineSelectionSnapshotFactory.capture(
            from: initial, selectedRange: unicodeRange,
            pageGenerationID: pageID, currentEntryID: entryID
        )
        try expect(unicodeSnapshot?.selectedText == "/ˈsekʃn/",
                   "curly quotes, em dash, IPA, and CJK do not shift UTF-16 selection")
        try expect(!InlineSelectionSnapshotFactory.validate(
            snapshot!, in: initial, pageGenerationID: UUID(), currentEntryID: entryID
        ), "page generation mismatch invalidates stale selection")

        let laterSnapshot = InlineSelectionSnapshotFactory.capture(
            from: rendered, selectedRange: (rendered.string as NSString).range(of: "sections",
                                                                                options: .backwards),
            pageGenerationID: pageID, currentEntryID: entryID
        )
        try expect(laterSnapshot?.selectedText == "sections",
                   "selection after an earlier supplement still maps to its base block")
        let second = InlineLookupSupplement(
            supplementID: UUID(), parentEntryID: pageID, selectionSnapshot: laterSnapshot!,
            quickResult: .word(InlineWordQuickResult(
                partOfSpeech: "noun", definitions: ["部分"], source: "本地",
                providerDisplayName: nil, model: nil, fromCache: false
            )), expandedResult: nil, preparedLocalExpansion: nil, localSource: "本地",
            aiProvider: nil, aiModel: nil, state: .success, generation: 1
        )
        let thirdSnapshot = syntheticInlineSnapshot("section", kind: .word, pageID: pageID,
                                                    blockID: blocks[0].blockID)
        let third = InlineLookupSupplement(
            supplementID: UUID(), parentEntryID: pageID, selectionSnapshot: thirdSnapshot,
            quickResult: .word(InlineWordQuickResult(
                partOfSpeech: "noun", definitions: ["章节"], source: "本地",
                providerDisplayName: nil, model: nil, fromCache: false
            )), expandedResult: nil, preparedLocalExpansion: nil, localSource: "本地",
            aiProvider: nil, aiModel: nil, state: .success, generation: 1
        )
        let three = renderer.render(baseBlocks: blocks, supplements: [supplement, second, third],
                                    layout: inlineLayout)
        try expect(three.string.components(separatedBy: "来源：").count == 4,
                   "three supplements remain independently anchored after re-render")
        try expect(InlineSelectionSnapshotFactory.capture(
            from: three,
            selectedRange: (three.string as NSString).range(of: "组装；装配；集合"),
            pageGenerationID: pageID, currentEntryID: entryID
        ) == nil, "inline result cannot create nested inline lookup")
    }

    private static func testCacheAndService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-AISmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AIExplanationCache(databaseURL: root.appendingPathComponent("cache.sqlite"))
        let suite = "LocalDictionary.AICacheSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults)
        var configuration = AIProviderConfiguration.zhipuPreset
        configuration.enabled = true
        configuration.baseURL = "https://mock.invalid/v1"
        configuration.model = "model-a"
        store.save(configuration)
        let client = StubClient(result: .success(sample))
        let service = AIExplanationService(configurationStore: store,
                                           keychain: StubKeychain("dummy-key"),
                                           cache: cache,
                                           clientFactory: { client })
        store.saveAutomaticSentenceAnalysisEnabled(true)
        let unavailableService = AIExplanationService(configurationStore: store,
                                                      keychain: StubKeychain(nil),
                                                      cache: cache,
                                                      clientFactory: { client })
        let unavailable = await unavailableService.availability()
        try expect(!unavailable.automaticSentenceAnalysisEnabled && !unavailable.isConfigured &&
                   client.sentenceCalls == 0,
                   "automatic sentence analysis remains disabled and performs no request")
        let first = try await service.explain(query: "Prompt", domain: "technology")
        try expect(!first.fromCache && client.calls == 1, "network result")
        client.result = .failure(AIClientError.offline)
        let cached = try await service.explain(query: "prompt", domain: "technology")
        try expect(cached.fromCache && client.calls == 1, "offline cache hit")

        client.sentenceResult = .success(sampleSentenceAnalysis)
        let firstSentence = try await service.analyzeSentence(sampleSentenceText)
        try expect(!firstSentence.fromCache && client.sentenceCalls == 1,
                   "sentence network result")
        let learningContext = LanguageContext.make(query: sampleSentenceText)
        let studyText = StudyText(text: sampleSentenceText, language: .english,
                                  origin: .originalQuery)!
        let gatedResult = try await service.analyzeStudyText(
            studyText, languageContext: learningContext
        )
        try expect(gatedResult.fromCache && client.sentenceCalls == 1,
                   "learning-language study text passed the hard gate and reused its cache")
        let nativeContext = LanguageContext.make(query: "写入完成后验证是否真正秒级结束。")
        let invalidStudyText = StudyText(
            text: "写入完成后验证是否真正秒级结束。",
            language: .simplifiedChinese,
            origin: .originalQuery
        )!
        do {
            _ = try await service.analyzeStudyText(
                invalidStudyText, languageContext: nativeContext, bypassCache: true
            )
            throw SmokeFailure.failed("native-language text crossed the AI study-language gate")
        } catch let error as AIClientError {
            try expect(error == .studyTextUnavailable(expected: .english) &&
                       client.sentenceCalls == 1,
                       "study-language mismatch reached the provider client")
        }
        client.sentenceResult = .failure(AIClientError.offline)
        let cachedSentence = try await service.analyzeSentence(sampleSentenceText)
        try expect(cachedSentence.fromCache && client.sentenceCalls == 1,
                   "sentence cache hit without network")
        client.translationResult = .success(sampleTextTranslation)
        let firstTranslation = try await service.translateText(sampleSentenceText)
        try expect(!firstTranslation.fromCache && client.translationCalls == 1,
                   "long-text translation network result")
        client.translationResult = .failure(AIClientError.offline)
        let cachedTranslation = try await service.translateText(sampleSentenceText)
        try expect(cachedTranslation.fromCache && client.translationCalls == 1 &&
                   cachedTranslation.result.translation == sampleTextTranslation.translation,
                   "long-text translation has an independent cache hit")
        let mixedSource = "所以如果 Evidence Candidate 的 Resource Center 里仍显示 " +
            "FreeDict，那才是 bug。"
        let mixedContext = LanguageContext.make(query: mixedSource)
        let nativeIdentity = AITranslationCacheIdentity(
            context: mixedContext, targetLanguage: .simplifiedChinese
        )
        let learningIdentity = AITranslationCacheIdentity(
            context: mixedContext, targetLanguage: .english
        )
        try expect(AIExplanationCache.textTranslationCacheKey(
            text: mixedSource, configuration: configuration, identity: nativeIdentity
        ) != AIExplanationCache.textTranslationCacheKey(
            text: mixedSource, configuration: configuration, identity: learningIdentity
        ), "AI translation cache identity omitted the explicit target language")
        try await cache.storeTextTranslation(
            AITextTranslation(sourceText: mixedSource,
                              translation: "这是旧方向的中文缓存。"),
            text: mixedSource, configuration: configuration, identity: nativeIdentity
        )
        client.translationResult = .success(AITextTranslation(
            sourceText: mixedSource,
            translation: "So if FreeDict is still shown in the Resource Center, that is a bug."
        ))
        let learningTranslation = try await service.translateText(
            mixedSource, targetLanguage: .english, languageContext: mixedContext
        )
        try expect(!learningTranslation.fromCache &&
                   learningTranslation.targetLanguage == .english,
                   "old native-target cache hit the new learning-target request")
        client.translationResult = .success(AITextTranslation(
            sourceText: mixedSource,
            translation: "所以，如果资源中心仍显示 FreeDict，那就是错误。"
        ))
        do {
            _ = try await service.translateText(
                mixedSource, targetLanguage: .english,
                languageContext: mixedContext, bypassCache: true
            )
            throw SmokeFailure.failed("wrong-target AI result entered the UI success path")
        } catch let failure as AIProviderRequestFailure {
            guard case .wrongTargetLanguage(expected: .english, actual: .simplifiedChinese) =
                    failure.underlying as? AIClientError else {
                throw SmokeFailure.failed("wrong-target AI result lost its typed rejection")
            }
        }
        try expect(AIExplanationCache.cacheKey(query: sampleSentenceText,
                                               configuration: configuration) !=
                   AIExplanationCache.sentenceCacheKey(sentence: sampleSentenceText,
                                                       configuration: configuration),
                   "word and sentence cache isolation")
        try expect(AIExplanationCache.textTranslationCacheKey(
                        text: sampleSentenceText, configuration: configuration
                   ) != AIExplanationCache.sentenceCacheKey(
                        sentence: sampleSentenceText, configuration: configuration
                   ), "translation and sentence-analysis cache isolation")

        configuration.model = "model-b"
        store.save(configuration)
        do {
            _ = try await service.explain(query: "prompt", domain: "technology")
            throw SmokeFailure.failed("old model cache reused")
        } catch let failure as AIProviderRequestFailure {
            try expect(failure.providerID == configuration.providerID &&
                       (failure.underlying as? AIClientError) == .offline,
                       "model cache isolation")
        }
        try await service.clearCache()
        configuration.model = "model-a"
        store.save(configuration)
        let cleared = try await cache.value(for: "prompt", configuration: configuration)
        try expect(cleared == nil,
                   "cache clear")
        let clearedSentence = try await cache.sentenceValue(for: sampleSentenceText,
                                                            configuration: configuration)
        try expect(clearedSentence == nil, "sentence cache clear")
        let clearedTranslation = try await cache.textTranslationValue(
            for: sampleSentenceText, configuration: configuration
        )
        try expect(clearedTranslation == nil, "text translation cache clear")
    }

    private static func testProviderFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-AIFallback-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        let store = AIConfigurationStore(defaults: defaults)
        var fallbackCatalog = AIProviderCatalog.builtIn
        fallbackCatalog.profiles[1].enabled = true
        fallbackCatalog.automaticFallbackEnabled = true
        try store.saveCatalog(fallbackCatalog)
        let google = AIProviderConfiguration.googlePreset
        let zhipu = AIProviderConfiguration.zhipuPreset
        let keychain = StubKeychain(values: [google.keychainAccount: "google-key",
                                             zhipu.keychainAccount: "zhipu-key"])
        let manager = AIProviderProfileManager(store: store, keychain: keychain)
        let client = StubClient(result: .failure(AIClientError.offline))
        client.resultsByProvider = [google.providerID: .failure(AIClientError.timeout),
                                    zhipu.providerID: .success(sample)]
        client.sentenceResultsByProvider = [
            google.providerID: .failure(AIClientError.rateLimited()),
            zhipu.providerID: .success(sampleSentenceAnalysis)
        ]
        let cache = AIExplanationCache(databaseURL: root.appendingPathComponent("cache.sqlite"))
        let service = AIExplanationService(configurationStore: store,
                                           keychain: keychain,
                                           cache: cache,
                                           profileManager: manager,
                                           clientFactory: { client })
        let result = try await service.explain(query: "fallback", domain: "general")
        try expect(result.providerDisplayName == "智谱 AI" && client.calls == 2 &&
                   client.requestedProviderIDs == [google.providerID, zhipu.providerID],
                   "Google failure falls back to Zhipu once")

        client.requestedProviderIDs.removeAll()
        let sentence = try await service.analyzeSentence(sampleSentenceText)
        try expect(sentence.providerDisplayName == "智谱 AI" && client.sentenceCalls == 2 &&
                   client.requestedProviderIDs == [google.providerID, zhipu.providerID],
                   "sentence provider fallback is ordered and non-duplicating")

        let callsBeforeCache = client.sentenceCalls
        client.sentenceResultsByProvider = [google.providerID: .failure(AIClientError.offline),
                                            zhipu.providerID: .failure(AIClientError.offline)]
        let cached = try await service.analyzeSentence(sampleSentenceText)
        try expect(cached.fromCache && cached.providerDisplayName == "智谱 AI" &&
                   client.sentenceCalls == callsBeforeCache + 1 &&
                   client.requestedProviderIDs.last == google.providerID,
                   "primary provider is tried before isolated fallback-provider cache")

        client.requestedProviderIDs.removeAll()
        client.resultsByProvider = [google.providerID: .failure(AIClientError.cancelled),
                                    zhipu.providerID: .success(sample)]
        do {
            _ = try await service.explain(query: "cancelled-query", domain: "general")
            throw SmokeFailure.failed("cancelled request fell through")
        } catch let failure as AIProviderRequestFailure {
            try expect((failure.underlying as? AIClientError) == .cancelled &&
                       client.requestedProviderIDs == [google.providerID],
                       "user cancellation never switches provider")
        }
    }

    private static func testSingleProviderConnectionSequence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-AIConnection-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        let store = AIConfigurationStore(defaults: defaults)
        try store.saveCatalog(.builtIn)
        let persistedBeforeTests = try store.loadCatalog()
        let google = AIProviderConfiguration.googlePreset
        let zhipu = AIProviderConfiguration.zhipuPreset
        let keychain = StubKeychain(values: [google.keychainAccount: "google-key",
                                             zhipu.keychainAccount: "zhipu-key"])
        let manager = AIProviderProfileManager(store: store, keychain: keychain)
        let client = StubClient(result: .success(sample))
        client.sentenceResult = .success(sampleSentenceAnalysis)
        let service = AIExplanationService(
            configurationStore: store,
            keychain: keychain,
            cache: AIExplanationCache(databaseURL: root.appendingPathComponent("cache.sqlite")),
            profileManager: manager,
            clientFactory: { client }
        )

        var googleDraft = google
        googleDraft.providerDisplayName = "Google Draft"
        googleDraft.baseURL = "https://draft.google.example/v1"
        googleDraft.model = "gemini-draft-model"

        client.connectionResult = .failure(AIClientError.unauthorized)
        do {
            try await service.testConnection(configuration: googleDraft,
                                             replacementKey: "window-google-key")
            throw SmokeFailure.failed("basic connection failure accepted")
        } catch let error as AIClientError {
            try expect(error == .unauthorized && client.sentenceCalls == 0,
                       "basic failure stops before sentence test")
        }

        client.connectionResult = .success(())
        client.sentenceResult = .failure(AIClientError.schemaInvalid(field: "translation_zh"))
        try await service.testConnection(configuration: googleDraft,
                                         replacementKey: "window-google-key")
        do {
            try await service.testSentenceFunction(configuration: googleDraft,
                                                   replacementKey: "window-google-key")
            throw SmokeFailure.failed("functional sentence failure accepted")
        } catch let error as AIClientError {
            try expect(error == .schemaInvalid(field: "translation_zh"),
                       "functional failure remains distinct from basic connection")
        }

        client.sentenceResult = .success(sampleSentenceAnalysis)
        try await service.testConnection(configuration: googleDraft,
                                         replacementKey: "window-google-key")
        try await service.testSentenceFunction(configuration: googleDraft,
                                               replacementKey: "window-google-key")
        client.result = .success(AIExplanation(
            headword: "下载", recommendedEnglishExpressions: ["download"],
            partsOfSpeech: [AIExplanationPartOfSpeech(
                partOfSpeech: "verb",
                senses: [AIExplanationSense(definitionEN: "Transfer data.",
                                             definitionZH: "传输数据。")]
            )]
        ))
        let report = try await service.testCompatibility(
            configuration: googleDraft, replacementKey: "window-google-key"
        )
        try expect(report.hasRecommendedEnglish &&
                   report.sentenceParseMode == .strictJSON &&
                   report.summary.contains("传输/模型") &&
                   report.summary.contains("句子解析"),
                   "compatibility report covers transport, recommendation, and sentence parsing")
        try expect(client.testedConfigurations.last?.providerID == google.providerID &&
                   client.testedConfigurations.last?.baseURL == googleDraft.normalizedBaseURL &&
                   client.testedConfigurations.last?.model == "gemini-draft-model" &&
                   client.sentenceConfigurations.last?.providerID == google.providerID,
                   "two-stage test uses current unsaved draft and one provider only")
        try expect(client.sentenceInputs.last ==
                   "Because it was raining, the match was postponed.",
                   "functional test uses the fixed minimal sentence")
        let persisted = try store.loadCatalog()
        try expect(persisted == persistedBeforeTests,
                   "connection tests never save draft configuration")
    }

    private static func testProviderSwitchRetryAndScopedCacheClear() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-AIProviderSwitch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        let store = AIConfigurationStore(defaults: defaults)
        var google = AIProviderConfiguration.googlePreset
        google.enabled = true
        let deepSeek = AIProviderConfiguration(
            providerID: UUID(), enabled: false, providerType: .openAICompatible,
            providerDisplayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", priority: 2
        )
        try store.saveCatalog(AIProviderCatalog(profiles: [google, deepSeek]))
        let keychain = StubKeychain(values: [google.keychainAccount: "google-key",
                                             deepSeek.keychainAccount: "deepseek-key"])
        let manager = AIProviderProfileManager(store: store, keychain: keychain)
        let client = StubClient(result: .failure(AIClientError.timeout))
        client.resultsByProvider[google.providerID] = .failure(AIClientError.timeout)
        client.resultsByProvider[deepSeek.providerID] = .success(sample)
        let cache = AIExplanationCache(databaseURL: root.appendingPathComponent("cache.sqlite"))
        let service = AIExplanationService(configurationStore: store, keychain: keychain,
                                           cache: cache, profileManager: manager,
                                           clientFactory: { client })

        do {
            _ = try await service.explain(query: "Tencent", domain: "general")
            throw SmokeFailure.failed("Google timeout accepted")
        } catch let failure as AIProviderRequestFailure {
            try expect(failure.providerID == google.providerID &&
                       (failure.underlying as? AIClientError) == .timeout,
                       "failure reports the actual Google provider and model")
        }

        var switchedGoogle = google
        switchedGoogle.enabled = false
        var switchedDeepSeek = deepSeek
        switchedDeepSeek.enabled = true
        switchedDeepSeek.priority = 1
        switchedGoogle.priority = 2
        try store.saveCatalog(AIProviderCatalog(profiles: [switchedDeepSeek, switchedGoogle]))
        client.requestedProviderIDs.removeAll()
        let switched = try await service.explain(query: "Tencent", domain: "general",
                                                 bypassCache: true)
        try expect(switched.providerID == deepSeek.providerID &&
                   switched.providerDisplayName == "DeepSeek" &&
                   client.requestedProviderIDs == [deepSeek.providerID],
                   "provider switch retry uses DeepSeek and cannot reuse Google state")

        let callsBeforeReload = client.calls
        _ = try await service.explain(query: "Tencent", domain: "general", bypassCache: true)
        try expect(client.calls == callsBeforeReload + 1,
                   "explicit re-query bypasses a successful cache")
        let hasDeepSeekCache = await service.hasCurrentCache(
            for: "Tencent", intent: .word, providerID: deepSeek.providerID
        )
        try expect(hasDeepSeekCache,
                   "successful response creates a scoped cache entry")
        try await service.clearCurrentCache(for: "Tencent", intent: .word,
                                            providerID: deepSeek.providerID)
        let hasCacheAfterClear = await service.hasCurrentCache(
            for: "Tencent", intent: .word, providerID: deepSeek.providerID
        )
        try expect(!hasCacheAfterClear,
                   "clear removes only the current query/provider/mode key")

        client.resultsByProvider[deepSeek.providerID] = .failure(AIClientError.invalidJSON)
        do {
            _ = try await service.explain(query: "invalid-result", domain: "general",
                                          bypassCache: true)
            throw SmokeFailure.failed("invalid response accepted")
        } catch {}
        let failureWasCached = await service.hasCurrentCache(
            for: "invalid-result", intent: .word, providerID: deepSeek.providerID
        )
        try expect(!failureWasCached,
                   "format and request failures are never cached")
    }

    private static func testFormatter() throws {
        let presentation = AIExplanationPresentation(explanation: sample,
                                                     providerDisplayName: "智谱 AI",
                                                     model: "glm-4.7-flash",
                                                     fromCache: false)
        let attributed = AIEntryFormatter().format(presentation)
        let rendered = attributed.string
        try expect(rendered.contains("AI 双语解释"), "AI title")
        try expect(rendered.contains("由 智谱 AI · glm-4.7-flash 生成"), "AI attribution")
        try expect(rendered.contains("促使行动的提示"), "Chinese definition")
        try expect(!rendered.contains("<") && !rendered.contains("Oxford"), "unsafe attribution")
        for substantiveText in ["A cue for action.", "常用于技术语境。",
                                "Enter a prompt.", "输入一条提示。", "system prompt"] {
            let range = (rendered as NSString).range(of: substantiveText)
            guard range.location != NSNotFound,
                  let color = attributed.attribute(
                    .foregroundColor, at: range.location, effectiveRange: nil
                  ) as? NSColor else {
                throw SmokeFailure.failed("missing attributed body text: \(substantiveText)")
            }
            try expect(color == .labelColor,
                       "substantive AI body text is not readable in DarkAqua: \(substantiveText)")
        }
    }

    @MainActor
    private static func testSafeCompatibilityMarkdownRendering() throws {
        let markdown = """
        ### 结构分析
        ### 关键表达 (Key Expressions) ###
        **结构分析**
        `五本` 与 *preferred*
        ---
        - 第一项
        1. 第二项
        <script>window.evil = true</script>
        ![remote](https://example.invalid/pixel.png)

        关键表达
        | 英语表达 | 中文含义 | 用法说明 |
        |:---|:---:|---:|
        | `do the hotspot test` | 做热点测试 | **hotspot test** 为固定搭配 |
        | first | 首先 | 祈使句中常放在句末；保留 escaped \\| pipe |
        """
        var analysis = sampleSentenceAnalysis
        analysis.responseParseMode = .compatibleJSON
        analysis.rawFallbackText = markdown
        let attributed = AISentenceEntryFormatter().format(
            AISentenceAnalysisPresentation(
                analysis: analysis, providerDisplayName: "DeepSeek",
                model: "compatible", fromCache: false
            )
        )
        let rendered = attributed.string
        try expect(!rendered.contains("兼容模式：") &&
                   !rendered.contains("服务返回内容不兼容") &&
                   rendered.contains("结构分析") &&
                   rendered.contains("关键表达 (Key Expressions)") &&
                   rendered.contains("五本") &&
                   rendered.contains("• 第一项") && rendered.contains("1. 第二项") &&
                   rendered.contains("────────────────") && rendered.contains("remote") &&
                   rendered.contains("英语表达：do the hotspot test") &&
                   rendered.contains("中文含义：做热点测试") &&
                   rendered.contains("用法说明：hotspot test 为固定搭配") &&
                   rendered.contains("用法说明：祈使句中常放在句末；保留 escaped | pipe"),
                   "readable compatibility Markdown was not rendered as a normal success")
        try expect(!rendered.contains("**") && !rendered.contains("`") &&
                   !rendered.contains("###") &&
                   !rendered.contains("|:---|") &&
                   !rendered.contains("<script") && !rendered.contains("window.evil") &&
                   !rendered.contains("https://"),
                   "compatible Markdown leaked source markers, HTML, or remote URL")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else {
                throw SmokeFailure.failed("missing appearance \(name.rawValue)")
            }
            appearance.performAsCurrentDrawingAppearance {
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
                view.appearance = appearance
                view.drawsBackground = true
                view.backgroundColor = .textBackgroundColor
                view.textStorage?.setAttributedString(attributed)
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
            }
        }
    }

    @MainActor
    private static func testLanguageSettingsWindow() throws {
        _ = NSApplication.shared
        let defaults = MemoryDefaults()
        let store = LanguagePreferencesStore(defaults: defaults)
        var english = LanguagePreferences.productionDefault
        english.uiLanguage = .english
        AppLocalization.configureAtLaunch(english)
        let englishController = LanguageSettingsWindowController(store: store)
        guard let content = englishController.window?.contentView,
              let native = findView("language-settings-native", in: content) as? NSPopUpButton,
              let learning = findView("language-settings-learning", in: content) as? NSPopUpButton,
              let ui = findView("language-settings-ui", in: content) as? NSPopUpButton,
              let save = findView("language-settings-save", in: content) as? NSButton else {
            throw SmokeFailure.failed("language settings did not expose all three AppKit controls")
        }
        try expect(englishController.window?.title == "Language Settings" &&
                   native.itemTitles == ["Simplified Chinese", "English"] &&
                   learning.itemTitles == ["Simplified Chinese", "English"] &&
                   ui.itemTitles == ["Follow Native Language", "Simplified Chinese", "English"],
                   "English UI language settings window")
        native.selectItem(at: 1)
        learning.selectItem(at: 0)
        ui.selectItem(at: 2)
        save.performClick(nil)
        let swapped = store.load()
        try expect(swapped.nativeLanguage == .english &&
                   swapped.learningLanguage == .simplifiedChinese &&
                   swapped.uiLanguage == .english,
                   "two-language role swap was not persisted by the real settings controller")

        AppLocalization.configureAtLaunch(.productionDefault)
        let chineseController = LanguageSettingsWindowController(store: store)
        try expect(chineseController.window?.title == "语言设置",
                   "Simplified Chinese settings window did not localize after relaunch")
    }

    @MainActor
    private static func findView(_ accessibilityID: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == accessibilityID { return root }
        for subview in root.subviews {
            if let found = findView(accessibilityID, in: subview) { return found }
        }
        return nil
    }

    private static func testTolerantWordExplanationSchema() throws {
        let tencent = Data(#"""
        {
          "headword":"Tencent",
          "entryType":"proper_noun",
          "definitions":[{"zh":"腾讯，一家中国科技公司。","en":"A Chinese technology company."}]
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(AIExplanation.self, from: tencent)
            .validated(fallbackHeadword: "Tencent")
        try expect(decoded.pronunciations.isEmpty &&
                   decoded.partsOfSpeech.first?.partOfSpeech == "专有名词" &&
                   decoded.partsOfSpeech.first?.senses.first?.definitionZH.contains("腾讯") == true,
                   "proper-name response succeeds without pronunciation or explicit POS")

        let missingOptional = Data(#"""
        {
          "headword":"example",
          "parts_of_speech":[{"senses":[{"definition_zh":"示例"}]}]
        }
        """#.utf8)
        let optionalDecoded = try JSONDecoder().decode(AIExplanation.self, from: missingOptional)
            .validated(fallbackHeadword: "example")
        try expect(optionalDecoded.pronunciations.isEmpty &&
                   optionalDecoded.partsOfSpeech.first?.partOfSpeech.isEmpty == true,
                   "missing optional pronunciation and part-of-speech fields default safely")

        let singlePronunciation = Data(#"{"headword":"Tencent","pronunciations":"","definitions":[{"zh":"腾讯公司"}]}"#.utf8)
        let singlePronunciationDecoded = try JSONDecoder().decode(
            AIExplanation.self, from: singlePronunciation
        ).validated(fallbackHeadword: "tencent")
        try expect(singlePronunciationDecoded.pronunciations.isEmpty,
                   "an empty scalar pronunciation cannot invalidate a useful definition")

        let suggestion = Data(#"{"headword":"teh","spelling_suggestions":["the"]}"#.utf8)
        let suggestionDecoded = try JSONDecoder().decode(AIExplanation.self, from: suggestion)
            .validated(fallbackHeadword: "teh")
        try expect(suggestionDecoded.partsOfSpeech.isEmpty &&
                   suggestionDecoded.spellingSuggestions == ["the"],
                   "spelling suggestion is a displayable result")

        do {
            _ = try JSONDecoder().decode(AIExplanation.self,
                                         from: Data(#"{"headword":"empty"}"#.utf8))
                .validated(fallbackHeadword: "empty")
            throw SmokeFailure.failed("empty word explanation accepted")
        } catch let error as AIClientError {
            try expect(error == .invalidResponse, "empty response remains invalid")
        }
    }

    @MainActor
    private static func testEnglishWordChineseDefinitionPriority() throws {
        for query in ["download", "culture", "validation", "pharmacokinetics"] {
            let explanation = try AIExplanation(
                headword: query,
                pronunciations: ["/fixture/"],
                partsOfSpeech: [AIExplanationPartOfSpeech(
                    partOfSpeech: "noun / verb",
                    senses: [AIExplanationSense(
                        definitionEN: "English definition for \(query).",
                        definitionZH: "\(query) 的中文核心释义。",
                        usageNoteZH: "用于合成方向与字段顺序回归。",
                        examples: [AIExplanationExample(
                            en: "A synthetic English example.",
                            zh: "一条合成中文例句。"
                        )]
                    )]
                )]
            ).validated(fallbackHeadword: query)
            let rendered = AIEntryFormatter().format(AIExplanationPresentation(
                explanation: explanation, providerDisplayName: "Synthetic",
                model: "fixture", fromCache: false
            )).string as NSString
            let headword = rendered.range(of: query)
            let pronunciation = rendered.range(of: "/fixture/")
            let partOfSpeech = rendered.range(of: "noun / verb")
            let chinese = rendered.range(of: "中文核心释义")
            let english = rendered.range(of: "English definition")
            let nativeLabel = rendered.range(of: "母语核心意思")
            let learningLabel = rendered.range(of: "学习语言释义")
            try expect(headword.location != NSNotFound &&
                       pronunciation.location > headword.location &&
                       partOfSpeech.location > pronunciation.location &&
                       nativeLabel.location > partOfSpeech.location &&
                       chinese.location > partOfSpeech.location &&
                       learningLabel.location > chinese.location &&
                       english.location > chinese.location,
                       "\(query) did not render headword/pronunciation/POS/Chinese/English in order")
        }
    }

    @MainActor
    private static func testChineseRecommendedEnglishSchemaAndRendering() throws {
        let fixtures: [(query: String, primary: String, alternatives: [String])] = [
            ("下载", "download", []),
            ("文化", "culture", []),
            ("提交", "submit", ["submission"]),
            ("验证", "verify", ["validation"]),
            ("药代动力学", "pharmacokinetics", [])
        ]
        for fixture in fixtures {
            let object: [String: Any] = [
                "headword": fixture.query,
                "recommended_english_expressions": [fixture.primary] + fixture.alternatives,
                "parts_of_speech": [[
                    "part_of_speech": fixture.alternatives.isEmpty ? "verb" : "verb / noun",
                    "senses": [[
                        "definition_en": "A concise English definition.",
                        "definition_zh": "简明中文解释。",
                        "usage_note_zh": "按实际词性选择表达。",
                        "examples": [["en": "Synthetic example.", "zh": "合成例句。"]]
                    ]]
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let explanation = try JSONDecoder().decode(AIExplanation.self, from: data)
                .validated(fallbackHeadword: fixture.query)
            try expect(explanation.recommendedEnglishExpressions.first == fixture.primary,
                       "\(fixture.query) primary English expression")
            let attributed = AIEntryFormatter().format(AIExplanationPresentation(
                explanation: explanation, providerDisplayName: "Synthetic",
                model: "fixture", fromCache: false
            ))
            let rendered = attributed.string
            let primaryRange = (rendered as NSString).range(of: fixture.primary)
            let posRange = (rendered as NSString).range(of: "verb")
            let definitionRange = (rendered as NSString).range(of: "A concise")
            try expect(primaryRange.location != NSNotFound &&
                       primaryRange.location < posRange.location &&
                       primaryRange.location < definitionRange.location,
                       "\(fixture.query) English expression is not at the top")
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                guard let appearance = NSAppearance(named: name) else {
                    throw SmokeFailure.failed("missing appearance \(name.rawValue)")
                }
                appearance.performAsCurrentDrawingAppearance {
                    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
                    view.appearance = appearance
                    view.drawsBackground = true
                    view.backgroundColor = .textBackgroundColor
                    view.textStorage?.setAttributedString(attributed)
                    view.layoutManager?.ensureLayout(for: view.textContainer!)
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                    }
                }
                var missingDynamicColor = false
                attributed.enumerateAttribute(
                    .foregroundColor, in: NSRange(location: 0, length: attributed.length)
                ) { value, _, stop in
                    guard let color = value as? NSColor,
                          color.type == .catalog || color.alphaComponent == 0 else {
                        missingDynamicColor = true
                        stop.pointee = true
                        return
                    }
                }
                try expect(!missingDynamicColor,
                           "Chinese AI result contains a fixed/missing foreground color")
            }
        }

        let missing = Data(#"""
        {
          "headword":"下载",
          "parts_of_speech":[{"part_of_speech":"verb","senses":[{"definition_zh":"获取文件"}]}]
        }
        """#.utf8)
        do {
            _ = try JSONDecoder().decode(AIExplanation.self, from: missing)
                .validated(fallbackHeadword: "下载")
            throw SmokeFailure.failed("Chinese response without recommended English accepted")
        } catch let error as AIClientError {
            try expect(error == .schemaInvalid(field: "recommended_english_expressions"),
                       "Chinese response missing English has wrong schema error")
        }
    }

    private static func testSentenceFormatterAndGenerationGate() throws {
        let presentation = AISentenceAnalysisPresentation(
            analysis: sampleSentenceAnalysis,
            providerDisplayName: "智谱 AI",
            model: "glm-4.7-flash",
            fromCache: false
        )
        let rendered = AISentenceEntryFormatter().format(presentation).string
        for heading in ["AI 句子解析", "学习对象：English · 解释语言：简体中文",
                        "原句", "自然翻译", "句子主干",
                        "分句与修饰关系", "重点语法", "搭配与句型",
                        "难点表达", "简化改写", "学习提示"] {
            try expect(rendered.contains(heading), "sentence formatter section \(heading)")
        }
        try expect(rendered.contains(sampleSentenceText) &&
                   rendered.contains(sampleSentenceAnalysis.translationZH) &&
                   rendered.contains("Although A, B."), "sentence formatter mapping")
        try expect(!rendered.contains("<") && !rendered.contains("Oxford"),
                   "sentence formatter safe attribution")

        var gate = AIQueryGenerationGate()
        let sentenceA = gate.beginQuery()
        let sentenceB = gate.beginQuery()
        try expect(!gate.accepts(sentenceA) && gate.accepts(sentenceB),
                   "old sentence response cannot overwrite new query")
        _ = gate.beginQuery()
        try expect(!gate.accepts(sentenceB), "cancellation invalidates response generation")

        var operationGate = AISentenceOperationGate()
        for index in 0..<50 {
            let sentenceID = "sentence-\(index % 5)"
            let operation = operationGate.begin(sentenceID: sentenceID)
            if index.isMultiple(of: 7) {
                let retry = operationGate.begin(sentenceID: sentenceID)
                try expect(!operationGate.accepts(operation) &&
                           operationGate.accepts(retry),
                           "retry did not supersede only its sentence")
                try expect(operationGate.finish(retry),
                           "retry operation did not finish")
            } else {
                let sibling = operationGate.begin(sentenceID: "sibling-\(index)")
                try expect(operationGate.accepts(operation) &&
                           operationGate.accepts(sibling),
                           "sibling sentence operation was globally replaced")
                try expect(operationGate.finish(operation) &&
                           operationGate.finish(sibling),
                           "independent sentence operation did not finish")
            }
        }
        try expect(operationGate.activeCount == 0,
                   "50-operation sentence stress leaked active ownership")

        var duplicate = sampleSentenceAnalysis
        duplicate.rawFallbackText = duplicate.translationZH
        let deduplicated = AISentenceEntryFormatter().format(
            AISentenceAnalysisPresentation(
                analysis: duplicate, providerDisplayName: "DeepSeek",
                model: "plain", fromCache: false
            )
        ).string
        try expect(!deduplicated.contains("AI 返回的非结构化内容"),
                   "identical raw fallback was displayed twice")
    }

    private static func testRequestLifecycleAndUserMessages() throws {
        var lifecycle = AIRequestLifecycle()
        let success = lifecycle.begin()
        try expect(lifecycle.isLoading && lifecycle.finish(success) && !lifecycle.isLoading,
                   "successful production request exits loading")

        for error in [AIClientError.timeout, .invalidJSON, .cancelled] {
            let token = lifecycle.begin()
            try expect(lifecycle.isLoading, "failed production request enters loading")
            _ = AIRequestUserMessage.message(for: error)
            try expect(lifecycle.finish(token) && !lifecycle.isLoading,
                       "timeout, parse failure, and cancellation exit loading")
        }

        let old = lifecycle.begin()
        let retry = lifecycle.begin()
        try expect(!lifecycle.finish(old) && lifecycle.isLoading,
                   "late old response cannot end the active retry")
        try expect(lifecycle.finish(retry) && !lifecycle.isLoading,
                   "active retry owns its terminal state")

        let timeout = AIRequestUserMessage.message(for: AIClientError.timeout)
        let offline = AIRequestUserMessage.message(for: AIClientError.offline)
        let schema = AIRequestUserMessage.message(for: AIClientError.schemaInvalid(field: "x"))
        try expect(timeout.contains("超时") && timeout.contains("网络") &&
                   offline.contains("网络") && schema.contains("格式") && schema.contains("更换"),
                   "AI failures expose safe actionable guidance")
        try expect(!schema.contains("x") && !schema.contains("{") && !schema.contains("/Users/"),
                   "user-visible format errors hide internal fields and paths")
    }

    private static func testLocalSentenceGlossary() async throws {
        let century21: [String: LocalGlossaryLookupResult] = [
            "statistically significant": .init(partOfSpeech: "adjective",
                                                definitions: ["统计学上显著的"],
                                                source: "21世纪大英汉词典"),
            "imply": .init(partOfSpeech: "verb", definitions: ["暗示；意味着"],
                           source: "21世纪大英汉词典"),
            "develop": .init(partOfSpeech: "verb", definitions: ["开发；发展"],
                             source: "21世纪大英汉词典"),
            "finding": .init(partOfSpeech: "noun", definitions: ["研究结果；发现"],
                             source: "21世纪大英汉词典"),
            "cardiovascular risk": .init(partOfSpeech: "noun",
                                          definitions: ["心血管风险"],
                                          source: "21世纪大英汉词典"),
            "gut microbiota": .init(partOfSpeech: "noun", definitions: ["肠道微生物群"],
                                    source: "21世纪大英汉词典")
        ]
        let medical: [String: LocalGlossaryLookupResult] = [
            "clinically meaningful": .init(partOfSpeech: "adjective",
                                            definitions: ["具有临床意义的"],
                                            source: "英中医学辞海"),
            "associated with": .init(partOfSpeech: "phrase",
                                      definitions: ["与……相关"],
                                      source: "英中医学辞海"),
            "diabetes": .init(partOfSpeech: "noun", definitions: ["糖尿病"],
                              source: "英中医学辞海")
        ]
        let oxford: [String: LocalGlossaryLookupResult] = [
            "hypothesis": .init(partOfSpeech: "noun", definitions: ["假说；假设"],
                                source: "牛津高阶 8"),
            "treatment": .init(partOfSpeech: "noun", definitions: ["治疗"],
                               source: "牛津高阶 8"),
            "relapse": .init(partOfSpeech: "noun", definitions: ["复发"],
                             source: "牛津高阶 8")
        ]
        let service = LocalSentenceGlossaryService(sources: [
            .init(name: "21世纪大英汉词典", priority: 1) { century21[$0] },
            .init(name: "英中医学辞海", priority: 2) { medical[$0] },
            .init(name: "牛津高阶 8", priority: 3) { oxford[$0] }
        ], managedFallback: nil)
        let sentences = [
            sampleSentenceText,
            "The drug, which was initially developed to treat diabetes, was later found to reduce cardiovascular risk.",
            "Because I smoke every day, my lungs are in poor health.",
            "Researchers have suggested that the observed effect may be associated with changes in gut microbiota.",
            "Not only did the treatment improve symptoms, but it also reduced the risk of relapse.",
            "“If the hypothesis is correct,” the author argues, “the findings could change how the disease is treated.”"
        ]
        var allEntries: [LocalSentenceGlossaryEntry] = []
        for sentence in sentences {
            let glossary = await service.analyze(sentence: sentence)
            try expect(glossary.entries.count <= LocalSentenceGlossaryService.maximumEntries,
                       "local glossary result limit")
            try expect(glossary.candidateQueryCount <=
                       LocalSentenceGlossaryService.maximumCandidateQueries,
                       "local glossary query limit")
            try expect(!glossary.entries.contains { ["the", "a", "an", "of", "to", "and"]
                .contains($0.surface.lowercased()) }, "local glossary stopword filtering")
            allEntries += glossary.entries
        }
        try expect(allEntries.contains { $0.lookupTerm == "statistically significant" },
                   "longest useful phrase is preferred")
        try expect(allEntries.contains { $0.lookupTerm == "clinically meaningful" },
                   "medical phrase lookup")
        try expect(allEntries.contains { $0.surface.lowercased() == "developed" &&
                                         $0.lookupTerm == "develop" },
                   "developed lemma fallback")
        try expect(allEntries.contains { $0.surface.lowercased() == "findings" &&
                                         $0.lookupTerm == "finding" },
                   "findings lemma fallback")
        try expect(LocalSentenceGlossaryFormatter().format(
            LocalSentenceGlossary(sourceText: sampleSentenceText,
                                  entries: Array(allEntries.prefix(2)),
                                  candidateQueryCount: 1)
        ).string.contains("不代表完整句子翻译"), "offline disclaimer")
    }

    private static func testAINoteExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-AINoteSmoke-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LocalDictionary.AINoteSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ObsidianNoteStore(defaults: defaults)
        let presentation = AIExplanationPresentation(explanation: sample,
                                                     providerDisplayName: "智谱 AI",
                                                     model: "glm-4.7-flash",
                                                     fromCache: false)
        let section = AIExplanationMarkdownFormatter().section(for: presentation,
                                                               headword: "prompt")
        try expect(section.markdown.contains("### AI 双语解释"), "AI Markdown heading")
        try expect(section.markdown.contains("> 由 智谱 AI · glm-4.7-flash 生成"),
                   "AI attribution")
        try expect(section.markdown.contains("#### noun") &&
                   section.markdown.contains("**促使行动的提示。**") &&
                   section.markdown.contains("英文定义：A cue for action.") &&
                   section.markdown.contains("例句：Enter a prompt.") &&
                   section.markdown.contains("译文：输入一条提示。") &&
                   section.markdown.contains("常见搭配：system prompt"),
                   "AI Markdown structure")
        try expect(!section.markdown.contains("mock.invalid") &&
                   !section.markdown.contains("dummy-key") &&
                   !section.markdown.contains("{\""), "AI Markdown private fields")
        let misleading = AIExplanationPresentation(explanation: sample,
                                                   providerDisplayName: "Oxford AI",
                                                   model: "mock-model",
                                                   fromCache: false)
        let safeAttribution = AIExplanationMarkdownFormatter().section(for: misleading)
        try expect(!safeAttribution.markdown.lowercased().contains("oxford") &&
                   safeAttribution.markdown.contains("自定义 AI 服务"),
                   "AI Markdown cannot impersonate Oxford")

        let local = StructuredDictionaryEntry(headword: "prompt",
                                              phonetics: ["/prɒmpt/"],
                                              partsOfSpeech: ["noun"],
                                              definitions: ["提示"],
                                              examples: ["The prompt appeared."],
                                              source: "牛津高阶 8")
        let localOnly = VocabularyNoteSaveContent(headword: "prompt",
                                                  localEntry: local,
                                                  aiSection: nil)
        let localOnlyURL = root.appendingPathComponent("local-only.md")
        try Data().write(to: localOnlyURL)
        let localOnlyResult = try store.save(localOnly, to: localOnlyURL)
        try expect(localOnlyResult == .localSaved,
                   "local-only save")
        let localOnlyText = try String(contentsOf: localOnlyURL, encoding: .utf8)
        try expect(localOnlyText.contains("### 牛津高阶 8") &&
                   !localOnlyText.contains("### AI 双语解释"), "unchecked excludes AI")

        let roleAware = VocabularyNoteSaveContent(
            headword: "prompt", localEntry: local, aiSection: nil,
            languageMetadata: FavoriteLanguageMetadata(
                sourceLanguage: .english,
                nativeLanguage: .simplifiedChinese,
                learningLanguage: .english,
                studyLanguage: nil
            )
        )
        let roleAwareURL = root.appendingPathComponent("role-aware.md")
        try Data().write(to: roleAwareURL)
        _ = try store.save(roleAware, to: roleAwareURL)
        let roleAwareText = try String(contentsOf: roleAwareURL, encoding: .utf8)
        try expect(roleAwareText.contains(
            "<!-- LocalDictionary-Language source=en; native=zh-Hans; learning=en; study=none -->"
        ), "new favorite omitted backward-compatible language-role metadata")

        let combined = VocabularyNoteSaveContent(headword: "prompt",
                                                 localEntry: local,
                                                 aiSection: section)
        let combinedURL = root.appendingPathComponent("combined.md")
        try Data().write(to: combinedURL)
        let combinedResult = try store.save(combined, to: combinedURL)
        try expect(combinedResult == .savedWithAI,
                   "local plus AI save")
        let combinedText = try String(contentsOf: combinedURL, encoding: .utf8)
        try expect(exactHeading("## prompt", in: combinedText) == 1 &&
                   exactHeading("### AI 双语解释", in: combinedText) == 1,
                   "combined headings")

        let noSelection = VocabularyNoteSaveContent(headword: "prompt",
                                                    localEntry: nil,
                                                    aiSection: nil)
        do {
            _ = try store.save(noSelection, to: combinedURL)
            throw SmokeFailure.failed("AI-only unchecked save accepted")
        } catch let error as ObsidianNoteStoreError {
            try expect(error == .invalidEntry, "AI-only unchecked blocked")
        }

        let aiOnly = VocabularyNoteSaveContent(headword: "prompt",
                                               localEntry: nil,
                                               aiSection: section)
        let aiOnlyURL = root.appendingPathComponent("ai-only.md")
        try Data().write(to: aiOnlyURL)
        let aiOnlyResult = try store.save(aiOnly, to: aiOnlyURL)
        try expect(aiOnlyResult == .savedWithAI,
                   "AI-only checked save")
        let aiOnlyText = try String(contentsOf: aiOnlyURL, encoding: .utf8)
        try expect(aiOnlyText.hasPrefix("## prompt\n\n### AI 双语解释") &&
                   !aiOnlyText.contains("### 牛津高阶 8"), "AI-only Markdown")

        let newlyCreatedURL = root.appendingPathComponent("new-ai-note.md")
        let createResult = try store.createOrSave(aiOnly, at: newlyCreatedURL)
        try expect(createResult == .savedWithAI &&
                   FileManager.default.fileExists(atPath: newlyCreatedURL.path),
                   "new AI-only note creation")

        let existingURL = root.appendingPathComponent("existing.md")
        let existing = ObsidianNoteStore.markdownBlock(for: local, newline: "\n") +
            "\n## another\n\nKeep this entry."
        try Data(existing.utf8).write(to: existingURL)
        let augmentedResult = try store.save(combined, to: existingURL)
        try expect(augmentedResult == .aiAddedToExistingEntry,
                   "append AI to existing entry")
        let augmented = try String(contentsOf: existingURL, encoding: .utf8)
        let aiRange = augmented.range(of: "### AI 双语解释")!
        let nextRange = augmented.range(of: "## another")!
        try expect(aiRange.lowerBound < nextRange.lowerBound &&
                   exactHeading("## prompt", in: augmented) == 1 &&
                   exactHeading("### 牛津高阶 8", in: augmented) == 1,
                   "AI inserted in matching entry range")
        let beforeDuplicate = try Data(contentsOf: existingURL)
        let duplicateResult = try store.save(combined, to: existingURL)
        try expect(duplicateResult == .aiAlreadyPresent,
                   "existing AI section result")
        let afterDuplicate = try Data(contentsOf: existingURL)
        try expect(afterDuplicate == beforeDuplicate,
                   "existing AI section preserved")

        let fencedURL = root.appendingPathComponent("fenced.md")
        let fenced = "## prompt\n\n```markdown\n### AI 双语解释\n```\n"
        try Data(fenced.utf8).write(to: fencedURL)
        let fencedSaveResult = try store.save(aiOnly, to: fencedURL)
        try expect(fencedSaveResult == .aiAddedToExistingEntry,
                   "code fence AI heading ignored")
        let fencedResult = try String(contentsOf: fencedURL, encoding: .utf8)
        try expect(exactHeading("### AI 双语解释", in: fencedResult) == 2,
                   "real AI heading appended after code fence")

        let crlfURL = root.appendingPathComponent("crlf.md")
        let crlf = ObsidianNoteStore.markdownBlock(for: local, newline: "\r\n")
        try Data(crlf.utf8).write(to: crlfURL)
        _ = try store.save(combined, to: crlfURL)
        let crlfResult = try String(contentsOf: crlfURL, encoding: .utf8)
        try expect(!crlfResult.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                   "AI preserves CRLF")
        try expect(exactHeading("## prompt", in: crlfResult) == 1,
                   "CRLF entry range does not duplicate heading")

        let readOnlyURL = root.appendingPathComponent("read-only.md")
        let readOnlyData = Data("## prompt\n\nDo not change.\n".utf8)
        try readOnlyData.write(to: readOnlyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: readOnlyURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: readOnlyURL.path) }
        do {
            _ = try store.save(combined, to: readOnlyURL)
            throw SmokeFailure.failed("read-only AI save accepted")
        } catch let error as ObsidianNoteStoreError {
            try expect(error == .targetNotWritable, "read-only AI save blocked")
        }
        let readOnlyAfter = try Data(contentsOf: readOnlyURL)
        try expect(readOnlyAfter == readOnlyData,
                   "read-only note undamaged")

        let cached = AIExplanationPresentation(explanation: sample,
                                               providerDisplayName: "智谱 AI",
                                               model: "glm-4.7-flash",
                                               fromCache: true)
        try expect(AIExplanationMarkdownFormatter().section(for: cached,
                                                            headword: "prompt") == section,
                   "cached result exports identically")
        let networkProbe = StubClient(result: .failure(AIClientError.offline))
        try expect(networkProbe.calls == 0, "note export performs no provider request")
    }

    private static func testSentenceNoteExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-SentenceNoteSmoke-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LocalDictionary.SentenceNoteSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ObsidianNoteStore(defaults: defaults)
        let presentation = AISentenceAnalysisPresentation(
            analysis: sampleSentenceAnalysis,
            providerDisplayName: "智谱 AI",
            model: "glm-4.7-flash",
            fromCache: false
        )
        let glossary = LocalSentenceGlossary(
            sourceText: sampleSentenceText,
            entries: [
                LocalSentenceGlossaryEntry(surface: "statistically significant",
                                           lookupTerm: "statistically significant",
                                           partOfSpeech: "adjective",
                                           definitions: ["统计学上显著的"],
                                           source: "21世纪大英汉词典",
                                           isPhrase: true),
                LocalSentenceGlossaryEntry(surface: "imply", lookupTerm: "imply",
                                           partOfSpeech: "verb",
                                           definitions: ["暗示；意味着"],
                                           source: "牛津高阶 8",
                                           isPhrase: false)
            ],
            candidateQueryCount: 8
        )
        let formatter = SentenceAnalysisMarkdownFormatter()
        let combined = formatter.content(sourceText: sampleSentenceText,
                                         aiPresentation: presentation,
                                         glossary: glossary)!
        try expect(combined.title.hasPrefix("句子解析｜") &&
                   !combined.title.contains("#") && combined.title.hasSuffix("…"),
                   "safe truncated sentence title")
        let combinedURL = root.appendingPathComponent("combined.md")
        try Data().write(to: combinedURL)
        let combinedResult = try store.save(combined, to: combinedURL)
        try expect(combinedResult == .saved,
                   "sentence AI and glossary save")
        let combinedText = try String(contentsOf: combinedURL, encoding: .utf8)
        try expect(combinedText.contains("### 原句") &&
                   combinedText.contains("### AI 解析") &&
                   combinedText.contains("### 本地词语参考") &&
                   combinedText.contains("AI 生成：智谱 AI · glm-4.7-flash") &&
                   !combinedText.contains("mock.invalid") &&
                   !combinedText.contains("API Key"), "sentence Markdown sections")
        try expect(ObsidianNoteStore.containsSentence(in: combinedText,
                                                      sourceText: sampleSentenceText),
                   "sentence blockquote duplicate detection")
        let beforeDuplicate = try Data(contentsOf: combinedURL)
        let duplicateResult = try store.save(combined, to: combinedURL)
        try expect(duplicateResult == .aiAlreadyPresent,
                   "sentence duplicate with AI")
        let afterDuplicate = try Data(contentsOf: combinedURL)
        try expect(afterDuplicate == beforeDuplicate,
                   "sentence duplicate does not change file")

        let localOnly = formatter.content(sourceText: sampleSentenceText,
                                          aiPresentation: nil,
                                          glossary: glossary)!
        let localURL = root.appendingPathComponent("local.md")
        try Data().write(to: localURL)
        let localResult = try store.save(localOnly, to: localURL)
        try expect(localResult == .saved,
                   "local glossary only sentence save")
        let localDuplicate = try store.save(localOnly, to: localURL)
        try expect(localDuplicate == .alreadySaved,
                   "local-only sentence duplicate")
        let augmented = try store.save(combined, to: localURL)
        try expect(augmented == .aiAddedToExistingSentence,
                   "AI added to existing local sentence")
        let augmentedText = try String(contentsOf: localURL, encoding: .utf8)
        try expect(exactHeading("## \(combined.title)", in: augmentedText) == 1 &&
                   exactHeading("### AI 解析", in: augmentedText) == 1 &&
                   exactHeading("### 本地词语参考", in: augmentedText) == 1 &&
                   augmentedText.range(of: "### AI 解析")!.lowerBound <
                    augmentedText.range(of: "### 本地词语参考")!.lowerBound,
                   "AI supplements existing entry before local glossary")

        let fencedURL = root.appendingPathComponent("fenced.md")
        let fenced = "## fake\n\n```markdown\n### 原句\n> \(sampleSentenceText)\n```\n"
        try Data(fenced.utf8).write(to: fencedURL)
        let fencedResult = try store.save(localOnly, to: fencedURL)
        try expect(fencedResult == .saved,
                   "fenced original sentence ignored")

        let crlfURL = root.appendingPathComponent("crlf-sentence.md")
        try Data("Existing\r\n\r\n".utf8).write(to: crlfURL)
        _ = try store.save(localOnly, to: crlfURL)
        let crlf = try String(contentsOf: crlfURL, encoding: .utf8)
        try expect(!crlf.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                   "sentence save preserves CRLF")

        let createdURL = root.appendingPathComponent("created.md")
        let createResult = try store.createOrSave(localOnly, at: createdURL)
        try expect(createResult == .saved,
                   "new sentence note creation")
        try store.rememberTarget(createdURL)
        let currentContains = try store.contains(sentence: sampleSentenceText)
        try expect(currentContains,
                   "sentence star state uses current note")
        let networkProbe = StubClient(result: .failure(AIClientError.offline))
        _ = formatter.content(sourceText: sampleSentenceText,
                              aiPresentation: presentation,
                              glossary: glossary)
        _ = try store.save(combined, to: combinedURL)
        try expect(networkProbe.calls == 0 && networkProbe.sentenceCalls == 0,
                   "sentence collection performs no provider request")
    }

    private static func testInlineLookupNoteExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictionary-InlineNote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("inline.md")
        try Data().write(to: url)
        let store = ObsidianNoteStore()
        let local = StructuredDictionaryEntry(headword: "prompt", phonetics: [],
                                              partsOfSpeech: ["noun"],
                                              definitions: ["提示"], examples: [],
                                              source: "牛津高阶 8")
        let quick = InlineLookupNoteItem(
            selectedText: "compound", normalizedText: "compound", kind: "word",
            quickLines: ["- 简释：化合物；复合物"], expandedLines: [],
            source: "英中医学辞海", provider: nil, model: nil
        )
        let content = VocabularyNoteSaveContent(headword: "prompt", localEntry: local,
                                                aiSection: nil,
                                                inlineSupplements: [quick])
        _ = try store.save(content, to: url)
        let first = try String(contentsOf: url, encoding: .utf8)
        try expect(exactHeading("### 应用内划词补充", in: first) == 1 &&
                   exactHeading("#### compound", in: first) == 1 &&
                   first.contains("- 类型：word") &&
                   first.contains("- 选中内容：compound") &&
                   !first.contains("supplementID") && !first.contains("<!--"),
                   "inline supplement exports readable Markdown without technical IDs")

        let beforeDuplicate = try Data(contentsOf: url)
        _ = try store.save(content, to: url)
        let afterDuplicate = try Data(contentsOf: url)
        try expect(afterDuplicate == beforeDuplicate,
                   "duplicate inline quick supplement is not appended")

        let expanded = InlineLookupNoteItem(
            selectedText: "compound", normalizedText: "compound", kind: "word",
            quickLines: quick.quickLines,
            expandedLines: ["- 例句：The compound was isolated.", "- 搭配：chemical compound"],
            source: quick.source, provider: nil, model: nil
        )
        let expandedContent = VocabularyNoteSaveContent(
            headword: "prompt", localEntry: local, aiSection: nil,
            inlineSupplements: [expanded]
        )
        _ = try store.save(expandedContent, to: url)
        let augmented = try String(contentsOf: url, encoding: .utf8)
        try expect(exactHeading("#### compound", in: augmented) == 1 &&
                   exactHeading("##### 了解更多", in: augmented) == 1 &&
                   augmented.contains("The compound was isolated."),
                   "later collection fills expansion without duplicate quick block")

        let sentenceItem = InlineLookupNoteItem(
            selectedText: sampleSentenceText, normalizedText: sampleSentenceText,
            kind: "sentence", quickLines: ["- 中文翻译：自然中文翻译。"],
            expandedLines: [], source: "", provider: "Mock AI", model: "mock-model"
        )
        let sentenceContent = SentenceNoteSaveContent(
            sourceText: "This parent sentence contains enough words to be analyzed.",
            title: "句子解析｜This parent sentence…", aiSectionMarkdown: nil,
            glossarySectionMarkdown: nil, inlineSupplements: [sentenceItem]
        )
        let sentenceURL = root.appendingPathComponent("sentence-inline.md")
        try Data().write(to: sentenceURL)
        _ = try store.save(sentenceContent, to: sentenceURL)
        let sentenceText = try String(contentsOf: sentenceURL, encoding: .utf8)
        try expect(sentenceText.contains("### 原句") &&
                   sentenceText.contains("### 应用内划词补充") &&
                   sentenceText.contains("- AI 来源：Mock AI · mock-model"),
                   "sentence parent exports only already generated inline AI content")
    }

    private static func exactHeading(_ heading: String, in content: String) -> Int {
        content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { $0 == heading }
            .count
    }
}
