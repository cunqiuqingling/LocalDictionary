import AppKit
import Foundation

private enum IntegrationFailure: Error {
    case failed(String)
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw IntegrationFailure.failed(message) }
}

private final class GuideReminderDefaults: FirstLaunchGuidePersisting {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}

@MainActor
private final class MockSelectionWindowHost: GlobalSelectionWindowHosting {
    let globalSelectionWindowSize: CGSize
    private(set) var appliedFrames: [(CGRect, UInt64)] = []
    private(set) var hideCount = 0

    init(size: CGSize = CGSize(width: 120, height: 44)) {
        globalSelectionWindowSize = size
    }

    func applyGlobalSelectionWindowFrame(_ frame: CGRect, generation: UInt64) {
        appliedFrames.append((frame, generation))
    }

    func hideGlobalSelectionWindow() {
        hideCount += 1
    }
}

private actor DirectionMockTranslationEngine: OfflineTranslationEngine {
    private(set) var translationCalls = 0
    private(set) var preparationCalls = 0
    private(set) var translatedIDs: [String] = []
    var status: OfflineTranslationAvailability
    var failingIDs: Set<String> = []

    init(status: OfflineTranslationAvailability = .installed) {
        self.status = status
    }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability {
        status
    }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        translationCalls += 1
        if requests.contains(where: { request in
            failingIDs.contains(request.id) || failingIDs.contains(where: {
                request.id.hasPrefix($0 + "#")
            })
        }) {
            throw OfflineTranslationError.systemFailure
        }
        translatedIDs.append(contentsOf: requests.map(\.id))
        return requests.map {
            let translatedText: String
            switch $0.pair.target {
            case .english:
                translatedText = "Synthetic English translation for the selected sentence."
            case .simplifiedChinese:
                translatedText = "这是为所选句子生成的合成中文译文。"
            }
            return OfflineTranslationResponse(
                id: $0.id,
                sourceText: $0.sourceText,
                translatedText: translatedText,
                pair: $0.pair
            )
        }
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        preparationCalls += 1
        status = .installed
    }

    func fail(id: String) {
        failingIDs.insert(id)
    }
}

private actor DirectionGlossary: TranslationGlossaryService {
    func evidence(for term: String, language: QueryLanguage) async
        -> TranslationGlossaryEvidence? {
        TranslationGlossaryEvidence(
            suggestion: language == .english ? "合成释义" : "synthetic expression",
            source: "合成词典",
            professional: term.localizedCaseInsensitiveContains("clinical")
        )
    }
}

@main
private struct SelectionDirectionIntegrationSmoke {
    static func main() async throws {
        try testProductionPlacement()
        try testFirstLaunchGuideReminder()
        try await testDirectionStateAndActions()
        print("SelectionDirectionIntegrationSmoke PASS")
    }

    @MainActor
    private static func testFirstLaunchGuideReminder() throws {
        let defaults = GuideReminderDefaults()
        let reminder = FirstLaunchGuideReminder(defaults: defaults)
        try expect(reminder.claimPresentation(),
                   "first launch did not claim the guide reminder")
        try expect(!reminder.claimPresentation(),
                   "guide reminder was not limited to one presentation")
        try expect(defaults.bool(forKey: FirstLaunchGuideReminder.promptShownKey),
                   "guide reminder did not persist its presentation state")
    }

    @MainActor
    private static func testProductionPlacement() throws {
        let policyPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: DictionaryPanelInteractionPolicy.styleMask,
            backing: .buffered,
            defer: true
        )
        policyPanel.collectionBehavior = DictionaryPanelInteractionPolicy.collectionBehavior
        try expect(policyPanel.styleMask.contains(.nonactivatingPanel) &&
                   policyPanel.collectionBehavior.contains(.canJoinAllSpaces) &&
                   policyPanel.collectionBehavior.contains(.fullScreenAuxiliary),
                   "lookup panel is not a non-activating full-screen auxiliary")
        let longQueryField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        DictionaryPanelInteractionPolicy.configureSearchField(longQueryField)
        try expect(longQueryField.cell?.usesSingleLineMode == true &&
                   longQueryField.cell?.isScrollable == true &&
                   longQueryField.cell?.wraps == false &&
                   longQueryField.cell?.lineBreakMode == .byClipping,
                   "long search field is not horizontally scrollable")

        let displays = [
            SelectionDisplayGeometry(
                displayID: 1,
                appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                accessibilityFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            SelectionDisplayGeometry(
                displayID: 2,
                appKitFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 875),
                accessibilityFrame: CGRect(x: -1440, y: 180, width: 1440, height: 900)
            )
        ]
        let rawRects = [
            CGRect(x: -1180, y: 250, width: 340, height: 20),
            CGRect(x: -1180, y: 274, width: 220, height: 20)
        ]
        let mockAXCapture = AccessibilitySelectionCapture(
            text: "selected text",
            selectionRects: rawRects,
            capturedAt: Date()
        )
        let converted = AXSelectionCoordinateConverter.convert(
            mockAXCapture.selectionRects, displays: displays
        )
        try expect(converted.count == 2, "AX rectangles did not convert")
        try expect(converted[0].width == rawRects[0].width,
                   "Retina point width was scaled")
        try expect(converted[0].minX == -1180, "negative display X changed")
        try expect(converted[0].minY == 810,
                   "per-display top-to-bottom conversion is wrong")
        try expect(AXSelectionCoordinateConverter.preferredDisplayID(
            for: mockAXCapture.selectionRects, displays: displays
        ) == 2, "selection-majority display was not selected")

        let controller = GlobalSelectionPlacementController()
        let host = MockSelectionWindowHost()
        var generation: UInt64 = 1
        let scenarios: [[CGRect]] = [
            converted,
            [CGRect(x: -1438, y: 842, width: 180, height: 20)],
            [CGRect(x: -190, y: 4, width: 170, height: 20)],
            [CGRect(x: -1200, y: 180, width: 900, height: 480)]
        ]
        for rects in scenarios {
            let context = GlobalSelectionContext(
                selectedText: "generation-\(generation)",
                selectionRects: rects,
                anchorRect: rects.last,
                generation: generation,
                capturedAt: Date(),
                preferredDisplayID: 2,
                rightToLeft: false,
                sourceProcessIdentifier: 42
            )
            try expect(controller.present(
                context, displays: displays, fallbackDisplayID: 1, host: host
            ), "production controller did not present scenario \(generation)")
            guard let applied = host.appliedFrames.last else {
                throw IntegrationFailure.failed("mock host did not receive actual frame")
            }
            try expect(applied.1 == generation, "window generation mismatch")
            try expect(displays[1].visibleFrame.contains(applied.0),
                       "window frame used wrong screen")
            try expect(!rects.map { $0.insetBy(dx: -8, dy: -8) }
                .contains(where: applied.0.intersects),
                "actual window frame overlaps expanded selection")
            try expect(controller.selectedText(for: generation) ==
                       "generation-\(generation)",
                       "click text was not bound to window generation")
            generation &+= 1
        }

        let frameBeforeStale = host.appliedFrames.last?.0
        let stale = GlobalSelectionContext(
            selectedText: "stale",
            selectionRects: converted,
            anchorRect: converted.last,
            generation: 1,
            capturedAt: Date(),
            preferredDisplayID: 2,
            rightToLeft: false,
            sourceProcessIdentifier: 42
        )
        try expect(!controller.present(
            stale, displays: displays, fallbackDisplayID: 1, host: host
        ), "stale generation was accepted")
        try expect(host.appliedFrames.last?.0 == frameBeforeStale,
                   "stale generation replaced the current frame")

        let hidesBefore = host.hideCount
        let impossible = GlobalSelectionContext(
            selectedText: "covered",
            selectionRects: [displays[1].visibleFrame],
            anchorRect: displays[1].visibleFrame,
            generation: generation,
            capturedAt: Date(),
            preferredDisplayID: 2,
            rightToLeft: false,
            sourceProcessIdentifier: 42
        )
        try expect(!controller.present(
            impossible, displays: displays, fallbackDisplayID: 1, host: host
        ), "fully covered screen should fail closed")
        try expect(host.hideCount == hidesBefore + 1,
                   "no-safe-position did not hide the window")
        generation &+= 1

        let empty = GlobalSelectionContext(
            selectedText: "no bounds",
            selectionRects: [],
            anchorRect: nil,
            generation: generation,
            capturedAt: Date(),
            preferredDisplayID: nil,
            rightToLeft: false,
            sourceProcessIdentifier: nil
        )
        try expect(!controller.present(
            empty, displays: displays, fallbackDisplayID: 1, host: host
        ), "empty selection rectangles should not invent geometry")
        controller.invalidate(generation: generation + 1, host: host)
        try expect(controller.selectedText(for: generation) == nil,
                   "invalidated selection retained click text")
    }

    private static func testDirectionStateAndActions() async throws {
        var gate = SentenceDirectionGenerationGate()
        let old = gate.begin(sentenceID: "sentence-0003")
        let latest = gate.begin(sentenceID: "sentence-0003")
        try expect(!gate.accepts(sentenceID: "sentence-0003", generation: old),
                   "late direction generation was accepted")
        try expect(gate.accepts(sentenceID: "sentence-0003", generation: latest),
                   "latest direction generation was rejected")
        gate.invalidate(sentenceID: "sentence-0003")
        try expect(!gate.accepts(sentenceID: "sentence-0003", generation: latest),
                   "cancelled direction generation remained valid")

        let engine = DirectionMockTranslationEngine()
        let coordinator = OfflineTranslationCoordinator(maximumConcurrentTasks: 2) { engine }
        let pipeline = LongTextAnalysisPipeline(
            translation: coordinator, glossary: DirectionGlossary()
        )
        let automatic = try await pipeline.analyze(
            "The clinical treatment worked.\n\n该药物改善了症状。"
        )
        try expect(automatic.sentences.count == 2,
                   "known-language sentence count")
        try expect(automatic.sentences.allSatisfy {
            if case .translated = $0.translationState { return true }
            return false
        }, "known English/Chinese sentences did not translate automatically")

        let ambiguous = LongTextSentence(
            id: "sentence-0003",
            order: 2,
            paragraph: 2,
            sourceText: "dose 5 mg 后复查",
            language: .mixed,
            translatedText: nil,
            translationError: nil,
            translationState: .awaitingDirection,
            basicAnalysis: BasicSentenceAnalyzer().analyze(
                sentence: "dose 5 mg 后复查", language: .mixed
            )
        )
        let initial = LongTextAnalysisResult(
            sourceText: automatic.sourceText + "\n\ndose 5 mg 后复查",
            sentences: automatic.sentences + [ambiguous],
            vocabulary: automatic.vocabulary,
            requiresDirectionChoice: true,
            generatedAt: Date()
        )
        let formatter = LongTextResultFormatter()
        let rendered = formatter.format(initial, queryGeneration: 77)
        var directionURLs: [URL] = []
        rendered.enumerateAttribute(
            .link, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            guard let url = value as? URL,
                  url.host == "translate-direction" else { return }
            directionURLs.append(url)
        }
        let ambiguousURLs = directionURLs.filter {
            $0.path.contains(ambiguous.id)
        }
        try expect(ambiguousURLs.count == 2,
                   "uncertain sentence did not render two direction controls")
        try expect(ambiguousURLs.allSatisfy {
            !$0.absoluteString.contains(ambiguous.sourceText)
        }, "source text leaked into action URL")
        let actions = ambiguousURLs.compactMap {
            LongTextActionRouter.parse(
                $0, expectedGeneration: 77, validSentenceIDs: [ambiguous.id]
            )
        }
        try expect(actions.count == 2, "valid direction actions were rejected")
        try expect(actions.contains {
            if case .translate(_, let pair, _) = $0 {
                return pair.target == .simplifiedChinese
            }
            return false
        }, "translate-to-Chinese action missing")
        try expect(actions.contains {
            if case .translate(_, let pair, _) = $0 {
                return pair.target == .english
            }
            return false
        }, "translate-to-English action missing")

        guard let validURL = ambiguousURLs.first else {
            throw IntegrationFailure.failed("missing valid action URL")
        }
        try expect(LongTextActionRouter.parse(
            validURL, expectedGeneration: 78, validSentenceIDs: [ambiguous.id]
        ) == nil, "old query generation was accepted")
        try expect(LongTextActionRouter.parse(
            validURL, expectedGeneration: 77, validSentenceIDs: ["sentence-9999"]
        ) == nil, "forged sentence ID was accepted")
        let illegal = URL(
            string: "localdictionary://translate-direction/\(ambiguous.id)" +
                "?target=fr&generation=77"
        )!
        try expect(LongTextActionRouter.parse(
            illegal, expectedGeneration: 77, validSentenceIDs: [ambiguous.id]
        ) == nil, "illegal direction was accepted")
        let malicious = URL(
            string: "localdictionary://translate-direction/\(ambiguous.id)" +
                "?target=en&generation=77&text=\(String(repeating: "x", count: 300))"
        )!
        try expect(LongTextActionRouter.parse(
            malicious, expectedGeneration: 77, validSentenceIDs: [ambiguous.id]
        ) == nil, "oversized or extra-query action was accepted")

        let translated = try await pipeline.translateSentence(
            in: initial,
            sentenceID: ambiguous.id,
            pair: OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        )
        try expect(translated.sentences[0] == initial.sentences[0] &&
                   translated.sentences[1] == initial.sentences[1],
                   "direction selection changed another sentence")
        try expect(translated.sentences[2].translatedText == "这是为所选句子生成的合成中文译文。",
                   "selected sentence did not use chosen target")
        try expect(!translated.completeTranslation.contains("请选择本句翻译方向"),
                   "top translation was not reassembled")
        try expect(translated.vocabulary.count <= 15,
                   "direction recomputation exceeded vocabulary cap")
        try expect(Set(translated.vocabulary.map(\.lemma)).count ==
                   translated.vocabulary.count,
                   "direction recomputation duplicated lemmas")

        try expect(!LongTextSegmenter.containsTranslatableLanguage("12345 — !!!"),
                   "numeric/punctuation content requested direction")
        try expect(!LongTextSegmenter.containsTranslatableLanguage(
            "https://example.com/path"
        ), "URL requested a direction")

        let packEngine = DirectionMockTranslationEngine(status: .supportedNeedsDownload)
        let packCoordinator = OfflineTranslationCoordinator { packEngine }
        let packPipeline = LongTextAnalysisPipeline(translation: packCoordinator)
        let pair = OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        let beforePreparation = await packPipeline.availability(for: pair)
        try expect(beforePreparation == .supportedNeedsDownload,
                   "language-pack-required state missing")
        try await packPipeline.prepareLanguagePack(for: pair)
        let afterPreparation = await packPipeline.availability(for: pair)
        try expect(afterPreparation == .installed,
                   "explicit prepare did not install mock pack")
        let preparationCalls = await packEngine.preparationCalls
        try expect(preparationCalls == 1,
                   "language pack was not prepared exactly once")

        await engine.fail(id: "sentence-0001")
        let partial = try await pipeline.analyze(
            "The first clinical sentence failed. The second treatment sentence worked."
        )
        try expect(partial.sentences.count == 2, "partial-failure sentence count")
        try expect(partial.sentences[0].translationError == .systemFailure,
                   "failed sentence did not keep typed error")
        try expect(partial.sentences[1].translatedText != nil,
                   "one sentence failure blocked another sentence")

        await engine.fail(id: ambiguous.id)
        do {
            _ = try await pipeline.translateSingleSentence(ambiguous, pair: pair)
            throw IntegrationFailure.failed("translation failure was not surfaced")
        } catch let error as OfflineTranslationError {
            try expect(error == .systemFailure, "wrong typed failure")
        }
        try expect(automatic.sentences.allSatisfy { $0.translatedText != nil },
                   "one sentence failure damaged other sentence results")
    }
}
