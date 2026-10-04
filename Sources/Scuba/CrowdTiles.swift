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
}

@MainActor
final class CrowdTiles {
    /// One small window per tile, so clicks anywhere else reach the desktop.
    private var windows: [NSWindow] = []
    /// What each window shows (its pool and window), to tell new tiles from
    /// ones that were already there.
    private var keys: [String] = []
    var onOpen: ((CrowdTile) -> Void)?
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
            w.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = TileView(frame: CGRect(origin: .zero, size: t.rect.size))
            v.tile = t
            v.onOpen = { [weak self] t in self?.onOpen?(t) }
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
            ctx.duration = 0.22
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

    override func mouseDown(with event: NSEvent) {
        if let tile { onOpen?(tile) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = tile else { return }
        if t.porthole {
            drawPorthole(t)
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
