import AppKit

/// "Show pool boundaries": a faint outline around each pool of the board
/// you're on, so a cluttered board reads at a glance. Only the board's own
/// pools: a pool holding a board of its own is one outline, never a
/// breakdown of what's inside it.
///
/// The outlines sit behind every window (just above the wallpaper), so they
/// never cover anything: you see them in the gaps between windows and
/// across any open space.
@MainActor
final class PoolBounds {
    private var window: NSWindow?
    private var view: BoundsView?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "poolBounds") }
        set { UserDefaults.standard.set(newValue, forKey: "poolBounds") }
    }

    /// - Parameter rects: the pools, in AppKit screen coordinates.
    func show(_ rects: [CGRect], on screen: NSScreen) {
        guard enabled, !rects.isEmpty else {
            hide()
            return
        }
        if window == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            // Above the wallpaper, its depth shade and the desktop icons; below every window.
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = BoundsView(frame: CGRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            window = w
            view = v
        }
        window?.setFrame(screen.frame, display: false)
        view?.frame = CGRect(origin: .zero, size: screen.frame.size)
        view?.origin = screen.frame.origin
        if view?.rects != rects {
            view?.rects = rects
            view?.needsDisplay = true
        }
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

private final class BoundsView: NSView {
    var origin: CGPoint = .zero
    var rects: [CGRect] = []

    override func draw(_ dirtyRect: NSRect) {
        // A hairline of light with a soft dark edge, so it shows on bright and
        // dark wallpapers alike, inset into the gap between windows.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        for r in rects {
            let local = r.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: local, xRadius: 11, yRadius: 11)
            NSColor(white: 1, alpha: 0.025).setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor(white: 1, alpha: 0.3).setStroke()
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
