import AppKit
import SwiftUI
@preconcurrency import Translation

@MainActor
final class SystemTranslationHostModel: ObservableObject {
    static let maximumPendingOperations = 8

    enum VisibleStatus: String {
        case notInstalled = "Apple 系统离线翻译语言包尚未安装"
        case checking = "正在检查系统语言包…"
        case requestingPermission = "等待用户允许 macOS 准备语言资源"
        case systemPreparing = "macOS 正在准备 Apple 离线翻译语言包…"
        case backgroundPreparationPossible = "macOS 可能仍在后台准备语言资源"
        case installed = "Apple 系统离线翻译语言包已安装"
        case translating = "正在进行基础离线翻译…"
        case unsupported = "系统不支持该语言方向"
        case failed = "系统翻译暂时失败"
        case stoppedWaiting = "本 App 已停止等待；macOS 可能仍在后台准备"
    }

    enum Health: String, Equatable {
        case healthy
        case operationFailed
        case sessionInvalid
    }

    private enum OperationKind {
        case translate([OfflineTranslationRequest],
                       CheckedContinuation<[OfflineTranslationResponse], Error>)
        case prepare(CheckedContinuation<Void, Error>)
    }

    private struct Operation {
        let id: UUID
        let pair: OfflineTranslationPair
        let kind: OperationKind
    }

    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var configurationGeneration: UInt64 = 0
    @Published private(set) var visibleStatus: VisibleStatus = .notInstalled
    @Published private(set) var operationStage: OfflineTranslationStage?
    @Published private(set) var diagnosticLines: [String] = []
    @Published private(set) var health: Health = .healthy

    private var queue: [Operation] = []
    private var active: Operation?
    private var activeConfigurationGeneration: UInt64?
    private var configurationPair: OfflineTranslationPair?
    private var installedPairs: Set<OfflineTranslationPair> = []
    private var sessionCallbackGenerations: Set<UInt64> = []
    private var retiredSessionGenerations: Set<UInt64> = []
    private var terminalOperationIDs: Set<UUID> = []
    private var terminalOperationOrder: [UUID] = []
    private(set) var hostAttached = false
    private(set) var hostGeneration: UInt64 = 0

    var hasPendingOperations: Bool { active != nil || !queue.isEmpty }
    var pendingOperationCount: Int { queue.count + (active == nil ? 0 : 1) }

    func hostDidAttach() {
        if !hostAttached { hostGeneration &+= 1 }
        hostAttached = true
        record(event: "host_attached", detail: "host_generation=\(hostGeneration)")
        evidence("translationHostAttached")
        activateNextIfNeeded()
    }

    func hostDidDetach() {
        hostAttached = false
        record(event: "host_detached")
        let error = OfflineTranslationError.hostEnded
        let queued = queue
        queue.removeAll()
        if let active {
            _ = finishCurrentOperation(
                id: active.id, sessionGeneration: activeConfigurationGeneration,
                resultKind: "failure", error: error, responses: nil,
                invalidateSession: true
            )
        } else {
            retiredSessionGenerations.formUnion(sessionCallbackGenerations)
            configuration?.invalidate()
            configuration = nil
            configurationPair = nil
        }
        for operation in queued {
            markTerminal(operation.id)
            evidence("operationTerminal", operationID: operation.id, pair: operation.pair,
                     strings: [
                        "resultKind": "failure",
                        "operationState": "failed",
                        "typedReason": String(describing: error)
                     ])
            resume(operation, throwing: error)
        }
        operationStage = .completion
        visibleStatus = .backgroundPreparationPossible
        evidence("translationHostDetached", strings: [
            "serviceHealth": "sessionNeedsRebuild",
            "operationState": "failed"
        ])
    }

    func enqueueTranslation(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        guard !requests.isEmpty, let pair = requests.first?.pair,
              requests.allSatisfy({ $0.pair == pair && !$0.sourceText.isEmpty }) else {
            throw OfflineTranslationError.emptyInput
        }
        let operationID = UUID()
        evidence("appleTranslationRequested", operationID: operationID, pair: pair,
                 strings: [
                    "operationState": "queued",
                    "offlineOutputRole": requests.first?.outputRole?.rawValue ?? "unspecified"
                 ],
                 integers: [
                    "resultLength": 0,
                    "pendingContinuationCount": Int64(pendingOperationCount + 1)
                 ])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[OfflineTranslationResponse], Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: OfflineTranslationError.cancelled)
                    return
                }
                guard canEnqueueOperation else {
                    continuation.resume(throwing: OfflineTranslationError.hostUnavailable)
                    return
                }
                queue.append(Operation(id: operationID, pair: pair,
                                       kind: .translate(requests, continuation)))
                evidence("operationQueued", operationID: operationID, pair: pair,
                         strings: ["operationState": "idle"])
                activateNextIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation(id: operationID) }
        }
    }

    func enqueuePreparation(for pair: OfflineTranslationPair) async throws {
        let operationID = UUID()
        visibleStatus = .requestingPermission
        record(operationID: operationID, pair: pair, event: "queued")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: OfflineTranslationError.cancelled)
                    return
                }
                guard canEnqueueOperation else {
                    continuation.resume(throwing: OfflineTranslationError.hostUnavailable)
                    return
                }
                queue.append(Operation(id: operationID, pair: pair,
                                       kind: .prepare(continuation)))
                activateNextIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation(id: operationID) }
        }
    }

    func runActiveOperation(with session: TranslationSession,
                            sessionGeneration: UInt64) async {
        let operation = active
        evidence("sessionCreated", operationID: operation?.id, pair: operation?.pair,
                 strings: [
                    "serviceHealth": evidenceHealth,
                    "operationState": evidenceOperationState
                 ], integers: ["sessionGeneration": Int64(clamping: sessionGeneration)])
        let before = await Self.sessionCapabilityDiagnostics(session)
        record(operationID: operation?.id, pair: operation?.pair,
               event: "session_capabilities_before",
               detail: "session_generation=\(sessionGeneration) " + before)
        await runActiveOperation(
            sessionGeneration: sessionGeneration,
            prepare: { try await session.prepareTranslation() },
            translate: { source in try await session.translate(source).targetText }
        )
        evidence("sessionDisposed", operationID: operation?.id, pair: operation?.pair,
                 strings: [
                    "serviceHealth": evidenceHealth,
                    "operationState": evidenceOperationState
                 ], integers: ["sessionGeneration": Int64(clamping: sessionGeneration)])
        activateNextIfNeeded()
    }

    func runActiveOperation(
        sessionGeneration: UInt64,
        prepare: @escaping () async throws -> Void,
        translate: @escaping (String) async throws -> String
    ) async {
        sessionCallbackGenerations.insert(sessionGeneration)
        defer {
            sessionCallbackGenerations.remove(sessionGeneration)
            retiredSessionGenerations.remove(sessionGeneration)
            activateNextIfNeeded()
        }
        guard let operation = active,
              activeConfigurationGeneration == sessionGeneration else {
            record(event: "late_session_ignored",
                   detail: "session_generation=\(sessionGeneration) active_generation=\(activeConfigurationGeneration.map(String.init) ?? "none")")
            evidence("lateCallbackDiscarded", strings: [
                "callbackDiscardReason": "sessionGenerationMismatch",
                "operationState": evidenceOperationState
            ], integers: [
                "sessionGeneration": Int64(clamping: sessionGeneration)
            ], booleans: [
                "callbackAccepted": false
            ])
            return
        }
        do {
            switch operation.kind {
            case .prepare:
                operationStage = .preparation
                visibleStatus = .systemPreparing
                record(operationID: operation.id, pair: operation.pair,
                       event: "prepare_invoked",
                       detail: "session_generation=\(sessionGeneration)")
                evidence("preparationStarted", operationID: operation.id,
                         pair: operation.pair,
                         strings: ["operationState": "preparing"],
                         integers: ["sessionGeneration": Int64(clamping: sessionGeneration)])
                try await prepare()
                record(operationID: operation.id, pair: operation.pair,
                       event: "prepare_returned",
                       detail: "session_generation=\(sessionGeneration)")
                try Task.checkCancellation()
                guard finishCurrentOperation(
                    id: operation.id, sessionGeneration: sessionGeneration,
                    resultKind: "success", error: nil, responses: nil,
                    invalidateSession: false
                ) else {
                    record(operationID: operation.id, pair: operation.pair,
                           event: "late_session_result_ignored",
                           detail: "session_generation=\(sessionGeneration)")
                    return
                }
                visibleStatus = .checking
            case .translate(let requests, _):
                operationStage = .translation
                visibleStatus = .translating
                evidence("translationStarted", operationID: operation.id,
                         pair: operation.pair,
                         strings: ["operationState": "translating"],
                         integers: [
                            "sessionGeneration": Int64(clamping: sessionGeneration),
                            "resultLength": Int64(requests.reduce(0) {
                                $0 + $1.sourceText.count
                            })
                         ])
                var responses: [OfflineTranslationResponse] = []
                responses.reserveCapacity(requests.count)
                for request in requests {
                    try Task.checkCancellation()
                    let translatedText = try await translate(request.sourceText)
                    responses.append(OfflineTranslationResponse(
                        id: request.id,
                        sourceText: request.sourceText,
                        translatedText: translatedText,
                        pair: request.pair,
                        outputRole: request.outputRole
                    ))
                }
                guard finishCurrentOperation(
                    id: operation.id, sessionGeneration: sessionGeneration,
                    resultKind: "success", error: nil, responses: responses,
                    invalidateSession: false
                ) else {
                    record(operationID: operation.id, pair: operation.pair,
                           event: "late_session_result_ignored",
                           detail: "session_generation=\(sessionGeneration)")
                    evidence("lateCallbackDiscarded", operationID: operation.id,
                             pair: operation.pair,
                             strings: [
                                "callbackDiscardReason": "operationGenerationMismatch",
                                "operationState": evidenceOperationState
                             ], integers: [
                                "sessionGeneration": Int64(clamping: sessionGeneration)
                             ], booleans: ["callbackAccepted": false])
                    return
                }
            }
        } catch is CancellationError {
            _ = finishCurrentOperation(
                id: operation.id, sessionGeneration: sessionGeneration,
                resultKind: "cancelled", error: .cancelled, responses: nil,
                invalidateSession: true
            )
        } catch let error as OfflineTranslationError {
            _ = finishCurrentOperation(
                id: operation.id, sessionGeneration: sessionGeneration,
                resultKind: error == .cancelled ? "cancelled" : "failure",
                error: error, responses: nil, invalidateSession: true
            )
        } catch {
            _ = finishCurrentOperation(
                id: operation.id, sessionGeneration: sessionGeneration,
                resultKind: "failure", error: Self.map(error), responses: nil,
                invalidateSession: true
            )
        }
    }

    func setAvailabilityStatus(_ availability: OfflineTranslationAvailability) {
        switch availability {
        case .installed: visibleStatus = .installed
        case .supportedNeedsDownload: visibleStatus = .notInstalled
        case .unsupported: visibleStatus = .unsupported
        case .checking: visibleStatus = .checking
        case .temporarilyUnavailable: visibleStatus = .failed
        }
        evidence("availabilityResult", strings: [
            "systemAvailability": evidenceAvailability(availability),
            "serviceHealth": evidenceHealth,
            "operationState": evidenceOperationState
        ])
    }

    func setWaitingForUser() {
        guard active == nil else { return }
        visibleStatus = .notInstalled
    }

    func setWaitingForSystem() {
        guard active == nil else { return }
        visibleStatus = .requestingPermission
    }

    func recordAvailability(_ availability: OfflineTranslationAvailability,
                            pair: OfflineTranslationPair,
                            event: String) {
        if availability == .installed { installedPairs.insert(pair) }
        record(pair: pair, event: event,
               detail: "availability=\(String(describing: availability)) is_ready=\(availability == .installed)")
        evidence(event == "availability" ? "availabilityResult" : event,
                 pair: pair, strings: [
                    "systemAvailability": evidenceAvailability(availability),
                    "serviceHealth": evidenceHealth,
                    "operationState": evidenceOperationState
                 ])
    }

    func setPreparationFailure(_ error: OfflineTranslationError,
                               pair: OfflineTranslationPair) {
        if error == .cancelled {
            visibleStatus = .stoppedWaiting
        } else if error == .preparationIncomplete {
            visibleStatus = .backgroundPreparationPossible
        } else {
            visibleStatus = .failed
        }
        record(pair: pair, event: "prepare_failed", detail: String(describing: error))
    }

    func stopWaitingForSystemPreparation() {
        let error = OfflineTranslationError.cancelled
        let queued = queue
        queue.removeAll()
        if let active {
            _ = finishCurrentOperation(
                id: active.id, sessionGeneration: activeConfigurationGeneration,
                resultKind: "cancelled", error: error, responses: nil,
                invalidateSession: true
            )
        } else {
            retiredSessionGenerations.formUnion(sessionCallbackGenerations)
            configuration?.invalidate()
            configuration = nil
            configurationPair = nil
        }
        for operation in queued {
            markTerminal(operation.id)
            evidence("operationTerminal", operationID: operation.id, pair: operation.pair,
                     strings: [
                        "resultKind": "cancelled",
                        "operationState": "cancelled",
                        "typedReason": String(describing: error)
                     ])
            resume(operation, throwing: error)
        }
        health = .sessionInvalid
        operationStage = .completion
        visibleStatus = .stoppedWaiting
        record(event: "app_stopped_waiting",
               detail: "session_generation=\(configurationGeneration) system_download_cancelled=false")
        evidence("appleStopWaitingClicked", strings: [
            "operationState": "cancelled",
            "serviceHealth": "sessionNeedsRebuild"
        ])
    }

    private func activateNextIfNeeded() {
        let currentCallbackBlocks = sessionCallbackGenerations.contains(configurationGeneration) &&
            !retiredSessionGenerations.contains(configurationGeneration)
        guard hostAttached, !currentCallbackBlocks, active == nil, !queue.isEmpty else {
            return
        }
        let operation = queue.removeFirst()
        active = operation
        operationStage = .sessionCreation
        configurationGeneration &+= 1
        activeConfigurationGeneration = configurationGeneration
        health = .healthy
        switch operation.kind {
        case .prepare: visibleStatus = .requestingPermission
        case .translate: visibleStatus = .checking
        }
        record(operationID: operation.id, pair: operation.pair,
               event: "activated",
               detail: "session_generation=\(configurationGeneration) host_generation=\(hostGeneration)")
        evidence("nextOperationStarted", operationID: operation.id, pair: operation.pair,
                 strings: [
                    "systemAvailability": installedPairs.contains(operation.pair)
                        ? "installed" : "unknown",
                    "serviceHealth": "ready",
                    "operationState": "checking"
                 ], integers: [
                    "operationGeneration": Int64(clamping: configurationGeneration),
                    "sessionGeneration": Int64(clamping: configurationGeneration)
                 ])
        if configuration == nil || configurationPair != operation.pair {
            configuration = TranslationSession.Configuration(
                source: operation.pair.source.localeLanguage,
                target: operation.pair.target.localeLanguage
            )
            configurationPair = operation.pair
            evidence("configurationCreated", operationID: operation.id,
                     pair: operation.pair,
                     integers: [
                        "sessionGeneration": Int64(clamping: configurationGeneration)
                     ])
        } else {
            // Apple's documented same-language re-arm mechanism increments Configuration.version
            // and gives translationTask a new TranslationSession. The terminal session itself is
            // never cached or reused.
            configuration?.invalidate()
            evidence("sessionRebuilt", operationID: operation.id, pair: operation.pair,
                     integers: [
                        "sessionGeneration": Int64(clamping: configurationGeneration)
                     ])
        }
    }

    private var canEnqueueOperation: Bool {
        queue.count + (active == nil ? 0 : 1) < Self.maximumPendingOperations
    }

    private func cancelOperation(id: UUID) {
        let error = OfflineTranslationError.cancelled
        if let active, active.id == id {
            _ = finishCurrentOperation(
                id: id, sessionGeneration: activeConfigurationGeneration,
                resultKind: "cancelled", error: error, responses: nil,
                invalidateSession: true
            )
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let operation = queue.remove(at: index)
        markTerminal(operation.id)
        evidence("operationTerminal", operationID: operation.id, pair: operation.pair,
                 strings: [
                    "resultKind": "cancelled",
                    "operationState": "cancelled",
                    "typedReason": String(describing: error)
                 ])
        resume(operation, throwing: error)
        activateNextIfNeeded()
    }

    @discardableResult
    private func finishCurrentOperation(
        id: UUID,
        sessionGeneration: UInt64?,
        resultKind: String,
        error: OfflineTranslationError?,
        responses: [OfflineTranslationResponse]?,
        invalidateSession: Bool
    ) -> Bool {
        guard let operation = active, operation.id == id,
              sessionGeneration == nil || activeConfigurationGeneration == sessionGeneration,
              !terminalOperationIDs.contains(id) else { return false }
        let retiredGeneration = activeConfigurationGeneration
        active = nil
        activeConfigurationGeneration = nil
        operationStage = .completion
        markTerminal(id)

        if invalidateSession {
            if let retiredGeneration { retiredSessionGenerations.insert(retiredGeneration) }
            configuration?.invalidate()
            configuration = nil
            configurationPair = nil
            health = error == .cancelled ? .sessionInvalid : .operationFailed
            visibleStatus = error == .cancelled ? .stoppedWaiting : .failed
        } else {
            health = .healthy
            if case .translate = operation.kind {
                installedPairs.insert(operation.pair)
                visibleStatus = .installed
            } else {
                visibleStatus = .checking
            }
        }

        if let error {
            let state = error == .cancelled ? "cancelled" : "failed"
            record(operationID: operation.id, pair: operation.pair,
                   event: error == .cancelled ? "app_stopped_waiting" : "error",
                   detail: String(describing: error))
            evidence(error == .deadlineExceeded(.translation)
                ? "translationTimedOut" : (error == .cancelled
                    ? "translationCancelled" : "translationFailed"),
                operationID: operation.id, pair: operation.pair,
                strings: [
                    "resultKind": resultKind,
                    "operationState": state,
                    "serviceHealth": invalidateSession ? "sessionNeedsRebuild" : evidenceHealth,
                    "typedReason": String(describing: error)
                ])
            evidence("operationTerminal", operationID: operation.id, pair: operation.pair,
                     strings: [
                        "resultKind": resultKind,
                        "operationState": state,
                        "typedReason": String(describing: error)
                     ])
            resume(operation, throwing: error)
        } else {
            if case .translate = operation.kind, let responses {
                evidence("translationSucceeded", operationID: operation.id,
                         pair: operation.pair,
                         strings: [
                            "resultKind": "success",
                            "operationState": "success"
                         ], integers: [
                            "sessionGeneration": Int64(clamping:
                                sessionGeneration ?? configurationGeneration),
                            "resultLength": Int64(responses.reduce(0) {
                                $0 + $1.translatedText.count
                            })
                         ])
                evidence("successCleanupStarted", operationID: operation.id,
                         pair: operation.pair,
                         strings: ["operationState": "success"])
                evidence("successCleanupCompleted", operationID: operation.id,
                         pair: operation.pair,
                         strings: [
                            "systemAvailability": "installed",
                            "serviceHealth": "ready",
                            "operationState": "success"
                         ])
            }
            evidence("operationTerminal", operationID: operation.id, pair: operation.pair,
                     strings: [
                        "resultKind": resultKind,
                        "operationState": "success"
                     ])
            switch operation.kind {
            case .prepare(let continuation):
                continuation.resume()
            case .translate(_, let continuation):
                guard let responses else {
                    continuation.resume(throwing: OfflineTranslationError.invalidResponse)
                    activateNextIfNeeded()
                    return true
                }
                continuation.resume(returning: responses)
            }
        }
        activateNextIfNeeded()
        return true
    }

    private func markTerminal(_ id: UUID) {
        terminalOperationIDs.insert(id)
        terminalOperationOrder.append(id)
        if terminalOperationOrder.count > 512 {
            let count = terminalOperationOrder.count - 512
            let expired = Array(terminalOperationOrder.prefix(count))
            terminalOperationOrder.removeFirst(count)
            terminalOperationIDs.subtract(expired)
        }
    }

    /// Called only after the coordinator has observed the failed operation complete. It
    /// invalidates the failed session generation, leaves installed availability untouched, and
    /// makes the next queued/query operation start from a clean configuration.
    func recoverAfterOperationFailure(_ error: OfflineTranslationError) {
        // A coordinator deadline first cancels the awaiting continuation. That cancellation may
        // finish while Apple's translationTask callback remains suspended indefinitely. Retire
        // only those old callback generations; never terminate a newer active operation.
        guard active == nil else { return }
        retiredSessionGenerations.formUnion(sessionCallbackGenerations)
        configuration?.invalidate()
        configuration = nil
        configurationPair = nil
        activeConfigurationGeneration = nil
        health = .healthy
        operationStage = .completion
        visibleStatus = .checking
        record(event: "operation_recovered",
               detail: "failure=\(String(describing: error)) rearmed_generation=\(configurationGeneration)")
        evidence("sessionRebuilt", strings: [
            "serviceHealth": "ready",
            "operationState": "idle",
            "typedReason": String(describing: error)
        ], integers: [
            "sessionGeneration": Int64(clamping: configurationGeneration)
        ])
        activateNextIfNeeded()
    }

    private func resume(_ operation: Operation, throwing error: Error) {
        switch operation.kind {
        case .translate(_, let continuation): continuation.resume(throwing: error)
        case .prepare(let continuation): continuation.resume(throwing: error)
        }
    }

    private func record(operationID: UUID? = nil,
                        pair: OfflineTranslationPair? = nil,
                        event: String,
                        detail: String? = nil) {
        var fields = ["event=\(event)"]
        if let operationID { fields.append("operation=\(operationID.uuidString.lowercased())") }
        if let pair { fields.append("pair=\(pair.source.rawValue)->\(pair.target.rawValue)") }
        if let detail { fields.append("detail=\(detail)") }
        diagnosticLines.append(fields.joined(separator: " "))
        if diagnosticLines.count > 40 { diagnosticLines.removeFirst(diagnosticLines.count - 40) }
        #if DEBUG
        NSLog("LocalDictionary AppleTranslation: %@", diagnosticLines.last ?? "")
        #endif
    }

    private var evidenceHealth: String {
        switch health {
        case .healthy: return "ready"
        case .operationFailed: return "temporarilyRecovering"
        case .sessionInvalid: return "sessionNeedsRebuild"
        }
    }

    private var evidenceOperationState: String {
        switch operationStage {
        case .availabilityCheck: return "checking"
        case .sessionCreation: return "checking"
        case .preparation: return "preparing"
        case .translation: return "translating"
        case .fallback: return "failed"
        case .completion: return active == nil ? "idle" : "success"
        case nil: return active == nil ? "idle" : "checking"
        }
    }

    private func evidenceAvailability(
        _ availability: OfflineTranslationAvailability
    ) -> String {
        switch availability {
        case .installed: return "installed"
        case .supportedNeedsDownload: return "downloadable"
        case .unsupported: return "unsupported"
        case .checking: return "checking"
        case .temporarilyUnavailable: return "unknown"
        }
    }

    private func evidence(
        _ eventType: String,
        operationID: UUID? = nil,
        pair: OfflineTranslationPair? = nil,
        strings: [String: String] = [:],
        integers: [String: Int64] = [:],
        booleans: [String: Bool] = [:]
    ) {
        var text = strings
        var numbers = integers
        if let operationID { text["operationID"] = operationID.uuidString.lowercased() }
        if let pair {
            text["queryLanguage"] = pair.source.rawValue
            text["targetLanguage"] = pair.target.rawValue
            text["translationSourceLanguage"] = pair.source.rawValue
            text["translationTargetLanguage"] = pair.target.rawValue
        }
        if text["offlineOutputRole"] == nil,
           let operationID,
           let role = outputRole(for: operationID) {
            text["offlineOutputRole"] = role.rawValue
        }
        numbers["hostGeneration"] = Int64(clamping: hostGeneration)
        numbers["operationGeneration"] = Int64(clamping:
            activeConfigurationGeneration ?? configurationGeneration
        )
        numbers["sessionGeneration"] = numbers["sessionGeneration"] ??
            Int64(clamping: configurationGeneration)
        numbers["activeOperationCount"] = active == nil ? 0 : 1
        numbers["pendingTaskCount"] = Int64(pendingOperationCount)
        numbers["pendingContinuationCount"] = Int64(pendingOperationCount)
        ManualEvidenceRecorder.shared.record(
            eventType, strings: text, integers: numbers,
            booleans: booleans.merging([
                "isChecking": operationStage == .availabilityCheck ||
                    operationStage == .sessionCreation,
                "isPreparing": operationStage == .preparation,
                "isTranslating": operationStage == .translation
            ]) { current, _ in current }
        )
    }

    private func outputRole(for operationID: UUID) -> OfflineTranslationOutputRole? {
        let operation: Operation?
        if active?.id == operationID {
            operation = active
        } else {
            operation = queue.first { $0.id == operationID }
        }
        guard let operation else { return nil }
        if case .translate(let requests, _) = operation.kind {
            return requests.first?.outputRole
        }
        return nil
    }

    private static func map(_ error: Error) -> OfflineTranslationError {
        if TranslationError.unsupportedSourceLanguage ~= error ||
            TranslationError.unsupportedTargetLanguage ~= error ||
            TranslationError.unsupportedLanguagePairing ~= error {
            return .unsupportedLanguagePair
        }
        if TranslationError.nothingToTranslate ~= error { return .emptyInput }
        if #available(macOS 26.0, *) {
            if TranslationError.notInstalled ~= error {
                return .languagePackRequired
            }
            if TranslationError.alreadyCancelled ~= error {
                return .cancelled
            }
        }
        return .systemFailure
    }

    private static func sessionCapabilityDiagnostics(
        _ session: TranslationSession
    ) async -> String {
        if #available(macOS 26.0, *) {
            return "can_request_downloads=\(session.canRequestDownloads) " +
                "is_ready=\(await session.isReady)"
        }
        return "can_request_downloads=unavailable_before_macos_26 " +
            "is_ready=unavailable_before_macos_26"
    }
}

private struct SystemTranslationHostView: View {
    @ObservedObject var model: SystemTranslationHostModel

    var body: some View {
        let sessionGeneration = model.configurationGeneration
        HStack(spacing: 6) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.secondary)
            Text(model.visibleStatus.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .onAppear { model.hostDidAttach() }
        .onDisappear { model.hostDidDetach() }
        .translationTask(model.configuration) { session in
            await model.runActiveOperation(with: session,
                                           sessionGeneration: sessionGeneration)
        }
    }
}

@MainActor
final class SystemTranslationHostController {
    let model = SystemTranslationHostModel()
    private let hostingController: NSHostingController<SystemTranslationHostView>

    init() {
        hostingController = NSHostingController(
            rootView: SystemTranslationHostView(model: model)
        )
    }

    var view: NSView { hostingController.view }

    func detach() {
        hostingController.view.removeFromSuperview()
        model.hostDidDetach()
    }
}

final class SystemTranslationEngine: @unchecked Sendable, OfflineTranslationEngine,
    OfflineTranslationOperationRecovering {
    private weak var model: SystemTranslationHostModel?

    @MainActor
    init(model: SystemTranslationHostModel) {
        self.model = model
    }

    func availability(for pair: OfflineTranslationPair) async
        -> OfflineTranslationAvailability {
        let availability = await LanguageAvailability().status(
            from: pair.source.localeLanguage, to: pair.target.localeLanguage
        )
        let mapped: OfflineTranslationAvailability
        switch availability {
        case .installed: mapped = .installed
        case .supported: mapped = .supportedNeedsDownload
        case .unsupported: mapped = .unsupported
        @unknown default: mapped = .temporarilyUnavailable
        }
        await model?.setAvailabilityStatus(mapped)
        await model?.recordAvailability(mapped, pair: pair, event: "availability")
        return mapped
    }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        guard requests.first?.pair != nil else { return [] }
        // Availability is checked and cached as a separate service fact by the coordinator.
        // Rechecking here used to turn a transient post-success LanguageAvailability delay into
        // a user-visible unavailable state before operation #2 could create its session.
        guard let model else { throw OfflineTranslationError.hostEnded }
        return try await model.enqueueTranslation(requests)
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        let initialAvailability = await availability(for: pair)
        await model?.recordAvailability(initialAvailability, pair: pair,
                                        event: "availability_before")
        guard initialAvailability != .unsupported else {
            throw OfflineTranslationError.unsupportedLanguagePair
        }
        if initialAvailability == .installed { return }
        guard let model else { throw OfflineTranslationError.hostEnded }
        do {
            try await model.enqueuePreparation(for: pair)
            let after = await availability(for: pair)
            await model.recordAvailability(after, pair: pair,
                                           event: "availability_after")
            guard after == .installed else {
                let error = OfflineTranslationError.preparationIncomplete
                await model.setPreparationFailure(error, pair: pair)
                throw error
            }
        } catch is CancellationError {
            await model.setPreparationFailure(.cancelled, pair: pair)
            throw OfflineTranslationError.cancelled
        } catch let error as OfflineTranslationError {
            await model.setPreparationFailure(error, pair: pair)
            throw error
        } catch {
            await model.setPreparationFailure(.systemFailure, pair: pair)
            throw OfflineTranslationError.systemFailure
        }
    }

    func recoverAfterOperationFailure(_ error: OfflineTranslationError) async {
        await model?.recoverAfterOperationFailure(error)
    }
}

private extension OfflineTranslationLanguage {
    var localeLanguage: Locale.Language {
        Locale.Language(identifier: rawValue)
    }
}
