import Foundation

final class SentenceAnalysisMarkdownFormatter {
    func content(sourceText: String,
                 aiPresentation: AISentenceAnalysisPresentation?,
                 glossary: LocalSentenceGlossary?) -> SentenceNoteSaveContent? {
        let sentence = SentenceTextNormalizer.normalize(sourceText)
        guard !sentence.isEmpty else { return nil }
        let aiSection = aiPresentation.map(aiMarkdownSection)
        let glossarySection = glossary.flatMap { $0.hasEntries ? glossaryMarkdownSection($0) : nil }
        let content = SentenceNoteSaveContent(
            sourceText: sentence,
            title: title(for: sentence),
            aiSectionMarkdown: aiSection,
            glossarySectionMarkdown: glossarySection
        )
        return content.isValid ? content : nil
    }

    func title(for sentence: String) -> String {
        let normalized = SentenceTextNormalizer.normalize(sentence)
        var preview = normalized.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "|", with: "｜")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumVisibleCharacters = 48
        if preview.count > maximumVisibleCharacters {
            preview = String(preview.prefix(maximumVisibleCharacters - 1)) + "…"
        }
        return "句子解析｜" + (preview.isEmpty ? "英文句子" : preview)
    }

    private func aiMarkdownSection(
        _ presentation: AISentenceAnalysisPresentation
    ) -> String {
        let analysis = presentation.analysis
        var lines = [
            "### AI 解析",
            "",
            "> AI 生成：\(safeProviderName(presentation.providerDisplayName)) · \(inline(presentation.model))"
        ]
        appendSection("自然翻译", body: analysis.translationZH, to: &lines)

        let core = analysis.coreStructure
        var coreLines: [String] = []
        appendBullet("句型", analysis.sentenceType, to: &coreLines)
        appendBullet("主语", core.subject, to: &coreLines)
        appendBullet("谓语", core.predicate, to: &coreLines)
        appendBullet("宾语或补语", core.objectOrComplement, to: &coreLines)
        appendBullet("基本结构", core.structureSummaryZH, to: &coreLines)
        appendSection("句子主干", lines: coreLines, to: &lines)

        var clauseLines: [String] = []
        for clause in analysis.clauses.prefix(12) {
            let text = inline(clause.text)
            guard !text.isEmpty else { continue }
            clauseLines.append("- **\(clauseTitle(clause.type))**：\(text)")
            appendIndentedBullet("作用", clause.functionZH, to: &clauseLines)
            appendIndentedBullet("中文", clause.translationZH, to: &clauseLines)
        }
        appendSection("分句与修饰关系", lines: clauseLines, to: &lines)

        var grammarLines: [String] = []
        for point in analysis.grammarPoints.prefix(12) {
            let name = inline(point.grammarName)
            guard !name.isEmpty else { continue }
            grammarLines.append("- **\(name)**")
            appendIndentedBullet("原文", point.fragment, to: &grammarLines)
            appendIndentedBullet("说明", point.explanationZH, to: &grammarLines)
            appendIndentedBullet("句型", point.pattern, to: &grammarLines)
        }
        appendSection("重点语法", lines: grammarLines, to: &lines)

        var collocationLines: [String] = []
        for item in analysis.collocations.prefix(10) {
            let expression = inline(item.expression)
            let meaning = inline(item.meaningZH)
            guard !expression.isEmpty, !meaning.isEmpty else { continue }
            collocationLines.append("- **\(expression)**：\(meaning)")
            appendIndentedBullet("句型", item.pattern, to: &collocationLines)
            appendIndentedBullet("例句", item.exampleEN, to: &collocationLines)
            appendIndentedBullet("译文", item.exampleZH, to: &collocationLines)
        }
        appendSection("搭配与句型", lines: collocationLines, to: &lines)

        var difficultLines: [String] = []
        for item in analysis.difficultExpressions.prefix(10) {
            let expression = inline(item.expression)
            let meaning = inline(item.meaningZH)
            guard !expression.isEmpty, !meaning.isEmpty else { continue }
            difficultLines.append("- **\(expression)**：\(meaning)")
            appendIndentedBullet("用法", item.usageZH, to: &difficultLines)
        }
        appendSection("难点表达", lines: difficultLines, to: &lines)
        appendSection("简化改写", body: analysis.paraphraseEN, to: &lines)
        appendSection("学习提示", body: analysis.learningNoteZH, to: &lines)
        return lines.joined(separator: "\n")
    }

    private func glossaryMarkdownSection(_ glossary: LocalSentenceGlossary) -> String {
        var lines = ["### 本地词语参考", ""]
        for entry in glossary.entries.prefix(LocalSentenceGlossaryService.maximumEntries) {
            let term = inline(entry.displayTerm)
            guard !term.isEmpty else { continue }
            let definitions = entry.definitions.prefix(2).map(inline).filter { !$0.isEmpty }
            guard !definitions.isEmpty else { continue }
            lines.append("- **\(term)**：\(definitions.joined(separator: "；"))")
            let part = inline(entry.partOfSpeech)
            if !part.isEmpty { lines.append("  - 词性：\(part)") }
            let source = inline(entry.source)
            if !source.isEmpty { lines.append("  - 来源：\(source)") }
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func appendSection(_ title: String, body: String,
                               to lines: inout [String]) {
        let clean = inline(body)
        guard !clean.isEmpty else { return }
        lines += ["", "#### \(title)", "", clean]
    }

    private func appendSection(_ title: String, lines sectionLines: [String],
                               to lines: inout [String]) {
        guard !sectionLines.isEmpty else { return }
        lines += ["", "#### \(title)", ""] + sectionLines
    }

    private func appendBullet(_ title: String, _ value: String,
                              to lines: inout [String]) {
        let clean = inline(value)
        if !clean.isEmpty { lines.append("- \(title)：\(clean)") }
    }

    private func appendIndentedBullet(_ title: String, _ value: String,
                                      to lines: inout [String]) {
        let clean = inline(value)
        if !clean.isEmpty { lines.append("  - \(title)：\(clean)") }
    }

    private func clauseTitle(_ type: String) -> String {
        switch type {
        case "main": return "主句"
        case "subordinate": return "从句"
        case "relative": return "定语从句"
        case "participial": return "分词结构"
        default: return "其他成分"
        }
    }

    private func safeProviderName(_ value: String) -> String {
        let clean = inline(value)
        let lowercase = clean.lowercased()
        if clean.isEmpty || clean.contains("牛津") || lowercase.contains("oxford") {
            return "自定义 AI 服务"
        }
        return clean
    }

    private func inline(_ value: String) -> String {
        var escaped = SentenceTextNormalizer.normalize(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "[", "]", "<", ">", "#"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped
    }
}
