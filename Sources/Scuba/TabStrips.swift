import AppKit

/// The strip of tabs along the top of a tabbed tile.
struct TabStrip {
    struct Tab {
        let window: UInt32
        let name: String
        let icon: NSImage?
    }
    var rect: CGRect          // AppKit screen coordinates
    let panel: UUID
    let tabs: [Tab]
    let front: UInt32
    /// More inside the tile this strip tops: the ball at its right end.
    var more: MoreInside? = nil
}

/// One small window per tabbed tile, sitting in the space above the window
/// in front (below every app window, like the crowd tiles). Click a tab to
/// bring it to the front; drag it down out of the strip to give it a tile
/// of its own (a middle click does the same).
@MainActor
final class TabStrips {
    private var windows: [UUID: NSWindow] = [:]
    /// While a resize plays as pictures, strips sit above the pictures.
    var lifted = false {
        didSet { for w in windows.values { w.level = level } }
    }
    private var level: NSWindow.Level {
        lifted ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
               : NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    }
    var onSelect: ((UUID, UInt32) -> Void)?
    var onPopOut: ((UUID, UInt32) -> Void)?
    /// A tab swiped sideways with two fingers: out to that side (true: left / above).
    var onSwipeOut: ((UUID, UInt32, Bool) -> Void)?
    var onClose: ((UUID, UInt32) -> Void)?
    /// The ball, clicked: the tile it's on, to step into.
    var onMore: ((UUID) -> Void)?

    func show(_ strips: [TabStrip]) {
        var keep = Set<UUID>()
        for s in strips {
            keep.insert(s.panel)
            let w = windows[s.panel] ?? make()
            windows[s.panel] = w
            let view = (w.contentView as? TabStripView) ?? TabStripView(frame: .zero)
            view.strip = s
            view.onSelect = { [weak self] p, x in self?.onSelect?(p, x) }
            view.onPopOut = { [weak self] p, x in self?.onPopOut?(p, x) }
            view.onClose = { [weak self] p, x in self?.onClose?(p, x) }
            view.onMore = { [weak self] p in self?.onMore?(p) }
            view.onSwipeOut = { [weak self] p, x, b in self?.onSwipeOut?(p, x, b) }
            if w.contentView !== view { w.contentView = view }
            w.setFrame(s.rect, display: false)
            view.frame = CGRect(origin: .zero, size: s.rect.size)
            view.needsDisplay = true
            if w.alphaValue < 1 || !w.isVisible {
                w.alphaValue = 0
                w.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.fade
                    w.animator().alphaValue = 1
                }
            }
        }
        for (id, w) in windows where !keep.contains(id) {
            w.orderOut(nil)
            windows[id] = nil
        }
    }

    /// Moves one tile's strip (to follow its window while you resize it).
    func move(panel: UUID, to rect: CGRect) {
        guard let w = windows[panel] else { return }
        w.setFrame(rect, display: true)
        w.contentView?.frame = CGRect(origin: .zero, size: rect.size)
        w.contentView?.needsDisplay = true
    }

    func hide() {
        for w in windows.values { w.orderOut(nil) }
        windows.removeAll()
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.level = level
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return w
    }
}

private final class TabStripView: NSView {
    var strip: TabStrip? { didSet { needsDisplay = true } }
    var onSelect: ((UUID, UInt32) -> Void)?
    var onPopOut: ((UUID, UInt32) -> Void)?
    var onClose: ((UUID, UInt32) -> Void)?
    var onSwipeOut: ((UUID, UInt32, Bool) -> Void)?
    var onMore: ((UUID) -> Void)?
    private var overMore = false
    private var hovered: Int?

    /// The ball at the strip's right end, when there's more inside.
    private var ballRect: CGRect? {
        guard strip?.more != nil else { return nil }
        let r = bounds.insetBy(dx: 3, dy: 3)
        return CGRect(x: r.maxX - MoreBall.size - 2, y: r.midY - MoreBall.size / 2,
                      width: MoreBall.size, height: MoreBall.size)
    }
    /// A two-finger swipe across a tab: how far it's gone sideways, and the
    /// tab it started on.
    private var swipeX: CGFloat = 0
    private var swipeTab: Int?
    private var swipeDone = false

    override func scrollWheel(with event: NSEvent) {
        guard let s = strip, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            swipeX = 0
            swipeDone = false
            swipeTab = index(at: convert(event.locationInWindow, from: nil))
        }
        // Fingers moving right, whichever way scrolling is set to go.
        let dx = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaX : event.scrollingDeltaX
        swipeX += dx
        if !swipeDone, let i = swipeTab, s.tabs.indices.contains(i), abs(swipeX) > 40,
           abs(swipeX) > abs(event.scrollingDeltaY) * 2 {
            swipeDone = true
            onSwipeOut?(s.panel, s.tabs[i].window, swipeX < 0)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipeX = 0
            swipeTab = nil
        }
    }
    private var overClose = false
    private var pressed: Int?
    private var draggedOut = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Each tab's rect, side by side, at most 240 points wide.
    private func tabRects() -> [CGRect] {
        guard let s = strip, !s.tabs.isEmpty else { return [] }
        var r = bounds.insetBy(dx: 3, dy: 3)
        if s.more != nil { r.size.width -= MoreBall.size + 8 }
        let gap: CGFloat = 3
        let n = CGFloat(s.tabs.count)
        let width = min(240, (r.width - gap * (n - 1)) / n)
        return s.tabs.indices.map { i in
            CGRect(x: r.minX + CGFloat(i) * (width + gap), y: r.minY, width: width, height: r.height)
        }
    }

    private func index(at p: CGPoint) -> Int? { tabRects().firstIndex { $0.contains(p) } }

    /// A tab's X, where its icon is (it shows in place of the icon when
    /// you point at the tab).
    private func closeRect(_ tab: CGRect) -> CGRect {
        CGRect(x: tab.minX + 6, y: tab.midY - 9, width: 18, height: 18)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let onBall = ballRect?.insetBy(dx: -3, dy: -3).contains(p) ?? false
        if onBall != overMore { overMore = onBall; needsDisplay = true }
        let i = index(at: p)
        let over = i.map { closeRect(tabRects()[$0]).insetBy(dx: -2, dy: -2).contains(p) } ?? false
        if i != hovered || over != overClose { hovered = i; overClose = over; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; overClose = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let b = ballRect, b.insetBy(dx: -3, dy: -3).contains(p), let more = strip?.more {
            onMore?(more.panel)
            return
        }
        let i = index(at: p)
        if let i, let s = strip, closeRect(tabRects()[i]).insetBy(dx: -2, dy: -2).contains(p) {
            pressed = nil
            onClose?(s.panel, s.tabs[i].window)
            return
        }
        pressed = i
        draggedOut = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let out = p.y < bounds.minY - 24 || p.y > bounds.maxY + 24
        if out != draggedOut { draggedOut = out; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; draggedOut = false; needsDisplay = true }
        guard let s = strip, let i = pressed, s.tabs.indices.contains(i) else { return }
        let w = s.tabs[i].window
        if draggedOut {
            onPopOut?(s.panel, w)
        } else if index(at: convert(event.locationInWindow, from: nil)) == i {
            onSelect?(s.panel, w)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let s = strip, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPopOut?(s.panel, s.tabs[i].window)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = strip else { return }
        let back = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSColor(white: 0.08, alpha: 0.78).setFill()
        back.fill()
        if let b = ballRect, let more = s.more {
            MoreBall.draw(in: b, icon: more.icons.first ?? nil, count: more.count, hovered: overMore)
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        for (i, r) in tabRects().enumerated() {
            let tab = s.tabs[i]
            let isFront = tab.window == s.front
            let shape = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            if pressed == i && draggedOut {
                NSColor.white.withAlphaComponent(0.08).setFill()
                shape.fill()
                NSColor.white.withAlphaComponent(0.45).setStroke()
                shape.setLineDash([4, 3], count: 2, phase: 0)
                shape.lineWidth = 1
                shape.stroke()
            } else if isFront {
                NSColor.white.withAlphaComponent(0.20).setFill()
                shape.fill()
            } else if hovered == i || pressed == i {
                NSColor.white.withAlphaComponent(0.10).setFill()
                shape.fill()
            }
            var x = r.minX + 8
            let iconSize: CGFloat = 16
            if hovered == i && !(pressed == i && draggedOut) {
                // Pointing at the tab: its X, in place of its icon.
                let c = closeRect(r)
                NSColor(white: 1, alpha: overClose ? 0.28 : 0.12).setFill()
                NSBezierPath(ovalIn: c).fill()
                let m = c.insetBy(dx: 5.5, dy: 5.5)
                let cross = NSBezierPath()
                cross.move(to: CGPoint(x: m.minX, y: m.minY))
                cross.line(to: CGPoint(x: m.maxX, y: m.maxY))
                cross.move(to: CGPoint(x: m.minX, y: m.maxY))
                cross.line(to: CGPoint(x: m.maxX, y: m.minY))
                cross.lineWidth = 1.5
                cross.lineCapStyle = .round
                NSColor(white: 1, alpha: overClose ? 1 : 0.8).setStroke()
                cross.stroke()
                x += iconSize + 6
            } else if let icon = tab.icon {
                icon.draw(in: CGRect(x: x, y: r.midY - iconSize / 2, width: iconSize, height: iconSize))
                x += iconSize + 6
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isFront ? .semibold : .regular),
                .foregroundColor: NSColor(white: 1, alpha: isFront ? 0.95 : 0.65),
                .paragraphStyle: para,
            ]
            let textWidth = r.maxX - 8 - x
            if textWidth > 12 {
                NSAttributedString(string: tab.name, attributes: attrs)
                    .draw(in: CGRect(x: x, y: r.midY - 8, width: textWidth, height: 16))
            }
        }
    }
}
