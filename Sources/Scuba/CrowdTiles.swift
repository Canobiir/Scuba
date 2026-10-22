import AppKit

/// A panel that's too small to be useful (say, deep inside a nested board
/// seen from Home) shows as a tile with its main app's icon instead of
/// squashed windows. Click the tile to dive into that panel.
struct CrowdTile {
    var rect: CGRect          // AppKit screen coordinates
    let icon: NSImage?
    let name: String
    let extra: Int            // other windows in the panel
    let panel: UUID
    let owner: UUID           // the board the panel is on
    let window: UInt32        // the main window
    /// A porthole: a window too big for its spot on a nested board, shown as
    /// a frosted picture cropped at the pool's edge instead of spilling out.
    var porthole = false
    /// The frosted picture (at the window's real size, in pixels).
    var picture: CGImage? = nil
    /// Where the window's top-left corner would be (the picture is drawn
    /// from there and cropped by the tile).
    var anchor: CGPoint = .zero
    /// A porthole's whole spot, before it gives way to live windows.
    var full: CGRect = .zero
    /// A small symbol in the corner (SF Symbol name): a lock for private
    /// things seen from above, two squares for a copy of a window.
    var badge: String? = nil
    /// Clicking goes to the tile's board (instead of diving into its pool).
    var jumpOnly = false
    /// A live porthole: the whole window shrunk to fit, kept up to date,
    /// instead of a frosted still picture.
    var live = false
    /// A miniature of a whole board too small to see: each of its pools
    /// (screen coordinates), drawn as an outline with its app's icon.
    var cells: [CGRect] = []
    var cellIcons: [NSImage?] = []
    /// A window too small to use where it is: its picture shrunk into the
    /// tile and frosted over, with its app's icon.
    var shrunk = false
    /// A shelf: frosted tiles side by side, drawn as one (each one a cell),
    /// to step into together. The pools and the windows, cell by cell.
    var shelfPanels: [UUID] = []
    var shelfWindows: [UInt32] = []
    /// Which cell was clicked or swiped (a shelf's).
    var picked: Int? = nil
}

@MainActor
final class CrowdTiles {
    /// One small window per tile, so clicks anywhere else reach the desktop.
    private var windows: [NSWindow] = []
    /// While a resize plays as pictures, tiles sit above the pictures (so
    /// they still follow the gaps live); otherwise below every app window.
    var lifted = false {
        didSet { for w in windows { w.level = level } }
    }
    private var level: NSWindow.Level {
        lifted ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
               : NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    }
    /// What each window shows (its pool and window), to tell new tiles from
    /// ones that were already there.
    private var keys: [String] = []
    var onOpen: ((CrowdTile) -> Void)?
    /// The X on a frosted window: close it.
    var onClose: ((CrowdTile) -> Void)?
    /// Two fingers up on a frosted window: it inflates (up is how far the
    /// fingers moved up, in points).
    var onSwipe: ((CrowdTile, Controller.SwipePhase, CGFloat) -> Void)?
    /// A frosted window dragged by its bar: where the pointer is (screen
    /// coordinates), as it moves and when it's let go.
    var onDragMove: ((CrowdTile, CGPoint) -> Void)?
    var onDragEnd: ((CrowdTile, CGPoint) -> Void)?
    /// Where live portholes get their pictures.
    weak var live: LivePortholes?

    /// Shows these tiles. Tiles that are new fade in, and tiles that are no
    /// longer there fade out, so a window turning into a porthole (or back)
    /// eases across instead of cutting.
    func show(_ tiles: [CrowdTile]) {
        let oldWindows = windows
        let oldKeys = keys
        windows = []
        keys = []
        var arriving: [NSWindow] = []
        for t in tiles {
            let key = "\(t.panel.uuidString)/\(t.window)/\(t.porthole)"
            let w = NSWindow(contentRect: t.rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            // Above the desktop, its icons and widgets; below every app window.
            w.level = level
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = TileView(frame: CGRect(origin: .zero, size: t.rect.size))
            v.tile = t
            v.onOpen = { [weak self] t in self?.onOpen?(t) }
            v.onClose = { [weak self] t in self?.onClose?(t) }
            v.onSwipe = { [weak self] t, ph, up in self?.onSwipe?(t, ph, up) }
            v.onDragMove = { [weak self] t, p in self?.onDragMove?(t, p) }
            v.onDragEnd = { [weak self] t, p in self?.onDragEnd?(t, p) }
            if t.porthole && t.live {
                // The live picture underneath, the outline and icon on top.
                let box = NSView(frame: CGRect(origin: .zero, size: t.rect.size))
                box.wantsLayer = true
                let feed = FeedView(frame: box.bounds.insetBy(dx: 1, dy: 1))
                if let pic = t.picture { feed.feed.contents = pic }   // until the first live picture
                live?.attach(feed.feed, to: t.window)
                box.addSubview(feed)
                box.addSubview(v)
                w.contentView = box
            } else {
                w.contentView = v
            }
            w.setFrame(t.rect, display: true)
            if !oldKeys.contains(key) {
                w.alphaValue = 0
                arriving.append(w)
            }
            w.orderFront(nil)
            windows.append(w)
            keys.append(key)
        }
        // Tiles still here were just redrawn: the old copies go at once.
        // Tiles that are gone fade out.
        var leaving: [NSWindow] = []
        for (w, key) in zip(oldWindows, oldKeys) {
            if keys.contains(key) { w.orderOut(nil) } else { leaving.append(w) }
        }
        guard !arriving.isEmpty || !leaving.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fade
            for w in arriving { w.animator().alphaValue = 1 }
            for w in leaving { w.animator().alphaValue = 0 }
        }
        if !leaving.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 260_000_000)
                for w in leaving { w.orderOut(nil) }
            }
        }
    }

    /// Moves a pool's tile (while you drag the gap beside it), without
    /// redrawing everything.
    func move(panel: UUID, to rect: CGRect) {
        for (w, key) in zip(windows, keys) where key.hasPrefix(panel.uuidString + "/") {
            w.setFrame(rect, display: true)
            for v in w.contentView.map({ [$0] + $0.subviews }) ?? [] {
                v.frame = CGRect(origin: .zero, size: rect.size)
                v.needsDisplay = true
            }
        }
    }

    func hide() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        keys.removeAll()
    }
}

/// The live picture under a live porthole: the window shrunk to fit.
private final class FeedView: NSView {
    let feed = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = feed   // before wantsLayer, so the layer is ours to fill
        wantsLayer = true
        feed.cornerRadius = 9
        feed.masksToBounds = true
        feed.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        feed.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TileView: NSView {
    var tile: CrowdTile?
    var onOpen: ((CrowdTile) -> Void)?
    var onClose: ((CrowdTile) -> Void)?
    var onSwipe: ((CrowdTile, Controller.SwipePhase, CGFloat) -> Void)?
    var onDragMove: ((CrowdTile, CGPoint) -> Void)?
    var onDragEnd: ((CrowdTile, CGPoint) -> Void)?
    private var hovered = false
    /// Dragging by the bar: where the pointer is in the tile, and whether
    /// it's moved yet (a click on the bar without moving just opens it).
    private var grab: CGPoint?
    private var grabMoved = false

    private static let barHeight: CGFloat = 24

    /// A frosted window's bar along its top, to drag it by like a title bar.
    private var barRect: CGRect? {
        guard let t = tile, t.window != 0, t.cells.isEmpty, t.badge == nil, !t.jumpOnly, !t.porthole,
              bounds.width >= 120, bounds.height >= 80 else { return nil }
        return CGRect(x: bounds.minX, y: bounds.maxY - Self.barHeight, width: bounds.width, height: Self.barHeight)
    }
    private var overClose = false
    private var swiping = false

    /// Two fingers on a frosted window (a trackpad swipe, not a mouse wheel):
    /// up inflates it. The coast after your fingers lift doesn't count.
    /// A mouse wheel (no phases): the swipe ends a moment after it stops.
    private var wheelEnd: DispatchWorkItem?

    override func scrollWheel(with event: NSEvent) {
        guard var t = tile, event.momentumPhase.isEmpty else { return }
        // A shelf: the app under your fingers inflates out of it.
        if !t.shelfPanels.isEmpty {
            guard let i = withCell(t, at: event).picked, i < t.shelfPanels.count, i < t.cells.count else { return }
            t = CrowdTile(rect: t.cells[i], icon: i < t.cellIcons.count ? t.cellIcons[i] : nil, name: t.name,
                          extra: 0, panel: t.shelfPanels[i], owner: t.owner, window: t.shelfWindows[i])
        }
        guard t.window != 0, t.cells.isEmpty else { return }
        // Fingers moving up (or sideways, either way) unroll it; down rolls
        // it back. Whichever way scrolling is set to go.
        // (A mouse wheel's steps are lines, not points.)
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dy = (event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY) * k
        let dx = event.scrollingDeltaX * k
        let up = abs(dx) > abs(dy) ? abs(dx) : dy
        // A tile can be redrawn mid-swipe (a fresh picture): whichever part
        // of the swipe a tile sees first starts it here (the controller
        // carries on with one already under way).
        let ending = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if !swiping, !ending {
            swiping = true
            onSwipe?(t, .began, 0)
        }
        guard swiping else { return }
        if up != 0 { onSwipe?(t, .changed, up) }
        if ending {
            swiping = false
            onSwipe?(t, .ended, 0)
        } else if event.phase.isEmpty {
            wheelEnd?.cancel()
            let tile = t
            let end = DispatchWorkItem { [weak self] in
                guard let self, self.swiping else { return }
                self.swiping = false
                self.onSwipe?(tile, .ended, 0)
            }
            wheelEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: end)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; overClose = false; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        let over = closeRect.map { $0.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) } ?? false
        if over != overClose { overClose = over; needsDisplay = true }
    }

    /// A frosted window (or a porthole) gets an X in its top-left corner
    /// when you point at it; boards drawn small and hidden things don't.
    private var closeRect: CGRect? {
        guard let t = tile, t.window != 0, t.cells.isEmpty, t.badge == nil, !t.jumpOnly,
              bounds.width >= 70, bounds.height >= 50 else { return nil }
        let size: CGFloat = 18
        let top = barRect.map { $0.midY + size / 2 } ?? bounds.maxY - 9
        return CGRect(x: bounds.minX + 9, y: top - size, width: size, height: size)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tile else { return }
        let here = convert(event.locationInWindow, from: nil)
        if let x = closeRect, x.insetBy(dx: -4, dy: -4).contains(here) {
            onClose?(tile)
            return
        }
        if let bar = barRect, bar.contains(here) {
            grab = here
            grabMoved = false
            return
        }
        onOpen?(withCell(tile, at: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let g = grab, let t = tile, let w = window else { return }
        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(x: mouse.x - g.x, y: mouse.y - g.y)
        if !grabMoved {
            guard hypot(origin.x - w.frame.minX, origin.y - w.frame.minY) > 4 else { return }
            grabMoved = true
            w.alphaValue = 0.85
            w.level = .floating   // above the windows it passes over
        }
        w.setFrameOrigin(origin)
        onDragMove?(t, mouse)
    }

    override func mouseUp(with event: NSEvent) {
        guard grab != nil, let t = tile else { return }
        grab = nil
        if grabMoved {
            grabMoved = false
            onDragEnd?(t, NSEvent.mouseLocation)
        } else {
            onOpen?(t)
        }
    }

    /// The tile, noting which of a shelf's cells is under the pointer.
    private func withCell(_ t: CrowdTile, at event: NSEvent) -> CrowdTile {
        guard !t.shelfPanels.isEmpty, let w = window else { return t }
        let p = w.convertPoint(toScreen: event.locationInWindow)
        var out = t
        out.picked = t.cells.firstIndex { $0.contains(p) }
        return out
    }

    /// The bar along a frosted window's top, with its app's name.
    private func drawBar() {
        guard let bar = barRect, let t = tile else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).addClip()
        NSColor(white: 1, alpha: hovered ? 0.12 : 0.07).setFill()
        bar.fill()
        NSGraphicsContext.restoreGraphicsState()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: t.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: hovered ? 0.85 : 0.6),
            .paragraphStyle: para,
        ]).draw(in: CGRect(x: bar.minX + 34, y: bar.midY - 7, width: bar.width - 68, height: 14))
    }

    /// The X, on top of whatever the tile shows.
    private func drawClose() {
        guard hovered, let r = closeRect else { return }
        let circle = NSBezierPath(ovalIn: r)
        NSColor(white: overClose ? 0.22 : 0.08, alpha: overClose ? 0.9 : 0.62).setFill()
        circle.fill()
        NSColor(white: 1, alpha: overClose ? 0.5 : 0.25).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()
        let inset = r.insetBy(dx: 5.5, dy: 5.5)
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: inset.minX, y: inset.minY))
        cross.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
        cross.move(to: CGPoint(x: inset.minX, y: inset.maxY))
        cross.line(to: CGPoint(x: inset.maxX, y: inset.minY))
        cross.lineWidth = 1.6
        cross.lineCapStyle = .round
        NSColor(white: 1, alpha: overClose ? 1 : 0.85).setStroke()
        cross.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        defer { drawBar(); drawClose() }
        guard let t = tile else { return }
        if t.porthole {
            drawPorthole(t)
            drawBadge(t)
            return
        }
        if !t.cells.isEmpty {
            drawMiniature(t)
            drawBadge(t)
            return
        }
        if t.shrunk {
            drawShrunk(t)
            drawBadge(t)
            return
        }
        defer { drawBadge(t) }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        NSColor(white: 0.1, alpha: hovered ? 0.72 : 0.55).setFill()
        path.fill()
        if let tint = AppColour.of(t.icon) {
            tint.withAlphaComponent(AppColour.amount).setFill()
            path.fill()
        }
        NSColor(white: 1, alpha: hovered ? 0.5 : 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()

        let showName = r.height > 90 && r.width > 70
        let iconSize = max(16, min(72, min(r.width, r.height) * 0.5))
        let iconY = r.midY - iconSize / 2 + (showName ? 9 : 0)
        t.icon?.draw(in: CGRect(x: r.midX - iconSize / 2, y: iconY, width: iconSize, height: iconSize))

        if showName {
            let label = t.name + (t.extra > 0 ? "  +\(t.extra)" : "")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.85),
                .paragraphStyle: para,
            ]
            NSAttributedString(string: label, attributes: attrs)
                .draw(in: CGRect(x: r.minX + 6, y: iconY - 22, width: r.width - 12, height: 16))
        } else if t.extra > 0, r.width > 30 {
            // Tiny tile: just a count badge in the corner.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            NSAttributedString(string: "+\(t.extra)", attributes: attrs)
                .draw(at: CGPoint(x: r.maxX - 22, y: r.minY + 4))
        }
    }

    /// A window too small to use: its picture shrunk to fill the tile (the
    /// top of it, where its title and toolbar are), frosted over, with its
    /// app's icon, and its name when there's room.
    private func drawShrunk(_ t: CrowdTile) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let clip = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if let pic = t.picture, let ctx = NSGraphicsContext.current?.cgContext {
            let pw = CGFloat(pic.width), ph = CGFloat(pic.height)
            let scale = max(r.width / max(pw, 1), r.height / max(ph, 1))
            let size = CGSize(width: pw * scale, height: ph * scale)
            ctx.interpolationQuality = .medium
            ctx.draw(pic, in: CGRect(x: r.midX - size.width / 2, y: r.maxY - size.height,
                                     width: size.width, height: size.height))
        } else {
            NSColor(white: 0.16, alpha: 0.9).setFill()
            r.fill()
        }
        // The frost: the window's own colours, blurred, just a touch darker
        // so the icon and name read on top (and a little of the app's icon
        // colour only if that setting is on).
        NSColor(white: 0.06, alpha: hovered ? 0.14 : 0.26).setFill()
        r.fill()
        if let tint = AppColour.of(t.icon) {
            tint.withAlphaComponent(AppColour.amount).setFill()
            r.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: hovered ? 0.55 : 0.25).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        let iconSize = max(16, min(56, min(r.width, r.height) * 0.4))
        let showName = r.height > iconSize + 40 && r.width > 80
        let iconY = r.midY - iconSize / 2 + (showName ? 9 : 0)
        t.icon?.draw(in: CGRect(x: r.midX - iconSize / 2, y: iconY, width: iconSize, height: iconSize))
        guard showName else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowBlurRadius = 4
        let label = (hovered ? "Dive in" : t.name) + (t.extra > 0 && !hovered ? "  +\(t.extra)" : "")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
            .paragraphStyle: para,
            .shadow: shadow,
        ]
        NSAttributedString(string: label, attributes: attrs)
            .draw(in: CGRect(x: r.minX + 6, y: iconY - 22, width: r.width - 12, height: 16))
    }

    /// A board too small to see, as a little copy of itself: each pool's
    /// outline (so its splits show), with its app's icon.
    private func drawMiniature(_ t: CrowdTile) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let back = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        NSColor(white: 0.1, alpha: hovered ? 0.72 : 0.55).setFill()
        back.fill()
        NSColor(white: 1, alpha: hovered ? 0.5 : 0.18).setStroke()
        back.lineWidth = 1
        back.stroke()
        for (i, cell) in t.cells.enumerated() {
            let local = CGRect(x: cell.minX - t.rect.minX, y: cell.minY - t.rect.minY,
                               width: cell.width, height: cell.height)
            let c = local.insetBy(dx: 3, dy: 3).intersection(r.insetBy(dx: 3, dy: 3))
            guard !c.isNull, c.width > 4, c.height > 4 else { continue }
            let path = NSBezierPath(roundedRect: c, xRadius: 6, yRadius: 6)
            NSColor(white: 1, alpha: 0.06).setFill()
            path.fill()
            NSColor(white: 1, alpha: hovered ? 0.55 : 0.32).setStroke()
            path.lineWidth = 1
            path.stroke()
            let size = max(10, min(40, min(c.width, c.height) * 0.45))
            if i < t.cellIcons.count, let icon = t.cellIcons[i] {
                icon.draw(in: CGRect(x: c.midX - size / 2, y: c.midY - size / 2, width: size, height: size))
            }
        }
    }

    /// The tile's corner symbol, if it has one.
    private func drawBadge(_ t: CrowdTile) {
        guard let name = t.badge, bounds.width > 40, bounds.height > 40,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = symbol.withSymbolConfiguration(config) ?? symbol
        let size = image.size
        let pad: CGFloat = 8
        let spot = CGRect(x: bounds.minX + pad, y: bounds.maxY - pad - size.height, width: size.width, height: size.height)
        let back = NSBezierPath(roundedRect: spot.insetBy(dx: -5, dy: -4), xRadius: 6, yRadius: 6)
        NSColor(white: 0, alpha: 0.45).setFill()
        back.fill()
        // Tint the symbol white.
        let tinted = NSImage(size: size, flipped: false) { r in
            image.draw(in: r)
            NSColor(white: 1, alpha: 0.9).set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: spot)
    }

    /// The window's picture at its real size, cropped by the pool's edge and
    /// frosted, with its app's icon and name on top.
    private func drawPorthole(_ t: CrowdTile) {
        if t.live {
            drawLive(t)
            return
        }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let clip = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if let pic = t.picture, let ctx = NSGraphicsContext.current?.cgContext {
            let scale = window?.backingScaleFactor ?? 2
            let size = CGSize(width: CGFloat(pic.width) / scale, height: CGFloat(pic.height) / scale)
            // The window's top-left corner, in this view (AppKit: y up).
            let top = CGPoint(x: t.anchor.x - t.rect.minX, y: t.anchor.y - t.rect.minY)
            ctx.interpolationQuality = .medium
            ctx.draw(pic, in: CGRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height))
        } else {
            NSColor(white: 0.16, alpha: 0.9).setFill()
            r.fill()
        }
        // The frost's tint: darker at rest, lighter when you point at it.
        NSColor(white: 0.08, alpha: hovered ? 0.18 : 0.34).setFill()
        r.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 1, alpha: hovered ? 0.55 : 0.22).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        let iconSize = max(20, min(56, min(r.width, r.height) * 0.32))
        let showName = r.height > iconSize + 40 && r.width > 80
        let iconY = r.midY - iconSize / 2 + (showName ? 10 : 0)
        t.icon?.draw(in: CGRect(x: r.midX - iconSize / 2, y: iconY, width: iconSize, height: iconSize))
        guard showName else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowBlurRadius = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
            .paragraphStyle: para,
            .shadow: shadow,
        ]
        NSAttributedString(string: hovered ? "Dive in" : t.name, attributes: attrs)
            .draw(in: CGRect(x: r.minX + 6, y: iconY - 22, width: r.width - 12, height: 16))
    }

    /// A live porthole's top layer: the window itself shows underneath,
    /// shrunk to fit. On top, an outline and its app's icon in the corner,
    /// and "Dive in" when you point at it.
    private func drawLive(_ t: CrowdTile) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let clip = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        if hovered {
            NSColor(white: 0.06, alpha: 0.32).setFill()
            clip.fill()
        }
        NSColor(white: 1, alpha: hovered ? 0.55 : 0.22).setStroke()
        clip.lineWidth = 1
        clip.stroke()
        let size = max(14, min(26, min(r.width, r.height) * 0.16))
        let spot = CGRect(x: r.maxX - size - 7, y: r.minY + 7, width: size, height: size)
        if let icon = t.icon {
            let back = NSBezierPath(roundedRect: spot.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
            NSColor(white: 0, alpha: 0.35).setFill()
            back.fill()
            icon.draw(in: spot)
        }
        guard hovered, r.width > 90, r.height > 50 else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.7)
        shadow.shadowBlurRadius = 4
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.95),
            .paragraphStyle: para,
            .shadow: shadow,
        ]
        NSAttributedString(string: "Dive in", attributes: attrs)
            .draw(in: CGRect(x: r.minX + 6, y: r.midY - 9, width: r.width - 12, height: 18))
    }
}
