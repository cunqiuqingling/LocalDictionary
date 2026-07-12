import Foundation

enum HTMLTextCleaner {
    private static let removalPatterns = [
        #"(?is)<script\b[^>]*>.*?</script\s*>"#,
        #"(?is)<style\b[^>]*>.*?</style\s*>"#,
        #"(?is)<(?:link|img|audio|video|source|object|iframe)\b[^>]*>"#
    ]

    static func clean(_ html: String) -> String {
        var text = html
        for pattern in removalPatterns {
            text = text.replacingOccurrences(of: pattern,
                                              with: "",
                                              options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#,
                                          with: "\n",
                                          options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<li\b[^>]*>"#,
                                          with: "\n• ",
                                          options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(?:p|div|li|section|article|h[1-6]|tr)>"#,
                                          with: "\n",
                                          options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]+>"#,
                                          with: " ",
                                          options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: #"[\t ]+"#,
                                          with: " ",
                                          options: .regularExpression)
        text = text.replacingOccurrences(of: #" *\n *"#,
                                          with: "\n",
                                          options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#,
                                          with: "\n\n",
                                          options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ source: String) -> String {
        var value = source
        let named = [
            "&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&lt;": "<",
            "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&mdash;": "—",
            "&ndash;": "–", "&middot;": "·", "&copy;": "©"
        ]
        for (entity, replacement) in named {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }

        guard let expression = try? NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|([0-9]+));"#) else {
            return value
        }
        let matches = expression.matches(in: value,
                                         range: NSRange(value.startIndex..., in: value)).reversed()
        for match in matches {
            guard let fullRange = Range(match.range, in: value) else { continue }
            let hexRange = Range(match.range(at: 1), in: value)
            let decimalRange = Range(match.range(at: 2), in: value)
            let number: UInt32?
            if let hexRange {
                number = UInt32(value[hexRange], radix: 16)
            } else if let decimalRange {
                number = UInt32(value[decimalRange], radix: 10)
            } else {
                number = nil
            }
            if let number, let scalar = UnicodeScalar(number) {
                value.replaceSubrange(fullRange, with: String(scalar))
            }
        }
        return value
    }
}

