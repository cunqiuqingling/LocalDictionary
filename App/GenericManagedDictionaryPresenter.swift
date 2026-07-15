import AppKit

@MainActor
final class GenericManagedDictionaryPresenter {
    func attributedString(for hit: ManagedDictionaryQueryHit) -> NSAttributedString {
        let output = NSMutableAttributedString()
        append(hit.displayName + "\n", to: output,
               font: .systemFont(ofSize: 15, weight: .semibold), color: .systemBlue,
               spacingBefore: 0, spacingAfter: 7)
        append(hit.matchedHeadword + "\n", to: output,
               font: .systemFont(ofSize: 20, weight: .semibold), color: .labelColor,
               spacingBefore: 0, spacingAfter: 5)
        append("基础格式显示\n", to: output,
               font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
               spacingBefore: 0, spacingAfter: 9)
        for block in hit.blocks {
            append(block, to: output)
        }
        if hit.truncated {
            append("内容超过安全显示上限，已截断。\n", to: output,
                   font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
                   spacingBefore: 8, spacingAfter: 4)
        }
        return output
    }

    private func append(_ block: GenericMDictBlock, to output: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 7
        var baseFont = NSFont.systemFont(ofSize: 14)
        switch block.kind {
        case .heading:
            baseFont = .systemFont(ofSize: max(15, 19 - CGFloat(max(1, block.level))),
                                   weight: .semibold)
            paragraph.paragraphSpacingBefore = 7
            paragraph.paragraphSpacing = 5
        case .listItem:
            paragraph.headIndent = 16
            paragraph.firstLineHeadIndent = 4
        case .blockquote:
            paragraph.headIndent = 14
            paragraph.firstLineHeadIndent = 14
        case .preformatted:
            baseFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            paragraph.headIndent = 10
            paragraph.firstLineHeadIndent = 10
        case .paragraph:
            break
        }
        for run in block.runs {
            var font = run.code
                ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: run.bold ? .semibold : .regular)
                : baseFont
            if !run.code, run.bold {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if run.italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            output.append(NSAttributedString(string: run.text, attributes: [
                .font: font,
                .foregroundColor: block.kind == .blockquote
                    ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        if !output.string.hasSuffix("\n") {
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: baseFont, .paragraphStyle: paragraph
            ]))
        }
    }

    private func append(_ value: String, to output: NSMutableAttributedString,
                        font: NSFont, color: NSColor,
                        spacingBefore: CGFloat, spacingAfter: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        output.append(NSAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]))
    }
}
