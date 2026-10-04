import AppKit
import QuartzCore

/// Watches for window drags. While you drag a window, it shows the panel
/// layout; when you let go, the window goes into the panel under the pointer,
/// or into a new panel if you dropped near a panel's edge.
/// Holding Option when you let go cancels.
@MainActor
final class DragDock {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    private var monitors: [Any] = []

    private var candidate: (id: CGWindowID, bounds: CGRect)?
    private var dragging = false
    /// The window is being resized by its edges, not moved.
    private var resizing = false
    /// Windows near where you pressed (an edge grab can land on the neighbour).
    private var nearby: [(id: CGWindowID, bounds: CGRect)] = []
    /// Recent pointer positions while dragging, for throws.
    private var trail: [(time: CFTimeInterval, point: CGPoint)] = []
    private var lastCheck = Date.distantPast
    private var target: Controller.DropTarget?

    private var overlay: NSWindow?
    private var view: DropView?
    /// With two screens: the one the drag started on, the one showing the
    /// overlay, and the one whose windows are making room right now.
    private var source: Controller?
    private var overlayOwner: Controller?
    private var previewOwner: Controller?

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
    }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.mouseDragged()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.mouseUp()
        }) { monitors.append(m) }
    }

    // MARK: Mouse

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func mouseDown() {
        for other in Controller.all { other.clearEdgeResize() }
        let c = pick()
        guard !c.onSurface else { candidate = nil; return }
        source = c
        let p = NSEvent.mouseLocation
        let point = CGPoint(x: p.x, y: primaryHeight - p.y)
        candidate = c.windows.windowAt(point)
        nearby = c.windows.windowsNear(point)
        dragging = false
        resizing = false
        trail.removeAll()
        target = nil
    }

    private func mouseDragged() {
        guard let c = candidate else { return }
        // Every movement counts toward a throw, before any throttling.
        let t = CACurrentMediaTime()
        trail.append((t, NSEvent.mouseLocation))
        trail.removeAll { t - $0.time > 0.15 }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 1.0 / 30 else { return }
        lastCheck = now

        if !dragging {
            // A window near the press changing size: you're resizing it by an
            // edge (which may be a different window from the one on top there).
            if let r = resized() {
                candidate = r
                resizing = true
                (source ?? controller).edgeResize(r.id, final: false)
                return
            }
            // It only counts as a window drag if the window itself moved
            // without changing size (a resize or text selection doesn't).
            guard let b = controller.windows.bounds(of: c.id) else { return }
            let moved = abs(b.minX - c.bounds.minX) + abs(b.minY - c.bounds.minY)
            let sameSize = abs(b.width - c.bounds.width) < 2 && abs(b.height - c.bounds.height) < 2
            if !sameSize {
                // Resizing by an edge: the gap beside a filled window follows it.
                resizing = true
                (source ?? controller).edgeResize(c.id, final: false)
                return
            }
            guard moved > 12 else { return }
            dragging = true
            // Look up the windows on screen now, so the glide after the drop starts at once.
            (source ?? controller).glider.warmUp()
        }
        // The screen under the pointer (the drag may cross to another display).
        let here = pick()
        // Over a screen that's on its plain desktop, a live map or left alone:
        // nothing to dock into there.
        guard !here.onSurface, here.screen.frame.contains(NSEvent.mouseLocation) else {
            hideOverlay()
            previewOwner?.endPreview(restore: true)
            previewOwner = nil
            target = nil
            return
        }
        if overlayOwner !== here {
            hideOverlay()
            showOverlay(for: here)
        }
        if let old = previewOwner, old !== here { old.endPreview(restore: true) }
        previewOwner = here
        target = here.dropTarget(at: NSEvent.mouseLocation)
        view?.target = target
        view?.needsDisplay = true
        // Show where it'll land: the panel's windows make room as you hover.
        here.previewDrop(c.id, target: NSEvent.modifierFlags.contains(.option) ? nil : target)
    }

    /// The window near the press whose size has changed, if any (the one on
    /// top first).
    private func resized() -> (id: CGWindowID, bounds: CGRect)? {
        let pool = candidate.map { [$0] + nearby.filter { n in n.id != candidate?.id } } ?? nearby
        return pool.first { n in
            guard let b = controller.windows.bounds(of: n.id) else { return false }
            return abs(b.width - n.bounds.width) >= 2 || abs(b.height - n.bounds.height) >= 2
        }
    }

    /// How fast the pointer was going when you let go (points per second),
    /// or nil if it had slowed down or stopped.
    private func releaseVelocity() -> CGVector? {
        // Measured right up to the release, so stopping before letting go is no throw.
        let now = CACurrentMediaTime(), end = NSEvent.mouseLocation
        guard let first = trail.first(where: { now - $0.time < 0.08 }), now - first.time > 0.012 else { return nil }
        let dt = CGFloat(now - first.time)
        return CGVector(dx: (end.x - first.point.x) / dt, dy: (end.y - first.point.y) / dt)
    }

    private func mouseUp() {
        let shownTarget = target
        let shownOwner = overlayOwner
        defer {
            candidate = nil
            nearby.removeAll()
            dragging = false
            resizing = false
            trail.removeAll()
            target = nil
        }
        guard var c = candidate else { return }
        if !dragging, let r = resized() { c = r }
        guard dragging else {
            // Not a drag-to-dock, but did you resize it by its edges?
            if let now = controller.windows.bounds(of: c.id),
               abs(now.width - c.bounds.width) > 2 || abs(now.height - c.bounds.height) > 2 ||
               abs(now.minX - c.bounds.minX) > 2 || abs(now.minY - c.bounds.minY) > 2 {
                let owner = source ?? controller
                // A filled window's edge moved the gap beside it; anything else floats.
                if !owner.edgeResize(c.id, final: true) { owner.noteManualChange(c.id) }
            } else if resizing {
                (source ?? controller).edgeResize(c.id, final: true)
            }
            return
        }
        hideOverlay()
        let dest = pick()
        dest.glider.warmUp()
        let from = source ?? dest
        if let old = previewOwner, old !== dest { old.endPreview(restore: true) }
        previewOwner = nil
        let cancelled = NSEvent.modifierFlags.contains(.option)

        // Let go while still moving fast: a throw. It lands in the pool it was
        // heading for, wherever exactly you let go.
        let releasedAt = NSEvent.mouseLocation
        if !cancelled, !dest.onSurface, dest.throwing, let v = releaseVelocity(), hypot(v.dx, v.dy) > 1400 {
            dest.endPreview(restore: true)
            if from !== dest { from.letGo(of: c.id) }
            let id = c.id
            let fallback = dest.dropTarget(at: releasedAt)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                dest.windows.refresh()
                guard dest.windows.exists(id) else { return }
                if !dest.throwWindow(id, from: releasedAt, velocity: v) {
                    if let t = fallback { dest.drop(id, on: t) } else { from.noteManualChange(id) }
                }
            }
            return
        }
        // What you see is what you get: the drop does what the preview was
        // showing, rather than looking again at exactly where you let go (a
        // last twitch onto the Fill pill would otherwise turn a float into a fill).
        let shown = (shownOwner === dest) ? shownTarget : nil
        guard !cancelled, !dest.onSurface, dest.screen.frame.contains(NSEvent.mouseLocation),
              let t = shown ?? dest.dropTarget(at: NSEvent.mouseLocation) else {
            // Dropped outside the layout or with Option: it stays where you put it,
            // and anything that made room for it goes back.
            dest.endPreview(restore: true)
            from.noteManualChange(c.id)
            return
        }
        dest.endPreview(restore: false)
        // Moved to another screen's boards: it leaves the boards it came from.
        if from !== dest { from.letGo(of: c.id) }
        // Let the window finish its own move before we place it.
        let id = c.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            dest.windows.refresh()
            guard dest.windows.exists(id) else { return }
            dest.drop(id, on: t)
        }
    }

    // MARK: Overlay

    private func showOverlay(for owner: Controller) {
        overlayOwner = owner
        let screen = owner.screen
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let v = DropView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.origin = screen.frame.origin
        v.panels = owner.dropPanels().map { ($0.panel.id, $0.rect, $0.label) }
        w.contentView = v
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        overlay = w
        view = v
    }

    private func hideOverlay() {
        overlay?.orderOut(nil)
        overlay = nil
        overlayOwner = nil
        view = nil
    }
}

private final class DropView: NSView {
    var origin: CGPoint = .zero
    var panels: [(id: UUID, rect: CGRect, label: String)] = []
    var target: Controller.DropTarget?

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        func drawPanel(_ rect: CGRect, label: String) {
            let r = local(rect).insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSColor(white: 0, alpha: 0.12).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.45).setStroke()
            path.lineWidth = 2
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.5),
                .paragraphStyle: para,
            ]
            NSAttributedString(string: label, attributes: attrs)
                .draw(in: CGRect(x: r.minX, y: r.maxY - 48, width: r.width, height: 36))
        }

        // Every panel except the one under the pointer, which is drawn as a
        // preview of what the drop will do.
        for p in panels where p.id != target?.panel.id {
            drawPanel(p.rect, label: p.label)
        }

        guard let t = target else { return }

        func label(_ string: String, size: CGFloat, in rect: CGRect, color: NSColor = .white) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]
            let text = NSAttributedString(string: string, attributes: attrs)
            let h = text.size().height
            text.draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h))
        }

        switch t.action {
        case .float:
            // Floating: the panel just gets a dashed outline; the window stays
            // exactly where you let go.
            let r = local(t.panelRect).insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSColor(white: 0, alpha: 0.10).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            path.setLineDash([8, 5], count: 2, phase: 0)
            path.stroke()

        case .fill, .newPanel:
            if let keep = t.remaining {
                // New panel: the existing one is shown at its new, smaller size.
                drawPanel(keep, label: t.panelLabel)
            }
            let r = local(t.highlight).insetBy(dx: 6, dy: 6)
            let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            accent.withAlphaComponent(0.28).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 3
            path.stroke()
            if t.remaining != nil { label(t.label, size: 20, in: r) }
        }

        // Snap bars of the hovered panel, on top of everything.
        for (i, bar) in t.bars.enumerated() {
            let r = local(bar.rect)
            let isActive = i == t.activeBar
            let path = NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) / 2,
                                    yRadius: min(r.width, r.height) / 2)
            (isActive ? accent : NSColor(white: 1, alpha: 0.18)).setFill()
            path.fill()
            (isActive ? NSColor.white : NSColor(white: 1, alpha: 0.55)).setStroke()
            path.lineWidth = isActive ? 2 : 1
            path.stroke()
            if case .fill = bar.action {
                label("Fill", size: 16, in: r)
            }
        }
    }
}
