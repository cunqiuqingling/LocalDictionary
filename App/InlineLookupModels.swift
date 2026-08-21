import AppKit

enum AIRequestIntent: String, Codable, CaseIterable, Sendable {
    case inlineWordQuick = "inline_word_quick"
    case inlineSentenceQuick = "inline_sentence_quick"
    case inlineWordExpansion = "inline_word_expansion"
    case inlineSentenceExpansion = "inline_sentence_expansion"

    var promptVersion: Int {
        self == .inlineWordQuick ? 3 : 2
    }

    var isQuick: Bool {
        self == .inlineWordQuick || self == .inlineSentenceQuick
    }

    var maximumTokens: Int {
        switch self {
        case .inlineWordQuick: return 512
        case .inlineSentenceQuick: return 512
        case .inlineWordExpansion: return 1_800
        case .inlineSentenceExpansion: return 2_600
        }
    }
}

enum InlineLookupSelectionKind: String, Codable, Equatable, Sendable {
    case word
    case phrase
    case sentence
}

enum InlineLookupState: Equatable, Sendable {
    case loadingQuick
    case loadingOffline
    case aiActionAvailable(localMiss: Bool)
    case loadingAI
    case success
    case loadingExpansion
    case compactFailure(String)
}

enum InlineOfflineTranslationState: Equatable, Sendable {
    case notRequested
    case checking(OfflineTranslationPair)
    case translating(OfflineTranslationPair)
    case translated(text: String, pair: OfflineTranslationPair)
    case languagePackRequired(OfflineTranslationPair)
    case unavailable(OfflineTranslationPair)
    case failed(OfflineTranslationPair)
}

/// Chooses the Apple operation for an inline selection from the current language roles.
/// Inline lookup uses the current Native↔Learning pair in both directions. The controller still
/// keeps a reliable single-word local hit ahead of Apple; phrases/sentences and local misses may
/// use an already-installed Apple language pack before the explicit third-party AI action.
enum InlineOfflineTranslationPlanner {
    static func operation(
        for text: String,
        preferences: LanguagePreferences
    ) -> PlannedOfflineTranslation? {
        let context = LanguageContext.make(
            classification: QueryIntentClassifier.classify(text),
            preferences: preferences
        )
        guard let plan = OfflineTranslationPlan.make(context: context) else {
            return nil
        }
        let desiredRole: OfflineTranslationOutputRole = context.isNativeDominant
            ? .learningVersion : .nativeVersion
        return plan.operations.first { operation in
            operation.outputRole == desiredRole &&
                operation.pair.source.languageIdentifier !=
                    operation.pair.target.languageIdentifier
        }
    }

    static func automaticallyTranslates(
        availability: OfflineTranslationAvailability
    ) -> Bool {
        availability == .installed
    }
}

struct InlineWordQuickAIResult: Codable, Equatable, Sendable {
    var partOfSpeech: String
    var definitionsZH: [String]
    var learningEquivalent: String? = nil
    var learningDefinition: String? = nil
    var nativeExplanation: String? = nil
    var exampleLearning: String? = nil
    var exampleNative: String? = nil

    enum CodingKeys: String, CodingKey {
        case partOfSpeech = "part_of_speech"
        case definitionsZH = "definitions_zh"
        case learningEquivalent = "learning_language_equivalent"
        case learningDefinition = "learning_language_definition"
        case nativeExplanation = "native_language_explanation"
        case exampleLearning = "example_learning_language"
        case exampleNative = "example_native_language"
    }

    func validated() throws -> InlineWordQuickAIResult {
        let part = Self.clean(partOfSpeech, limit: 60)
        let definitions = definitionsZH.prefix(3).compactMap { value -> String? in
            let clean = Self.clean(value, limit: 180)
            return clean.isEmpty ? nil : clean
        }
        guard !definitions.isEmpty else {
            throw AIClientError.schemaInvalid(field: "definitions_zh")
        }
        return InlineWordQuickAIResult(
            partOfSpeech: part,
            definitionsZH: definitions,
            learningEquivalent: Self.optionalClean(learningEquivalent, limit: 180),
            learningDefinition: Self.optionalClean(learningDefinition, limit: 360),
            nativeExplanation: Self.optionalClean(nativeExplanation, limit: 360),
            exampleLearning: Self.optionalClean(exampleLearning, limit: 360),
            exampleNative: Self.optionalClean(exampleNative, limit: 360)
        )
    }

    private static func clean(_ value: String, limit: Int) -> String {
        String(SentenceTextNormalizer.normalize(value).prefix(limit))
    }

    private static func optionalClean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let clean = clean(value, limit: limit)
        return clean.isEmpty ? nil : clean
    }
}

struct InlineSentenceQuickAIResult: Codable, Equatable, Sendable {
    var translation: String

    func validated() throws -> InlineSentenceQuickAIResult {
        let clean = String(SentenceTextNormalizer.normalize(translation).prefix(1_200))
        guard !clean.isEmpty else { throw AIClientError.schemaInvalid(field: "translation") }
        return InlineSentenceQuickAIResult(translation: clean)
    }
}

struct InlineWordQuickResult: Equatable, Sendable {
    let partOfSpeech: String
    let definitions: [String]
    let source: String
    let providerDisplayName: String?
    let model: String?
    let fromCache: Bool
    let learningEquivalent: String?
    let learningDefinition: String?
    let nativeExplanation: String?
    let exampleLearning: String?
    let exampleNative: String?

    init(partOfSpeech: String, definitions: [String], source: String,
         providerDisplayName: String?, model: String?, fromCache: Bool,
         learningEquivalent: String? = nil, learningDefinition: String? = nil,
         nativeExplanation: String? = nil, exampleLearning: String? = nil,
         exampleNative: String? = nil) {
        self.partOfSpeech = partOfSpeech
        self.definitions = definitions
        self.source = source
        self.providerDisplayName = providerDisplayName
        self.model = model
        self.fromCache = fromCache
        self.learningEquivalent = learningEquivalent
        self.learningDefinition = learningDefinition
        self.nativeExplanation = nativeExplanation
        self.exampleLearning = exampleLearning
        self.exampleNative = exampleNative
    }

    var isAI: Bool { providerDisplayName != nil }
}

struct InlineSentenceQuickResult: Equatable, Sendable {
    let translation: String
    let providerDisplayName: String
    let model: String
    let fromCache: Bool
}

enum InlineLookupQuickResult: Equatable, Sendable {
    case word(InlineWordQuickResult)
    case sentence(InlineSentenceQuickResult)
}

struct InlineLocalDictionaryHit: Equatable, Sendable {
    let source: String
    let partOfSpeech: String
    let chineseDefinitions: [String]
    let additionalDefinitions: [String]
    let examples: [String]
    let collocations: [String]
    let inflections: [String]
    let roots: [String]
    let isRootDictionary: Bool

    var hasChineseCoreDefinition: Bool {
        !isRootDictionary && !chineseDefinitions.isEmpty
    }

    var hasExpansion: Bool {
        !additionalDefinitions.isEmpty || !examples.isEmpty || !collocations.isEmpty ||
            !inflections.isEmpty || !roots.isEmpty
    }
}

struct InlineLocalLookupSource: Sendable {
    let name: String
    let priority: Int
    let lookup: @MainActor @Sendable (String) -> InlineLocalDictionaryHit?
}

typealias ManagedInlineLookup = @Sendable (String) async -> [InlineLocalDictionaryHit]

struct InlineLocalLookupResult: Equatable, Sendable {
    let quick: InlineWordQuickResult?
    let hits: [InlineLocalDictionaryHit]

    var expansion: InlineLocalExpansion? {
        let definitions = hits.flatMap(\.additionalDefinitions).uniqueInlineValues(maximum: 8)
        let examples = hits.flatMap(\.examples).uniqueInlineValues(maximum: 4)
        let collocations = hits.flatMap(\.collocations).uniqueInlineValues(maximum: 6)
        let inflections = hits.flatMap(\.inflections).uniqueInlineValues(maximum: 8)
        let roots = hits.flatMap(\.roots).uniqueInlineValues(maximum: 6)
        let sources = hits.filter(\.hasExpansion).map(\.source).uniqueInlineValues(maximum: 5)
        let value = InlineLocalExpansion(definitions: definitions,
                                         examples: examples,
                                         collocations: collocations,
                                         inflections: inflections,
                                         roots: roots,
                                         sources: sources)
        return value.hasContent ? value : nil
    }
}

struct InlineLocalExpansion: Equatable, Sendable {
    let definitions: [String]
    let examples: [String]
    let collocations: [String]
    let inflections: [String]
    let roots: [String]
    let sources: [String]

    var hasContent: Bool {
        !definitions.isEmpty || !examples.isEmpty || !collocations.isEmpty ||
            !inflections.isEmpty || !roots.isEmpty
    }
}

enum InlineLookupExpandedResult: Sendable {
    case local(InlineLocalExpansion)
    case aiWord(AIExplanationPresentation)
    case aiSentence(AISentenceAnalysisPresentation)
}

enum InlineBaseBlockKind: String, Equatable, Sendable {
    case paragraph
    case exampleWithTranslation
}

struct InlineBaseBlock {
    let blockID: UUID
    let sourceUTF16Range: NSRange
    let content: NSAttributedString
    let kind: InlineBaseBlockKind
}

struct InlineLookupAnchor: Equatable, Sendable {
    let blockID: UUID
    let selectionUTF16RangeInBlock: NSRange
}

struct InlineSelectionSnapshot: Equatable, Sendable {
    let pageGenerationID: UUID
    let selectedRange: NSRange
    let selectedText: String
    let normalizedText: String
    let containingParagraphRange: NSRange
    let anchor: InlineLookupAnchor
    let selectionKind: InlineLookupSelectionKind
    let contextBefore: String
    let contextAfter: String
    let currentEntryID: String

    var duplicateKey: String {
        "\(anchor.blockID.uuidString)|\(selectionKind.rawValue)|\(normalizedText)"
    }
}

struct InlineLookupSupplement: Sendable {
    let supplementID: UUID
    let parentEntryID: UUID
    let selectionSnapshot: InlineSelectionSnapshot
    var quickResult: InlineLookupQuickResult?
    var expandedResult: InlineLookupExpandedResult?
    var preparedLocalExpansion: InlineLocalExpansion?
    var localSource: String?
    var aiProvider: String?
    var aiModel: String?
    var offlineTranslationState: InlineOfflineTranslationState = .notRequested
    var state: InlineLookupState
    var generation: UInt64

    var selectedText: String { selectionSnapshot.selectedText }
    var normalizedText: String { selectionSnapshot.normalizedText }
    var selectionKind: InlineLookupSelectionKind { selectionSnapshot.selectionKind }
    var anchor: InlineLookupAnchor { selectionSnapshot.anchor }
    var duplicateKey: String { selectionSnapshot.duplicateKey }
}

enum InlineSelectionSnapshotFactory {
    static func capture(
        from textStorage: NSAttributedString,
        selectedRange: NSRange,
        pageGenerationID: UUID,
        currentEntryID: String
    ) -> InlineSelectionSnapshot? {
        guard selectedRange.length > 0,
              selectedRange.location >= 0,
              NSMaxRange(selectedRange) <= textStorage.length,
              !containsInlineSupplement(textStorage, range: selectedRange),
              let mapping = blockMapping(in: textStorage, range: selectedRange) else {
            return nil
        }

        // NSAttributedString and NSString both interpret NSRange as UTF-16 offsets.
        let captured = textStorage.attributedSubstring(from: selectedRange).string
        guard let selection = cleanedSelection(captured) else { return nil }
        let paragraph = (textStorage.string as NSString).paragraphRange(for: selectedRange)
        let nsText = textStorage.string as NSString
        let contextLimit = 32
        let beforeStart = max(mapping.renderedBlockRange.location,
                              selectedRange.location - contextLimit)
        let beforeRange = NSRange(location: beforeStart,
                                  length: selectedRange.location - beforeStart)
        let afterEnd = min(NSMaxRange(mapping.renderedBlockRange),
                           NSMaxRange(selectedRange) + contextLimit)
        let afterRange = NSRange(location: NSMaxRange(selectedRange),
                                 length: afterEnd - NSMaxRange(selectedRange))

        return InlineSelectionSnapshot(
            pageGenerationID: pageGenerationID,
            selectedRange: selectedRange,
            selectedText: selection.text,
            normalizedText: selection.normalized,
            containingParagraphRange: paragraph,
            anchor: InlineLookupAnchor(
                blockID: mapping.blockID,
                selectionUTF16RangeInBlock: NSRange(
                    location: selectedRange.location - mapping.renderedBlockRange.location,
                    length: selectedRange.length
                )
            ),
            selectionKind: selection.kind,
            contextBefore: nsText.substring(with: beforeRange),
            contextAfter: nsText.substring(with: afterRange),
            currentEntryID: currentEntryID
        )
    }

    static func validate(
        _ snapshot: InlineSelectionSnapshot,
        in textStorage: NSAttributedString,
        pageGenerationID: UUID,
        currentEntryID: String
    ) -> Bool {
        guard snapshot.pageGenerationID == pageGenerationID,
              snapshot.currentEntryID == currentEntryID,
              snapshot.selectedRange.length > 0,
              NSMaxRange(snapshot.selectedRange) <= textStorage.length,
              !containsInlineSupplement(textStorage, range: snapshot.selectedRange),
              let mapping = blockMapping(in: textStorage, range: snapshot.selectedRange),
              mapping.blockID == snapshot.anchor.blockID else {
            return false
        }
        let current = textStorage.attributedSubstring(from: snapshot.selectedRange).string
        guard let cleaned = cleanedSelection(current),
              cleaned.kind == snapshot.selectionKind,
              cleaned.normalized == snapshot.normalizedText,
              cleaned.text.precomposedStringWithCanonicalMapping ==
                snapshot.selectedText.precomposedStringWithCanonicalMapping else {
            return false
        }
        let localRange = NSRange(
            location: snapshot.selectedRange.location - mapping.renderedBlockRange.location,
            length: snapshot.selectedRange.length
        )
        return localRange == snapshot.anchor.selectionUTF16RangeInBlock
    }

    static func normalizedIdentity(_ value: String,
                                   kind: InlineLookupSelectionKind) -> String? {
        guard let cleaned = cleanedSelection(value), cleaned.kind == kind else { return nil }
        return cleaned.normalized
    }

    private static func cleanedSelection(_ rawValue: String)
        -> (text: String, normalized: String, kind: InlineLookupSelectionKind)? {
        let classification = QueryIntentClassifier.classify(rawValue)
        let selectedText: String
        let kind: InlineLookupSelectionKind
        switch classification.intent {
        case .word, .phrase:
            selectedText = cleanWordOrPhrase(classification.normalizedText)
            kind = classification.intent == .word ? .word : .phrase
        case .sentence:
            selectedText = classification.normalizedText
            kind = .sentence
        case .textTooLong:
            return nil
        }
        guard !selectedText.isEmpty else { return nil }
        let canonical = selectedText.precomposedStringWithCanonicalMapping
        let normalized = kind == .sentence ? canonical : canonical.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
        return (selectedText, normalized, kind)
    }

    private static func cleanWordOrPhrase(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Browser/PDF/Zotero renderers commonly expose the visual Markdown wrappers as part of
        // the accessibility selection. Strip only a balanced outer wrapper; internal underscores
        // (for example `deep_seek`) remain authoritative query text.
        for (open, close) in [("**", "**"), ("__", "__"), ("`", "`"),
                              ("*", "*"), ("_", "_")] {
            if value.count > open.count + close.count,
               value.hasPrefix(open), value.hasSuffix(close) {
                value = String(value.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"),
            ("「", "」"), ("『", "』"), ("«", "»"), ("‹", "›")
        ]
        if value.count >= 2, let first = value.first, let last = value.last,
           quotePairs.contains(where: { $0.0 == first && $0.1 == last }) {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let boundaryPunctuation: Set<Character> = [
            ",", ".", ";", ":", "!", "?", "，", "。", "；", "：", "！", "？",
            "“", "”", "‘", "’", "\"", "(", ")", "[", "]", "{", "}"
        ]
        while let first = value.first, boundaryPunctuation.contains(first) {
            value.removeFirst()
        }
        while let last = value.last, boundaryPunctuation.contains(last) {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsInlineSupplement(_ storage: NSAttributedString,
                                                 range: NSRange) -> Bool {
        var found = false
        storage.enumerateAttribute(.inlineSupplementID, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private static func blockMapping(in storage: NSAttributedString, range: NSRange)
        -> (blockID: UUID, renderedBlockRange: NSRange)? {
        guard range.length > 0 else { return nil }
        var startRange = NSRange()
        var endRange = NSRange()
        guard let startValue = storage.attribute(.inlineBaseBlockID, at: range.location,
                                                 effectiveRange: &startRange) as? String,
              let endValue = storage.attribute(.inlineBaseBlockID,
                                               at: NSMaxRange(range) - 1,
                                               effectiveRange: &endRange) as? String,
              startValue == endValue,
              startRange == endRange,
              let blockID = UUID(uuidString: startValue) else { return nil }
        return (blockID, startRange)
    }
}

enum InlineBaseBlockBuilder {
    static func build(from attributedString: NSAttributedString) -> [InlineBaseBlock] {
        guard attributedString.length > 0 else { return [] }
        let string = attributedString.string as NSString
        var paragraphs: [(range: NSRange, content: NSAttributedString)] = []
        var location = 0
        while location < attributedString.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard range.length > 0 else { break }
            paragraphs.append((range, attributedString.attributedSubstring(from: range)))
            location = NSMaxRange(range)
        }

        var blocks: [InlineBaseBlock] = []
        var index = 0
        while index < paragraphs.count {
            let current = paragraphs[index]
            if isEnglishExample(current.content), index + 1 < paragraphs.count,
               containsCJK(paragraphs[index + 1].content.string) {
                var endIndex = index + 1
                while endIndex + 1 < paragraphs.count,
                      containsCJK(paragraphs[endIndex + 1].content.string),
                      !isHeading(paragraphs[endIndex + 1].content) {
                    endIndex += 1
                }
                let end = NSMaxRange(paragraphs[endIndex].range)
                let range = NSRange(location: current.range.location,
                                    length: end - current.range.location)
                blocks.append(InlineBaseBlock(
                    blockID: UUID(), sourceUTF16Range: range,
                    content: attributedString.attributedSubstring(from: range),
                    kind: .exampleWithTranslation
                ))
                index = endIndex + 1
                continue
            }
            blocks.append(InlineBaseBlock(blockID: UUID(), sourceUTF16Range: current.range,
                                          content: current.content, kind: .paragraph))
            index += 1
        }
        return blocks
    }

    private static func isEnglishExample(_ value: NSAttributedString) -> Bool {
        let text = value.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.contains(where: isASCIIEnglishLetter),
              !containsCJK(text), let font = firstFont(in: value) else { return false }
        return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
    }

    private static func isASCIIEnglishLetter(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }

    private static func isHeading(_ value: NSAttributedString) -> Bool {
        guard let font = firstFont(in: value) else { return false }
        return font.pointSize >= 15 && NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    private static func firstFont(in value: NSAttributedString) -> NSFont? {
        let ns = value.string as NSString
        for location in 0..<value.length {
            let scalar = ns.substring(with: NSRange(location: location, length: 1))
            if scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let font = value.attribute(.font, at: location, effectiveRange: nil) as? NSFont {
                return font
            }
        }
        return nil
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}

actor InlineLocalLookupService {
    private let sources: [InlineLocalLookupSource]
    private let managedFallback: ManagedInlineLookup?

    init(sources: [InlineLocalLookupSource], managedFallback: ManagedInlineLookup?) {
        self.sources = sources.sorted { $0.priority < $1.priority }
        self.managedFallback = managedFallback
    }

    func lookup(_ query: String) async -> InlineLocalLookupResult {
        let normalized = SentenceTextNormalizer.normalize(query)
        guard !normalized.isEmpty else { return InlineLocalLookupResult(quick: nil, hits: []) }
        var hits: [InlineLocalDictionaryHit] = []
        var quick: InlineWordQuickResult?
        for source in sources {
            guard !Task.isCancelled else { break }
            guard let hit = await source.lookup(normalized) else { continue }
            hits.append(hit)
            if quick == nil, hit.hasChineseCoreDefinition {
                quick = InlineWordQuickResult(
                    partOfSpeech: hit.partOfSpeech,
                    definitions: Array(hit.chineseDefinitions.prefix(3)),
                    source: hit.source,
                    providerDisplayName: nil,
                    model: nil,
                    fromCache: false
                )
            }
        }
        if hits.isEmpty, let managedFallback, !Task.isCancelled {
            let managedHits = await managedFallback(normalized)
            hits.append(contentsOf: managedHits)
            if quick == nil, let hit = managedHits.first {
                let definitions = hit.chineseDefinitions.isEmpty
                    ? hit.additionalDefinitions : hit.chineseDefinitions
                if !definitions.isEmpty {
                    quick = InlineWordQuickResult(
                        partOfSpeech: hit.partOfSpeech,
                        definitions: Array(definitions.prefix(3)),
                        source: hit.source,
                        providerDisplayName: nil,
                        model: nil,
                        fromCache: false
                    )
                }
            }
        }
        return InlineLocalLookupResult(quick: quick, hits: hits)
    }
}

extension NSAttributedString.Key {
    static let inlineSupplementID = NSAttributedString.Key("LocalDictionary.InlineSupplementID")
    static let inlineBaseBlockID = NSAttributedString.Key("LocalDictionary.InlineBaseBlockID")
    static let inlineBaseSourceUTF16Start = NSAttributedString.Key(
        "LocalDictionary.InlineBaseSourceUTF16Start"
    )
    static let inlineControlAnchor = NSAttributedString.Key("LocalDictionary.InlineControlAnchor")
}

struct InlineLayoutMetrics: Equatable {
    static let minimumAvailableWidth: CGFloat = 240
    static let horizontalPadding: CGFloat = 12
    static let leadingBorderWidth: CGFloat = 2

    let textContainerWidth: CGFloat
    let lineFragmentPadding: CGFloat
    let pageInsetLeft: CGFloat
    let pageInsetRight: CGFloat
    let availableWidth: CGFloat
    let blockContentWidth: CGFloat

    var isUsable: Bool {
        availableWidth >= Self.minimumAvailableWidth &&
            blockContentWidth >= Self.minimumAvailableWidth
    }

    static func calculate(textContainerWidth: CGFloat, textViewWidth: CGFloat,
                          lineFragmentPadding: CGFloat,
                          pageInsetLeft: CGFloat, pageInsetRight: CGFloat) -> InlineLayoutMetrics {
        // NSTextView normally removes textContainerInset from containerSize already. Taking
        // the smaller value supports both managed and manually-sized containers without
        // subtracting the insets twice.
        let insetAdjustedViewWidth = max(0, textViewWidth - pageInsetLeft - pageInsetRight)
        let boundedContainerWidth = min(textContainerWidth, insetAdjustedViewWidth)
        let available = max(0, boundedContainerWidth - lineFragmentPadding * 2)
        let content = max(0, available - Self.horizontalPadding * 2 -
                          Self.leadingBorderWidth)
        return InlineLayoutMetrics(
            textContainerWidth: textContainerWidth,
            lineFragmentPadding: lineFragmentPadding,
            pageInsetLeft: pageInsetLeft,
            pageInsetRight: pageInsetRight,
            availableWidth: available,
            blockContentWidth: content
        )
    }
}

enum InlineFloatingButtonPlacement: String, Equatable {
    case right
    case above
    case below
    case left
    case actionRow
}

struct InlineFloatingButtonLayoutResult: Equatable {
    let frame: NSRect
    let placement: InlineFloatingButtonPlacement
}

enum InlineFloatingButtonLayout {
    static func place(buttonSize: NSSize, selectionLineRects: [NSRect],
                      visibleRect: NSRect,
                      selectionLineUsedRects: [NSRect] = [],
                      anchorBlockRect: NSRect? = nil,
                      occupiedTextRects: [NSRect] = [],
                      spacing: CGFloat = 8,
                      edgeInset: CGFloat = 8) -> InlineFloatingButtonLayoutResult? {
        let lines = selectionLineRects.filter { !$0.isEmpty && !$0.isNull }
        guard !lines.isEmpty, buttonSize.width > 0, buttonSize.height > 0 else { return nil }
        let selectionBounds = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
        let lastLine = lines.last!
        let usedLines = selectionLineUsedRects.filter { !$0.isEmpty && !$0.isNull }
        let lastUsedLine = usedLines.last ?? lastLine
        let block = anchorBlockRect ?? selectionBounds
        let occupied = occupiedTextRects.filter { !$0.isEmpty && !$0.isNull }
        let allowed = visibleRect.insetBy(dx: edgeInset, dy: edgeInset)
        guard allowed.width >= buttonSize.width, allowed.height >= buttonSize.height else {
            return nil
        }

        let right = (InlineFloatingButtonPlacement.right,
                     NSRect(x: lastUsedLine.maxX + spacing,
                            y: lastLine.midY - buttonSize.height / 2,
                            width: buttonSize.width, height: buttonSize.height))
        let above = (InlineFloatingButtonPlacement.above,
                     NSRect(x: allowed.maxX - buttonSize.width,
                            y: block.minY - spacing - buttonSize.height,
                            width: buttonSize.width, height: buttonSize.height))
        let below = (InlineFloatingButtonPlacement.below,
                     NSRect(x: allowed.maxX - buttonSize.width,
                            y: selectionBounds.maxY + spacing,
                            width: buttonSize.width, height: buttonSize.height))
        let paragraphAfter = (InlineFloatingButtonPlacement.below,
                              NSRect(x: allowed.maxX - buttonSize.width,
                                     y: block.maxY + spacing,
                                     width: buttonSize.width, height: buttonSize.height))
        let candidates = lines.count > 1
            ? [right, paragraphAfter, below, above]
            : [right, paragraphAfter, above, below]
        for (placement, frame) in candidates {
            guard allowed.contains(frame), !frame.intersects(selectionBounds),
                  !lines.contains(where: frame.intersects),
                  !occupied.contains(where: { frame.intersects($0.insetBy(dx: -2, dy: -1)) })
            else { continue }
            return InlineFloatingButtonLayoutResult(frame: frame, placement: placement)
        }

        // Last resort: find a real visible gap after the semantic block. The control remains an
        // independent NSView; no button text or attachment is inserted into textStorage.
        var y = max(block.maxY + spacing, allowed.minY)
        while y + buttonSize.height <= allowed.maxY {
            let frame = NSRect(x: allowed.maxX - buttonSize.width, y: y,
                               width: buttonSize.width, height: buttonSize.height)
            if !frame.intersects(selectionBounds),
               !occupied.contains(where: { frame.intersects($0.insetBy(dx: -2, dy: -1)) }) {
                return InlineFloatingButtonLayoutResult(frame: frame, placement: .actionRow)
            }
            y += 4
        }
        return nil
    }
}

final class InlineLookupAttributedFormatter {
    func format(_ supplement: InlineLookupSupplement,
                layout: InlineLayoutMetrics) -> NSAttributedString {
        precondition(layout.isUsable)
        let output = NSMutableAttributedString()
        let textBlock = makeTextBlock(layout: layout)
        append("\n", to: output)
        append("\(supplement.selectedText)\n",
               font: .systemFont(ofSize: 13.5, weight: .semibold),
               color: .labelColor, spacingBefore: 5, spacingAfter: 3,
               textBlock: textBlock, to: output)

        switch supplement.state {
        case .loadingQuick:
            append("正在查询本地词典…\n", color: .secondaryLabelColor,
                   textBlock: textBlock, to: output)
        case .loadingOffline:
            break
        case .aiActionAvailable(let localMiss):
            if localMiss {
                append("未找到本地释义。可按需使用 AI 双语解释。\n",
                       color: .secondaryLabelColor, textBlock: textBlock, to: output)
            } else {
                append("可按需使用 AI 双语解释；未点击不会联网。\n",
                       color: .secondaryLabelColor, textBlock: textBlock, to: output)
            }
        case .loadingAI:
            append("AI 双语解释正在请求…\n", color: .secondaryLabelColor,
                   textBlock: textBlock, to: output)
        case .loadingExpansion:
            appendQuick(supplement.quickResult, textBlock: textBlock, to: output)
            append("正在加载更多内容…\n", color: .secondaryLabelColor,
                   textBlock: textBlock, to: output)
        case .compactFailure(let message):
            appendQuick(supplement.quickResult, textBlock: textBlock, to: output)
            append("\(message)\n", color: .secondaryLabelColor,
                   textBlock: textBlock, to: output)
        case .success:
            if let expanded = supplement.expandedResult {
                appendExpanded(expanded, quick: supplement.quickResult,
                               textBlock: textBlock, to: output)
            } else {
                appendQuick(supplement.quickResult, textBlock: textBlock, to: output)
            }
        }

        appendOfflineTranslation(
            supplement.offlineTranslationState,
            textBlock: textBlock,
            beforeAIContentIn: output
        )

        let source = sourceText(for: supplement)
        if !source.isEmpty {
            append("来源：\(source)\n", font: .systemFont(ofSize: 10.5),
                   color: .secondaryLabelColor, spacingBefore: 3,
                   textBlock: textBlock, to: output)
        }
        let anchorLocation = output.length
        append("\u{200B}\n",
               font: .systemFont(ofSize: 11), color: .clear, spacingAfter: 6,
               textBlock: textBlock, to: output)
        output.addAttribute(.inlineControlAnchor, value: supplement.supplementID.uuidString,
                            range: NSRange(location: anchorLocation,
                                           length: output.length - anchorLocation))
        output.addAttribute(.inlineSupplementID, value: supplement.supplementID.uuidString,
                            range: NSRange(location: 0, length: output.length))
        return output
    }

    private func appendQuick(_ result: InlineLookupQuickResult?, textBlock: NSTextBlock,
                             to output: NSMutableAttributedString) {
        guard let result else { return }
        switch result {
        case .word(let word):
            if let equivalent = word.learningEquivalent, !equivalent.isEmpty {
                append("学习语言表达\n", font: .systemFont(ofSize: 11.5, weight: .semibold),
                       color: .labelColor, spacingBefore: 2,
                       textBlock: textBlock, to: output)
                append("\(equivalent)\n", font: .systemFont(ofSize: 14, weight: .semibold),
                       color: .labelColor, textBlock: textBlock, to: output)
            }
            if !word.partOfSpeech.isEmpty {
                append("\(word.partOfSpeech)\n", font: .systemFont(ofSize: 11.5, weight: .medium),
                       color: .labelColor, textBlock: textBlock, to: output)
            }
            if word.isAI && !word.definitions.isEmpty {
                append("母语核心释义\n", font: .systemFont(ofSize: 11.5, weight: .semibold),
                       color: .labelColor, spacingBefore: 2,
                       textBlock: textBlock, to: output)
            }
            for definition in word.definitions {
                append("• \(definition)\n", font: .systemFont(ofSize: 12.5),
                       color: .labelColor, textBlock: textBlock, to: output)
            }
            if let definition = word.learningDefinition, !definition.isEmpty {
                append("学习语言释义\n", font: .systemFont(ofSize: 11.5, weight: .semibold),
                       color: .labelColor, spacingBefore: 3,
                       textBlock: textBlock, to: output)
                append("\(definition)\n", font: .systemFont(ofSize: 12.5),
                       color: .labelColor, textBlock: textBlock, to: output)
            }
            if let explanation = word.nativeExplanation, !explanation.isEmpty,
               !word.definitions.contains(explanation) {
                append("用法说明\n", font: .systemFont(ofSize: 11.5, weight: .semibold),
                       color: .labelColor, spacingBefore: 3,
                       textBlock: textBlock, to: output)
                append("\(explanation)\n", font: .systemFont(ofSize: 12.5),
                       color: .labelColor, textBlock: textBlock, to: output)
            }
            if let learning = word.exampleLearning, !learning.isEmpty {
                append("例句\n", font: .systemFont(ofSize: 11.5, weight: .semibold),
                       color: .labelColor, spacingBefore: 3,
                       textBlock: textBlock, to: output)
                append("\(learning)\n", font: NSFontManager.shared.convert(
                    .systemFont(ofSize: 12.5), toHaveTrait: .italicFontMask
                ), color: .labelColor, textBlock: textBlock, to: output)
            }
            if let native = word.exampleNative, !native.isEmpty {
                append("\(native)\n", font: .systemFont(ofSize: 12.5),
                       color: .labelColor, textBlock: textBlock, to: output)
            }
        case .sentence(let sentence):
            append("\(sentence.translation)\n", font: .systemFont(ofSize: 13),
                   color: .labelColor, spacingAfter: 2, textBlock: textBlock, to: output)
        }
    }

    private func appendOfflineTranslation(
        _ state: InlineOfflineTranslationState,
        textBlock: NSTextBlock,
        beforeAIContentIn output: NSMutableAttributedString
    ) {
        // This content belongs before AI output. Insert it immediately after the selected-text
        // heading even though the formatter appends the AI state first for legacy cards.
        let content = NSMutableAttributedString()
        switch state {
        case .notRequested:
            return
        case .checking(let pair):
            append("正在检查 Apple 系统离线翻译（\(direction(pair))）…\n",
                   color: .secondaryLabelColor, textBlock: textBlock, to: content)
        case .translating(let pair):
            append("Apple 系统离线翻译正在处理（\(direction(pair))）…\n",
                   color: .secondaryLabelColor, textBlock: textBlock, to: content)
        case .translated(let text, let pair):
            append("Apple 系统离线翻译（\(direction(pair))）\n",
                   font: .systemFont(ofSize: 11.5, weight: .semibold),
                   color: .secondaryLabelColor, spacingBefore: 2,
                   textBlock: textBlock, to: content)
            append("\(text)\n", font: .systemFont(ofSize: 13),
                   color: .labelColor, spacingAfter: 3,
                   textBlock: textBlock, to: content)
        case .languagePackRequired(let pair):
            append("Apple 离线翻译语言包尚未准备（\(direction(pair))）。" +
                   "可在主查询的“本地功能”中主动准备。\n",
                   color: .secondaryLabelColor, textBlock: textBlock, to: content)
        case .unavailable(let pair):
            append("Apple 系统离线翻译暂不可用（\(direction(pair))）。\n",
                   color: .secondaryLabelColor, textBlock: textBlock, to: content)
        case .failed(let pair):
            append("Apple 系统离线翻译本次未完成（\(direction(pair))）。\n",
                   color: .secondaryLabelColor, textBlock: textBlock, to: content)
        }
        let insertion = selectedTextHeadingEnd(in: output)
        output.insert(content, at: insertion)
    }

    private func selectedTextHeadingEnd(in output: NSAttributedString) -> Int {
        let string = output.string as NSString
        guard string.length > 0 else { return 0 }
        let first = string.range(of: "\n")
        guard first.location != NSNotFound else { return output.length }
        let secondSearch = NSRange(
            location: NSMaxRange(first),
            length: string.length - NSMaxRange(first)
        )
        let second = string.range(of: "\n", options: [], range: secondSearch)
        return second.location == NSNotFound ? output.length : NSMaxRange(second)
    }

    private func direction(_ pair: OfflineTranslationPair) -> String {
        "\(pair.source.languageIdentifier.chineseName) → " +
            pair.target.languageIdentifier.chineseName
    }

    private func appendExpanded(_ result: InlineLookupExpandedResult,
                                quick: InlineLookupQuickResult?,
                                textBlock: NSTextBlock,
                                to output: NSMutableAttributedString) {
        switch result {
        case .local(let expansion):
            appendQuick(quick, textBlock: textBlock, to: output)
            appendSection("更多本地内容", values: expansion.definitions,
                          textBlock: textBlock, to: output)
            appendSection("词形", values: expansion.inflections,
                          textBlock: textBlock, to: output)
            appendSection("搭配", values: expansion.collocations,
                          textBlock: textBlock, to: output)
            appendSection("例句", values: expansion.examples,
                          textBlock: textBlock, to: output, italic: true)
            appendSection("构词", values: expansion.roots,
                          textBlock: textBlock, to: output)
        case .aiWord(let presentation):
            appendFormatted(AIEntryFormatter().format(presentation),
                            textBlock: textBlock, to: output)
        case .aiSentence(let presentation):
            appendFormatted(AISentenceEntryFormatter().format(presentation),
                            textBlock: textBlock, to: output)
        }
    }

    private func appendFormatted(_ value: NSAttributedString, textBlock: NSTextBlock,
                                 to output: NSMutableAttributedString) {
        let formatted = NSMutableAttributedString(attributedString: value)
        let string = formatted.string as NSString
        var location = 0
        while location < formatted.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard range.length > 0 else { break }
            let existing = formatted.attribute(.paragraphStyle, at: range.location,
                                               effectiveRange: nil) as? NSParagraphStyle
            let style = paragraphStyle(spacingBefore: existing?.paragraphSpacingBefore ?? 0,
                                       spacingAfter: existing?.paragraphSpacing ?? 3,
                                       textBlock: textBlock)
            formatted.addAttribute(.paragraphStyle, value: style, range: range)
            location = NSMaxRange(range)
        }
        output.append(formatted)
    }

    private func appendSection(_ title: String, values: [String],
                               textBlock: NSTextBlock,
                               to output: NSMutableAttributedString, italic: Bool = false) {
        guard !values.isEmpty else { return }
        append("\(title)\n", font: .systemFont(ofSize: 11.5, weight: .semibold),
               color: .secondaryLabelColor, spacingBefore: 4,
               textBlock: textBlock, to: output)
        for value in values {
            let font = italic ? NSFontManager.shared.convert(
                .systemFont(ofSize: 12), toHaveTrait: .italicFontMask
            ) : .systemFont(ofSize: 12)
            append("• \(value)\n", font: font, color: .labelColor,
                   textBlock: textBlock, to: output)
        }
    }

    private func sourceText(for supplement: InlineLookupSupplement) -> String {
        var values: [String] = []
        if case .translated = supplement.offlineTranslationState {
            values.append("Apple 系统离线翻译")
        }
        if let local = supplement.localSource, !local.isEmpty { values.append(local) }
        if let provider = supplement.aiProvider, !provider.isEmpty {
            let model = supplement.aiModel?.isEmpty == false ? " · \(supplement.aiModel!)" : ""
            values.append("AI：\(provider)\(model)")
        }
        return values.joined(separator: "；")
    }

    private func append(_ string: String, font: NSFont = .systemFont(ofSize: 12),
                        color: NSColor = .labelColor, spacingBefore: CGFloat = 0,
                        spacingAfter: CGFloat = 0, textBlock: NSTextBlock? = nil,
                        to output: NSMutableAttributedString) {
        let paragraph = paragraphStyle(spacingBefore: spacingBefore,
                                       spacingAfter: spacingAfter,
                                       textBlock: textBlock)
        output.append(NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]))
    }

    private func paragraphStyle(spacingBefore: CGFloat, spacingAfter: CGFloat,
                                textBlock: NSTextBlock?) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 0
        paragraph.tailIndent = 0
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = .leftToRight
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0
        paragraph.tabStops = []
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.lineSpacing = 1
        if let textBlock { paragraph.textBlocks = [textBlock] }
        return paragraph
    }

    private func makeTextBlock(layout: InlineLayoutMetrics) -> NSTextBlock {
        let block = NSTextBlock()
        block.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.22)
        block.setBorderColor(NSColor.separatorColor.withAlphaComponent(0.8), for: .minX)
        block.setContentWidth(layout.blockContentWidth, type: .absoluteValueType)
        block.setWidth(InlineLayoutMetrics.leadingBorderWidth, type: .absoluteValueType,
                       for: .border, edge: .minX)
        block.setWidth(InlineLayoutMetrics.horizontalPadding, type: .absoluteValueType,
                       for: .padding)
        return block
    }
}

final class InlinePageRenderer {
    private let formatter: InlineLookupAttributedFormatter

    init(formatter: InlineLookupAttributedFormatter = InlineLookupAttributedFormatter()) {
        self.formatter = formatter
    }

    func render(baseBlocks: [InlineBaseBlock],
                supplements: [InlineLookupSupplement],
                layout: InlineLayoutMetrics?) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let grouped = Dictionary(grouping: supplements) { $0.anchor.blockID }
        for block in baseBlocks {
            let base = NSMutableAttributedString(attributedString: block.content)
            if base.length > 0 {
                base.addAttributes([
                    .inlineBaseBlockID: block.blockID.uuidString,
                    .inlineBaseSourceUTF16Start: block.sourceUTF16Range.location
                ], range: NSRange(location: 0, length: base.length))
            }
            output.append(base)
            guard let layout, layout.isUsable else { continue }
            for supplement in (grouped[block.blockID] ?? []).sorted(by: {
                $0.anchor.selectionUTF16RangeInBlock.location <
                    $1.anchor.selectionUTF16RangeInBlock.location
            }) {
                output.append(formatter.format(supplement, layout: layout))
            }
        }
        return output
    }
}

final class InlineLookupMarkdownFormatter {
    func items(from supplements: [InlineLookupSupplement]) -> [InlineLookupNoteItem] {
        supplements.compactMap(item).reduce(into: [InlineLookupNoteItem]()) { result, value in
            if let index = result.firstIndex(where: { $0.identity == value.identity }) {
                if result[index].expandedLines.isEmpty && !value.expandedLines.isEmpty {
                    result[index] = value
                }
            } else {
                result.append(value)
            }
        }
    }

    private func item(_ supplement: InlineLookupSupplement) -> InlineLookupNoteItem? {
        guard let quick = supplement.quickResult else { return nil }
        var quickLines: [String] = []
        switch quick {
        case .word(let result):
            if !result.partOfSpeech.isEmpty { quickLines.append("- 词性：\(result.partOfSpeech)") }
            for definition in result.definitions.prefix(3) {
                quickLines.append("- 简释：\(definition)")
            }
        case .sentence(let result):
            quickLines.append("- 中文翻译：\(result.translation)")
        }
        guard !quickLines.isEmpty else { return nil }
        return InlineLookupNoteItem(
            selectedText: supplement.selectedText,
            normalizedText: supplement.normalizedText,
            kind: supplement.selectionKind.rawValue,
            quickLines: quickLines,
            expandedLines: expandedLines(for: supplement.expandedResult),
            source: supplement.localSource ?? "",
            provider: supplement.aiProvider,
            model: supplement.aiModel
        )
    }

    private func expandedLines(for result: InlineLookupExpandedResult?) -> [String] {
        guard let result else { return [] }
        switch result {
        case .local(let expansion):
            var lines: [String] = []
            lines += expansion.definitions.prefix(8).map { "- 更多释义：\($0)" }
            lines += expansion.inflections.prefix(8).map { "- 词形：\($0)" }
            lines += expansion.collocations.prefix(6).map { "- 搭配：\($0)" }
            lines += expansion.examples.prefix(4).map { "- 例句：\($0)" }
            lines += expansion.roots.prefix(6).map { "- 构词：\($0)" }
            return lines
        case .aiWord(let presentation):
            var lines: [String] = []
            for part in presentation.explanation.partsOfSpeech.prefix(4) {
                if !part.partOfSpeech.isEmpty { lines.append("- 词性：\(part.partOfSpeech)") }
                for sense in part.senses.prefix(4) {
                    if !sense.definitionZH.isEmpty { lines.append("- 中文释义：\(sense.definitionZH)") }
                    if !sense.definitionEN.isEmpty { lines.append("- 英文释义：\(sense.definitionEN)") }
                    for example in sense.examples.prefix(2) where !example.en.isEmpty {
                        lines.append("- 例句：\(example.en)")
                        if !example.zh.isEmpty { lines.append("- 译文：\(example.zh)") }
                    }
                    lines += sense.collocations.prefix(4).map { "- 搭配：\($0)" }
                }
            }
            return lines
        case .aiSentence(let presentation):
            let analysis = presentation.analysis
            var lines = ["- 自然翻译：\(analysis.translationZH)"]
            if !analysis.coreStructure.structureSummaryZH.isEmpty {
                lines.append("- 句子主干：\(analysis.coreStructure.structureSummaryZH)")
            }
            for point in analysis.grammarPoints.prefix(5) {
                lines.append("- 语法：\(point.grammarName) — \(point.explanationZH)")
            }
            for collocation in analysis.collocations.prefix(5) {
                lines.append("- 搭配：\(collocation.expression) — \(collocation.meaningZH)")
            }
            if !analysis.paraphraseEN.isEmpty { lines.append("- 简化改写：\(analysis.paraphraseEN)") }
            if !analysis.learningNoteZH.isEmpty { lines.append("- 学习提示：\(analysis.learningNoteZH)") }
            return lines
        }
    }
}

private extension Array where Element == String {
    func uniqueInlineValues(maximum: Int) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in self {
            let clean = SentenceTextNormalizer.normalize(value)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            output.append(clean)
            if output.count == maximum { break }
        }
        return output
    }
}
