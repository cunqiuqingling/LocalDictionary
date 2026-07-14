import AppKit
import Foundation

private enum SmokeFailure: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.failed(message) }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class StubKeychain: AIKeychainStoring {
    var value: String?
    init(_ value: String?) { self.value = value }
    func readKey(account: String) async throws -> String? { value }
    func storeKey(_ key: String, account: String) async throws { value = key }
    func deleteKey(account: String) async throws { value = nil }
}

private final class StubClient: AIProviderClient {
    var calls = 0
    var sentenceCalls = 0
    var result: Result<AIExplanation, Error>
    var sentenceResult: Result<AISentenceAnalysis, Error> = .failure(AIClientError.offline)
    init(result: Result<AIExplanation, Error>) { self.result = result }
    func explain(query: String, domain: String,
                 configuration: AIProviderConfiguration, apiKey: String) async throws -> AIExplanation {
        calls += 1
        return try result.get()
    }
    func analyzeSentence(_ sentence: String,
                         configuration: AIProviderConfiguration,
                         apiKey: String) async throws -> AISentenceAnalysis {
        sentenceCalls += 1
        return try sentenceResult.get()
    }
    func testConnection(configuration: AIProviderConfiguration, apiKey: String) async throws {}
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

@main
private struct AIServiceSmoke {
    static func main() async throws {
        try testQueryIntentAndNormalization()
        try testConfigurationAndUserDefaults()
        if ProcessInfo.processInfo.environment["LOCALDICTIONARY_SKIP_KEYCHAIN_SMOKE"] != "1" {
            try await testKeychain()
        }
        try await testClientAndErrors()
        try await testCacheAndService()
        try testFormatter()
        try testSentenceFormatterAndGenerationGate()
        try await testLocalSentenceGlossary()
        try testAINoteExport()
        try testSentenceNoteExport()
        print("AI service smoke: PASS")
    }

    private static func testQueryIntentAndNormalization() throws {
        try expect(QueryIntentClassifier.classify("prompt").intent == .word,
                   "single word intent")
        try expect(QueryIntentClassifier.classify("machine learning").intent == .phrase,
                   "short phrase intent")
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
        try expect(QueryIntentClassifier.classify(String(repeating: "a", count: 801)).intent == .textTooLong,
                   "character safety limit")
        try expect(QueryIntentClassifier.classify("First sentence. Second sentence. Third sentence. Fourth sentence.").intent == .textTooLong,
                   "sentence count safety limit")
        try expect(QueryIntentClassifier.classify("First sentence.\n\nSecond paragraph.").intent == .textTooLong,
                   "multiple paragraphs safety limit")
        try expect(QueryIntentClassifier.classify("这是一个主要为中文的句子。英文很少").intent == .textTooLong,
                   "mostly non-English safety limit")
    }

    private static func testConfigurationAndUserDefaults() throws {
        let preset = AIProviderConfiguration.zhipuPreset
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
        store.save(saved)
        let secret = "test-secret-must-not-enter-defaults"
        try expect(!defaults.dictionaryRepresentation().values.contains {
            String(describing: $0).contains(secret)
        }, "API key leaked to UserDefaults")
        try expect(store.load() == saved, "configuration round trip")
    }

    private static func testKeychain() async throws {
        let keychain = AIKeychainStore(service: "LocalDictionary.AISmoke.\(UUID().uuidString)")
        let account = UUID().uuidString
        defer { Task { try? await keychain.deleteKey(account: account) } }
        try await keychain.storeKey("dummy-test-key-one", account: account)
        let first = try await keychain.readKey(account: account)
        try expect(first == "dummy-test-key-one",
                   "keychain insert/read")
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
            try expect(requestText.contains(sampleSentenceText), "sentence source sent")
            try expect(!requestText.contains("Obsidian") &&
                       !requestText.contains("/Users/") &&
                       !requestText.contains("牛津高阶"), "sentence request excludes local data")
            let body = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
            try expect(body["max_tokens"] as? Int == 2_600,
                       "sentence response budget")
            return (200, try sentenceEnvelope(sampleSentenceAnalysis))
        }
        let sentenceResult = try await client.analyzeSentence(sampleSentenceText,
                                                              configuration: configuration,
                                                              apiKey: "dummy-key")
        try expect(sentenceResult == sampleSentenceAnalysis,
                   "sentence strict JSON decode")

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
            try expect(error == .invalidResponse, "sentence invalid JSON rejected")
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
            try expect(error == .invalidResponse, "connection response validation")
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
                                   (429, AIClientError.quotaExceeded),
                                   (500, AIClientError.serverError)] {
            MockURLProtocol.handler = { _ in (status, Data("{}".utf8)) }
            do {
                _ = try await client.explain(query: "prompt", domain: "general",
                                             configuration: custom, apiKey: "dummy-key")
                throw SmokeFailure.failed("HTTP \(status) did not fail")
            } catch let error as AIClientError {
                try expect(error == expected, "HTTP \(status) mapping")
            }
        }
        MockURLProtocol.handler = { _ in
            let invalid = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "not json"]]]
            ])
            return (200, invalid)
        }
        do {
            _ = try await client.explain(query: "prompt", domain: "general",
                                         configuration: custom, apiKey: "dummy-key")
            throw SmokeFailure.failed("invalid JSON accepted")
        } catch let error as AIClientError {
            try expect(error == .invalidResponse, "invalid JSON mapping")
        }
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
        try expect(unavailable.automaticSentenceAnalysisEnabled && !unavailable.isConfigured &&
                   client.sentenceCalls == 0,
                   "automatic sentence analysis with no key performs no request")
        let first = try await service.explain(query: "Prompt", domain: "technology")
        try expect(!first.fromCache && client.calls == 1, "network result")
        client.result = .failure(AIClientError.offline)
        let cached = try await service.explain(query: "prompt", domain: "technology")
        try expect(cached.fromCache && client.calls == 1, "offline cache hit")

        client.sentenceResult = .success(sampleSentenceAnalysis)
        let firstSentence = try await service.analyzeSentence(sampleSentenceText)
        try expect(!firstSentence.fromCache && client.sentenceCalls == 1,
                   "sentence network result")
        client.sentenceResult = .failure(AIClientError.offline)
        let cachedSentence = try await service.analyzeSentence(sampleSentenceText)
        try expect(cachedSentence.fromCache && client.sentenceCalls == 1,
                   "sentence cache hit without network")
        try expect(AIExplanationCache.cacheKey(query: sampleSentenceText,
                                               configuration: configuration) !=
                   AIExplanationCache.sentenceCacheKey(sentence: sampleSentenceText,
                                                       configuration: configuration),
                   "word and sentence cache isolation")

        configuration.model = "model-b"
        store.save(configuration)
        do {
            _ = try await service.explain(query: "prompt", domain: "technology")
            throw SmokeFailure.failed("old model cache reused")
        } catch let error as AIClientError {
            try expect(error == .offline, "model cache isolation")
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
    }

    private static func testFormatter() throws {
        let presentation = AIExplanationPresentation(explanation: sample,
                                                     providerDisplayName: "智谱 AI",
                                                     model: "glm-4.7-flash",
                                                     fromCache: false)
        let rendered = AIEntryFormatter().format(presentation).string
        try expect(rendered.contains("AI 双语解释"), "AI title")
        try expect(rendered.contains("由 智谱 AI · glm-4.7-flash 生成"), "AI attribution")
        try expect(rendered.contains("促使行动的提示"), "Chinese definition")
        try expect(!rendered.contains("<") && !rendered.contains("Oxford"), "unsafe attribution")
    }

    private static func testSentenceFormatterAndGenerationGate() throws {
        let presentation = AISentenceAnalysisPresentation(
            analysis: sampleSentenceAnalysis,
            providerDisplayName: "智谱 AI",
            model: "glm-4.7-flash",
            fromCache: false
        )
        let rendered = AISentenceEntryFormatter().format(presentation).string
        for heading in ["AI 句子解析", "原句", "自然翻译", "句子主干",
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
        ])
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
                   section.markdown.contains("**A cue for action.**") &&
                   section.markdown.contains("中文释义：促使行动的提示。") &&
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

    private static func exactHeading(_ heading: String, in content: String) -> Int {
        content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { $0 == heading }
            .count
    }
}
