import Foundation

final class AIExplanationMarkdownFormatter {
    func section(for presentation: AIExplanationPresentation,
                 headword: String? = nil) -> AIExplanationNoteSection {
        let explanation = presentation.explanation
        let provider = safeProviderName(presentation.providerDisplayName)
        let model = inline(presentation.model)
        var lines = [
            "### AI 双语解释",
            "",
            "> 由 \(provider) · \(model) 生成"
        ]
        let pronunciations = explanation.pronunciations.prefix(4)
            .map(inline).filter { !$0.isEmpty }
        if !pronunciations.isEmpty {
            lines += ["", "- 音标：\(pronunciations.joined(separator: "；"))"]
        }
        let domain = inline(explanation.domain)
        if !domain.isEmpty { lines.append("- 领域：\(domain)") }

        for part in explanation.partsOfSpeech.prefix(8) {
            let partOfSpeech = inline(part.partOfSpeech)
            if !partOfSpeech.isEmpty {
                lines += ["", "#### \(partOfSpeech)", ""]
            }
            for (index, sense) in part.senses.prefix(6).enumerated() {
                let english = inline(sense.definitionEN)
                let chinese = inline(sense.definitionZH)
                guard !english.isEmpty || !chinese.isEmpty else { continue }
                if !english.isEmpty {
                    lines.append("\(index + 1). **\(english)**")
                } else {
                    lines.append("\(index + 1). \(chinese)")
                }
                if !chinese.isEmpty, !english.isEmpty {
                    lines.append("   - 中文释义：\(chinese)")
                }
                let usage = inline(sense.usageNoteZH)
                if !usage.isEmpty { lines.append("   - 用法说明：\(usage)") }
                for example in sense.examples.prefix(2) {
                    let englishExample = inline(example.en)
                    let chineseExample = inline(example.zh)
                    if !englishExample.isEmpty {
                        lines.append("   - 例句：\(englishExample)")
                    }
                    if !chineseExample.isEmpty {
                        lines.append("   - 译文：\(chineseExample)")
                    }
                }
                let collocations = sense.collocations.prefix(8)
                    .map(inline).filter { !$0.isEmpty }
                if !collocations.isEmpty {
                    lines.append("   - 常见搭配：\(collocations.joined(separator: "；"))")
                }
            }
        }
        let caution = inline(explanation.caution)
        if !caution.isEmpty { lines += ["", "- 注意：\(caution)"] }
        let savedHeadword = headword?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIExplanationNoteSection(headword: savedHeadword?.isEmpty == false
                                            ? savedHeadword! : explanation.headword,
                                        markdown: lines.joined(separator: "\n"))
    }

    private func safeProviderName(_ value: String) -> String {
        let cleaned = inline(value)
        let lowercase = cleaned.lowercased()
        if cleaned.isEmpty || cleaned.contains("牛津") || lowercase.contains("oxford") {
            return "自定义 AI 服务"
        }
        return cleaned
    }

    private func inline(_ value: String) -> String {
        let cleaned = value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var escaped = cleaned.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "[", "]", "<", ">", "#"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped
    }
}
