import AppKit

final class LocalSentenceGlossaryFormatter {
    func format(_ glossary: LocalSentenceGlossary) -> NSAttributedString {
        let output = NSMutableAttributedString()
        append("本地词语参考\n", font: .systemFont(ofSize: 15, weight: .semibold),
               color: .labelColor, spacingBefore: 10, spacingAfter: 5, to: output)
        append("当前处于离线模式或 AI 服务不可用。\n以下内容来自本地词典，仅提供重点词语对照，不代表完整句子翻译。\n",
               font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor,
               spacingAfter: 9, to: output)
        guard glossary.hasEntries else {
            append("本地词典未识别出可用的重点词语。\n",
                   font: .systemFont(ofSize: 13), color: .secondaryLabelColor,
                   spacingAfter: 5, to: output)
            return output
        }
        for entry in glossary.entries {
            append("• \(entry.displayTerm)\n", font: .systemFont(ofSize: 13.5, weight: .semibold),
                   color: .labelColor, headIndent: 14, spacingBefore: 3,
                   spacingAfter: 1, to: output)
            if !entry.partOfSpeech.isEmpty {
                append(entry.partOfSpeech + "\n", font: .systemFont(ofSize: 11.5),
                       color: .secondaryLabelColor, firstLineIndent: 16, headIndent: 16,
                       spacingAfter: 1, to: output)
            }
            for definition in entry.definitions {
                append(definition + "\n", font: .systemFont(ofSize: 12.5),
                       color: .labelColor, firstLineIndent: 16, headIndent: 16,
                       spacingAfter: 1, to: output)
            }
            append("来源：\(entry.source)\n", font: .systemFont(ofSize: 11),
                   color: .secondaryLabelColor, firstLineIndent: 16, headIndent: 16,
                   spacingAfter: 4, to: output)
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
}
