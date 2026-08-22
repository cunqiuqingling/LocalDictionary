import AppKit
import Foundation
import SQLite3

private enum SmokeFailure: Error {
    case failed(String)
}

private final class LanguageMemoryDefaults: LanguagePreferencesPersisting {
    var values: [String: Any] = [:]
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw SmokeFailure.failed(message) }
}

private func renderingContrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat? {
    guard let first = foreground.usingColorSpace(.deviceRGB),
          let second = background.usingColorSpace(.deviceRGB) else { return nil }
    func luminance(_ color: NSColor) -> CGFloat {
        func component(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * component(color.redComponent) +
            0.7152 * component(color.greenComponent) +
            0.0722 * component(color.blueComponent)
    }
    let a = luminance(first)
    let b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private final class LockedCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private actor MockTranslationEngine: OfflineTranslationEngine {
    private(set) var translationCalls = 0
    private(set) var preparationCalls = 0
    var status: OfflineTranslationAvailability = .installed

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { status }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        translationCalls += 1
        return requests.reversed().map {
            let translated = $0.pair.target == .simplifiedChinese
                ? "[zh-Hans] 合成翻译结果"
                : "[en] synthetic translated result"
            return OfflineTranslationResponse(
                id: $0.id, sourceText: $0.sourceText,
                translatedText: translated,
                pair: $0.pair
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        preparationCalls += 1
    }
}

private actor WaitingPreparationEngine: OfflineTranslationEngine {
    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .supportedNeedsDownload }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] { [] }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private actor SelectiveFailureTranslationEngine: OfflineTranslationEngine {
    let failedTarget: OfflineTranslationLanguage
    private var hasInjectedFailure = false

    init(failedTarget: OfflineTranslationLanguage) {
        self.failedTarget = failedTarget
    }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        guard let pair = requests.first?.pair else { return [] }
        if pair.target == failedTarget, !hasInjectedFailure {
            hasInjectedFailure = true
            throw OfflineTranslationError.deadlineExceeded(.translation)
        }
        return requests.map { request in
            OfflineTranslationResponse(
                id: request.id, sourceText: request.sourceText,
                translatedText: pair.target == .english
                    ? "This is a valid English learning version."
                    : "这是有效的简体中文版本。",
                pair: pair, outputRole: request.outputRole
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}
}

/// Reproduces the real mixed Chinese-side batch shape: one Chinese-dominant row is echoed while
/// another row has a valid translation. The pipeline must retain the valid row instead of marking
/// the complete Chinese version unavailable.
private actor MixedChineseSideEchoEngine: OfflineTranslationEngine {
    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        requests.map { request in
            let translated: String
            if request.pair.target == .simplifiedChinese,
               request.sourceText.contains("build fails") {
                translated = request.sourceText
            } else if request.pair.target == .simplifiedChinese {
                translated = "这是另一句有效的简体中文译文。"
            } else {
                translated = "This is a valid English version."
            }
            return OfflineTranslationResponse(
                id: request.id, sourceText: request.sourceText,
                translatedText: translated, pair: request.pair,
                outputRole: request.outputRole
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}
}

/// Mirrors the latest real Evidence: Apple accepts an IPA/POS glossary request but the Chinese
/// operation returns an English-dominant normalized glossary. The pipeline must keep the valid
/// English side and recover only the Chinese side from glosses already present in the selection.
private actor IPAGlossaryWrongTargetEngine: OfflineTranslationEngine {
    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        requests.map { request in
            OfflineTranslationResponse(
                id: request.id, sourceText: request.sourceText,
                translatedText: request.pair.target == .simplifiedChinese
                    ? "Rule out. Exclude indigenous. Local. Make permanent. Larva."
                    : "Rule out; indigenous; perpetuate; larva.",
                pair: request.pair, outputRole: request.outputRole
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}
}

private actor NeverReturningTranslationEngine: OfflineTranslationEngine {
    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}
}

private actor ColdInstalledTranslationEngine: OfflineTranslationEngine {
    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        try await Task.sleep(for: .seconds(6))
        return requests.map {
            OfflineTranslationResponse(
                id: $0.id, sourceText: $0.sourceText,
                translatedText: "cold-start-complete", pair: $0.pair
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}
}

private actor RetryingColdInstalledTranslationEngine: OfflineTranslationEngine {
    private(set) var calls = 0

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability { .installed }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        calls += 1
        if calls == 1 { try await Task.sleep(for: .milliseconds(90)) }
        return requests.map {
            OfflineTranslationResponse(
                id: $0.id, sourceText: $0.sourceText,
                translatedText: "fresh-session-complete", pair: $0.pair
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {}
}

private actor MockGlossary: TranslationGlossaryService {
    func evidence(for term: String, language: QueryLanguage) async
        -> TranslationGlossaryEvidence? {
        TranslationGlossaryEvidence(
            suggestion: language == .english ? "合成释义" : "synthetic expression",
            source: term.contains("clinical") ? "合成医学词典" : "合成双语词典",
            professional: term.contains("clinical")
        )
    }
}

private actor WrongBrazilGlossary: TranslationGlossaryService {
    func evidence(for term: String, language: QueryLanguage) async
        -> TranslationGlossaryEvidence? {
        guard term.caseInsensitiveCompare("Brazil") == .orderedSame else { return nil }
        return TranslationGlossaryEvidence(
            suggestion: "巴西木；红色染料", source: "合成错误第一义", professional: false
        )
    }
}

private func makeForwardDictionaryFixture() -> LocalSentenceGlossaryService {
    let definitions: [String: String] = [
        "attractive": "有吸引力的",
        "complicated": "复杂的",
        "tuition": "学费",
        "guarantee": "保证",
        "proposal": "提议",
        "response": "回应",
        "capable": "有能力的",
        "exclude": "排除",
        "learner": "学习者"
    ]

    return LocalSentenceGlossaryService(sources: [
        LocalGlossaryDictionarySource(name: "合成成熟正向词典", priority: 0) { term in
            guard let definition = definitions[term.lowercased()] else { return nil }
            return LocalGlossaryLookupResult(
                partOfSpeech: "",
                definitions: [definition],
                source: "合成成熟正向词典"
            )
        }
    ], managedFallback: nil)
}

@main
private struct OfflineLanguageSmoke {
    static func main() async throws {
        try testLanguagePreferencesAndContext()
        try testStudyTextRouting()
        try await Task { @MainActor in try testUILocalization() }.value
        try testRouting()
        try await testTranslationAndLongText()
        try await testMixedFailureIsolation()
        try await testAppleDeadlineAndLocalBasicFallback()
        try await testInstalledColdTranslationDeadline()
        try await testHeavyWorkSerialization()
        try await testWaitingApplePreparationCancellation()
        try await testForwardVocabularyFixture()
        try await testProperNounVocabularyPrecision()
        try await testReverseLookup()
        try await testLargeReverseWriterLifecycle()
        try testBasicAnalysis()
        try testSegmentationPerformance()
        try testSelectionPlacement()
        print("OfflineLanguageSmoke PASS")
    }

    private static func testLanguagePreferencesAndContext() throws {
        let defaults = LanguageMemoryDefaults()
        let store = LanguagePreferencesStore(defaults: defaults)
        try expect(store.load() == .productionDefault,
                   "missing language preferences did not migrate to zh-Hans/en/followNative")
        var englishUI = LanguagePreferences.productionDefault
        englishUI.uiLanguage = .english
        try expect(store.save(englishUI) && store.load() == englishUI,
                   "language preference persistence")
        var unsupported = englishUI
        unsupported.learningLanguage = .german
        try expect(!store.save(unsupported) && store.load() == englishUI,
                   "not-production-ready language pair became selectable")

        let english = LanguageContext.make(
            classification: QueryIntentClassifier.classify("culture"),
            preferences: .productionDefault
        )
        try expect(english.queryRelation == .learning &&
                   english.translationTargetLanguage == .simplifiedChinese &&
                   english.studyTextLanguage == .english &&
                   english.explanationLanguage == .simplifiedChinese,
                   "learning-language context routing")
        let chinese = LanguageContext.make(
            classification: QueryIntentClassifier.classify("文化"),
            preferences: .productionDefault
        )
        try expect(chinese.queryRelation == .native &&
                   chinese.translationTargetLanguage == .english &&
                   chinese.studyTextLanguage == .english,
                   "native-language context routing")
        let nativeWithEnglishExplanation = LanguageContext.make(
            classification: QueryIntentClassifier.classify("你听说过她的名字吗？"),
            preferences: .productionDefault,
            explanationLanguage: .english
        )
        let nativeDefaultPlan = OfflineTranslationPlan.make(context: LanguageContext.make(
            classification: QueryIntentClassifier.classify("你听说过她的名字吗？"),
            preferences: .productionDefault
        ))
        try expect(nativeWithEnglishExplanation.explanationLanguage == .english &&
                   OfflineTranslationPlan.make(context: nativeWithEnglishExplanation) ==
                    nativeDefaultPlan &&
                   nativeWithEnglishExplanation.offlineTranslationPair ==
                    OfflineTranslationPair(source: .simplifiedChinese, target: .english),
                   "Explanation Language leaked into OfflineTranslationPair")
        let mixedNativeText =
            "所以如果 Evidence Candidate 的 Resource Center 里还看到 FreeDict 正常作为可安装资源，那才是 bug"
        let mixed = LanguageContext.make(
            classification: QueryIntentClassifier.classify(mixedNativeText),
            preferences: .productionDefault
        )
        try expect(mixed.queryRelation == .mixedNativeDominant &&
                   mixed.dominantLanguage == .simplifiedChinese &&
                   mixed.translationTargetLanguage == .english &&
                   mixed.offlineTranslationPair == OfflineTranslationPair(
                    source: .simplifiedChinese, target: .english
                   ), "Chinese-dominant mixed query direction regressed")
        let mixedPlan = OfflineTranslationPlan.make(context: mixed)
        try expect(mixedPlan?.kind == .mixedBidirectional &&
                   mixedPlan?.operations.count == 2 &&
                   Set(mixedPlan?.operations.map(\.pair.target) ?? []) ==
                    Set([.english, .simplifiedChinese]),
                   "mixed native-dominant input did not plan two targets")
        let mixedLearningText =
            "If the Resource Center 还是 shows FreeDict as installable, that is a bug."
        let mixedLearning = LanguageContext.make(
            classification: QueryIntentClassifier.classify(mixedLearningText),
            preferences: .productionDefault
        )
        try expect(mixedLearning.queryRelation == .mixedLearningDominant &&
                   mixedLearning.dominantLanguage == .english &&
                   mixedLearning.translationTargetLanguage == .simplifiedChinese &&
                   mixedLearning.offlineTranslationPair == OfflineTranslationPair(
                    source: .english, target: .simplifiedChinese
                   ), "English-dominant mixed query direction regressed")
        let reversePlan = OfflineTranslationPlan.make(context: mixedLearning)
        try expect(reversePlan?.kind == .mixedBidirectional &&
                   reversePlan?.operations.count == 2,
                   "mixed learning-dominant input did not plan two targets")
        let unknown = LanguageContext.make(query: "12345 -- ???")
        try expect(OfflineTranslationPlan.make(context: unknown)?.kind ==
                    .unknownBidirectional,
                   "unknown input did not choose bounded bidirectional routing")

        let noOp = TranslationResultValidator.validate(
            source: mixedNativeText, result: mixedNativeText,
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english)
        )
        try expect(noOp.noOpTranslation && noOp.resultLanguage == .simplifiedChinese,
                   "mixed Apple source echo was accepted as translation")
        let translated = TranslationResultValidator.validate(
            source: mixedNativeText,
            result: "Therefore, if FreeDict is still shown as installable in the Resource Center of the Evidence Candidate, that is a bug.",
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english)
        )
        try expect(!translated.noOpTranslation && translated.resultLanguage == .english,
                   "valid mixed translation with product names was rejected")
        let wrongTarget = TranslationResultValidator.validate(
            source: mixedNativeText,
            result: "所以，如果资源中心仍显示 FreeDict，那就是错误。",
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english)
        )
        try expect(wrongTarget.wrongTargetLanguage,
                   "Chinese-dominant result was accepted for target=en")
        let properName = TranslationResultValidator.validate(
            source: "FreeDict", result: "FreeDict",
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        )
        try expect(!properName.noOpTranslation,
                   "unchanged standalone technical name was treated as a failed sentence")
        let shortChineseEcho = TranslationResultValidator.validate(
            source: "苹果", result: "苹果",
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english)
        )
        try expect(shortChineseEcho.noOpTranslation,
                   "short Chinese Apple echo was accepted as an English translation")
        let shortEnglishEcho = TranslationResultValidator.validate(
            source: "apple", result: "apple",
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        )
        try expect(shortEnglishEcho.noOpTranslation,
                   "short English Apple echo was accepted as a Chinese translation")
        let nativePassthrough = TranslationResultValidator.validate(
            source: "你先做热点测试，别同时改 VPN、DNS 和 Codex。",
            result: "你先做热点测试，别同时改 VPN、DNS 和 Codex。",
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        )
        try expect(nativePassthrough.targetLanguagePassthrough &&
                   !nativePassthrough.noOpTranslation &&
                   !nativePassthrough.wrongTargetLanguage,
                   "mixed native-side target-language passthrough was rejected")
        let bilingualGlossary =
            "abuzz |ə'bʌz| a. 嗡嗡响的；peer |pɪə| n. 同龄人；rigidly adv. 严格地"
        let glossaryPassthrough = TranslationResultValidator.validate(
            source: bilingualGlossary, result: bilingualGlossary,
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        )
        try expect(glossaryPassthrough.targetLanguagePassthrough &&
                   !glossaryPassthrough.noOpTranslation,
                   "bilingual glossary row made the mixed Chinese version unavailable")
        let glossarySegments = LongTextSegmenter.segment(bilingualGlossary)
        try expect(glossarySegments.count == 1 &&
                   glossarySegments[0].sourceText == bilingualGlossary,
                   "POS abbreviations split a bilingual glossary away from its Chinese glosses")
        let copiedIPAGlossary =
            "rule out vt. 排除 indigenous |ɪnˈdɪdʒɪnəs| a. 当地的，本地的 " +
            "perpetuate |pəˈpetʃueɪt| vt. 使永久 larva |ˈlɑːvə| n. 幼虫 pl. larvae"
        let copiedGlossarySegments = LongTextSegmenter.segment(copiedIPAGlossary)
        try expect(copiedGlossarySegments.count == 1 &&
                   copiedGlossarySegments[0].sourceText == copiedIPAGlossary,
                   "space-separated IPA/POS glossary was split into unrelated Apple operations")
        let copiedGlossaryNative = TranslationResultValidator.validate(
            source: copiedIPAGlossary, result: copiedIPAGlossary,
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        )
        try expect(copiedGlossaryNative.targetLanguagePassthrough &&
                   !copiedGlossaryNative.noOpTranslation &&
                   !copiedGlossaryNative.wrongTargetLanguage,
                   "valid bilingual IPA glossary was rejected as an unavailable Chinese version")
        let untranslatedEnglishClause =
            "这次请先检查所有设置和日志，如果 build fails then change the " +
            "configuration and retry，最后再继续下一步。"
        let unsafeNativeEcho = TranslationResultValidator.validate(
            source: untranslatedEnglishClause, result: untranslatedEnglishClause,
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        )
        try expect(unsafeNativeEcho.noOpTranslation &&
                   !unsafeNativeEcho.targetLanguagePassthrough,
                   "untranslated English clause was accepted as the Chinese version")
        let untranslatedChineseClause =
            "If the build fails, 请检查网络设置并重新启动，然后再 retry the operation."
        let unsafeLearningEcho = TranslationResultValidator.validate(
            source: untranslatedChineseClause, result: untranslatedChineseClause,
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english)
        )
        try expect(unsafeLearningEcho.noOpTranslation &&
                   !unsafeLearningEcho.targetLanguagePassthrough,
                   "untranslated Chinese clause was accepted as the English version")
        let pureEnglishPassthrough = TranslationResultValidator.validate(
            source: "This segment is already English.",
            result: "This segment is already English.",
            pair: OfflineTranslationPair(source: .simplifiedChinese, target: .english)
        )
        try expect(pureEnglishPassthrough.targetLanguagePassthrough,
                   "pure English row could not remain in the mixed English version")
    }

    private static func testStudyTextRouting() throws {
        let english = LongTextSegmenter.segment(
            "The result should remain stable after relaunch."
        )
        try expect(english.count == 1 && english[0].studyText?.language == .english &&
                   english[0].studyText?.origin == .originalQuery,
                   "English source was not retained as the learning-language study text")
        let chinese = LongTextSegmenter.segment("写入完成后验证是否真正秒级结束。")
        try expect(chinese.count == 1 && chinese[0].studyText == nil &&
                   chinese[0].basicAnalysis == .waitingForStudyText,
                   "native source was analyzed before a reliable English study text existed")

        let mixedParagraphs = LongTextSegmenter.segment(
            "You do the hotspot test first.\n\n你先做热点测试，别同时改其他东西。"
        )
        guard mixedParagraphs.count == 2 else {
            throw SmokeFailure.failed("mixed target-language passthrough segmentation")
        }
        let englishSource = mixedParagraphs[0]
        let chineseSource = mixedParagraphs[1]
        try expect(englishSource.offlineVersions.count == 2 &&
                   chineseSource.offlineVersions.count == 2 &&
                   englishSource.offlineVersions.allSatisfy {
                       if case .translating = $0.state { return true }
                       return false
                   } && chineseSource.offlineVersions.allSatisfy {
                       if case .translating = $0.state { return true }
                       return false
                   },
                   "mixed plan did not retain two independent Apple operations per segment")
        let mixedNativeDominant = LongTextSegmenter.segment(
            "你先做热点测试；随后检查 VPN、DNS、router 和 Codex，别同时改其他设置。"
        )
        try expect(mixedNativeDominant.count == 1 &&
                   mixedNativeDominant[0].offlineVersions.count == 2,
                   "Chinese-dominant mixed sentence lost a bidirectional operation")
        let mixedLearningDominant = LongTextSegmenter.segment(
            "If the Resource Center 还是 shows FreeDict as installable, that is a bug."
        )
        try expect(mixedLearningDominant.count == 1 &&
                   mixedLearningDominant[0].offlineVersions.count == 2,
                   "English-dominant mixed sentence lost a bidirectional operation")

        let naturalMultiSentenceTranslation =
            "Wear a pair of quirky sunglasses. Keep the hairstyle richly textured."
        let projected = AIStudyTextProjector.project(
            translation: naturalMultiSentenceTranslation,
            onto: chinese, learningLanguage: .english
        )
        try expect(projected?[chinese[0].id]?.text == naturalMultiSentenceTranslation,
                   "one native source row discarded a natural multi-sentence AIStudyText")

        let twoNativeRows = LongTextSegmenter.segment(
            "先验证写入是否结束。然后确认普通查询仍然可用。"
        )
        let threeTargetSentences =
            "First verify that writing has finished. " +
            "Then confirm the result. Ordinary queries must remain available."
        let multiProjection = AIStudyTextProjector.project(
            translation: threeTargetSentences,
            onto: twoNativeRows, learningLanguage: .english
        )
        try expect(twoNativeRows.count == 2 && multiProjection?.count == 2,
                   "canonical AIStudyText was not projected onto every native source row")
        let projectedText = twoNativeRows.compactMap { multiProjection?[$0.id]?.text }
            .joined(separator: " ")
        for fragment in [
            "First verify that writing has finished.",
            "Then confirm the result.",
            "Ordinary queries must remain available."
        ] {
            try expect(projectedText.components(separatedBy: fragment).count == 2,
                       "multi-target AIStudyText projection lost or duplicated a target segment")
        }
        try expect(twoNativeRows.allSatisfy {
            multiProjection?[$0.id]?.language == .english &&
                multiProjection?[$0.id]?.origin == .aiTranslation
        }, "projected StudyText lost its canonical language/origin identity")

        let learningRows = LongTextSegmenter.segment(
            "The team observed the bees. The result supported the hypothesis."
        )
        let sentenceNativeTranslations = Dictionary(uniqueKeysWithValues:
            zip(learningRows.map(\.id), [
                "研究团队观察了蜜蜂。",
                "结果支持了这一假设。"
            ])
        )
        let composedNative = CanonicalNativeAITranslation.compose(
            sourceSentences: learningRows,
            translationsBySentenceID: sentenceNativeTranslations,
            nativeLanguage: .simplifiedChinese
        )
        try expect(composedNative == "研究团队观察了蜜蜂。\n结果支持了这一假设。",
                   "sentence-first AI flow did not establish one canonical native translation")
        var missingNativeTranslation = sentenceNativeTranslations
        missingNativeTranslation.removeValue(forKey: learningRows[1].id)
        try expect(CanonicalNativeAITranslation.compose(
            sourceSentences: learningRows,
            translationsBySentenceID: missingNativeTranslation,
            nativeLanguage: .simplifiedChinese
        ) == nil, "partial sentence AI results incorrectly replaced the full deep translation")
    }

    @MainActor
    private static func testUILocalization() throws {
        var english = LanguagePreferences.productionDefault
        english.uiLanguage = .english
        AppLocalization.configureAtLaunch(english)
        try expect(AppLocalization.text("保存", "Save") == "Save",
                   "English UI localization")
        AppLocalization.configureAtLaunch(.productionDefault)
        try expect(AppLocalization.text("保存", "Save") == "保存",
                   "Simplified Chinese UI localization")
    }

    private static func testHeavyWorkSerialization() async throws {
        let coordinator = LocalHeavyWorkCoordinator()
        let first = try await coordinator.acquire(.reverseIndex)
        let apple = Task { try await coordinator.acquire(.appleLanguagePreparation) }
        let resource = Task {
            try await coordinator.acquire(.resourceInstallationFinalization)
        }
        try await Task.sleep(for: .milliseconds(10))
        let queued = await coordinator.snapshot()
        try expect(queued.active == .reverseIndex,
                   "reverse index did not hold the only heavy-work permit")
        try expect(queued.waiting.count == 2,
                   "heavy work was not queued serially")
        apple.cancel()
        _ = await apple.result
        await first.release()
        let third = try await resource.value
        let promoted = await coordinator.snapshot()
        try expect(promoted.active == .resourceInstallationFinalization,
                   "cancelled waiter blocked the next heavy job")
        await third.release()
        let idle = await coordinator.snapshot()
        try expect(idle.active == nil && idle.waiting.isEmpty,
                   "heavy-work queue did not drain")
    }

    private static func testWaitingApplePreparationCancellation() async throws {
        let heavyWork = LocalHeavyWorkCoordinator()
        let engine = WaitingPreparationEngine()
        let coordinator = OfflineTranslationCoordinator(
            heavyWorkCoordinator: heavyWork,
            factory: { engine }
        )
        let pair = OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        let task = Task { try await coordinator.prepareLanguagePack(for: pair) }
        try await Task.sleep(for: .milliseconds(20))
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let elapsed = started.duration(to: .now)
        guard case .failure = result else {
            throw SmokeFailure.failed("cancelled Apple preparation unexpectedly completed")
        }
        try expect(elapsed < .seconds(1),
                   "Apple preparation cancellation exceeded the termination bound")
        let snapshot = await heavyWork.snapshot()
        try expect(snapshot.active == nil && snapshot.waiting.isEmpty,
                   "Apple preparation retained the heavy-work permit after cancellation")
    }

    private static func testForwardVocabularyFixture() async throws {
        let text = """
        Although every learner found the attractive proposal complicated, the tuition response
        excluded neither capable students nor the guarantee because it was necessary.
        """
        let selected = await OfflineVocabularySelector().select(
            from: LongTextSegmenter.segment(text),
            glossary: makeForwardDictionaryFixture()
        )
        let displayedTerms = Set(selected.map { $0.term.lowercased() })
        for expected in ["attractive", "complicated", "tuition", "guarantee", "proposal",
                         "response", "capable", "excluded", "learner"] {
            try expect(displayedTerms.contains(expected),
                       "mature forward dictionary fixture missed \(expected)")
        }
        for functionWord in ["because", "every", "although", "neither"] {
            try expect(!displayedTerms.contains(functionWord),
                       "function word was added to fill the vocabulary list")
        }
        try expect(selected.count < OfflineVocabularySelector.maximumItems,
                   "vocabulary was padded to 15")
        try expect(selected.allSatisfy {
            $0.source == "合成成熟正向词典" &&
                $0.meaningOrSuggestion != "本地词典暂无可靠释义"
        }, "vocabulary used a lexical-filter placeholder instead of the forward index")

        let coordinator = LocalHeavyWorkCoordinator()
        let permit = try await coordinator.acquire(.reverseIndex)
        let whileIndexing = await makeForwardDictionaryFixture().evidence(
            for: "tuition", language: .english
        )
        await permit.release()
        try expect(whileIndexing?.suggestion == "学费",
                   "reverse indexing blocked the independent forward dictionary path")
    }

    private static func testProperNounVocabularyPrecision() async throws {
        let selected = await OfflineVocabularySelector().select(
            from: LongTextSegmenter.segment(
                "The researchers collected observations in Brazil during the summer."
            ),
            glossary: WrongBrazilGlossary()
        )
        guard let brazil = selected.first(where: {
            $0.term.caseInsensitiveCompare("Brazil") == .orderedSame
        }) else {
            throw SmokeFailure.failed("Brazil proper noun was omitted from precision fixture")
        }
        try expect(brazil.meaningOrSuggestion == "巴西（国家；专有名词）" &&
                   brazil.source == "上下文专有名词识别",
                   "Brazil used the dictionary's unrelated plant/dye first sense")
    }

    private static func testRouting() throws {
        try expect(QueryIntentClassifier.classify("prompt").intent == .word,
                   "English word route")
        try expect(QueryIntentClassifier.classify("machine learning").intent == .phrase,
                   "English phrase route")
        try expect(QueryIntentClassifier.classify("药物").isChineseLookup,
                   "Chinese reverse route")
        try expect(QueryIntentClassifier.classify("这个药物可以改善症状。").intent == .sentence,
                   "Chinese sentence route")
        try expect(QueryIntentClassifier.classify("First sentence.\n\nSecond paragraph.").intent ==
                   .sentence, "paragraph route")
        try expect(QueryIntentClassifier.classify("该 drug may improve symptoms.").language == .mixed,
                   "mixed route")
        try expect(QueryIntentClassifier.classify("   ").rejectionReason == .empty,
                   "empty route")
        try expect(QueryIntentClassifier.classify("12345").intent == .textTooLong,
                   "numeric route")
        try expect(QueryIntentClassifier.classify(String(repeating: "a", count: 12_001)).intent ==
                   .textTooLong, "long safety route")
        let installed = AppleTranslationActionPresentation.make(
            availability: .installed, isLongText: false
        )
        try expect(installed.isEnabled &&
                   installed.title == "Apple 系统离线翻译（简体中文 → English）",
                   "installed Chinese Apple capability is not directly executable")
        let preparing = AppleTranslationActionPresentation.make(
            availability: .supportedNeedsDownload, isLongText: false
        )
        try expect(preparing.isEnabled &&
                   preparing.title == "准备 Apple 离线翻译语言包（简体中文 ⇄ English）",
                   "supported Chinese Apple capability has wrong preparation action")
        let unavailable = AppleTranslationActionPresentation.make(
            availability: .temporarilyUnavailable, isLongText: false
        )
        try expect(!unavailable.isEnabled && unavailable.title.contains("暂不可用"),
                   "unavailable Apple capability is not a typed visible state")
    }

    private static func testTranslationAndLongText() async throws {
        let mock = MockTranslationEngine()
        let counter = FactoryCounter()
        let coordinator = OfflineTranslationCoordinator(maximumConcurrentTasks: 2) {
            await counter.increment()
            return mock
        }
        let wordStarted = ContinuousClock.now
        for _ in 0..<10_000 {
            try expect(QueryIntentClassifier.classify("prompt").intent == .word,
                       "English word route changed")
        }
        let wordElapsed = wordStarted.duration(to: .now)
        let initialFactoryCount = await counter.value
        try expect(initialFactoryCount == 0, "engine initialized eagerly")
        print("PERF english-word-routing-10000-ms=\(milliseconds(wordElapsed))")
        let pipeline = LongTextAnalysisPipeline(
            translation: coordinator, glossary: MockGlossary()
        )
        let text = """
        Although the clinical findings were statistically significant, they did not necessarily imply a meaningful benefit.

        该药物可以改善症状，但是并不适用于所有患者。
        """
        let started = ContinuousClock.now
        let result = try await pipeline.analyze(text)
        let elapsed = started.duration(to: .now)
        let finalFactoryCount = await counter.value
        try expect(finalFactoryCount == 2,
                   "each opposite-direction operation must cross a fresh engine boundary")
        try expect(result.sentences.count == 2, "sentence segmentation")
        try expect(result.sentences.allSatisfy { $0.translatedText != nil },
                   "translation results")
        try expect(result.vocabulary.count <= 15, "vocabulary hard cap")
        try expect(result.sentences.allSatisfy { $0.offlineVersions.count == 2 } &&
                   result.completeTranslation.hasPrefix("English\n") &&
                   result.completeTranslation.contains("\n\n简体中文\n"),
                   "mixed long text did not render both target-language versions")
        try expect(elapsed < .seconds(5), "synthetic pipeline unexpectedly slow")
        let translationCalls = await mock.translationCalls
        let preparationCalls = await mock.preparationCalls
        try expect(translationCalls >= 1, "translation not invoked")
        try expect(preparationCalls == 0, "language pack prepared silently")
        print("PERF synthetic-long-text-ms=\(milliseconds(elapsed))")
    }

    private static func testMixedFailureIsolation() async throws {
        let scenarios: [(String, OfflineTranslationLanguage)] = [
            ("所以如果 Evidence Candidate 的 Resource Center 里仍显示 FreeDict，" +
                "那才是 bug。", .english),
            ("If the Resource Center 还是 shows FreeDict as installable, that is a bug.",
             .simplifiedChinese)
        ]
        for (mixed, failedTarget) in scenarios {
            let engine = SelectiveFailureTranslationEngine(failedTarget: failedTarget)
            let coordinator = OfflineTranslationCoordinator(maximumConcurrentTasks: 1) {
                engine
            }
            let pipeline = LongTextAnalysisPipeline(translation: coordinator)
            let result = try await pipeline.analyze(mixed)
            guard let sentence = result.sentences.first else {
                throw SmokeFailure.failed("mixed isolation result missing")
            }
            let successfulTarget: OfflineTranslationLanguage =
                failedTarget == .english ? .simplifiedChinese : .english
            try expect(sentence.offlineVersions.first(where: {
                $0.pair.target == failedTarget
            })?.translationError == .deadlineExceeded(.translation),
                       "failed mixed side lost its typed terminal")
            try expect(sentence.offlineVersions.first(where: {
                $0.pair.target == successfulTarget
            })?.translatedText != nil,
                       "one mixed-side failure poisoned the opposite operation")
            let next = try await pipeline.analyze("Have you heard her name before?")
            try expect(next.sentences.first?.translatedText != nil,
                       "mixed-side failure poisoned the next normal query")
        }

        let echoEngine = MixedChineseSideEchoEngine()
        let echoPipeline = LongTextAnalysisPipeline(
            translation: OfflineTranslationCoordinator(maximumConcurrentTasks: 1) {
                echoEngine
            }
        )
        let partial = try await echoPipeline.analyze(
            "这次请先检查日志，如果 build fails then change the configuration and retry，" +
            "最后再继续。\n\nThe second sentence still needs a Chinese translation."
        )
        try expect(partial.sentences.count == 2,
                   "mixed Chinese-side isolation fixture did not segment")
        let firstNative = partial.sentences[0].offlineVersions.first {
            $0.outputRole == .nativeVersion
        }
        let secondNative = partial.sentences[1].offlineVersions.first {
            $0.outputRole == .nativeVersion
        }
        try expect(firstNative?.translationError == .noOpTranslation,
                   "unsafe mixed echo was not kept as a typed per-row failure")
        try expect(secondNative?.translatedText == "这是另一句有效的简体中文译文。",
                   "one mixed echo discarded another valid Chinese-version row")
        try expect(partial.sentences.allSatisfy { sentence in
            sentence.offlineVersions.first {
                $0.outputRole == .learningVersion
            }?.translatedText != nil
        }, "Chinese-side row failure poisoned the English version")

        let ipaGlossary =
            "rule out vt. 排除 indigenous |ɪnˈdɪdʒɪnəs| a. 当地的，本地的 " +
            "perpetuate |pəˈpɛtʃʊeɪt| vt. 使永久 larva |ˈlɑːvə| n. 幼虫 pl. larvae"
        let ipaPipeline = LongTextAnalysisPipeline(
            translation: OfflineTranslationCoordinator(maximumConcurrentTasks: 1) {
                IPAGlossaryWrongTargetEngine()
            }
        )
        let ipaResult = try await ipaPipeline.analyze(ipaGlossary)
        guard let ipaSentence = ipaResult.sentences.first,
              let ipaNative = ipaSentence.offlineVersions.first(where: {
                  $0.outputRole == .nativeVersion
              }),
              let ipaLearning = ipaSentence.offlineVersions.first(where: {
                  $0.outputRole == .learningVersion
              }) else {
            throw SmokeFailure.failed("IPA glossary bilingual versions missing")
        }
        try expect(ipaNative.translationSource == .sourceBilingualGlossary &&
                   ipaNative.translationError == nil &&
                   ipaNative.translatedText == "排除\n当地的，本地的\n使永久\n幼虫",
                   "wrong-target Apple response did not recover the existing Chinese glosses")
        try expect(ipaLearning.translationSource == .appleSystem &&
                   ipaLearning.translatedText?.contains("indigenous") == true,
                   "IPA glossary Chinese-side recovery changed the valid English side")
        try expect(!ipaResult.completeTranslation.contains("当前不可用"),
                   "recovered IPA glossary still rendered an unavailable version")
    }

    private static func testAppleDeadlineAndLocalBasicFallback() async throws {
        let never = NeverReturningTranslationEngine()
        let local = LocalBasicTranslationEngine(lookup: LocalBasicTranslationLookup(
            englishToChinese: { term in
                ["clinical benefit": "临床获益", "patient": "患者",
                 "treatment": "治疗", "improve": "改善"][term]
            },
            chineseToEnglish: { term in
                ["苹果": "apple", "下载": "download", "患者": "patient",
                 "治疗": "treatment", "改善": "improve"][term]
            }
        ))
        let deadlines = OfflineTranslationDeadlinePolicy(
            availability: .milliseconds(50), preparation: .milliseconds(50),
            translation: .milliseconds(80), fallback: .seconds(1)
        )
        let coordinator = OfflineTranslationCoordinator(
            maximumConcurrentTasks: 1,
            deadlinePolicy: deadlines,
            fallbackFactory: { local },
            factory: { never }
        )
        let pipeline = LongTextAnalysisPipeline(
            translation: coordinator, glossary: MockGlossary()
        )
        let english = "The clinical benefit can improve the patient."
        let started = ContinuousClock.now
        let englishResult = try await pipeline.analyze(english)
        let elapsed = started.duration(to: .now)
        try expect(elapsed < .seconds(2), "never-return Apple path exceeded watchdog")
        try expect(englishResult.sentences.first?.translationSource != .appleSystem &&
                   englishResult.translationProviderLabel == "Apple 系统离线翻译" &&
                   englishResult.completeTranslation == "Apple 系统离线翻译当前不可用。" &&
                   !englishResult.completeTranslation.contains("临床获益"),
                   "local dictionary candidates leaked into sentence translation output")
        let decision = await coordinator.lastDecision
        try expect(decision?.usedFallback == true &&
                   decision?.failure == .deadlineExceeded(.translation),
                   "typed Apple deadline decision missing")

        let chineseResult = try await pipeline.analyze("治疗可以改善患者。")
        try expect(chineseResult.completeTranslation == "Apple 系统离线翻译当前不可用。" &&
                   !chineseResult.completeTranslation.contains("treatment") &&
                   !chineseResult.completeTranslation.contains("patient"),
                   "Chinese local candidates leaked into sentence translation output")
        let short = try await coordinator.translate([
            OfflineTranslationRequest(
                id: "short", sourceText: "苹果",
                pair: OfflineTranslationPair(
                    source: .simplifiedChinese, target: .english
                )
            )
        ])
        try expect(short.first?.translatedText == "apple" &&
                   short.first?.source == .localDictionaryCandidate,
                   "Chinese short-word fallback did not preserve best local candidate")
        let draft = LongTextAnalysisPipeline.initialResult(for: english)
        try expect(!draft.sentences.isEmpty &&
                   LongTextResultFormatter().format(draft).string.contains("AI 深度分析（本句）"),
                   "long-text AI action is absent before Apple completion")
        try await MainActor.run {
            for value in [draft, englishResult, chineseResult] {
                let attributed = LongTextResultFormatter().format(value)
                for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                    guard let appearance = NSAppearance(named: appearanceName) else {
                        throw SmokeFailure.failed("missing rendering appearance")
                    }
                    appearance.performAsCurrentDrawingAppearance {
                        let view = NSTextView(
                            frame: NSRect(x: 0, y: 0, width: 520, height: 900)
                        )
                        view.appearance = appearance
                        view.drawsBackground = true
                        view.backgroundColor = .textBackgroundColor
                        view.textStorage?.setAttributedString(attributed)
                        view.layoutManager?.ensureLayout(for: view.textContainer!)
                        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                        }
                    }
                    var invalidColor = false
                    attributed.enumerateAttribute(
                        .foregroundColor, in: NSRange(location: 0, length: attributed.length)
                    ) { value, _, stop in
                        guard let color = value as? NSColor,
                              let ratio = renderingContrast(color, .textBackgroundColor),
                              ratio >= 3 else {
                            invalidColor = true
                            stop.pointee = true
                            return
                        }
                    }
                    try expect(!invalidColor,
                               "offline translation/analysis has a fixed or missing color")
                }
            }
        }
    }

    private static func testInstalledColdTranslationDeadline() async throws {
        let engine = ColdInstalledTranslationEngine()
        let coordinator = OfflineTranslationCoordinator(
            maximumConcurrentTasks: 1,
            deadlinePolicy: .production,
            factory: { engine }
        )
        let pair = OfflineTranslationPair(
            source: .simplifiedChinese, target: .english
        )
        let availability = await coordinator.availability(for: pair)
        try expect(availability == .installed,
                   "cold deadline fixture must start installed")
        let started = ContinuousClock.now
        let result = try await coordinator.translate([
            OfflineTranslationRequest(sourceText: "这是一次正常的冷启动翻译请求。", pair: pair)
        ])
        let elapsed = started.duration(to: .now)
        try expect(result.first?.translatedText == "cold-start-complete" &&
                   elapsed >= .seconds(5) && elapsed < .seconds(10),
                   "installed 5–8 second cold TranslationSession was killed too early")
        let maximum = OfflineTranslationDeadlinePolicy.production.translationBudget(
            characterCount: 100_000, sentenceCount: 10_000,
            installed: true, coldSession: true
        )
        try expect(maximum == .seconds(18),
                   "production Apple translation deadline lost its explicit 18s cap")

        let retryEngine = RetryingColdInstalledTranslationEngine()
        let retryPolicy = OfflineTranslationDeadlinePolicy(
            availability: .milliseconds(20), preparation: .milliseconds(20),
            translation: .milliseconds(40), fallback: .milliseconds(20),
            maximumTranslation: .milliseconds(140),
            coldInstalledGrace: .milliseconds(30)
        )
        let retryCoordinator = OfflineTranslationCoordinator(
            maximumConcurrentTasks: 1, deadlinePolicy: retryPolicy,
            factory: { retryEngine }
        )
        let retryAvailability = await retryCoordinator.availability(for: pair)
        try expect(retryAvailability == .installed,
                   "retry fixture must start installed")
        let retryResult = try await retryCoordinator.translate([
            OfflineTranslationRequest(sourceText: "文化", pair: pair)
        ])
        let retryCalls = await retryEngine.calls
        try expect(retryResult.first?.translatedText == "fresh-session-complete" &&
                   retryCalls == 2,
                   "installed cold timeout did not retry once with a fresh bounded session")
        let retryDecision = await retryCoordinator.lastDecision
        try expect(retryDecision?.stage == .completion && retryDecision?.failure == nil,
                   "successful cold retry did not publish completion")
    }

    private static func testReverseLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-ReverseSmoke-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.sqlite")
        let identity = ReverseIndexIdentity(
            dictionaryID: "synthetic", dictionaryName: "合成双语词典",
            sourceSHA256: String(repeating: "a", count: 64),
            indexPublicationID: "synthetic-publication", queryPriority: 0, sortPosition: 1
        )
        let reverseStarted = ContinuousClock.now
        let writer = try ReverseIndexStreamingWriter(destinationURL: url, identity: identity)
        try writer.append(ReverseIndexEntry(
            headword: "benefit", plainText: "<b>获益</b>；好处"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "clinical", plainText: "临床的；临床使用"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "duplicate", plainText: "临床获益"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "apple", plainText: "n.[C] 苹果；蘋果；苹果树的果实"
        ))
        for related in ["pome", "Pomer", "pomelike", "pomes"] {
            try writer.append(ReverseIndexEntry(headword: related, plainText: "苹果"))
        }
        try writer.append(ReverseIndexEntry(
            headword: "culture", plainText: "文化；文明；社会的文化传统"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "civilization", plainText: "文明；文化"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "cultural", plainText: "文化"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "kulturs", plainText: "文化"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "diffusion",
            plainText: "一种文化的要素特点向另一种文化的传播"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "diffusions",
            plainText: "一种文化的要素特点向另一种文化的传播"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "agriculture", plainText: "农业；农业文化的发展"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "random-no-phrase", plainText: "文；化；不连续的释义"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "download", plainText: "下载；下载文件"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "verify", plainText: "验证；核实"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "validation", plainText: "验证；确认有效性"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "submit", plainText: "提交；呈交"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "submission", plainText: "提交；所提交的材料"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "liver", plainText: "肝脏；肝"
        ))
        try writer.append(ReverseIndexEntry(
            headword: "kidney", plainText: "肾脏；肾"
        ))
        let summary = try writer.finish()
        let reverseElapsed = reverseStarted.duration(to: .now)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let sidecarBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        try expect(summary.entryCount == 23 && summary.applicableEntryCount >= 21,
                   "reverse entry/gloss count")
        let service = ReverseLookupService(descriptors: [
            ReverseIndexDescriptor(fileURL: url, identity: identity)
        ])
        let exact = await service.lookup("临床")
        try expect(exact.isEmpty,
                   "default reverse results must hide non-exact related glosses")
        let normalized = ReverseLookupNormalizer.normalizeQuery("　临床！")
        try expect(normalized == "临床", "full-width punctuation normalization")
        let apple = await service.lookup("　苹果，！")
        try expect(apple.first?.headword == "apple" &&
                   apple.filter { $0.headword.lowercased().hasPrefix("pom") }.count <= 1,
                   "苹果 did not prefer apple or collapse the pome family: " +
                    apple.map { "\($0.headword)|\($0.matchTier)|\($0.score)" }
                        .joined(separator: ","))
        let traditionalApple = await service.lookup("蘋果")
        try expect(traditionalApple.first?.headword == "apple",
                   "traditional 苹果 normalization")
        let culture = await service.lookup("文化")
        try expect(culture.first?.headword == "culture" &&
                   culture.first?.matchTier == .exactGloss &&
                   culture.dropFirst().allSatisfy { $0.matchTier == .strongGloss } &&
                   culture.first(where: { $0.headword == "civilization" })?.matchTier ==
                    .strongGloss &&
                   culture.first(where: { $0.headword == "cultural" })?.matchTier ==
                    .strongGloss &&
                   culture.first(where: { $0.headword == "kulturs" })?.matchTier ==
                    .strongGloss &&
                   culture.allSatisfy { $0.definitionSnippet.contains("文化") } &&
                   !culture.contains { ["diffusion", "diffusions", "agriculture",
                                        "random-no-phrase"].contains($0.headword) },
                   "culture precision-first ranking admitted a non-phrase candidate")
        let phrase = await service.lookup("临床获益")
        try expect(phrase.first?.headword == "duplicate" &&
                   phrase.allSatisfy { $0.definitionSnippet.contains("临床获益") },
                   "multi-character phrase was not matched continuously")
        let expectedHeads: [(String, Set<String>)] = [
            ("下载", ["download"]),
            ("验证", ["verify", "validation"]),
            ("提交", ["submit", "submission"]),
            ("肝脏", ["liver"]),
            ("肾脏", ["kidney"])
        ]
        for (query, allowed) in expectedHeads {
            let values = await service.lookup(query)
            try expect(!values.isEmpty && allowed.contains(values[0].headword) &&
                       values.allSatisfy { $0.definitionSnippet.contains(query) },
                       "reverse exact fixture failed for \(query)")
        }
        let singleHan = await service.lookup("文")
        try expect(singleHan.isEmpty, "single-Han low-confidence query should return zero")
        let noMatch = await service.lookupOutcome("完全无关词")
        try expect(noMatch.state == .noMatch && noMatch.results.isEmpty,
                   "ready reverse index no-match diagnosis")
        let oldSchemaIdentity = ReverseIndexIdentity(
            schemaVersion: ReverseIndexIdentity.openResourceSchemaVersion,
            dictionaryID: identity.dictionaryID,
            dictionaryName: identity.dictionaryName,
            sourceSHA256: identity.sourceSHA256,
            indexPublicationID: identity.indexPublicationID,
            queryPriority: identity.queryPriority,
            sortPosition: identity.sortPosition
        )
        await service.replaceDescriptors([
            ReverseIndexDescriptor(fileURL: url, identity: oldSchemaIdentity)
        ])
        let oldSchema = await service.lookupOutcome("苹果")
        try expect(oldSchema.state == .stale && oldSchema.results.isEmpty,
                   "legacy derived reverse schema was not invalidated for v3 rebuild")
        let stale = ReverseIndexIdentity(
            dictionaryID: identity.dictionaryID, dictionaryName: identity.dictionaryName,
            sourceSHA256: String(repeating: "b", count: 64),
            indexPublicationID: identity.indexPublicationID,
            queryPriority: 0, sortPosition: 1
        )
        await service.replaceDescriptors([ReverseIndexDescriptor(fileURL: url, identity: stale)])
        let staleResults = await service.lookup("临床")
        try expect(staleResults.isEmpty, "stale sidecar ignored")
        let staleOutcome = await service.lookupOutcome("苹果")
        try expect(staleOutcome.state == .stale,
                   "stale reverse index diagnosis")
        await service.replaceDescriptors([])
        await service.replaceBuildStages([identity.dictionaryID: .cancelled])
        let cancelledOutcome = await service.lookupOutcome("苹果")
        try expect(cancelledOutcome.state == .noAvailableIndexes,
                   "cancelled sidecar did not participate in lookup")
        let preferredURL = root.appendingPathComponent("preferred-weak.sqlite")
        let preferredIdentity = ReverseIndexIdentity(
            dictionaryID: "preferred-weak", dictionaryName: "首选弱候选",
            sourceSHA256: String(repeating: "c", count: 64),
            indexPublicationID: "preferred-weak-publication",
            queryPriority: 0, sortPosition: 0
        )
        let preferredWriter = try ReverseIndexStreamingWriter(
            destinationURL: preferredURL, identity: preferredIdentity
        )
        try preferredWriter.append(ReverseIndexEntry(
            headword: "cultural", plainText: "社会文化传统"
        ))
        _ = try preferredWriter.finish()
        let openURL = root.appendingPathComponent("open-exact.sqlite")
        let openIdentity = ReverseIndexIdentity(
            dictionaryID: "open-exact", dictionaryName: "FreeDict 英中词典",
            sourceSHA256: String(repeating: "d", count: 64),
            indexPublicationID: "open-exact-publication",
            queryPriority: 2, sortPosition: 10
        )
        let openWriter = try ReverseIndexStreamingWriter(
            destinationURL: openURL, identity: openIdentity
        )
        try openWriter.append(ReverseIndexEntry(headword: "culture", plainText: "文化"))
        _ = try openWriter.finish()
        let aggregate = ReverseLookupService(descriptors: [
            ReverseIndexDescriptor(fileURL: preferredURL, identity: preferredIdentity),
            ReverseIndexDescriptor(fileURL: openURL, identity: openIdentity)
        ])
        let aggregateValues = await aggregate.lookup("文化")
        try expect(aggregateValues.first?.headword == "culture" &&
                   aggregateValues.first?.dictionaryName == "FreeDict 英中词典" &&
                   aggregateValues.map(\.dictionaryID) == ["open-exact"],
                   "exact open-resource gloss must replace hidden weak candidates")
        let directCC = LocalChineseQueryPlanner.merge(
            query: "文化",
            reverse: ReverseLookupOutcome(
                state: .success,
                results: [ReverseLookupResult(
                    headword: "cultural",
                    definitionSnippet: "社会文化传统",
                    dictionaryID: "preferred-weak",
                    dictionaryName: "首选弱候选",
                    matchReason: "匹配：相关短词义",
                    confidence: .low,
                    score: 1,
                    matchTier: .other,
                    sourcePriority: 0,
                    dictionaryOrder: 0
                )]
            ),
            directHits: [LocalChineseQueryPlanner.DirectHit(
                dictionaryID: "cc-cedict-direct",
                displayName: "CC-CEDICT中英词典",
                definitions: ["culture; civilization"],
                sourcePriority: 2,
                dictionaryOrder: 20
            )]
        )
        try expect(directCC.results.first?.headword == "culture" &&
                   directCC.results.first?.dictionaryID == "cc-cedict-direct" &&
                   directCC.results.first?.matchTier == .exactGloss &&
                   directCC.results.allSatisfy {
                       $0.dictionaryID == "cc-cedict-direct" && $0.matchTier == .exactGloss
                   },
                   "CC-CEDICT direct Chinese candidate was not merged before source priority: " +
                    directCC.results.map { "\($0.headword)|\($0.dictionaryID)|\($0.matchTier)" }
                        .joined(separator: ","))
        print("PERF reverse-16-entry-ms=\(milliseconds(reverseElapsed)) bytes=\(sidecarBytes)")
    }

    private static func testLargeReverseWriterLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-ReverseLarge-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("large.reverse.sqlite")
        let identity = ReverseIndexIdentity(
            dictionaryID: "synthetic-large",
            dictionaryName: "合成 50 万条词典",
            sourceSHA256: String(repeating: "c", count: 64),
            indexPublicationID: "synthetic-large-publication",
            queryPriority: 0,
            sortPosition: 1
        )
        let writer = try ReverseIndexStreamingWriter(
            destinationURL: destination,
            identity: identity
        )
        for index in 0..<500_000 {
            try writer.append(ReverseIndexEntry(
                headword: "synthetic-\(index)",
                plainText: "词"
            ))
        }
        var stages: [ReverseIndexBuildStage] = []
        let summary = try writer.finish { stages.append($0) }
        try expect(summary.entryCount == 500_000,
                   "500k synthetic enumeration count was not preserved")
        try expect(stages == [.optimizing, .validating, .publishing],
                   "reverse finalization stages were not distinct")
        try expect(FileManager.default.fileExists(atPath: destination.path),
                   "large synthetic sidecar was not atomically published")
        try expect(!FileManager.default.fileExists(atPath: writer.temporaryURL.path),
                   "published synthetic sidecar left a building file")
        let validationSamples = try (0..<7).map { _ in
            try ReverseIndexStreamingWriter.measureNormalValidation(
                at: destination, identity: identity,
                expectedEntryCount: 500_000,
                expectedApplicableCount: 500_000
            )
        }.sorted()
        let p50 = validationSamples[validationSamples.count / 2]
        let p95Index = max(0, Int(ceil(Double(validationSamples.count) * 0.95)) - 1)
        let p95 = validationSamples[p95Index]
        try expect(p95 < 10_000,
                   "500k normal validation regressed to a minute-scale gate")
        print(String(format:
            "PERF reverse-500k-normal-validation-p50-ms=%.3f p95-ms=%.3f " +
            "finish-total-ms=%.3f quick-ms=%.3f reopen-ms=%.3f",
            p50, p95, summary.metrics.totalMilliseconds,
            summary.metrics.quickValidationMilliseconds,
            summary.metrics.reopenMilliseconds))

        let unsupportedDestination = root.appendingPathComponent(
            "insufficient.reverse.sqlite"
        )
        let unsupportedWriter = try ReverseIndexStreamingWriter(
            destinationURL: unsupportedDestination, identity: identity
        )
        for index in 0..<1_000 {
            try unsupportedWriter.append(ReverseIndexEntry(
                headword: "english-only-\(index)",
                plainText: "no Chinese definition"
            ))
        }
        do {
            _ = try unsupportedWriter.finish()
            throw SmokeFailure.failed("zero-Chinese fixture published")
        } catch let error as ReverseIndexError {
            try expect(error == .noChineseDefinitions,
                       "zero-Chinese fixture has wrong typed failure")
        }
        try expect(!FileManager.default.fileExists(atPath: unsupportedDestination.path),
                   "zero-Chinese fixture left a published sidecar")

        let damaged = root.appendingPathComponent("validation-fail.reverse.sqlite")
        try FileManager.default.copyItem(at: destination, to: damaged)
        var damagedDatabase: OpaquePointer?
        guard sqlite3_open_v2(damaged.path, &damagedDatabase,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let damagedDatabase else {
            throw SmokeFailure.failed("cannot open validation-fail fixture")
        }
        sqlite3_exec(damagedDatabase, "DROP INDEX terms_entry", nil, nil, nil)
        sqlite3_close(damagedDatabase)
        do {
            _ = try ReverseIndexStreamingWriter.measureNormalValidation(
                at: damaged, identity: identity,
                expectedEntryCount: 500_000,
                expectedApplicableCount: 500_000
            )
            throw SmokeFailure.failed("validation-fail fixture passed normal gate")
        } catch let error as ReverseIndexError {
            try expect(error == .validationFailed,
                       "validation-fail fixture has wrong typed failure")
        }

        let finalizingDestination = root.appendingPathComponent("finalizing.reverse.sqlite")
        let finalizingFlag = LockedCancellationFlag()
        let finalizingWriter = try ReverseIndexStreamingWriter(
            destinationURL: finalizingDestination,
            identity: identity,
            cancellationCheck: { finalizingFlag.isCancelled() }
        )
        for index in 0..<2_000 {
            try finalizingWriter.append(ReverseIndexEntry(
                headword: "finalize-\(index)",
                plainText: "临床索引验证条目"
            ))
        }
        do {
            _ = try finalizingWriter.finish { stage in
                if stage == .optimizing { finalizingFlag.cancel() }
            }
            throw SmokeFailure.failed("reverse finalization ignored cancellation")
        } catch let error as ReverseIndexError {
            try expect(error == .cancelled,
                       "reverse finalization cancellation had the wrong failure state")
        }
        try expect(!FileManager.default.fileExists(atPath: finalizingDestination.path) &&
                   !FileManager.default.fileExists(atPath: finalizingWriter.temporaryURL.path),
                   "cancelled finalization published or retained a temporary sidecar")

        let cancelledDestination = root.appendingPathComponent("cancelled.reverse.sqlite")
        let cancelledTask = Task.detached(priority: .utility) { () throws -> URL in
            let cancellable = try ReverseIndexStreamingWriter(
                destinationURL: cancelledDestination,
                identity: identity
            )
            do {
                for index in 0..<500_000 {
                    try cancellable.append(ReverseIndexEntry(
                        headword: "cancel-\(index)",
                        plainText: "临床测试条目"
                    ))
                }
                _ = try cancellable.finish()
            } catch {
                cancellable.abort()
                throw error
            }
            return cancellable.temporaryURL
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.result
        switch cancelledResult {
        case .success:
            throw SmokeFailure.failed("cancelled reverse writer unexpectedly completed")
        case .failure:
            break
        }
        try expect(!FileManager.default.fileExists(atPath: cancelledDestination.path),
                   "cancelled reverse writer published a ready sidecar")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".building-") }
        try expect(leftovers.isEmpty,
                   "cancelled reverse writer left a temporary building sidecar")
    }

    private static func testBasicAnalysis() throws {
        let analyzer = BasicSentenceAnalyzer()
        let english = analyzer.analyze(
            sentence: "Although the result was measured, it did not imply a benefit.",
            language: .english
        )
        try expect(english.title == "基础结构识别", "honest analysis title")
        try expect(english.structureHints.contains { $0.contains("否定") },
                   "English negation")
        let infinitiveLead = analyzer.analyze(
            sentence: "To collect their data, Ms Di Pietro and her colleagues observed " +
                "the animals in Brazil.",
            language: .english
        )
        try expect(infinitiveLead.subjectOrTopic.contains("Ms Di Pietro") &&
                   infinitiveLead.predicate.lowercased() == "observed" &&
                   infinitiveLead.subjectOrTopic != "To" &&
                   infinitiveLead.predicate.lowercased() != "collect",
                   "sentence-initial infinitive was reported as the main clause")
        let participialLead = analyzer.analyze(
            sentence: "Capturing the insects’ behaviour on video, the team established " +
                "that there was no difference in average cell-building rate between the two " +
                "styles, and hence no efficiency advantage to either.",
            language: .english
        )
        try expect(participialLead.subjectOrTopic.lowercased().contains("the team") &&
                   participialLead.predicate.lowercased() == "established" &&
                   participialLead.predicate.lowercased() != "capturing",
                   "sentence-initial V-ing phrase was reported as the main predicate")
        let chinese = analyzer.analyze(
            sentence: "研究人员把样本放在实验室，但是样本被污染了。",
            language: .simplifiedChinese
        )
        try expect(chinese.structureHints.contains { $0.contains("把") },
                   "Chinese 把 structure")
        try expect(chinese.structureHints.contains { $0.contains("被") },
                   "Chinese 被 structure")
    }

    private static func testSegmentationPerformance() throws {
        let unit = "Although the result was measured, it did not necessarily imply a benefit. "
        let source = String(String(repeating: unit, count: 20).prefix(1_000))
        let started = ContinuousClock.now
        let sentences = LongTextSegmenter.segment(source)
        let elapsed = started.duration(to: .now)
        try expect(!sentences.isEmpty, "1,000-character segmentation")
        try expect(elapsed < .seconds(2), "1,000-character segmentation unexpectedly slow")
        print("PERF segmentation-1000-char-ms=\(milliseconds(elapsed))")
    }

    private static func testSelectionPlacement() throws {
        let visible = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let scenarios: [[CGRect]] = [
            [CGRect(x: -1000, y: 400, width: 120, height: 20)],
            [CGRect(x: -1000, y: 400, width: 300, height: 18),
             CGRect(x: -1000, y: 380, width: 220, height: 18)],
            [CGRect(x: -1438, y: 870, width: 100, height: 20)],
            [CGRect(x: -200, y: 4, width: 180, height: 20)]
        ]
        for rects in scenarios {
            let result = SelectionButtonPlacementEngine.place(
                SelectionButtonPlacementInput(
                    selectionRects: rects, buttonSize: CGSize(width: 72, height: 28),
                    visibleFrame: visible
                )
            )
            try expect(result != nil, "placement missing")
            try expect(visible.contains(result!.frame), "placement outside visible frame")
            try expect(!rects.contains(where: result!.frame.intersects),
                       "button overlaps selected text")
        }
        let stale = SelectionButtonPlacementEngine.place(
            SelectionButtonPlacementInput(
                selectionRects: [], buttonSize: CGSize(width: 72, height: 28),
                visibleFrame: visible
            )
        )
        try expect(stale == nil, "stale selection should hide")
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.3f", value)
    }
}

private actor FactoryCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}
