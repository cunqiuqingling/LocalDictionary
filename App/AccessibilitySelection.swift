import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum AccessibilitySelectionResult {
    case text(AccessibilitySelectionCapture)
    case noSelection
    case permissionDenied
    case secureInput
    case unavailable
}

struct AccessibilitySelectionCapture: Equatable {
    let text: String
    /// AX global display coordinates. Consumers must convert to the chosen NSScreen coordinate
    /// space once; Retina backing scale must not be applied to these point values.
    let selectionRects: [CGRect]
    let capturedAt: Date

    func isFresh(now: Date = Date(), maximumAge: TimeInterval = 1.5) -> Bool {
        now.timeIntervalSince(capturedAt) >= 0 &&
            now.timeIntervalSince(capturedAt) <= maximumAge && !text.isEmpty
    }
}

final class AccessibilitySelectionReader {
    func readSelection(from application: NSRunningApplication?) -> AccessibilitySelectionResult {
        guard AXIsProcessTrusted() else { return .permissionDenied }
        guard !IsSecureEventInputEnabled() else { return .secureInput }
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .unavailable
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let focusedElement = elementAttribute(kAXFocusedUIElementAttribute as CFString,
                                                 from: appElement) {
            if isSecureTextElement(focusedElement) { return .secureInput }
            if let selection = selectedCapture(from: focusedElement) {
                return .text(selection)
            }
        }

        if let focusedWindow = elementAttribute(kAXFocusedWindowAttribute as CFString,
                                                from: appElement),
           let selection = selectedCapture(from: focusedWindow) {
            return .text(selection)
        }
        return .noSelection
    }

    private func selectedCapture(from element: AXUIElement)
        -> AccessibilitySelectionCapture? {
        guard let text = selectedText(from: element), !text.isEmpty else { return nil }
        let rects = selectedRange(from: element).map {
            lineRects(for: $0, element: element)
        } ?? markerSelectionRect(from: element).map { [$0] } ?? []
        return AccessibilitySelectionCapture(
            text: text, selectionRects: rects.filter(Self.validRect), capturedAt: Date()
        )
    }

    private func selectedText(from element: AXUIElement) -> String? {
        if let value = attribute(kAXSelectedTextAttribute as CFString, from: element) as? String,
           !value.isEmpty {
            return value
        }

        guard let markerRange = attribute(kAXSelectedTextMarkerRangeAttribute as CFString,
                                          from: element) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
            markerRange,
            &value
        )
        guard error == .success else { return nil }
        return value as? String
    }

    private func selectedRange(from element: AXUIElement) -> CFRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute as CFString, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) && range.length > 0 ? range : nil
    }

    private func lineRects(for selectedRange: CFRange,
                           element: AXUIElement) -> [CGRect] {
        var values: [CGRect] = []
        let selectedEnd = selectedRange.location + selectedRange.length
        var cursor = selectedRange.location
        var visitedLines = 0
        while cursor < selectedEnd, visitedLines < 256 {
            guard let lineNumber = parameterizedNumber(
                kAXLineForIndexParameterizedAttribute as CFString,
                parameter: cursor as CFNumber, from: element
            ), let lineRange = parameterizedRange(
                kAXRangeForLineParameterizedAttribute as CFString,
                parameter: lineNumber as CFNumber, from: element
            ) else { break }
            let intersectionStart = max(cursor, lineRange.location)
            let intersectionEnd = min(selectedEnd, lineRange.location + lineRange.length)
            guard intersectionEnd > intersectionStart else { break }
            let intersection = CFRange(location: intersectionStart,
                                       length: intersectionEnd - intersectionStart)
            if let rect = parameterizedRect(
                kAXBoundsForRangeParameterizedAttribute as CFString,
                range: intersection, from: element
            ) { values.append(rect) }
            cursor = max(intersectionEnd, cursor + 1)
            visitedLines += 1
        }
        if values.isEmpty, let rect = parameterizedRect(
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range: selectedRange, from: element
        ) { values.append(rect) }
        return values
    }

    private func markerSelectionRect(from element: AXUIElement) -> CGRect? {
        guard let marker = attribute(kAXSelectedTextMarkerRangeAttribute as CFString,
                                     from: element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            marker, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
    }

    private func parameterizedNumber(_ name: CFString, parameter: CFTypeRef,
                                     from element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name, parameter, &value
        ) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func parameterizedRange(_ name: CFString, parameter: CFTypeRef,
                                    from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name, parameter, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func parameterizedRect(_ name: CFString, range: CFRange,
                                   from element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name, parameter, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
    }

    private static func validRect(_ value: CGRect) -> Bool {
        !value.isNull && !value.isInfinite && !value.isEmpty &&
            value.origin.x.isFinite && value.origin.y.isFinite
    }

    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        guard let subrole = attribute(kAXSubroleAttribute as CFString, from: element) as? String else {
            return false
        }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private func elementAttribute(_ name: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, from: element) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}

enum CleanedSelection: Equatable {
    case value(String)
    case empty
    case tooLong(Int)
}

enum SelectedTextCleaner {
    static let maximumLength = 100

    static func clean(_ source: String) -> CleanedSelection {
        var value = collapseWhitespace(in: source)
        value = stripWrappingQuotes(from: value)
        value = stripTrailingPunctuation(from: value)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else { return .empty }
        guard value.count <= maximumLength else { return .tooLong(value.count) }
        return .value(value)
    }

    private static func collapseWhitespace(in source: String) -> String {
        var output = ""
        var hasPendingSpace = false
        for character in source {
            if character.isWhitespace {
                hasPendingSpace = !output.isEmpty
            } else {
                if hasPendingSpace { output.append(" ") }
                output.append(character)
                hasPendingSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(from source: String) -> String {
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"),
            ("「", "」"), ("『", "』"), ("«", "»"), ("‹", "›")
        ]
        guard source.count >= 2,
              let first = source.first,
              let last = source.last,
              pairs.contains(where: { $0.0 == first && $0.1 == last }) else {
            return source
        }
        return String(source.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTrailingPunctuation(from source: String) -> String {
        let punctuation: Set<Character> = [
            ",", ".", ";", ":", "!", "?", "，", "。", "；", "：", "！", "？"
        ]
        var value = source
        while let last = value.last, punctuation.contains(last) {
            value.removeLast()
        }
        return value
    }
}

@MainActor
final class AccessibilityPermissionPrompter {
    private let promptShownKey = "AccessibilityPermissionPromptWasShown"

    func showIfNeeded() {
        guard !AXIsProcessTrusted(),
              !UserDefaults.standard.bool(forKey: promptShownKey) else { return }
        UserDefaults.standard.set(true, forKey: promptShownKey)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "允许辅助功能取词"
        alert.informativeText = "若要读取其他应用中当前选中的文字，请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 LocalDictionary。未授权时仍可手动输入查词。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
