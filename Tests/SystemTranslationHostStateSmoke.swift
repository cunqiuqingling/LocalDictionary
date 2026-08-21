import Foundation
import AppKit

private enum HostSmokeFailure: Error { case failed(String) }

private func hostExpect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw HostSmokeFailure.failed(message) }
}

@main
private enum SystemTranslationHostStateSmoke {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let pair = OfflineTranslationPair(source: .english, target: .simplifiedChinese)
        let model = SystemTranslationHostModel()
        model.hostDidAttach()

        async let preparation: Void = model.enqueuePreparation(for: pair)
        await waitForOperation(in: model)
        try hostExpect(model.visibleStatus == .requestingPermission,
                       "preparation did not enter requestingPermission")
        try hostExpect(model.configuration != nil,
                       "active translation host did not retain a configuration")
        try hostExpect(model.operationStage == .sessionCreation,
                       "session creation did not publish typed stage")
        await model.runActiveOperation(
            sessionGeneration: model.configurationGeneration,
            prepare: {},
            translate: { _ in throw OfflineTranslationError.invalidResponse }
        )
        try await preparation
        try hostExpect(model.visibleStatus == .checking,
                       "prepare return did not enter availability recheck")
        try hostExpect(model.operationStage == .completion,
                       "preparation did not publish completion stage")
        for event in ["host_attached", "queued", "activated", "prepare_invoked",
                      "prepare_returned"] {
            try hostExpect(model.diagnosticLines.contains(where: { $0.contains(event) }),
                           "missing host diagnostic: \(event)")
        }
        try hostExpect(model.diagnosticLines.allSatisfy {
            !$0.contains("user text") && !$0.contains("secret")
        }, "diagnostics retained query text")

        let translation = Task.detached {
            try await model.enqueueTranslation([
                OfflineTranslationRequest(id: "synthetic", sourceText: "fixture", pair: pair)
            ])
        }
        await waitForOperation(in: model)
        try hostExpect(model.operationStage == .sessionCreation,
                       "translation did not create a fresh typed session stage")
        await model.runActiveOperation(
            sessionGeneration: model.configurationGeneration,
            prepare: {},
            translate: { _ in "合成结果" }
        )
        let responses = try await translation.value
        try hostExpect(responses.first?.translatedText == "合成结果" &&
                       model.visibleStatus == .installed,
                       "mock translation lifecycle did not complete")

        let cancelled = Task.detached {
            try await model.enqueuePreparation(for: pair)
        }
        await waitForOperation(in: model)
        await model.runActiveOperation(
            sessionGeneration: model.configurationGeneration,
            prepare: { throw CancellationError() },
            translate: { _ in "" }
        )
        do {
            try await cancelled.value
            throw HostSmokeFailure.failed("cancelled preparation completed")
        } catch let error as OfflineTranslationError {
            try hostExpect(error == .cancelled && model.visibleStatus == .stoppedWaiting,
                           "stop waiting did not publish typed state")
        }

        let firstGenerationTask = Task.detached {
            try await model.enqueuePreparation(for: pair)
        }
        await waitForOperation(in: model)
        let staleGeneration = model.configurationGeneration
        model.stopWaitingForSystemPreparation()
        do {
            try await firstGenerationTask.value
            throw HostSmokeFailure.failed("stopped generation completed")
        } catch let error as OfflineTranslationError {
            try hostExpect(error == .cancelled, "stopped generation returned wrong error")
        }
        let replacement = Task.detached {
            try await model.enqueuePreparation(for: pair)
        }
        await waitForOperation(in: model)
        let currentGeneration = model.configurationGeneration
        var staleSessionInvoked = false
        await model.runActiveOperation(
            sessionGeneration: staleGeneration,
            prepare: { staleSessionInvoked = true },
            translate: { _ in "" }
        )
        try hostExpect(!staleSessionInvoked,
                       "late callback from invalidated session was allowed to run")
        await model.runActiveOperation(
            sessionGeneration: currentGeneration,
            prepare: {},
            translate: { _ in "" }
        )
        try await replacement.value
        try hostExpect(model.diagnosticLines.contains(where: {
            $0.contains("late_session_ignored") &&
                $0.contains("session_generation=\(staleGeneration)")
        }), "late-session generation diagnostic missing")

        let installedAfterStop = Task.detached {
            try await model.enqueueTranslation([
                OfflineTranslationRequest(
                    id: "installed-after-stop", sourceText: "fixture", pair: pair
                )
            ])
        }
        await waitForOperation(in: model)
        await model.runActiveOperation(
            sessionGeneration: model.configurationGeneration,
            prepare: {},
            translate: { _ in "重新可用" }
        )
        _ = try await installedAfterStop.value
        try hostExpect(model.visibleStatus == .installed,
                       "fresh installed state did not overwrite stoppedWaiting")

        // Reproduce the real failure shape: a translationTask callback remains suspended after
        // the awaiting operation reaches its deadline. Cancelling that operation must retire only
        // its session generation, and the next five queued operations must all start and finish in
        // this same host/model process.
        let timedOut = Task.detached {
            try await model.enqueueTranslation([
                OfflineTranslationRequest(
                    id: "timeout-fixture", sourceText: "timeout fixture", pair: pair
                )
            ])
        }
        await waitForOperation(in: model)
        let timedOutGeneration = model.configurationGeneration
        let suspendedCallback = Task { @MainActor in
            await model.runActiveOperation(
                sessionGeneration: timedOutGeneration,
                prepare: {},
                translate: { _ in
                    try await Task.sleep(for: .seconds(60))
                    return "too late"
                }
            )
        }
        for _ in 0..<100 where model.operationStage != .translation {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        timedOut.cancel()
        do {
            _ = try await timedOut.value
            throw HostSmokeFailure.failed("deadline fixture unexpectedly completed")
        } catch let error as OfflineTranslationError {
            try hostExpect(error == .cancelled, "deadline cancellation returned wrong error")
        }
        model.recoverAfterOperationFailure(.deadlineExceeded(.translation))
        for index in 0..<5 {
            let next = Task.detached {
                try await model.enqueueTranslation([
                    OfflineTranslationRequest(
                        id: "post-timeout-\(index)", sourceText: "fixture", pair: pair
                    )
                ])
            }
            await waitForOperation(in: model)
            try hostExpect(model.configurationGeneration == timedOutGeneration + UInt64(index + 1),
                           "post-timeout operation generation jumped or did not start")
            await model.runActiveOperation(
                sessionGeneration: model.configurationGeneration,
                prepare: {}, translate: { _ in "post-timeout-ok-\(index)" }
            )
            let value = try await next.value
            try hostExpect(value.first?.translatedText == "post-timeout-ok-\(index)",
                           "post-timeout queue did not recover at \(index)")
        }
        suspendedCallback.cancel()
        _ = await suspendedCallback.result

        // One process, one host model, 100 interleaved operations. Every injected timeout-like
        // framework error/cancellation is immediately followed by a successful operation; stale
        // callbacks are also replayed after a new generation has started.
        var successfulStressOperations = 0
        var failedStressOperations = 0
        for index in 0..<100 {
            let operation = Task.detached {
                try await model.enqueueTranslation([
                    OfflineTranslationRequest(
                        id: "stress-\(index)", sourceText: "fixture-\(index)", pair: pair
                    )
                ])
            }
            await waitForOperation(in: model)
            let generation = model.configurationGeneration
            let injectCancellation = index % 20 == 4
            let injectFailure = index % 20 == 14
            if injectCancellation || injectFailure {
                await model.runActiveOperation(
                    sessionGeneration: generation,
                    prepare: {},
                    translate: { _ in
                        if injectCancellation { throw CancellationError() }
                        throw OfflineTranslationError.systemFailure
                    }
                )
                do {
                    _ = try await operation.value
                    throw HostSmokeFailure.failed("injected stress failure completed")
                } catch let error as OfflineTranslationError {
                    failedStressOperations += 1
                    model.recoverAfterOperationFailure(error)
                }
            } else {
                await model.runActiveOperation(
                    sessionGeneration: generation,
                    prepare: {},
                    translate: { _ in "stress-ok-\(index)" }
                )
                let response = try await operation.value
                try hostExpect(response.first?.translatedText == "stress-ok-\(index)",
                               "stress response mismatch at \(index)")
                successfulStressOperations += 1
            }

            if index % 11 == 7 {
                var staleCallbackRan = false
                await model.runActiveOperation(
                    sessionGeneration: generation,
                    prepare: { staleCallbackRan = true },
                    translate: { _ in staleCallbackRan = true; return "stale" }
                )
                try hostExpect(!staleCallbackRan,
                               "old callback crossed operation generation at \(index)")
            }
        }
        try hostExpect(successfulStressOperations == 90 && failedStressOperations == 10,
                       "stress did not exercise enough success/failure operations")
        try hostExpect(model.pendingOperationCount == 0,
                       "stress leaked queued/active operations")
        try hostExpect(model.health == .healthy && model.visibleStatus == .installed,
                       "stress did not finish with a reusable healthy host")

        model.hostDidAttach()
        let detached = Task.detached {
            try await model.enqueuePreparation(for: pair)
        }
        await waitForOperation(in: model)
        model.hostDidDetach()
        do {
            try await detached.value
            throw HostSmokeFailure.failed("detached host left a continuation pending")
        } catch let error as OfflineTranslationError {
            try hostExpect(error == .hostEnded,
                           "host detach did not resume with hostEnded")
        }

        print("System Translation host mock lifecycle smoke: PASS")
    }

    @MainActor
    private static func waitForOperation(in model: SystemTranslationHostModel) async {
        for _ in 0..<100 {
            if model.hasPendingOperations { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
