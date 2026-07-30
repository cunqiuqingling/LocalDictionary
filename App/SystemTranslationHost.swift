import AppKit
import SwiftUI
@preconcurrency import Translation

@MainActor
final class SystemTranslationHostModel: ObservableObject {
    static let maximumPendingOperations = 8

    enum VisibleStatus: String {
        case idle = "系统离线翻译"
        case checking = "正在检查系统语言包…"
        case needsDownload = "需要下载 Apple 系统离线语言包"
        case preparing = "正在准备系统语言包…"
        case installed = "系统离线语言包已安装"
        case translating = "正在进行基础离线翻译…"
        case unsupported = "系统不支持该语言方向"
        case failed = "系统翻译暂时失败"
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
    @Published private(set) var visibleStatus: VisibleStatus = .idle

    private var queue: [Operation] = []
    private var active: Operation?
    private(set) var hostAttached = false

    func hostDidAttach() {
        hostAttached = true
        activateNextIfNeeded()
    }

    func hostDidDetach() {
        hostAttached = false
        configuration?.invalidate()
        configuration = nil
        let error = OfflineTranslationError.hostEnded
        if let active { resume(active, throwing: error) }
        queue.forEach { resume($0, throwing: error) }
        active = nil
        queue.removeAll()
        visibleStatus = .idle
    }

    func enqueueTranslation(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        guard !requests.isEmpty, let pair = requests.first?.pair,
              requests.allSatisfy({ $0.pair == pair && !$0.sourceText.isEmpty }) else {
            throw OfflineTranslationError.emptyInput
        }
        let operationID = UUID()
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
                activateNextIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation(id: operationID) }
        }
    }

    func enqueuePreparation(for pair: OfflineTranslationPair) async throws {
        let operationID = UUID()
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

    func runActiveOperation(with session: TranslationSession) async {
        guard let operation = active else { return }
        do {
            switch operation.kind {
            case .prepare(let continuation):
                visibleStatus = .preparing
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard finishActive(operation.id) else { return }
                visibleStatus = .installed
                continuation.resume()
                activateNextIfNeeded()
            case .translate(let requests, let continuation):
                visibleStatus = .translating
                var responses: [OfflineTranslationResponse] = []
                responses.reserveCapacity(requests.count)
                for request in requests {
                    try Task.checkCancellation()
                    let value = try await session.translate(request.sourceText)
                    responses.append(OfflineTranslationResponse(
                        id: request.id,
                        sourceText: request.sourceText,
                        translatedText: value.targetText,
                        pair: request.pair
                    ))
                }
                guard finishActive(operation.id) else { return }
                visibleStatus = .installed
                continuation.resume(returning: responses)
                activateNextIfNeeded()
            }
        } catch is CancellationError {
            if finishActive(operation.id) {
                resume(operation, throwing: OfflineTranslationError.cancelled)
                activateNextIfNeeded()
            }
        } catch let error as OfflineTranslationError {
            if finishActive(operation.id) {
                resume(operation, throwing: error)
                activateNextIfNeeded()
            }
        } catch {
            if finishActive(operation.id) {
                visibleStatus = .failed
                resume(operation, throwing: Self.map(error))
                activateNextIfNeeded()
            }
        }
    }

    func setAvailabilityStatus(_ availability: OfflineTranslationAvailability) {
        switch availability {
        case .installed: visibleStatus = .installed
        case .supportedNeedsDownload: visibleStatus = .needsDownload
        case .unsupported: visibleStatus = .unsupported
        case .checking: visibleStatus = .checking
        case .temporarilyUnavailable: visibleStatus = .failed
        }
    }

    private func activateNextIfNeeded() {
        guard hostAttached, active == nil, !queue.isEmpty else { return }
        let operation = queue.removeFirst()
        active = operation
        var next = TranslationSession.Configuration(
            source: operation.pair.source.localeLanguage,
            target: operation.pair.target.localeLanguage
        )
        // A fresh version is required even for two adjacent operations with the same pair.
        configuration?.invalidate()
        next.invalidate()
        configuration = TranslationSession.Configuration(
            source: operation.pair.source.localeLanguage,
            target: operation.pair.target.localeLanguage
        )
    }

    private var canEnqueueOperation: Bool {
        queue.count + (active == nil ? 0 : 1) < Self.maximumPendingOperations
    }

    private func cancelOperation(id: UUID) {
        let error = OfflineTranslationError.cancelled
        if let active, active.id == id {
            self.active = nil
            configuration?.invalidate()
            configuration = nil
            visibleStatus = .idle
            resume(active, throwing: error)
            activateNextIfNeeded()
            return
        }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let operation = queue.remove(at: index)
        resume(operation, throwing: error)
    }

    private func finishActive(_ id: UUID) -> Bool {
        guard active?.id == id else { return false }
        active = nil
        configuration = nil
        return true
    }

    private func resume(_ operation: Operation, throwing error: Error) {
        switch operation.kind {
        case .translate(_, let continuation): continuation.resume(throwing: error)
        case .prepare(let continuation): continuation.resume(throwing: error)
        }
    }

    private static func map(_ error: Error) -> OfflineTranslationError {
        if TranslationError.unsupportedSourceLanguage ~= error ||
            TranslationError.unsupportedTargetLanguage ~= error ||
            TranslationError.unsupportedLanguagePairing ~= error {
            return .unsupportedLanguagePair
        }
        if TranslationError.nothingToTranslate ~= error { return .emptyInput }
        return .systemFailure
    }
}

private struct SystemTranslationHostView: View {
    @ObservedObject var model: SystemTranslationHostModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.secondary)
            Text(model.visibleStatus.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .onAppear { model.hostDidAttach() }
        .onDisappear { model.hostDidDetach() }
        .translationTask(model.configuration) { session in
            await model.runActiveOperation(with: session)
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

final class SystemTranslationEngine: @unchecked Sendable, OfflineTranslationEngine {
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
        return mapped
    }

    func translate(_ requests: [OfflineTranslationRequest]) async throws
        -> [OfflineTranslationResponse] {
        guard let pair = requests.first?.pair else { return [] }
        switch await availability(for: pair) {
        case .installed: break
        case .supportedNeedsDownload: throw OfflineTranslationError.languagePackRequired
        case .unsupported: throw OfflineTranslationError.unsupportedLanguagePair
        case .checking, .temporarilyUnavailable:
            throw OfflineTranslationError.systemFailure
        }
        guard let model else { throw OfflineTranslationError.hostEnded }
        return try await model.enqueueTranslation(requests)
    }

    func prepareLanguagePack(for pair: OfflineTranslationPair) async throws {
        let availability = await availability(for: pair)
        guard availability != .unsupported else {
            throw OfflineTranslationError.unsupportedLanguagePair
        }
        if availability == .installed { return }
        guard let model else { throw OfflineTranslationError.hostEnded }
        try await model.enqueuePreparation(for: pair)
    }
}

private extension OfflineTranslationLanguage {
    var localeLanguage: Locale.Language {
        Locale.Language(identifier: rawValue)
    }
}
