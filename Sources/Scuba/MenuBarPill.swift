import AppKit

/// Scuba's menu bar item: one rounded pill of small buttons, like TrellisWM's.
///
///   ‹  ›  │  desktop  everything  │  Scuba menu
///
/// Each button lights up under the pointer and dims when there's nothing to
/// do (no history to go back to, say). The Scuba glyph opens the full menu,
/// and so does a right-click anywhere on the pill.
@MainActor
final class MenuBarPill: NSView {
    struct Segment {
        let id: String
        let symbol: String
        let tip: String
        var enabled = true
        var on = false          // drawn as selected (e.g. you're on your desktop)
        var width: CGFloat = 26
    }

    var segments: [Segment] = [] { didSet { relayout() } }
    var onClick: ((String) -> Void)?
    var onMenu: (() -> Void)?

    private var rects: [String: NSRect] = [:]
    private var dividers: [CGFloat] = []
    private var hovered: String?
    private var pressed: String?
    private var tracking: NSTrackingArea?

    static let inset: CGFloat = 4       // room either side of the pill
    static let gap: CGFloat = 7         // the space a divider takes

    /// The width the status item needs for these segments.
    static func width(for segments: [Segment]) -> CGFloat {
        var w = inset * 2 + 4
        var last: String?
        for s in segments {
            if let last, group(last) != group(s.id) { w += gap }
            w += s.width
            last = s.id
        }
        return ceil(w)
    }

    /// Buttons in the same group sit together; a hairline separates groups.
    private static func group(_ id: String) -> Int {
        switch id {
        case "back", "forward": return 0
        case "menu": return 2
        default: return 1
        }
    }

    private func relayout() {
        rects.removeAll()
        dividers.removeAll()
        removeAllToolTips()
        var x = Self.inset + 2
        var last: String?
        for s in segments {
            if let last, Self.group(last) != Self.group(s.id) {
                dividers.append(x + Self.gap / 2)
                x += Self.gap
            }
            let r = NSRect(x: x, y: 0, width: s.width, height: bounds.height)
            rects[s.id] = r
            _ = addToolTip(r, owner: s.tip as NSString, userData: nil)
            x += s.width
            last = s.id
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    // MARK: Drawing

    private var pillRect: NSRect {
        let h = min(bounds.height - 2, 22)
        return NSRect(x: Self.inset, y: (bounds.height - h) / 2, width: bounds.width - Self.inset * 2, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The menu bar's own appearance (light or dark over the wallpaper).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let pill = pillRect
            let ink = NSColor.labelColor
            ink.withAlphaComponent(0.11).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()

            for x in dividers {
                ink.withAlphaComponent(0.18).setFill()
                NSRect(x: round(x), y: pill.minY + 5, width: 1, height: pill.height - 10).fill()
            }

            for s in segments {
                guard let r = rects[s.id] else { continue }
                let cell = NSRect(x: r.minX + 1, y: pill.minY + 2, width: r.width - 2, height: pill.height - 4)
                let lit = s.enabled && (pressed == s.id || (hovered == s.id && pressed == nil))
                if s.on || lit {
                    let a: CGFloat = pressed == s.id ? 0.26 : (s.on ? 0.2 : 0.13)
                    ink.withAlphaComponent(a).setFill()
                    NSBezierPath(roundedRect: cell, xRadius: 5, yRadius: 5).fill()
                }
                drawSymbol(s, in: cell, colour: s.enabled ? ink : ink.withAlphaComponent(0.3))
            }
        }
    }

    private func drawSymbol(_ s: Segment, in cell: NSRect, colour: NSColor) {
        let size: CGFloat = (s.id == "back" || s.id == "forward") ? 12 : 13
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let base = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.tip)?
            .withSymbolConfiguration(config) else { return }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let r = NSRect(x: round(cell.midX - base.size.width / 2), y: round(cell.midY - base.size.height / 2),
                       width: base.size.width, height: base.size.height)
        tinted.draw(in: r)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func segment(at event: NSEvent) -> String? {
        let p = convert(event.locationInWindow, from: nil)
        return rects.first { $0.value.contains(p) }?.key
    }

    private func setHovered(_ id: String?) {
        guard id != hovered else { return }
        hovered = id
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { setHovered(segment(at: event)) }
    override func mouseEntered(with event: NSEvent) { setHovered(segment(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    override func mouseDown(with event: NSEvent) {
        guard let id = segment(at: event), segments.first(where: { $0.id == id })?.enabled == true else { return }
        if id == "menu" { pressed = nil; hovered = nil; needsDisplay = true; onMenu?(); return }
        pressed = id
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let id = pressed else { return }
        pressed = nil
        needsDisplay = true
        if segment(at: event) == id { onClick?(id) }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?() }

    // Clicks belong to the pill, not the button underneath it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
