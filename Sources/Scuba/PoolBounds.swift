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

    /// While a resize plays as pictures, the pills sit above the pictures.
    var lifted = false {
        didSet { window?.level = level }
    }
    private var level: NSWindow.Level {
        lifted ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
               : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "poolBounds") }
        set { UserDefaults.standard.set(newValue, forKey: "poolBounds") }
    }

    /// A fine outline around each docked window, just outside its edge.
    var windowOutlines: Bool {
        get { UserDefaults.standard.bool(forKey: "windowOutlines") }
        set { UserDefaults.standard.set(newValue, forKey: "windowOutlines") }
    }

    /// A soft pill in the middle of each gap between tiles, to grab and drag.
    var gapHandles: Bool {
        get { UserDefaults.standard.bool(forKey: "gapHandles") }
        set { UserDefaults.standard.set(newValue, forKey: "gapHandles") }
    }

    /// - Parameters:
    ///   - rects: the pools, in AppKit screen coordinates.
    ///   - windows: the docked windows, where they sit.
    ///   - handles: the pills in the gaps (AppKit screen coordinates).
    func show(_ rects: [CGRect], windows: [CGRect] = [], handles: [CGRect] = [], on screen: NSScreen) {
        let pools = enabled ? rects : []
        let edges = windowOutlines ? windows : []
        let pills = gapHandles ? handles : []
        guard !pools.isEmpty || !edges.isEmpty || !pills.isEmpty else {
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
            w.level = level
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = BoundsView(frame: CGRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            window = w
            view = v
        }
        window?.setFrame(screen.frame, display: false)
        view?.frame = CGRect(origin: .zero, size: screen.frame.size)
        view?.origin = screen.frame.origin
        if view?.rects != pools || view?.edges != edges || view?.pills != pills {
            view?.rects = pools
            view?.edges = edges
            view?.pills = pills
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
    var edges: [CGRect] = []
    var pills: [CGRect] = []

    override func draw(_ dirtyRect: NSRect) {
        // The gap handles: a soft pill of light in the middle of each gap.
        for r in pills {
            let local = r.offsetBy(dx: -origin.x, dy: -origin.y)
            let radius = min(local.width, local.height) / 2
            let path = NSBezierPath(roundedRect: local, xRadius: radius, yRadius: radius)
            NSColor(white: 1, alpha: 0.26).setFill()
            path.fill()
        }
        // Each docked window: a fine line of light just outside its edge (the
        // window covers the rest), with a soft dark halo so it reads on any
        // wallpaper. Its corners follow the window's own.
        let halo = NSShadow()
        halo.shadowColor = NSColor(white: 0, alpha: 0.45)
        halo.shadowBlurRadius = 3
        halo.shadowOffset = .zero
        for r in edges {
            let local = r.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -1.5, dy: -1.5)
            let path = NSBezierPath(roundedRect: local, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            halo.set()
            NSColor(white: 1, alpha: 0.32).setStroke()
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
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
