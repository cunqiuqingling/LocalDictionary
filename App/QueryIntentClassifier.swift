import Foundation

enum QueryIntent: Equatable {
    case word
    case phrase
    case sentence
    case textTooLong
}

enum QueryLanguage: String, Codable, Equatable, Sendable {
    case english
    case simplifiedChinese
    case mixed
    case undetermined
}

/// Stable language identity is intentionally separate from the current English/Chinese
/// implementation types. A language can be registered without being selectable in production.
enum LanguageIdentifier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case german = "de"
    case japanese = "ja"

    var englishName: String {
        switch self {
        case .simplifiedChinese: return "Simplified Chinese"
        case .english: return "English"
        case .german: return "German"
        case .japanese: return "Japanese"
        }
    }

    var chineseName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .german: return "德语"
        case .japanese: return "日语"
        }
    }
}

enum UILanguagePreference: String, Codable, CaseIterable, Equatable, Sendable {
    case followNative
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    func resolved(nativeLanguage: LanguageIdentifier) -> LanguageIdentifier {
        switch self {
        case .followNative:
            return nativeLanguage == .english ? .english : .simplifiedChinese
        case .simplifiedChinese: return .simplifiedChinese
        case .english: return .english
        }
    }
}

struct LanguagePreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let productionDefault = LanguagePreferences(
        nativeLanguage: .simplifiedChinese,
        learningLanguage: .english,
        uiLanguage: .followNative
    )

    var schemaVersion: Int = currentSchemaVersion
    var nativeLanguage: LanguageIdentifier
    var learningLanguage: LanguageIdentifier
    var uiLanguage: UILanguagePreference

    var resolvedUILanguage: LanguageIdentifier {
        uiLanguage.resolved(nativeLanguage: nativeLanguage)
    }


    var isProductionPair: Bool {
        LanguageCapabilityRegistry.shared.isProductionPair(
            native: nativeLanguage, learning: learningLanguage
        )
    }
}

protocol LanguagePreferencesPersisting: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: LanguagePreferencesPersisting {}

final class LanguagePreferencesStore: @unchecked Sendable {
    static let shared = LanguagePreferencesStore()
    static let defaultsKey = "LocalDictionary.LanguagePreferences.v1"

    private let defaults: LanguagePreferencesPersisting
    private let lock = NSLock()

    init(defaults: LanguagePreferencesPersisting = UserDefaults.standard) {
        self.defaults = defaults
    }

    func load() -> LanguagePreferences {
#if REVERSE_INDEX_CONTROLLER_TESTING
        if ProcessInfo.processInfo.environment["LOCALDICTIONARY_REVERSE_TEST_MODE"] != nil {
            return .productionDefault
        }
#endif
        lock.lock()
        defer { lock.unlock() }
        if let data = defaults.data(forKey: Self.defaultsKey),
           let value = try? JSONDecoder().decode(LanguagePreferences.self, from: data),
           value.schemaVersion == LanguagePreferences.currentSchemaVersion,
           value.isProductionPair,
           [.simplifiedChinese, .english].contains(value.resolvedUILanguage) {
            return value
        }
        let migrated = LanguagePreferences.productionDefault
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        return migrated
    }

    @discardableResult
    func save(_ preferences: LanguagePreferences) -> Bool {
        guard preferences.schemaVersion == LanguagePreferences.currentSchemaVersion,
              preferences.isProductionPair,
              [.simplifiedChinese, .english].contains(preferences.resolvedUILanguage),
              let data = try? JSONEncoder().encode(preferences) else { return false }
        lock.lock()
        defaults.set(data, forKey: Self.defaultsKey)
        let saved = defaults.data(forKey: Self.defaultsKey) == data
        lock.unlock()
        if saved {
            NotificationCenter.default.post(
                name: .localDictionaryLanguagePreferencesDidChange,
                object: self,
                userInfo: ["preferences": preferences]
            )
        }
        return saved
    }
}

extension Notification.Name {
    /// Posted only after a validated Native/Learning pair has been durably stored. Controllers
    /// use it to discard any operation configured with the old Apple language pair.
    static let localDictionaryLanguagePreferencesDidChange = Notification.Name(
        "LocalDictionary.LanguagePreferencesDidChange"
    )
}

enum QueryLanguageRelation: String, Codable, Equatable, Sendable {
    case native
    case learning
    case mixedNativeDominant
    case mixedLearningDominant
    case unsupported
}

enum LanguageCoverageBucket: String, Codable, Equatable, Sendable {
    case none
    case low
    case medium
    case high
}

enum LanguageClassifierConfidenceBucket: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

/// A bounded, script-aware profile for the production Chinese/English pair. Latin product names
/// and identifiers are deliberately down-weighted so a few spans such as `FreeDict` or `GPT-5`
/// cannot turn an otherwise Chinese sentence into an English-dominant query.
struct LanguageTextProfile: Equatable, Sendable {
    let hanCharacterCount: Int
    let latinTokenCount: Int
    let dominantLanguage: LanguageIdentifier?
    let nativeCoverageBucket: LanguageCoverageBucket
    let learningCoverageBucket: LanguageCoverageBucket
    let confidenceBucket: LanguageClassifierConfidenceBucket

    fileprivate let chineseScore: Double
    fileprivate let englishScore: Double

    static func make(_ source: String) -> LanguageTextProfile {
        let normalized = SentenceTextNormalizer.normalize(source)
        let han = normalized.unicodeScalars.filter(QueryIntentClassifier.isCJK).count
        let tokens = QueryIntentClassifier.englishWords(in: normalized)
        let english = tokens.reduce(0.0) { partial, token in
            partial + latinWeight(token)
        }
        let chinese = han == 0 ? 0 : max(1, Double(han) / 2.0)
        let dominant: LanguageIdentifier?
        if chinese == 0, english == 0 { dominant = nil }
        else if chinese >= english { dominant = .simplifiedChinese }
        else { dominant = .english }
        let total = chinese + english
        let nativeRatio = total == 0 ? 0 : chinese / total
        let learningRatio = total == 0 ? 0 : english / total
        let larger = max(chinese, english)
        let smaller = min(chinese, english)
        let ratio = smaller == 0 ? (larger > 0 ? Double.infinity : 1) : larger / smaller
        let confidence: LanguageClassifierConfidenceBucket = ratio >= 2.0
            ? .high : (ratio >= 1.35 ? .medium : .low)
        return LanguageTextProfile(
            hanCharacterCount: han,
            latinTokenCount: tokens.count,
            dominantLanguage: dominant,
            nativeCoverageBucket: bucket(nativeRatio),
            learningCoverageBucket: bucket(learningRatio),
            confidenceBucket: confidence,
            chineseScore: chinese,
            englishScore: english
        )
    }

    private static func bucket(_ ratio: Double) -> LanguageCoverageBucket {
        if ratio == 0 { return .none }
        if ratio >= 0.7 { return .high }
        if ratio >= 0.35 { return .medium }
        return .low
    }

    private static func latinWeight(_ token: String) -> Double {
        let lower = token.lowercased()
        if englishFunctionWords.contains(lower) { return 1 }
        let scalars = token.unicodeScalars
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasInternalUppercase = token.dropFirst().contains { $0.isUppercase }
        let looksLikeName = token.first?.isUppercase == true || token == token.uppercased()
        return (hasDigit || hasInternalUppercase || looksLikeName) ? 0.35 : 1
    }

    private static let englishFunctionWords: Set<String> = [
        "a", "an", "and", "as", "at", "be", "but", "by", "for", "from", "if", "in",
        "is", "it", "not", "of", "on", "or", "that", "the", "then", "this", "to",
        "was", "were", "will", "with"
    ]
}

struct TargetLanguageValidation: Equatable, Sendable {
    let resultLanguage: LanguageIdentifier?
    let isTargetLanguage: Bool
    let hanCharacterCount: Int
    let latinTokenCount: Int
}

/// A shared, bounded language gate used after both Apple and third-party translation. It does
/// not attempt semantic scoring; it only prevents a result dominated by the wrong language from
/// being published under a declared target-language role.
enum TargetLanguageValidator {
    static func validate(_ text: String,
                         targetLanguage: LanguageIdentifier) -> TargetLanguageValidation {
        let profile = LanguageTextProfile.make(text)
        let valid: Bool
        switch targetLanguage {
        case .english:
            valid = profile.dominantLanguage == .english && profile.latinTokenCount > 0
        case .simplifiedChinese:
            valid = profile.dominantLanguage == .simplifiedChinese &&
                profile.hanCharacterCount > 0
        case .german, .japanese:
            valid = profile.dominantLanguage == targetLanguage
        }
        return TargetLanguageValidation(
            resultLanguage: profile.dominantLanguage,
            isTargetLanguage: valid,
            hanCharacterCount: profile.hanCharacterCount,
            latinTokenCount: profile.latinTokenCount
        )
    }
}

struct LanguageContext: Equatable, Sendable {
    let nativeLanguage: LanguageIdentifier
    let learningLanguage: LanguageIdentifier
    let uiLanguage: LanguageIdentifier
    let queryLanguage: LanguageIdentifier?
    let queryRelation: QueryLanguageRelation
    let dominantLanguage: LanguageIdentifier?
    let hanCharacterCount: Int
    let latinTokenCount: Int
    let nativeCoverageBucket: LanguageCoverageBucket
    let learningCoverageBucket: LanguageCoverageBucket
    let classifierConfidenceBucket: LanguageClassifierConfidenceBucket
    let translationTargetLanguage: LanguageIdentifier?
    let studyTextLanguage: LanguageIdentifier
    let explanationLanguage: LanguageIdentifier

    var isNativeDominant: Bool {
        queryRelation == .native || queryRelation == .mixedNativeDominant
    }

    var isLearningDominant: Bool {
        queryRelation == .learning || queryRelation == .mixedLearningDominant
    }

    var isMixed: Bool {
        queryRelation == .mixedNativeDominant || queryRelation == .mixedLearningDominant
    }

    var isPureLearning: Bool { queryRelation == .learning }
    var isPureNative: Bool { queryRelation == .native }

    /// Mixed text must be normalized into a validated learning-language version before it can be
    /// used as the grammar-analysis object, regardless of which script is more numerous.
    var requiresLearningVersion: Bool { queryRelation != .learning }

    static func make(query: String,
                     preferences: LanguagePreferences =
                        LanguagePreferencesStore.shared.load()) -> LanguageContext {
        make(classification: QueryIntentClassifier.classify(query), preferences: preferences)
    }

    static func make(classification: QueryIntentClassification,
                     preferences: LanguagePreferences,
                     explanationLanguage: LanguageIdentifier? = nil) -> LanguageContext {
        let profile = LanguageTextProfile.make(classification.normalizedText)
        let queryLanguage = classification.language == .mixed
            ? profile.dominantLanguage : classification.language.languageIdentifier
        let relation: QueryLanguageRelation
        if classification.language == .mixed {
            relation = profile.dominantLanguage == preferences.learningLanguage
                ? .mixedLearningDominant : .mixedNativeDominant
        } else if queryLanguage == preferences.nativeLanguage {
            relation = .native
        } else if queryLanguage == preferences.learningLanguage {
            relation = .learning
        } else {
            relation = .unsupported
        }
        let target: LanguageIdentifier?
        switch relation {
        case .native, .mixedNativeDominant: target = preferences.learningLanguage
        case .learning, .mixedLearningDominant: target = preferences.nativeLanguage
        case .unsupported: target = nil
        }
        let nativeCoverage = preferences.nativeLanguage == .simplifiedChinese
            ? profile.nativeCoverageBucket : profile.learningCoverageBucket
        let learningCoverage = preferences.learningLanguage == .english
            ? profile.learningCoverageBucket : profile.nativeCoverageBucket
        return LanguageContext(
            nativeLanguage: preferences.nativeLanguage,
            learningLanguage: preferences.learningLanguage,
            uiLanguage: preferences.resolvedUILanguage,
            queryLanguage: queryLanguage,
            queryRelation: relation,
            dominantLanguage: profile.dominantLanguage,
            hanCharacterCount: profile.hanCharacterCount,
            latinTokenCount: profile.latinTokenCount,
            nativeCoverageBucket: nativeCoverage,
            learningCoverageBucket: learningCoverage,
            classifierConfidenceBucket: profile.confidenceBucket,
            translationTargetLanguage: target,
            studyTextLanguage: preferences.learningLanguage,
            explanationLanguage: explanationLanguage ?? preferences.nativeLanguage
        )
    }
}

enum StudyTextOrigin: String, Codable, Equatable, Sendable {
    case originalQuery
    case appleTranslation
    case aiTranslation
}

struct StudyText: Codable, Equatable, Sendable {
    let text: String
    let language: LanguageIdentifier
    let origin: StudyTextOrigin

    init?(text: String, language: LanguageIdentifier, origin: StudyTextOrigin) {
        let normalized = SentenceTextNormalizer.normalize(text)
        guard !normalized.isEmpty else { return nil }
        self.text = normalized
        self.language = language
        self.origin = origin
    }
}

struct OfflineStudyText: Equatable, Sendable {
    let studyText: StudyText

    init?(_ studyText: StudyText) {
        guard studyText.origin == .appleTranslation else { return nil }
        self.studyText = studyText
    }
}

/// Canonical third-party translation artifact for one native-language query. Both deep
/// translation rendering and sentence analysis consume this same value; Apple output never
/// initializes it.
struct AIStudyText: Equatable, Sendable {
    static let currentPromptVersion = 3
    let queryIdentity: String
    let sourceText: String
    let sourceLanguage: LanguageIdentifier?
    let nativeLanguage: LanguageIdentifier
    let learningLanguage: LanguageIdentifier
    let explanationLanguage: LanguageIdentifier
    let queryRelation: QueryLanguageRelation
    let dominantLanguage: LanguageIdentifier?
    let translationTargetLanguage: LanguageIdentifier
    let studyText: StudyText
    let providerID: UUID
    let model: String
    let promptVersion: Int
    let generation: UInt64

    func matches(query: String, context: LanguageContext,
                 providerID: UUID, model: String, generation: UInt64) -> Bool {
        queryIdentity == SentenceTextNormalizer.normalize(query) &&
            sourceText == SentenceTextNormalizer.normalize(query) &&
            sourceLanguage == context.queryLanguage &&
            nativeLanguage == context.nativeLanguage &&
            learningLanguage == context.learningLanguage &&
            explanationLanguage == context.explanationLanguage &&
            queryRelation == context.queryRelation &&
            dominantLanguage == context.dominantLanguage &&
            translationTargetLanguage == context.learningLanguage &&
            self.providerID == providerID && self.model == model &&
            promptVersion == Self.currentPromptVersion &&
            self.generation == generation
    }
}

struct LanguageCapability: Equatable, Sendable {
    let language: LanguageIdentifier
    let productionReady: Bool
    let wordLookup: Bool
    let lemma: Bool
    let dictionaryImport: Bool
    let aiAnalysis: Bool
    let nativeTranslationPartners: Set<LanguageIdentifier>
    let reverseFromNative: Set<LanguageIdentifier>
}

struct LanguageCapabilityRegistry: Sendable {
    static let shared = LanguageCapabilityRegistry()

    let capabilities: [LanguageIdentifier: LanguageCapability] = [
        .simplifiedChinese: LanguageCapability(
            language: .simplifiedChinese, productionReady: true,
            wordLookup: true, lemma: false, dictionaryImport: true, aiAnalysis: true,
            nativeTranslationPartners: [.english],
            reverseFromNative: [.english]
        ),
        .english: LanguageCapability(
            language: .english, productionReady: true,
            wordLookup: true, lemma: true, dictionaryImport: true, aiAnalysis: true,
            nativeTranslationPartners: [.simplifiedChinese],
            reverseFromNative: [.simplifiedChinese]
        ),
        .german: LanguageCapability(
            language: .german, productionReady: false,
            wordLookup: false, lemma: false, dictionaryImport: false, aiAnalysis: false,
            nativeTranslationPartners: [], reverseFromNative: []
        ),
        .japanese: LanguageCapability(
            language: .japanese, productionReady: false,
            wordLookup: false, lemma: false, dictionaryImport: false, aiAnalysis: false,
            nativeTranslationPartners: [], reverseFromNative: []
        )
    ]

    var productionLearningLanguages: [LanguageIdentifier] {
        capabilities.values.filter(\.productionReady).map(\.language).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    func isProductionPair(native: LanguageIdentifier,
                          learning: LanguageIdentifier) -> Bool {
        guard let capability = capabilities[learning], capability.productionReady else {
            return false
        }
        return capability.nativeTranslationPartners.contains(native) &&
            capability.reverseFromNative.contains(native)
    }
}

extension QueryLanguage {
    var languageIdentifier: LanguageIdentifier? {
        switch self {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .mixed, .undetermined: return nil
        }
    }
}

extension LanguageIdentifier {
    var queryLanguage: QueryLanguage {
        switch self {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .german, .japanese: return .undetermined
        }
    }
}

/// App-controlled UI localization. It is configured once at launch so changing the preference is
/// predictable and never mutates the process-wide AppleLanguages setting.
@MainActor
enum AppLocalization {
    private(set) static var language: LanguageIdentifier =
        LanguagePreferencesStore.shared.load().resolvedUILanguage

    static func configureAtLaunch(_ preferences: LanguagePreferences =
        LanguagePreferencesStore.shared.load()) {
        language = preferences.resolvedUILanguage
    }

    static func text(_ simplifiedChinese: String, _ english: String) -> String {
        language == .english ? english : simplifiedChinese
    }

    static func languageName(_ value: LanguageIdentifier) -> String {
        language == .english ? value.englishName : value.chineseName
    }
}

enum QueryIntentRejectionReason: Equatable {
    case none
    case empty
    case mostlyNonEnglish
    case characterLimit
    case wordLimit
    case multipleParagraphs
    case tooManySentences
}

struct QueryIntentClassification: Equatable {
    let intent: QueryIntent
    let normalizedText: String
    let englishWordCount: Int
    let rejectionReason: QueryIntentRejectionReason
    let shouldAttemptLocalLookupFirst: Bool
    let language: QueryLanguage
    let sentenceCount: Int
    let paragraphCount: Int

    var isLongForm: Bool {
        intent == .sentence && (sentenceCount > 1 || paragraphCount > 1 ||
            normalizedText.count > 280)
    }

    var isChineseLookup: Bool {
        (intent == .word || intent == .phrase) && language == .simplifiedChinese
    }
}

enum SentenceTextNormalizer {
    // 12,000 composed characters bounds duplicate String/NLTokenizer storage to a few
    // hundred KiB for normal UTF-8/UTF-16 text while admitting the required 1,000-character
    // analysis case. The UI never accepts an unbounded document.
    static let maximumCharacters = 12_000
    static let maximumLexicalTokens = 4_000

    static func normalize(_ source: String) -> String {
        let canonical = source.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        var currentLines: [String] = []
        for rawLine in canonical.components(separatedBy: "\n") {
            let line = collapseWhitespace(rawLine)
            if line.isEmpty {
                if !currentLines.isEmpty {
                    paragraphs.append(currentLines.joined(separator: " "))
                    currentLines.removeAll(keepingCapacity: true)
                }
            } else {
                currentLines.append(line)
            }
        }
        if !currentLines.isEmpty { paragraphs.append(currentLines.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func collapseWhitespace(_ source: String) -> String {
        var output = ""
        var pendingSpace = false
        for character in source {
            if character.isWhitespace {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace { output.append(" ") }
                output.append(character)
                pendingSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Recognizes an explicit three-Return gesture without turning an ordinary Return into an
/// automatic network action. The same normalized query must be submitted three times within the
/// bounded interval; editing the query or waiting longer starts a new sequence.
struct TripleReturnAITrigger: Sendable {
    enum Result: Equatable, Sendable {
        case firstReturn
        case secondReturn
        case triggerAI
    }

    private(set) var queryIdentity = ""
    private(set) var returnCount = 0
    private(set) var lastReturnTime: TimeInterval?
    let maximumInterval: TimeInterval

    init(maximumInterval: TimeInterval = 1.5) {
        self.maximumInterval = maximumInterval
    }

    mutating func register(query: String, at time: TimeInterval) -> Result {
        let identity = SentenceTextNormalizer.normalize(query)
        let continuesSequence = !identity.isEmpty && identity == queryIdentity &&
            lastReturnTime.map { time >= $0 && time - $0 <= maximumInterval } == true
        if continuesSequence {
            returnCount += 1
        } else {
            queryIdentity = identity
            returnCount = 1
        }
        lastReturnTime = time
        if returnCount >= 3 {
            reset()
            return .triggerAI
        }
        return returnCount == 2 ? .secondReturn : .firstReturn
    }

    mutating func reset() {
        queryIdentity = ""
        returnCount = 0
        lastReturnTime = nil
    }
}

enum QueryIntentClassifier {
    static func classify(_ source: String) -> QueryIntentClassification {
        let normalized = QuerySurfaceNormalizer.translationReadyText(source)
        guard !normalized.isEmpty else { return rejected(normalized, reason: .empty) }
        guard normalized.count <= SentenceTextNormalizer.maximumCharacters else {
            return rejected(normalized, reason: .characterLimit)
        }

        let words = englishWords(in: normalized)
        let cjkCount = normalized.unicodeScalars.filter(Self.isCJK).count
        let language = languageProfile(englishLetters: words.reduce(0) { $0 + $1.count },
                                       cjkCount: cjkCount)
        let lexicalCount = words.count + cjkLexicalEstimate(normalized)
        guard lexicalCount <= SentenceTextNormalizer.maximumLexicalTokens else {
            return rejected(normalized, wordCount: words.count, reason: .wordLimit,
                            language: language)
        }
        guard words.count > 0 || cjkCount > 0 else {
            return rejected(normalized, wordCount: words.count, reason: .mostlyNonEnglish,
                            language: .undetermined)
        }

        let sentences = max(1, independentSentenceCount(in: normalized))
        let paragraphs = max(1, normalized.components(separatedBy: "\n\n").count)

        if language == .english, words.count == 1, paragraphs == 1,
           !hasTerminalSentencePunctuation(normalized) {
            return accepted(.word, normalized, words.count, language, sentences, paragraphs,
                            localFirst: true)
        }
        if language == .simplifiedChinese, paragraphs == 1,
           !hasTerminalSentencePunctuation(normalized), cjkCount <= 4,
           !containsSentenceSignal(normalized) {
            return accepted(.word, normalized, words.count, language, sentences, paragraphs,
                            localFirst: false)
        }

        let sentenceLike: Bool
        switch language {
        case .english:
            sentenceLike = paragraphs > 1 || sentences > 1 ||
                looksLikePunctuationSeparatedProse(normalized, wordCount: words.count) ||
                (words.count >= 6 && (hasTerminalSentencePunctuation(normalized) ||
                    hasFiniteVerbSignal(words)) &&
                    !looksLikeTitleOrTerm(words, text: normalized,
                                          terminalPunctuation:
                                            hasTerminalSentencePunctuation(normalized)))
        case .simplifiedChinese:
            sentenceLike = paragraphs > 1 || sentences > 1 || cjkCount > 12 ||
                looksLikePunctuationSeparatedProse(normalized, wordCount: lexicalCount) ||
                hasTerminalSentencePunctuation(normalized) || containsSentenceSignal(normalized)
        case .mixed:
            sentenceLike = paragraphs > 1 || sentences > 1 ||
                looksLikePunctuationSeparatedProse(normalized, wordCount: lexicalCount) ||
                hasTerminalSentencePunctuation(normalized) || lexicalCount >= 6
        case .undetermined:
            sentenceLike = false
        }

        if sentenceLike {
            return accepted(.sentence, normalized, words.count, language, sentences, paragraphs,
                            localFirst: language == .english && words.count <= 10 &&
                                paragraphs == 1 && sentences == 1)
        }
        return accepted(.phrase, normalized, words.count, language, sentences, paragraphs,
                        localFirst: language == .english)
    }

    /// OCR, PDF and Markdown selections often contain commas/semicolons between otherwise valid
    /// tokens. Three or more tokens separated at least twice are prose for translation purposes,
    /// not a dictionary headword assembled from punctuation.
    private static func looksLikePunctuationSeparatedProse(_ text: String,
                                                            wordCount: Int) -> Bool {
        guard wordCount >= 3 else { return false }
        let separators: Set<Character> = [",", ";", "，", "；"]
        return text.filter(separators.contains).count >= 2
    }

    static func englishWords(in source: String) -> [String] {
        var result: [String] = []
        var current = ""
        let apostrophes: Set<Character> = ["'", "’"]
        for character in source {
            if character.isASCIIEnglishLetter {
                current.append(character)
            } else if (apostrophes.contains(character) || character == "-") && !current.isEmpty {
                current.append(character)
            } else {
                finishWord(&current, into: &result)
            }
        }
        finishWord(&current, into: &result)
        return result
    }

    private static func accepted(_ intent: QueryIntent, _ normalized: String, _ wordCount: Int,
                                 _ language: QueryLanguage, _ sentenceCount: Int,
                                 _ paragraphCount: Int, localFirst: Bool)
        -> QueryIntentClassification {
        QueryIntentClassification(intent: intent, normalizedText: normalized,
                                  englishWordCount: wordCount, rejectionReason: .none,
                                  shouldAttemptLocalLookupFirst: localFirst,
                                  language: language, sentenceCount: sentenceCount,
                                  paragraphCount: paragraphCount)
    }

    private static func rejected(_ normalized: String, wordCount: Int = 0,
                                 reason: QueryIntentRejectionReason,
                                 language: QueryLanguage = .undetermined)
        -> QueryIntentClassification {
        QueryIntentClassification(intent: .textTooLong, normalizedText: normalized,
                                  englishWordCount: wordCount, rejectionReason: reason,
                                  shouldAttemptLocalLookupFirst: false,
                                  language: language, sentenceCount: 0, paragraphCount: 0)
    }

    private static func finishWord(_ current: inout String, into result: inout [String]) {
        while let last = current.last, last == "-" || last == "'" || last == "’" {
            current.removeLast()
        }
        if !current.isEmpty { result.append(current) }
        current = ""
    }

    private static func languageProfile(englishLetters: Int, cjkCount: Int) -> QueryLanguage {
        if englishLetters > 0 && cjkCount > 0 { return .mixed }
        if cjkCount > 0 { return .simplifiedChinese }
        if englishLetters > 0 { return .english }
        return .undetermined
    }

    private static func cjkLexicalEstimate(_ source: String) -> Int {
        let count = source.unicodeScalars.filter(isCJK).count
        return count == 0 ? 0 : max(1, (count + 1) / 2)
    }

    static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func independentSentenceCount(in source: String) -> Int {
        var count = 0
        var inTerminator = false
        for character in source {
            let terminal = ".?!。？！".contains(character)
            if terminal && !inTerminator { count += 1 }
            inTerminator = terminal
        }
        return count
    }

    private static func hasTerminalSentencePunctuation(_ source: String) -> Bool {
        guard let last = source.last else { return false }
        return ".?!。？！”’\"".contains(last) &&
            source.contains { ".?!。？！".contains($0) }
    }

    private static func containsSentenceSignal(_ source: String) -> Bool {
        ["是", "有", "在", "把", "被", "因为", "但是", "如果", "虽然", "需要",
         "可以", "应该", "已经", "正在", "不会"].contains { source.contains($0) }
    }

    private static func hasFiniteVerbSignal(_ words: [String]) -> Bool {
        let auxiliaries: Set<String> = [
            "am", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did",
            "can", "could", "may", "might", "must", "shall", "should", "will", "would"
        ]
        let pronouns: Set<String> = [
            "i", "you", "he", "she", "it", "we", "they", "this", "that", "who", "which"
        ]
        let lower = words.map { $0.lowercased() }
        if lower.contains(where: auxiliaries.contains) { return true }
        if lower.contains(where: { $0.hasSuffix("ed") && $0.count > 4 }) { return true }
        return lower.count >= 8 &&
            lower.prefix(4).contains(where: pronouns.contains) &&
            lower.dropFirst().contains(where: { $0.hasSuffix("s") && $0.count > 3 })
    }

    private static func looksLikeTitleOrTerm(_ words: [String], text: String,
                                             terminalPunctuation: Bool) -> Bool {
        guard !terminalPunctuation, words.count <= 16 else { return false }
        let capitalized = words.filter { $0.first?.isUppercase == true }.count
        let titleLike = Double(capitalized) / Double(words.count) >= 0.65
        return titleLike && !text.contains(",") && !text.contains(";") && !text.contains(":")
    }
}

/// Browser/PDF/OCR selections can expose Markdown emphasis markers as literal query text. This
/// conservative normalizer repairs only unmistakable formatting artifacts: repeated underscores
/// between words and boundary underscores used as emphasis. A normal identifier such as
/// `snake_case` remains unchanged.
enum QuerySurfaceNormalizer {
    static func translationReadyText(_ source: String) -> String {
        let normalized = SentenceTextNormalizer.normalize(source)
        guard normalized.contains("_") else { return normalized }
        let characters = Array(normalized)
        var output = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "_" else {
                output.append(characters[index])
                index += 1
                continue
            }
            let start = index
            while index < characters.count, characters[index] == "_" { index += 1 }
            let count = index - start
            let previous = output.last
            let next = index < characters.count ? characters[index] : nil
            let previousIsLexical = previous?.isLetter == true || previous?.isNumber == true
            let nextIsLexical = next?.isLetter == true || next?.isNumber == true
            if count >= 2, previousIsLexical, nextIsLexical {
                if output.last != " " { output.append(" ") }
            } else if !previousIsLexical || !nextIsLexical {
                continue
            } else {
                output.append("_")
            }
        }
        return SentenceTextNormalizer.normalize(output)
    }
}

/// Recognizes a bounded bilingual glossary copied from a PDF/web page. These selections often
/// contain several headwords, IPA blocks and abbreviated parts of speech without semicolons or
/// line breaks. Treating `vt.`/`a.` as sentence endings breaks one glossary into unrelated Apple
/// requests. The detector deliberately requires repeated dictionary structure so an ordinary
/// mixed-language sentence is never granted glossary passthrough merely for containing one label.
enum BilingualGlossaryDetector {
    static func isStructuredGlossary(_ source: String) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_000 else { return false }
        let hanCount = value.unicodeScalars.filter(QueryIntentClassifier.isCJK).count
        let englishWords = QueryIntentClassifier.englishWords(in: value)
        guard hanCount >= 2, englishWords.count >= 2 else { return false }

        let lower = " " + value.lowercased()
        let markers = [
            " n.", " v.", " vi.", " vt.", " a.", " adj.", " adv.",
            " prep.", " pron.", " conj.", " pl."
        ]
        let partOfSpeechCount = markers.reduce(into: 0) { count, marker in
            count += occurrences(of: marker, in: lower)
        }
        let verticalBarCount = value.filter { $0 == "|" || $0 == "｜" }.count
        let explicitBoundaryCount = value.filter { ";；\n".contains($0) }.count
        let hanRunCount = cjkRunCount(in: value)

        return partOfSpeechCount >= 2 && hanRunCount >= 2 &&
            (verticalBarCount >= 2 || explicitBoundaryCount >= 1)
    }

    /// Returns only native-language glosses already present in a copied bilingual glossary.
    /// This is not a sentence translator: callers must first pass `isStructuredGlossary`, and
    /// the projection never invents or stitches dictionary meanings. It exists for Apple
    /// Translation responses that normalize an IPA/POS glossary back to English instead of
    /// producing the requested Chinese side.
    static func simplifiedChineseProjection(_ source: String) -> String? {
        guard isStructuredGlossary(source) else { return nil }
        var runs: [String] = []
        var current = ""
        let allowedPunctuation = CharacterSet(charactersIn: "，、；：。（）《》“”‘’/-")

        func finishRun() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "，、；：。（）/-")
            ))
            if value.unicodeScalars.contains(where: QueryIntentClassifier.isCJK) {
                runs.append(value)
            }
            current = ""
        }

        for scalar in source.unicodeScalars {
            if QueryIntentClassifier.isCJK(scalar) || allowedPunctuation.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                finishRun()
            }
        }
        if !current.isEmpty { finishRun() }

        let unique = runs.reduce(into: [String]()) { values, value in
            if !value.isEmpty, values.last != value { values.append(value) }
        }
        guard unique.count >= 2 else { return nil }
        let projected = unique.joined(separator: "\n")
        guard TargetLanguageValidator.validate(
            projected, targetLanguage: .simplifiedChinese
        ).isTargetLanguage else { return nil }
        return projected
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func cjkRunCount(in value: String) -> Int {
        var count = 0
        var inRun = false
        for scalar in value.unicodeScalars {
            let isCJK = QueryIntentClassifier.isCJK(scalar)
            if isCJK && !inRun { count += 1 }
            inRun = isCJK
        }
        return count
    }
}

struct AIQueryGenerationGate {
    private(set) var generation: UInt64 = 0

    mutating func beginQuery() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ candidate: UInt64) -> Bool { candidate == generation }
}

private extension Character {
    var isASCIIEnglishLetter: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }
}
