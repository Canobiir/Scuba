import AppKit

/// When you make a pool or window private (or show it everywhere again), a
/// small before-and-after map of the board it changes shows at the top of
/// the screen for a couple of seconds: how that board looks both ways.
@MainActor
final class FoldPreview {
    struct Cell {
        let rect: CGRect      // 0–1 within the board, y up
        let title: String     // the apps in the pool
        let isPrivate: Bool   // private, seen from here (a tile, or folded away)
        let isFocus: Bool     // the pool that changed
    }

    struct Map {
        let cells: [Cell]
        let aspect: CGFloat   // height / width
    }

    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    func show(title: String, before: Map, after: Map, on screen: NSScreen) {
        hideTask?.cancel()
        window?.orderOut(nil)
        let mapW: CGFloat = 230
        let mapH = max(90, min(200, mapW * after.aspect))
        let pad: CGFloat = 16, gapX: CGFloat = 18, header: CGFloat = 26, label: CGFloat = 18
        let size = CGSize(width: pad * 2 + mapW * 2 + gapX, height: pad * 2 + header + label + mapH)
        let vf = screen.visibleFrame
        let frame = CGRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 18,
                           width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = FoldPreviewView(frame: CGRect(origin: .zero, size: size))
        view.title = title
        view.before = before
        view.after = after
        view.metrics = (pad, gapX, header, label, mapW, mapH)
        w.contentView = view
        w.alphaValue = 1
        w.orderFrontRegardless()
        window = w
        hideTask = fadeOut(w, after: 2.4)
    }
}

private final class FoldPreviewView: NSView {
    var title = ""
    var before: FoldPreview.Map?
    var after: FoldPreview.Map?
    var metrics: (pad: CGFloat, gapX: CGFloat, header: CGFloat, label: CGFloat, mapW: CGFloat, mapH: CGFloat) =
        (16, 18, 26, 18, 230, 140)

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor(white: 0.08, alpha: 0.9).setFill()
        box.fill()

        let l = metrics
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ]).draw(at: CGPoint(x: l.pad, y: bounds.maxY - l.pad - 17))

        let mapsY = l.pad
        let left = CGRect(x: l.pad, y: mapsY, width: l.mapW, height: l.mapH)
        let right = CGRect(x: l.pad + l.mapW + l.gapX, y: mapsY, width: l.mapW, height: l.mapH)
        if let before { draw(before, in: left) }
        if let after { draw(after, in: right) }
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ]
        NSAttributedString(string: "Before", attributes: small).draw(at: CGPoint(x: left.minX, y: left.maxY + 3))
        NSAttributedString(string: "After", attributes: small).draw(at: CGPoint(x: right.minX, y: right.maxY + 3))
        // An arrow between them.
        NSAttributedString(string: "→", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.7),
        ]).draw(at: CGPoint(x: left.maxX + l.gapX / 2 - 6, y: left.midY - 9))
    }

    private func draw(_ map: FoldPreview.Map, in area: CGRect) {
        NSColor(white: 1, alpha: 0.05).setFill()
        NSBezierPath(roundedRect: area, xRadius: 6, yRadius: 6).fill()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        for c in map.cells {
            let r = CGRect(x: area.minX + c.rect.minX * area.width, y: area.minY + c.rect.minY * area.height,
                           width: c.rect.width * area.width, height: c.rect.height * area.height).insetBy(dx: 1.5, dy: 1.5)
            guard r.width > 2, r.height > 2 else { continue }
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            let fill: NSColor = c.isPrivate ? NSColor(white: 0.35, alpha: 0.55)
                : (c.isFocus ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor(white: 1, alpha: 0.16))
            fill.setFill()
            path.fill()
            if c.isFocus {
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            if c.isPrivate {
                // Diagonal hatching for private pools.
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                NSColor(white: 1, alpha: 0.18).setStroke()
                let hatch = NSBezierPath()
                var x = r.minX - r.height
                while x < r.maxX {
                    hatch.move(to: CGPoint(x: x, y: r.minY))
                    hatch.line(to: CGPoint(x: x + r.height, y: r.maxY))
                    x += 7
                }
                hatch.lineWidth = 1
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            guard r.height > 16, r.width > 30 else { continue }
            NSAttributedString(string: (c.isPrivate ? "🔒 " : "") + c.title, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.88),
                .paragraphStyle: para,
            ]).draw(in: CGRect(x: r.minX + 3, y: r.midY - 7, width: r.width - 6, height: 13))
        }
    }
}
