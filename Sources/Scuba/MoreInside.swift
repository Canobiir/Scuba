import AppKit

/// A tile holding a space with more in it than you can see from here (a
/// window hidden from above, breathing room folded away) gets a small dark
/// ball with the hidden app's icon, a hint that stepping in again shows it.
/// It sits at the right end of the tile's tab strip; a tile without tabs
/// has it in the same place, along its top. Click it to step in.
struct MoreInside {
    let rect: CGRect      // the tile (AppKit screen coordinates)
    let panel: UUID
    let icons: [NSImage?]
    let count: Int
}

/// The ball itself, for a strip or on its own.
enum MoreBall {
    static let size: CGFloat = 22

    static func draw(in r: CGRect, icon: NSImage?, count: Int, hovered: Bool) {
        let ball = NSBezierPath(ovalIn: r)
        NSColor(white: 0.03, alpha: hovered ? 0.96 : 0.9).setFill()
        ball.fill()
        NSColor(white: 1, alpha: hovered ? 0.45 : 0.22).setStroke()
        ball.lineWidth = 1
        ball.stroke()
        let s = r.width * 0.62
        icon?.draw(in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s))
        guard count > 1 else { return }
        // More than one hidden: a tiny count on its corner.
        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let t = text.size()
        let badge = CGRect(x: r.maxX - t.width - 3, y: r.minY - 2, width: t.width + 5, height: 11)
        NSColor(white: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5.5, yRadius: 5.5).fill()
        text.draw(at: CGPoint(x: badge.minX + 2.5, y: badge.minY + 0.5))
    }
}

/// Balls for tiles with no tab strip of their own.
@MainActor
final class MoreInsideHints {
    private var windows: [UUID: NSWindow] = [:]
    var onOpen: ((UUID) -> Void)?

    /// Where a tile's ball goes without a strip: its top right, where the
    /// strip's end would be.
    static func spot(in tile: CGRect) -> CGRect {
        CGRect(x: tile.maxX - 6 - MoreBall.size, y: tile.maxY - 4 - MoreBall.size,
               width: MoreBall.size, height: MoreBall.size)
    }

    func show(_ hints: [MoreInside]) {
        var keep = Set<UUID>()
        for h in hints {
            keep.insert(h.panel)
            let frame = Self.spot(in: h.rect).insetBy(dx: -3, dy: -3)
            let w = windows[h.panel] ?? make()
            windows[h.panel] = w
            let view = (w.contentView as? BallView) ?? BallView(frame: .zero)
            view.icon = h.icons.first ?? nil
            view.count = h.count
            view.panel = h.panel
            view.onOpen = { [weak self] p in self?.onOpen?(p) }
            if w.contentView !== view { w.contentView = view }
            w.setFrame(frame, display: true)
            view.frame = CGRect(origin: .zero, size: frame.size)
            view.needsDisplay = true
            if !w.isVisible { w.orderFront(nil) }
        }
        for (id, w) in windows where !keep.contains(id) {
            w.orderOut(nil)
            windows[id] = nil
        }
    }

    func hide() {
        for w in windows.values { w.orderOut(nil) }
        windows.removeAll()
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        // On top of the tile's window (it sits over its top edge).
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return w
    }
}

private final class BallView: NSView {
    var icon: NSImage?
    var count = 1
    var panel: UUID?
    var onOpen: ((UUID) -> Void)?
    private var hovered = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if let panel { onOpen?(panel) } }

    override func draw(_ dirtyRect: NSRect) {
        MoreBall.draw(in: bounds.insetBy(dx: 3, dy: 3), icon: icon, count: count, hovered: hovered)
    }
}
