import AppKit
import CoreGraphics

struct SelectionDisplayGeometry: Equatable, Sendable {
    let displayID: UInt32
    let appKitFrame: CGRect
    let visibleFrame: CGRect
    let accessibilityFrame: CGRect

    @MainActor
    static func liveScreens() -> [SelectionDisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = number.uint32Value
            return SelectionDisplayGeometry(
                displayID: displayID,
                appKitFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                accessibilityFrame: CGDisplayBounds(displayID)
            )
        }
    }
}

struct GlobalSelectionContext: Equatable, Sendable {
    let selectedText: String
    let selectionRects: [CGRect]
    let anchorRect: CGRect?
    let generation: UInt64
    let capturedAt: Date
    let preferredDisplayID: UInt32?
    let rightToLeft: Bool
    let sourceProcessIdentifier: Int32?

    func isFresh(now: Date = Date(), maximumAge: TimeInterval = 1.5) -> Bool {
        now.timeIntervalSince(capturedAt) >= 0 &&
            now.timeIntervalSince(capturedAt) <= maximumAge &&
            !selectedText.isEmpty
    }
}

enum AXSelectionCoordinateConverter {
    static func convert(_ accessibilityRects: [CGRect],
                        displays: [SelectionDisplayGeometry]) -> [CGRect] {
        accessibilityRects.compactMap { rect in
            guard valid(rect), let display = display(for: rect, displays: displays) else {
                return nil
            }
            return CGRect(
                x: display.appKitFrame.minX + rect.minX - display.accessibilityFrame.minX,
                y: display.appKitFrame.maxY -
                    (rect.maxY - display.accessibilityFrame.minY),
                width: rect.width,
                height: rect.height
            )
        }
    }

    static func preferredDisplayID(for accessibilityRects: [CGRect],
                                   displays: [SelectionDisplayGeometry]) -> UInt32? {
        accessibilityRects.compactMap { rect -> (UInt32, CGFloat)? in
            guard let display = display(for: rect, displays: displays) else { return nil }
            return (display.displayID, intersectionArea(rect, display.accessibilityFrame))
        }.max { $0.1 < $1.1 }?.0
    }

    private static func display(for rect: CGRect,
                                displays: [SelectionDisplayGeometry])
        -> SelectionDisplayGeometry? {
        displays.max {
            intersectionArea(rect, $0.accessibilityFrame) <
                intersectionArea(rect, $1.accessibilityFrame)
        }.flatMap {
            intersectionArea(rect, $0.accessibilityFrame) > 0 ? $0 : nil
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty &&
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}

@MainActor
protocol GlobalSelectionWindowHosting: AnyObject {
    var globalSelectionWindowSize: CGSize { get }
    func applyGlobalSelectionWindowFrame(_ frame: CGRect, generation: UInt64)
    func hideGlobalSelectionWindow()
}

@MainActor
final class GlobalSelectionPlacementController {
    private(set) var currentGeneration: UInt64 = 0
    private var currentContext: GlobalSelectionContext?

    @discardableResult
    func present(_ context: GlobalSelectionContext,
                 displays: [SelectionDisplayGeometry],
                 fallbackDisplayID: UInt32?,
                 additionalAvoidanceRects: [CGRect] = [],
                 host: any GlobalSelectionWindowHosting) -> Bool {
        guard context.generation >= currentGeneration else { return false }
        currentGeneration = context.generation
        currentContext = context
        guard context.isFresh(),
              let display = chooseDisplay(
                for: context, displays: displays, fallbackDisplayID: fallbackDisplayID
              ) else {
            host.hideGlobalSelectionWindow()
            return false
        }
        guard !context.selectionRects.isEmpty else {
            host.hideGlobalSelectionWindow()
            return false
        }
        let result = SelectionButtonPlacementEngine.place(
            SelectionButtonPlacementInput(
                selectionRects: context.selectionRects,
                anchorRect: context.anchorRect,
                buttonSize: host.globalSelectionWindowSize,
                visibleFrame: display.visibleFrame,
                rightToLeft: context.rightToLeft,
                additionalAvoidanceRects: additionalAvoidanceRects
            )
        )
        guard context.generation == currentGeneration, let result else {
            host.hideGlobalSelectionWindow()
            return false
        }
        host.applyGlobalSelectionWindowFrame(result.frame, generation: context.generation)
        return true
    }

    func invalidate(generation: UInt64, host: any GlobalSelectionWindowHosting) {
        guard generation >= currentGeneration else { return }
        currentGeneration = generation
        currentContext = nil
        host.hideGlobalSelectionWindow()
    }

    func selectedText(for generation: UInt64) -> String? {
        guard generation == currentGeneration,
              let currentContext,
              currentContext.generation == generation,
              currentContext.isFresh() else { return nil }
        return currentContext.selectedText
    }

    @discardableResult
    func refresh(_ context: GlobalSelectionContext) -> Bool {
        guard context.generation == currentGeneration,
              context.isFresh(),
              currentContext?.selectedText == context.selectedText else { return false }
        currentContext = context
        return true
    }

    private func chooseDisplay(for context: GlobalSelectionContext,
                               displays: [SelectionDisplayGeometry],
                               fallbackDisplayID: UInt32?)
        -> SelectionDisplayGeometry? {
        if let preferred = context.preferredDisplayID,
           let display = displays.first(where: { $0.displayID == preferred }) {
            return display
        }
        if let anchor = context.anchorRect,
           let display = displays.max(by: {
               intersectionArea(anchor, $0.appKitFrame) <
                   intersectionArea(anchor, $1.appKitFrame)
           }), intersectionArea(anchor, display.appKitFrame) > 0 {
            return display
        }
        if let fallbackDisplayID,
           let display = displays.first(where: { $0.displayID == fallbackDisplayID }) {
            return display
        }
        return displays.first
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

enum SelectionButtonPlacement: String, Equatable, Sendable {
    case below
    case above
    case right
    case left
    case selectionEnd
    case screenEdge
}

struct SelectionButtonPlacementInput: Equatable, Sendable {
    let selectionRects: [CGRect]
    let anchorRect: CGRect?
    let buttonSize: CGSize
    let visibleFrame: CGRect
    let gap: CGFloat
    let edgeInset: CGFloat
    let rightToLeft: Bool
    let additionalAvoidanceRects: [CGRect]

    init(selectionRects: [CGRect], anchorRect: CGRect? = nil,
         buttonSize: CGSize, visibleFrame: CGRect, gap: CGFloat = 8,
         edgeInset: CGFloat = 8, rightToLeft: Bool = false,
         additionalAvoidanceRects: [CGRect] = []) {
        self.selectionRects = selectionRects
        self.anchorRect = anchorRect
        self.buttonSize = buttonSize
        self.visibleFrame = visibleFrame
        self.gap = gap
        self.edgeInset = edgeInset
        self.rightToLeft = rightToLeft
        self.additionalAvoidanceRects = additionalAvoidanceRects
    }
}

struct SelectionButtonPlacementResult: Equatable, Sendable {
    let frame: CGRect
    let placement: SelectionButtonPlacement
    let anchorPoint: CGPoint
}

enum SelectionButtonPlacementEngine {
    static func place(_ input: SelectionButtonPlacementInput)
        -> SelectionButtonPlacementResult? {
        let selections = input.selectionRects.filter(valid)
        guard !selections.isEmpty, input.buttonSize.width > 0, input.buttonSize.height > 0,
              valid(input.visibleFrame) else { return nil }
        let allowed = input.visibleFrame.insetBy(dx: input.edgeInset, dy: input.edgeInset)
        guard allowed.width >= input.buttonSize.width,
              allowed.height >= input.buttonSize.height else { return nil }
        let bounds = selections.dropFirst().reduce(selections[0]) { $0.union($1) }
        let anchor = input.anchorRect.flatMap { valid($0) ? $0 : nil } ?? selections.last!
        let size = input.buttonSize
        let centeredX = min(max(bounds.midX - size.width / 2, allowed.minX),
                            allowed.maxX - size.width)
        let centeredY = min(max(bounds.midY - size.height / 2, allowed.minY),
                            allowed.maxY - size.height)
        let endX = input.rightToLeft
            ? anchor.minX - input.gap - size.width : anchor.maxX + input.gap
        let candidates: [(SelectionButtonPlacement, CGRect)] = [
            (.below, CGRect(x: centeredX, y: bounds.minY - input.gap - size.height,
                            width: size.width, height: size.height)),
            (.above, CGRect(x: centeredX, y: bounds.maxY + input.gap,
                            width: size.width, height: size.height)),
            (.right, CGRect(x: bounds.maxX + input.gap, y: centeredY,
                            width: size.width, height: size.height)),
            (.left, CGRect(x: bounds.minX - input.gap - size.width, y: centeredY,
                           width: size.width, height: size.height)),
            (.selectionEnd, CGRect(x: endX, y: anchor.midY - size.height / 2,
                                   width: size.width, height: size.height))
        ]
        for (placement, frame) in candidates where safe(
            frame, allowed: allowed, selections: selections,
            additional: input.additionalAvoidanceRects, gap: input.gap
        ) {
            return SelectionButtonPlacementResult(
                frame: frame, placement: placement,
                anchorPoint: CGPoint(x: anchor.midX, y: anchor.midY)
            )
        }

        // Deterministic perimeter scan. This remains on the current screen's visibleFrame,
        // so menu bar and Dock are excluded without screen capture or pixel inspection.
        let step = max(2, min(size.width, size.height) / 4)
        for frame in edgeFrames(allowed: allowed, size: size, step: step)
        where safe(frame, allowed: allowed, selections: selections,
                   additional: input.additionalAvoidanceRects, gap: input.gap) {
            return SelectionButtonPlacementResult(
                frame: frame, placement: .screenEdge,
                anchorPoint: CGPoint(x: anchor.midX, y: anchor.midY)
            )
        }
        // If a known selection covers every safe point, hiding is the only non-overlapping
        // behavior. Overlap is never used as a fallback.
        return nil
    }

    private static func safe(_ frame: CGRect, allowed: CGRect,
                             selections: [CGRect], additional: [CGRect],
                             gap: CGFloat) -> Bool {
        guard allowed.contains(frame) else { return false }
        let expandedSelections = selections.map { $0.insetBy(dx: -gap, dy: -gap) }
        return !expandedSelections.contains(where: frame.intersects) &&
            !additional.filter(valid).contains(where: frame.intersects)
    }

    private static func edgeFrames(allowed: CGRect, size: CGSize,
                                   step: CGFloat) -> [CGRect] {
        var values: [CGRect] = []
        var x = allowed.minX
        while x <= allowed.maxX - size.width {
            values.append(CGRect(x: x, y: allowed.minY, width: size.width, height: size.height))
            values.append(CGRect(x: x, y: allowed.maxY - size.height,
                                 width: size.width, height: size.height))
            x += step
        }
        var y = allowed.minY + step
        while y <= allowed.maxY - size.height - step {
            values.append(CGRect(x: allowed.minX, y: y,
                                 width: size.width, height: size.height))
            values.append(CGRect(x: allowed.maxX - size.width, y: y,
                                 width: size.width, height: size.height))
            y += step
        }
        return values
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty &&
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}
