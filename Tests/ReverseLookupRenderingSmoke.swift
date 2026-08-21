import AppKit
import Foundation

private enum RenderingSmokeError: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool,
                    _ message: String) throws {
    if !condition() { throw RenderingSmokeError.failed(message) }
}

private func relativeLuminance(_ color: NSColor) -> CGFloat? {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
    func component(_ value: CGFloat) -> CGFloat {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * component(rgb.redComponent) +
        0.7152 * component(rgb.greenComponent) +
        0.0722 * component(rgb.blueComponent)
}

private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat? {
    guard let first = relativeLuminance(foreground),
          let second = relativeLuminance(background) else { return nil }
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

@main
private enum ReverseLookupRenderingSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let results = [
            ReverseLookupResult(
                headword: "apple", definitionSnippet: "a round fruit",
                dictionaryID: "one", dictionaryName: "Synthetic One",
                matchReason: "释义匹配", confidence: .high, score: 100
            ),
            ReverseLookupResult(
                headword: "à la mode", definitionSnippet: "in a fashionable manner",
                dictionaryID: "two", dictionaryName: "Synthetic Two",
                matchReason: "候选匹配", confidence: .medium, score: 80
            )
        ]

        for query in ["苹果", "蘋果"] {
            let output = ReverseLookupResultFormatter.attributedResults(results, query: query)
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                guard let appearance = NSAppearance(named: appearanceName) else {
                    throw RenderingSmokeError.failed("appearance unavailable")
                }
                var capturedError: Error?
                appearance.performAsCurrentDrawingAppearance {
                    do {
                        let textView = NSTextView(
                            frame: NSRect(x: 0, y: 0, width: 520, height: 320)
                        )
                        textView.appearance = appearance
                        textView.drawsBackground = true
                        textView.backgroundColor = .textBackgroundColor
                        textView.textStorage?.setAttributedString(output)
                        textView.layoutManager?.ensureLayout(
                            for: textView.textContainer ?? NSTextContainer()
                        )

                        let bitmap = textView.bitmapImageRepForCachingDisplay(
                            in: textView.bounds
                        )
                        try expect(bitmap != nil,
                                   "text view did not produce a rendered bitmap")
                        if let bitmap {
                            textView.cacheDisplay(in: textView.bounds, to: bitmap)
                            try expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0,
                                       "rendered bitmap is empty")
                        }

                        for marker in [query, "apple", "a round fruit", "来源：",
                                       "置信度", "à la mode"] {
                            let range = (output.string as NSString).range(of: marker)
                            try expect(range.location != NSNotFound,
                                       "missing rendered marker \(marker)")
                            guard let color = output.attribute(
                                .foregroundColor, at: range.location, effectiveRange: nil
                            ) as? NSColor,
                                  let ratio = contrast(color, textView.backgroundColor) else {
                                throw RenderingSmokeError.failed(
                                    "marker \(marker) has no resolvable dynamic foreground color"
                                )
                            }
                            try expect(ratio >= 4.5,
                                       "marker \(marker) contrast \(ratio) is too low in " +
                                       appearanceName.rawValue)
                            let glyphRange = textView.layoutManager?.glyphRange(
                                forCharacterRange: range, actualCharacterRange: nil
                            ) ?? NSRange(location: 0, length: 0)
                            try expect(glyphRange.length > 0,
                                       "marker \(marker) did not reach AppKit glyph layout")
                        }
                    } catch {
                        capturedError = error
                    }
                }
                if let capturedError { throw capturedError }
            }
        }
        print("Reverse lookup Aqua/DarkAqua rendering smoke: PASS")
    }
}
