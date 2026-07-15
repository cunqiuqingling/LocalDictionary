import AppKit

final class AIEntryFormatter {
    func format(_ presentation: AIExplanationPresentation) -> NSAttributedString {
        let output = NSMutableAttributedString()
        append("AI 双语解释\n", font: .systemFont(ofSize: 15, weight: .semibold),
               color: .systemPurple, spacingBefore: 6, spacingAfter: 2, to: output)
        append("由 \(presentation.providerDisplayName) · \(presentation.model) 生成\n",
               font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
               spacingAfter: 12, to: output)
        let explanation = presentation.explanation
        append(explanation.headword + "\n", font: .systemFont(ofSize: 21, weight: .semibold),
               color: .labelColor, spacingAfter: 3, to: output)
        if !explanation.pronunciations.isEmpty {
            append(explanation.pronunciations.joined(separator: "  ") + "\n",
                   font: .systemFont(ofSize: 14), color: .secondaryLabelColor,
                   spacingAfter: 8, to: output)
        }
        if !explanation.domain.isEmpty {
            append("领域：\(explanation.domain)\n", font: .systemFont(ofSize: 12),
                   color: .secondaryLabelColor, spacingAfter: 8, to: output)
        }
        for part in explanation.partsOfSpeech {
            if !part.partOfSpeech.isEmpty {
                append(part.partOfSpeech + "\n", font: .systemFont(ofSize: 16, weight: .semibold),
                       color: .labelColor, spacingBefore: 8, spacingAfter: 5, to: output)
            }
            for (index, sense) in part.senses.enumerated() {
                if !sense.definitionEN.isEmpty {
                    append("\(index + 1). \(sense.definitionEN)\n",
                           font: .systemFont(ofSize: 14), color: .labelColor,
                           firstLineIndent: 0, headIndent: 18, spacingAfter: 2, to: output)
                }
                if !sense.definitionZH.isEmpty {
                    append(sense.definitionZH + "\n", font: .systemFont(ofSize: 14, weight: .medium),
                           color: .labelColor, firstLineIndent: 18, headIndent: 18,
                           spacingAfter: 2, to: output)
                }
                if !sense.usageNoteZH.isEmpty {
                    append(sense.usageNoteZH + "\n", font: .systemFont(ofSize: 12),
                           color: .secondaryLabelColor, firstLineIndent: 18, headIndent: 18,
                           spacingAfter: 4, to: output)
                }
                for example in sense.examples {
                    if !example.en.isEmpty {
                        append(example.en + "\n", font: italicFont(ofSize: 13),
                               color: .secondaryLabelColor, firstLineIndent: 26, headIndent: 26,
                               spacingAfter: 1, to: output)
                    }
                    if !example.zh.isEmpty {
                        append(example.zh + "\n", font: .systemFont(ofSize: 13),
                               color: .secondaryLabelColor, firstLineIndent: 26, headIndent: 26,
                               spacingAfter: 3, to: output)
                    }
                }
                if !sense.collocations.isEmpty {
                    append("常见搭配：" + sense.collocations.joined(separator: "；") + "\n",
                           font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                           firstLineIndent: 18, headIndent: 18, spacingAfter: 5, to: output)
                }
            }
        }
        if !explanation.spellingSuggestions.isEmpty {
            append("拼写建议\n", font: .systemFont(ofSize: 13, weight: .semibold),
                   color: .secondaryLabelColor, spacingBefore: 8, spacingAfter: 3,
                   to: output)
            append(explanation.spellingSuggestions.joined(separator: "、") + "\n",
                   font: .systemFont(ofSize: 13), color: .secondaryLabelColor,
                   firstLineIndent: 18, headIndent: 18, spacingAfter: 4, to: output)
        }
        if !explanation.caution.isEmpty {
            append("注意：\(explanation.caution)\n", font: .systemFont(ofSize: 12),
                   color: .secondaryLabelColor, spacingBefore: 8, spacingAfter: 3, to: output)
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
