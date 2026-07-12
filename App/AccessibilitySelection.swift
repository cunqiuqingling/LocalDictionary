import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum AccessibilitySelectionResult {
    case text(String)
    case noSelection
    case permissionDenied
    case secureInput
    case unavailable
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
            if let selection = selectedText(from: focusedElement), !selection.isEmpty {
                return .text(selection)
            }
        }

        if let focusedWindow = elementAttribute(kAXFocusedWindowAttribute as CFString,
                                                from: appElement),
           let selection = selectedText(from: focusedWindow), !selection.isEmpty {
            return .text(selection)
        }
        return .noSelection
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
