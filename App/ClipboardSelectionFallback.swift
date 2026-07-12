import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin

enum ClipboardSelectionFallbackResult {
    case text(String)
    case noText
    case unsafeSnapshot
    case restoreFailed
    case secureInput
    case unavailable
}

/// Performs one bounded, user-initiated Copy request against the application
/// that was frontmost before LocalDictionary displays its panel.
final class ClipboardSelectionFallback {
    private let pasteboard = NSPasteboard.general
    private let timeout: TimeInterval = 0.45
    private let pollingIntervalMicroseconds: useconds_t = 10_000

    func readSelection(from application: NSRunningApplication?) -> ClipboardSelectionFallbackResult {
        guard !IsSecureEventInputEnabled() else { return .secureInput }
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .unavailable
        }
        guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else {
            return .unsafeSnapshot
        }

        let originalChangeCount = snapshot.changeCount
        guard postCopy(to: application.processIdentifier) else { return .unavailable }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if pasteboard.changeCount != originalChangeCount {
                let copiedText = pasteboard.string(forType: .string)
                guard snapshot.restore(to: pasteboard) else { return .restoreFailed }
                guard let copiedText, !copiedText.isEmpty else { return .noText }
                return .text(copiedText)
            }
            usleep(pollingIntervalMicroseconds)
        }
        return .noText
    }

    private func postCopy(to processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: CGKeyCode(kVK_ANSI_C),
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_ANSI_C),
                                  keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }
}

private struct PasteboardSnapshot {
    private struct Item {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    // A large clipboard is left untouched instead of causing an unbounded
    // allocation in this lightweight, one-shot fallback.
    private static let maximumSnapshotBytes = 64 * 1024 * 1024

    let changeCount: Int
    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let initialChangeCount = pasteboard.changeCount
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            let hasUncapturedTypes = !(pasteboard.types?.isEmpty ?? true)
            guard !hasUncapturedTypes, pasteboard.changeCount == initialChangeCount else {
                return nil
            }
            return PasteboardSnapshot(changeCount: initialChangeCount, items: [])
        }

        var capturedItems: [Item] = []
        var totalBytes = 0
        capturedItems.reserveCapacity(pasteboardItems.count)

        for pasteboardItem in pasteboardItems {
            let types = pasteboardItem.types
            guard !types.isEmpty else { return nil }

            var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            representations.reserveCapacity(types.count)
            for type in types {
                guard let data = pasteboardItem.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= maximumSnapshotBytes else { return nil }
                representations.append((type, data))
            }
            capturedItems.append(Item(representations: representations))
        }

        guard pasteboard.changeCount == initialChangeCount else { return nil }
        return PasteboardSnapshot(changeCount: initialChangeCount, items: capturedItems)
    }

    func restore(to pasteboard: NSPasteboard) -> Bool {
        var restoredItems: [NSPasteboardItem] = []
        restoredItems.reserveCapacity(items.count)

        for item in items {
            let restoredItem = NSPasteboardItem()
            for representation in item.representations {
                guard restoredItem.setData(representation.data, forType: representation.type) else {
                    return false
                }
            }
            restoredItems.append(restoredItem)
        }

        pasteboard.clearContents()
        guard !restoredItems.isEmpty else { return true }
        return pasteboard.writeObjects(restoredItems)
    }
}
