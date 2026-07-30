import Foundation

private enum SmokeFailure: Error {
    case failed(String)
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw SmokeFailure.failed(message) }
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
            OfflineTranslationResponse(
                id: $0.id, sourceText: $0.sourceText,
                translatedText: "[\($0.pair.target.rawValue)] \($0.sourceText)",
                pair: $0.pair
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        preparationCalls += 1
    }
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

@main
private struct OfflineLanguageSmoke {
    static func main() async throws {
        try testRouting()
        try await testTranslationAndLongText()
        try await testReverseLookup()
        try testBasicAnalysis()
        try testSegmentationPerformance()
        try testSelectionPlacement()
        print("OfflineLanguageSmoke PASS")
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
        try expect(finalFactoryCount == 1, "engine factory count")
        try expect(result.sentences.count == 2, "sentence segmentation")
        try expect(result.sentences.allSatisfy { $0.translatedText != nil },
                   "translation results")
        try expect(result.vocabulary.count <= 15, "vocabulary hard cap")
        try expect(result.completeTranslation.hasPrefix("[zh-Hans]"),
                   "translation remains first and ordered")
        try expect(elapsed < .seconds(5), "synthetic pipeline unexpectedly slow")
        let translationCalls = await mock.translationCalls
        let preparationCalls = await mock.preparationCalls
        try expect(translationCalls >= 1, "translation not invoked")
        try expect(preparationCalls == 0, "language pack prepared silently")
        print("PERF synthetic-long-text-ms=\(milliseconds(elapsed))")
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
        let summary = try writer.finish()
        let reverseElapsed = reverseStarted.duration(to: .now)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let sidecarBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        try expect(summary.applicableEntryCount == 3, "reverse entry count")
        let service = ReverseLookupService(descriptors: [
            ReverseIndexDescriptor(fileURL: url, identity: identity)
        ])
        let exact = await service.lookup("临床")
        try expect(exact.first?.headword == "clinical", "reverse exact ranking")
        try expect(exact.first?.confidence == .high, "reverse confidence")
        let normalized = ReverseLookupNormalizer.normalizeQuery("　临床！")
        try expect(normalized == "临床", "full-width punctuation normalization")
        let stale = ReverseIndexIdentity(
            dictionaryID: identity.dictionaryID, dictionaryName: identity.dictionaryName,
            sourceSHA256: String(repeating: "b", count: 64),
            indexPublicationID: identity.indexPublicationID,
            queryPriority: 0, sortPosition: 1
        )
        await service.replaceDescriptors([ReverseIndexDescriptor(fileURL: url, identity: stale)])
        let staleResults = await service.lookup("临床")
        try expect(staleResults.isEmpty, "stale sidecar ignored")
        print("PERF reverse-3-entry-ms=\(milliseconds(reverseElapsed)) bytes=\(sidecarBytes)")
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
