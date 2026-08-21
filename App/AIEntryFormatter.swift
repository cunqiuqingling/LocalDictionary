import AppKit

enum SafeProviderMarkdownRenderer {
    static func attributedString(
        from markdown: String,
        baseFont: NSFont = .systemFont(ofSize: 13),
        color: NSColor = .labelColor
    ) -> NSAttributedString {
        let lines = sanitize(markdown).components(separatedBy: .newlines)
        let output = NSMutableAttributedString()
        var index = 0
        while index < lines.count {
            if let table = markdownTable(startingAt: index, in: lines) {
                output.append(renderTable(table, baseFont: baseFont, color: color))
                index = table.nextLineIndex
                continue
            }

            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if output.length > 0, !output.string.hasSuffix("\n\n") {
                    output.append(NSAttributedString(string: "\n"))
                }
                index += 1
                continue
            }
            if line.range(of: #"^\s*(?:-{3,}|_{3,}|\*{3,})\s*$"#,
                          options: .regularExpression) != nil {
                output.append(NSAttributedString(
                    string: "────────────────\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: NSColor.separatorColor]
                ))
                index += 1
                continue
            }
            var content = line
            var prefix = ""
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = 4
            var lineFont = baseFont
            if let headingRange = content.range(
                of: #"^#{1,6}\s+"#, options: .regularExpression
            ) {
                let level = content[..<headingRange.upperBound].filter { $0 == "#" }.count
                content.removeSubrange(headingRange)
                content = content.replacingOccurrences(
                    of: #"\s+#+\s*$"#, with: "", options: .regularExpression
                )
                lineFont = .systemFont(
                    ofSize: max(baseFont.pointSize, 17 - CGFloat(level)), weight: .semibold
                )
                paragraph.paragraphSpacingBefore = level <= 2 ? 9 : 6
                paragraph.paragraphSpacing = 4
            } else if content.range(of: #"^[-+*]\s+"#, options: .regularExpression) != nil {
                content = content.replacingOccurrences(
                    of: #"^[-+*]\s+"#, with: "", options: .regularExpression
                )
                prefix = "• "
                paragraph.headIndent = 16
            } else if let range = content.range(
                of: #"^\d+[.)、]\s+"#, options: .regularExpression
            ) {
                prefix = String(content[range])
                content.removeSubrange(range)
                paragraph.headIndent = 20
            }
            output.append(NSAttributedString(
                string: prefix,
                attributes: [.font: lineFont, .foregroundColor: color,
                             .paragraphStyle: paragraph]
            ))
            output.append(inline(content, baseFont: lineFont, color: color,
                                 paragraph: paragraph))
            if !output.string.hasSuffix("\n") {
                output.append(NSAttributedString(string: "\n"))
            }
            index += 1
        }
        return output
    }

    private struct MarkdownTable {
        let headers: [String]
        let rows: [[String]]
        let nextLineIndex: Int
    }

    /// Recognizes the safe, display-only subset of GFM pipe tables. The separator row is
    /// structural metadata and is never emitted as user-visible Markdown source.
    private static func markdownTable(startingAt index: Int,
                                      in lines: [String]) -> MarkdownTable? {
        guard index + 1 < lines.count,
              let headers = pipeCells(in: lines[index]),
              let separators = pipeCells(in: lines[index + 1]),
              !headers.isEmpty,
              headers.count == separators.count,
              separators.allSatisfy({ cell in
                  cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
              }) else {
            return nil
        }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count {
            let candidate = lines[nextIndex].trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, var cells = pipeCells(in: candidate) else { break }
            if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            } else if cells.count < headers.count {
                cells.append(contentsOf: repeatElement("", count: headers.count - cells.count))
            }
            rows.append(cells)
            nextIndex += 1
        }
        return MarkdownTable(headers: headers, rows: rows, nextLineIndex: nextIndex)
    }

    /// Splits only unescaped pipes outside inline-code spans. This prevents code such as
    /// `a | b` or an escaped `\|` from accidentally creating extra columns.
    private static func pipeCells(in source: String) -> [String]? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var cells = [""]
        var sawDelimiter = false
        var escaped = false
        var insideInlineCode = false
        var isFirstToken = true
        var hasLeadingDelimiter = false
        var hasTrailingDelimiter = false
        for character in trimmed {
            if escaped {
                if character != "|" { cells[cells.count - 1].append("\\") }
                cells[cells.count - 1].append(character)
                escaped = false
                isFirstToken = false
                hasTrailingDelimiter = false
                continue
            }
            if character == "\\" {
                escaped = true
                isFirstToken = false
                hasTrailingDelimiter = false
                continue
            }
            if character == "`" {
                insideInlineCode.toggle()
                cells[cells.count - 1].append(character)
                isFirstToken = false
                hasTrailingDelimiter = false
                continue
            }
            if character == "|", !insideInlineCode {
                cells.append("")
                sawDelimiter = true
                if isFirstToken { hasLeadingDelimiter = true }
                hasTrailingDelimiter = true
            } else {
                cells[cells.count - 1].append(character)
                hasTrailingDelimiter = false
            }
            isFirstToken = false
        }
        if escaped { cells[cells.count - 1].append("\\") }
        guard sawDelimiter else { return nil }

        if hasLeadingDelimiter { cells.removeFirst() }
        if hasTrailingDelimiter, !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Tables are rendered as compact, labelled row blocks. This remains readable in the
    /// dictionary panel's narrow widths and avoids HTML/WebView, remote content, and fixed
    /// column widths that would clip long bilingual text.
    private static func renderTable(_ table: MarkdownTable,
                                    baseFont: NSFont,
                                    color: NSColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 2

        if table.rows.isEmpty {
            for (columnIndex, header) in table.headers.enumerated() where !header.isEmpty {
                if columnIndex > 0 { output.append(NSAttributedString(string: "  ·  ")) }
                output.append(inline(header,
                                     baseFont: .systemFont(ofSize: baseFont.pointSize,
                                                           weight: .semibold),
                                     color: color,
                                     paragraph: paragraph))
            }
            output.append(NSAttributedString(string: "\n"))
            return output
        }

        for (rowIndex, row) in table.rows.enumerated() {
            let rowParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
            rowParagraph.paragraphSpacingBefore = rowIndex == 0 ? 2 : 5
            output.append(NSAttributedString(
                string: "\(rowIndex + 1).\n",
                attributes: [.font: NSFont.systemFont(ofSize: baseFont.pointSize - 1,
                                                       weight: .semibold),
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: rowParagraph]
            ))
            for columnIndex in table.headers.indices {
                let value = row[columnIndex]
                guard !value.isEmpty else { continue }
                let header = table.headers[columnIndex]
                if !header.isEmpty {
                    output.append(inline(header,
                                         baseFont: .systemFont(ofSize: baseFont.pointSize,
                                                               weight: .semibold),
                                         color: color,
                                         paragraph: paragraph))
                    output.append(NSAttributedString(
                        string: "：",
                        attributes: [.font: baseFont, .foregroundColor: color,
                                     .paragraphStyle: paragraph]
                    ))
                }
                output.append(inline(value, baseFont: baseFont, color: color,
                                     paragraph: paragraph))
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    private static func sanitize(_ source: String) -> String {
        var value = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // No HTML/WebView path exists here. Remove executable/remote constructs before parsing.
        value = value.replacingOccurrences(
            of: #"(?is)<(?:script|style)[^>]*>.*?</(?:script|style)>"#,
            with: "", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"<[^>]{1,512}>"#, with: "", options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1",
            options: .regularExpression
        )
        return value
    }

    private static func inline(_ source: String, baseFont: NSFont, color: NSColor,
                               paragraph: NSParagraphStyle) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var index = source.startIndex
        func append(_ text: String, font: NSFont, background: NSColor? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ]
            if let background { attributes[.backgroundColor] = background }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        while index < source.endIndex {
            let remainder = source[index...]
            if remainder.hasPrefix("**"),
               let closing = source.range(of: "**",
                   range: source.index(index, offsetBy: 2)..<source.endIndex) {
                let start = source.index(index, offsetBy: 2)
                append(String(source[start..<closing.lowerBound]),
                       font: NSFont.systemFont(ofSize: baseFont.pointSize,
                                               weight: .semibold))
                index = closing.upperBound
                continue
            }
            if remainder.hasPrefix("`"),
               let closing = source.range(of: "`",
                   range: source.index(after: index)..<source.endIndex) {
                append(String(source[source.index(after: index)..<closing.lowerBound]),
                       font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 0.5,
                                                        weight: .regular),
                       background: NSColor.quaternaryLabelColor.withAlphaComponent(0.12))
                index = closing.upperBound
                continue
            }
            if remainder.hasPrefix("*") || remainder.hasPrefix("_") {
                let marker = String(source[index])
                if let closing = source.range(of: marker,
                    range: source.index(after: index)..<source.endIndex) {
                    let font = NSFontManager.shared.convert(
                        baseFont, toHaveTrait: .italicFontMask
                    )
                    append(String(source[source.index(after: index)..<closing.lowerBound]),
                           font: font)
                    index = closing.upperBound
                    continue
                }
            }
            let next = source.index(after: index)
            append(String(source[index..<next]), font: baseFont)
            index = next
        }
        return output
    }
}

final class AIEntryFormatter {
    func format(_ presentation: AIExplanationPresentation) -> NSAttributedString {
        let uiEnglish = LanguagePreferencesStore.shared.load().resolvedUILanguage == .english
        func t(_ chinese: String, _ english: String) -> String {
            uiEnglish ? english : chinese
        }
        let output = NSMutableAttributedString()
        append(t("AI 双语解释\n", "AI Bilingual Explanation\n"),
               font: .systemFont(ofSize: 15, weight: .semibold),
               color: .systemPurple, spacingBefore: 6, spacingAfter: 2, to: output)
        append(t("由 \(presentation.providerDisplayName) · \(presentation.model) 生成\n",
                 "Generated by \(presentation.providerDisplayName) · \(presentation.model)\n"),
               font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
               spacingAfter: 12, to: output)
        let explanation = presentation.explanation
        let context = LanguageContext.make(query: explanation.headword)
        if context.isNativeDominant,
           let primary = explanation.recommendedEnglishExpressions.first {
            append(t("推荐 English 表达\n", "Recommended English Expression\n"),
                   font: .systemFont(ofSize: 12, weight: .semibold),
                   color: .secondaryLabelColor, spacingAfter: 2, to: output)
            append(primary + "\n", font: .systemFont(ofSize: 21, weight: .semibold),
                   color: .labelColor, spacingAfter: 3, to: output)
            append(t("查询：\(explanation.headword)\n", "Query: \(explanation.headword)\n"),
                   font: .systemFont(ofSize: 12),
                   color: .secondaryLabelColor, spacingAfter: 6, to: output)
        } else {
            append(explanation.headword + "\n",
                   font: .systemFont(ofSize: 21, weight: .semibold),
                   color: .labelColor, spacingAfter: 3, to: output)
        }
        if !explanation.pronunciations.isEmpty {
            append(explanation.pronunciations.joined(separator: "  ") + "\n",
                   font: .systemFont(ofSize: 14), color: .secondaryLabelColor,
                   spacingAfter: 8, to: output)
        }
        if !explanation.domain.isEmpty {
            append(t("领域：\(explanation.domain)\n", "Domain: \(explanation.domain)\n"),
                   font: .systemFont(ofSize: 12),
                   color: .secondaryLabelColor, spacingAfter: 8, to: output)
        }
        for part in explanation.partsOfSpeech {
            if !part.partOfSpeech.isEmpty {
                append(part.partOfSpeech + "\n", font: .systemFont(ofSize: 16, weight: .semibold),
                       color: .labelColor, spacingBefore: 8, spacingAfter: 5, to: output)
            }
            for (index, sense) in part.senses.enumerated() {
                if !sense.definitionZH.isEmpty {
                    let prefix = context.isLearningDominant
                        ? t("\(index + 1). 母语核心意思：", "\(index + 1). Native-language meaning: ")
                        : "\(index + 1). "
                    append(prefix + sense.definitionZH + "\n",
                           font: .systemFont(ofSize: 14, weight: .semibold),
                           color: .labelColor, firstLineIndent: 0, headIndent: 18,
                           spacingAfter: 2, to: output)
                }
                if !sense.definitionEN.isEmpty {
                    let prefix = context.isLearningDominant
                        ? t("学习语言释义：", "Learning-language definition: ") : ""
                    append(prefix + sense.definitionEN + "\n",
                           font: .systemFont(ofSize: 13.5), color: .labelColor,
                           firstLineIndent: 18, headIndent: 18, spacingAfter: 2, to: output)
                }
                if !sense.usageNoteZH.isEmpty {
                    append(sense.usageNoteZH + "\n", font: .systemFont(ofSize: 12),
                           color: .labelColor, firstLineIndent: 18, headIndent: 18,
                           spacingAfter: 4, to: output)
                }
                for example in sense.examples {
                    if !example.en.isEmpty {
                        append(example.en + "\n", font: italicFont(ofSize: 13),
                               color: .labelColor, firstLineIndent: 26, headIndent: 26,
                               spacingAfter: 1, to: output)
                    }
                    if !example.zh.isEmpty {
                        append(example.zh + "\n", font: .systemFont(ofSize: 13),
                               color: .labelColor, firstLineIndent: 26, headIndent: 26,
                               spacingAfter: 3, to: output)
                    }
                }
                if !sense.collocations.isEmpty {
                    append("常见搭配：" + sense.collocations.joined(separator: "；") + "\n",
                           font: .systemFont(ofSize: 12), color: .labelColor,
                           firstLineIndent: 18, headIndent: 18, spacingAfter: 5, to: output)
                }
            }
        }
        if !explanation.spellingSuggestions.isEmpty {
            append("拼写建议\n", font: .systemFont(ofSize: 13, weight: .semibold),
                   color: .secondaryLabelColor, spacingBefore: 8, spacingAfter: 3,
                   to: output)
            append(explanation.spellingSuggestions.joined(separator: "、") + "\n",
                   font: .systemFont(ofSize: 13), color: .labelColor,
                   firstLineIndent: 18, headIndent: 18, spacingAfter: 4, to: output)
        }
        if !explanation.caution.isEmpty {
            append("注意：\(explanation.caution)\n", font: .systemFont(ofSize: 12),
                   color: .labelColor, spacingBefore: 8, spacingAfter: 3, to: output)
        }
        let alternatives: ArraySlice<String> = context.isNativeDominant
            ? explanation.recommendedEnglishExpressions.dropFirst() : []
        if !alternatives.isEmpty {
            append("其他可能表达：" + alternatives.joined(separator: "；") + "\n",
                   font: .systemFont(ofSize: 12), color: .labelColor,
                   spacingBefore: 8, spacingAfter: 3, to: output)
        }
        if let fallback = explanation.rawFallbackText, !fallback.isEmpty {
            append("AI 返回的非结构化内容\n",
                   font: .systemFont(ofSize: 13, weight: .semibold),
                   color: .secondaryLabelColor, spacingBefore: 8, spacingAfter: 3, to: output)
            output.append(SafeProviderMarkdownRenderer.attributedString(from: fallback))
        }
        return output
    }

    private func append(_ string: String, font: NSFont, color: NSColor,
                        firstLineIndent: CGFloat = 0, headIndent: CGFloat = 0,
                        spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0,
                        to output: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = firstLineIndent
        paragraph.headIndent = headIndent
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.lineBreakMode = .byWordWrapping
        output.append(NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]))
    }

    private func italicFont(ofSize size: CGFloat) -> NSFont {
        NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }
}
