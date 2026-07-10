import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Public API
//
// CaretLocator resolves where the dictation indicator should appear.
//
// Integration (later pass — do not wire from App.swift here):
//   let anchor = CaretLocator().caretAnchor()
//   // or: CaretLocator.caretAnchor()
//   indicatorPanel.show(at: anchor)
//
// Requires Accessibility trust (`AXIsProcessTrusted()`). Without it the
// locator still returns a mouse-pointer anchor so the indicator can appear.
//
// Coordinate space: `CaretAnchor.rect` is always in **AppKit screen
// coordinates** (origin bottom-left of the primary display, Y up).

/// Which step of the caret fallback chain produced an anchor.
enum CaretFallbackLevel: Int, Sendable, Equatable, CustomStringConvertible {
    /// Precise insertion-point bounds via `kAXBoundsForRangeParameterizedAttribute`.
    case caret = 0
    /// Focused UI element's frame; indicator anchors at the field's bottom-left.
    case focusedField = 1
    /// `NSEvent.mouseLocation` when AX caret/field bounds are unavailable or bogus.
    case mouse = 2

    var description: String {
        switch self {
        case .caret: return "caret"
        case .focusedField: return "focusedField"
        case .mouse: return "mouse"
        }
    }
}

/// Screen-space rect plus the fallback level that produced it.
struct CaretAnchor: Sendable, Equatable {
    /// AppKit screen coordinates (Y-up). For `.caret` this is the caret/selection
    /// bounds (collapsed carets get a nominal height). For `.focusedField` this is
    /// a point-sized rect at the field's bottom-left. For `.mouse` a 1×1 rect at
    /// the pointer.
    var rect: CGRect
    var level: CaretFallbackLevel
}

/// Resolves the text caret (or a sensible fallback) via the Accessibility API.
///
/// Fallback chain (CursorBounds-style, vendored approach — no dependency):
/// 1. systemwide → focused element → selected text range → bounds-for-range
///    (rejects zero-size origin carets — Terminal.app often returns these)
/// 2. focused element's position + size (anchor at bottom-left of field),
///    skipped when AXValue is unsettable or the frame is VTE/window-sized
/// 3. mouse pointer location
///
/// Bogus Electron/web rects (off-screen or larger than the containing screen)
/// are rejected and the next level is tried. Terminals without caret bounds
/// fall through to mouse so the pill tracks the pointer instead of a corner.
struct CaretLocator: Sendable {
    /// Nominal height applied to collapsed (zero-size) caret rects so the
    /// indicator has something to sit next to.
    static let nominalCaretHeight: CGFloat = 16
    static let nominalCaretWidth: CGFloat = 2

    /// Instance entry point — identical to the static helper.
    func caretAnchor() -> CaretAnchor {
        Self.caretAnchor()
    }

    /// Resolves the best available caret anchor.
    static func caretAnchor() -> CaretAnchor {
        if let focused = focusedUIElement() {
            if let caret = caretBounds(of: focused),
               isPlausible(caret),
               isNonDegenerateCaret(caret)
            {
                return CaretAnchor(rect: normalizeCaretRect(caret), level: .caret)
            }
            // Skip static field bottoms (VTE / whole-window focus): mouse tracks better.
            if shouldUseFocusedField(of: focused),
               let field = focusedFieldAnchor(of: focused),
               isPlausible(field)
            {
                return CaretAnchor(rect: field, level: .focusedField)
            }
        }
        return mouseAnchor()
    }
}

// MARK: - AX focused element

private extension CaretLocator {
    static func focusedUIElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        // Prefer the focused UI element on the systemwide element directly.
        if let focused = copyElement(systemWide, attribute: kAXFocusedUIElementAttribute) {
            return focused
        }

        // Some apps only expose focus via the focused application.
        guard let app = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute) else {
            return nil
        }
        return copyElement(app, attribute: kAXFocusedUIElementAttribute)
    }

    static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

// MARK: - (a) Caret bounds

private extension CaretLocator {
    static func caretBounds(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )
        guard rangeStatus == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }

        let axRange = unsafeDowncast(rangeRef, to: AXValue.self)
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange, .cfRange, &cfRange) else { return nil }

        if let rect = boundsForRange(element, location: cfRange.location, length: max(cfRange.length, 0)) {
            return axToAppKit(rect)
        }

        // Collapsed caret sometimes fails with length 0; probe the next character.
        if cfRange.length == 0,
           let rect = boundsForRange(element, location: cfRange.location, length: 1)
        {
            return axToAppKit(rect)
        }

        return nil
    }

    static func boundsForRange(_ element: AXUIElement, location: CFIndex, length: CFIndex) -> CGRect? {
        var cfRange = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &boundsRef
        )
        guard status == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }

        let axBounds = unsafeDowncast(boundsRef, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Ensures collapsed carets have a usable size for panel placement.
    static func normalizeCaretRect(_ rect: CGRect) -> CGRect {
        var result = rect
        if result.height < 1 {
            result.size.height = nominalCaretHeight
        }
        if result.width < 1 {
            result.size.width = nominalCaretWidth
        }
        return result
    }

    /// Terminal.app often returns a zero-size rect at the origin that still passes
    /// `isPlausible`; real collapsed carets expose a non-zero height (or width).
    static func isNonDegenerateCaret(_ rect: CGRect) -> Bool {
        rect.width >= 1 || rect.height >= 1
    }
}

// MARK: - (b) Focused field bounds

private extension CaretLocator {
    /// Returns a point-sized AppKit rect at the **bottom-left** of the focused field.
    static func focusedFieldAnchor(of element: AXUIElement) -> CGRect? {
        guard let axFrame = elementFrameAX(of: element) else { return nil }
        let appKit = axToAppKit(axFrame)
        guard appKit.width > 0, appKit.height > 0 else { return nil }
        // Bottom-left of the field in AppKit coords (minX, minY).
        return CGRect(
            x: appKit.minX,
            y: appKit.minY,
            width: nominalCaretWidth,
            height: min(appKit.height, nominalCaretHeight)
        )
    }

    /// Whether the focused element's frame is a useful indicator anchor.
    ///
    /// Terminal VTEs (Ghostty, Terminal.app, …) expose a large unsettable
    /// `AXTextArea` without caret bounds — anchoring at that field's bottom-left
    /// sticks the pill in a corner. Prefer the mouse in those cases. Also skip
    /// oversized frames (whole window / full VTE) even when settable is unknown.
    static func shouldUseFocusedField(of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           !settable.boolValue
        {
            return false
        }

        guard let axFrame = elementFrameAX(of: element) else { return true }
        let appKit = axToAppKit(axFrame)
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.insetBy(dx: -2, dy: -2).intersects(appKit)
        }) else {
            return true
        }

        let screenArea = max(screen.frame.width * screen.frame.height, 1)
        let areaRatio = (appKit.width * appKit.height) / screenArea
        if areaRatio > 0.45 || appKit.height > screen.frame.height * 0.55 {
            return false
        }
        return true
    }

    static func elementFrameAX(of element: AXUIElement) -> CGRect? {
        // Prefer AXFrame when present.
        var frameRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success,
           let frameRef,
           CFGetTypeID(frameRef) == AXValueGetTypeID()
        {
            let axFrame = unsafeDowncast(frameRef, to: AXValue.self)
            var rect = CGRect.zero
            if AXValueGetValue(axFrame, .cgRect, &rect) {
                return rect
            }
        }

        var positionRef: CFTypeRef?
        let posStatus = AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionRef
        )
        guard posStatus == .success,
              let positionRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID()
        else { return nil }

        let axPos = unsafeDowncast(positionRef, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetType(axPos) == .cgPoint,
              AXValueGetValue(axPos, .cgPoint, &point)
        else { return nil }

        var sizeRef: CFTypeRef?
        let sizeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeRef
        )
        guard sizeStatus == .success,
              let sizeRef,
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        let axSize = unsafeDowncast(sizeRef, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetType(axSize) == .cgSize,
              AXValueGetValue(axSize, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }

        return CGRect(origin: point, size: size)
    }
}

// MARK: - (c) Mouse fallback

private extension CaretLocator {
    static func mouseAnchor() -> CaretAnchor {
        let point = NSEvent.mouseLocation
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        return CaretAnchor(rect: rect, level: .mouse)
    }
}

// MARK: - Coordinate conversion & plausibility

private extension CaretLocator {
    /// AX/Quartz global display coords (Y-down from top of main display) → AppKit (Y-up).
    static func axToAppKit(_ axRect: CGRect) -> CGRect {
        guard let referenceMaxY = mainDisplayMaxY() else { return axRect }

        let converted = convertAXRect(axRect, referenceMaxY: referenceMaxY)
        if intersectsAnyScreen(converted) {
            return converted
        }

        // Multi-display edge case: retry against the global desktop top edge.
        let desktopMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? referenceMaxY
        return convertAXRect(axRect, referenceMaxY: desktopMaxY)
    }

    static func convertAXRect(_ axRect: CGRect, referenceMaxY: CGFloat) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: referenceMaxY - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    static func mainDisplayMaxY() -> CGFloat? {
        let mainID = CGMainDisplayID()
        if let main = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == mainID
        }) {
            return main.frame.maxY
        }
        return NSScreen.screens.first?.frame.maxY
    }

    static func intersectsAnyScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).intersects(rect) }
    }

    /// Rejects Electron/web bogus bounds: entirely off-screen, or larger than the
    /// containing screen (common when AX returns the whole window/web view).
    static func isPlausible(_ appKitRect: CGRect) -> Bool {
        guard appKitRect.width.isFinite, appKitRect.height.isFinite,
              appKitRect.origin.x.isFinite, appKitRect.origin.y.isFinite
        else { return false }

        // Zero-size caret rects are OK (normalized later); reject only NaN/inf above.
        let probe = appKitRect.width < 1 && appKitRect.height < 1
            ? CGRect(x: appKitRect.minX, y: appKitRect.minY, width: 1, height: 1)
            : appKitRect

        guard let screen = NSScreen.screens.first(where: {
            $0.frame.insetBy(dx: -2, dy: -2).intersects(probe)
        }) ?? NSScreen.screens.first(where: {
            $0.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: probe.midX, y: probe.midY))
        }) else {
            return false
        }

        // Size larger than the screen ⇒ almost certainly a bogus web/Electron frame.
        if appKitRect.width > screen.frame.width + 1 || appKitRect.height > screen.frame.height + 1 {
            return false
        }

        return true
    }
}
