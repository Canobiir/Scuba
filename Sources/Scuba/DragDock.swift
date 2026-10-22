import AppKit
import QuartzCore

/// Watches for window drags. While you drag a window, the windows where it
/// would land make room for it (pools stay invisible: hold Shift to see them
/// and their snap bars). When you let go, it docks beside the window it was
/// near, fills an empty pool, or floats where you let go.
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
    /// Where you pressed (AppKit coordinates).
    private var pressAt: CGPoint = .zero
    /// Recent pointer positions while dragging, for throws.
    private var trail: [(time: CFTimeInterval, point: CGPoint)] = []
    private var lastCheck = Date.distantPast
    private var target: Controller.DropTarget?

    private var overlay: NSWindow?
    private var view: DropView?
    /// The overlay shows only where the window will land (no pools).
    private var overlayQuiet = false
    /// Stand-ins are playing this drag's previews (see DragStage).
    private var staged = false
    /// Patience: a new spot only takes over once the pointer has rested on
    /// it for a moment, so passing over things on the way doesn't make the
    /// windows jump about.
    private var shownKey = ""
    private var pendingKey = ""
    private var dwellTask: Task<Void, Never>?
    private let dwell: Double = 0.08
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
        dwellTask?.cancel()
        shownKey = ""
        pendingKey = ""
        if staged { c.stage.tearDown() }
        staged = false
        let p = NSEvent.mouseLocation
        let point = CGPoint(x: p.x, y: primaryHeight - p.y)
        candidate = c.windows.windowAt(point)
        nearby = c.windows.windowsNear(point)
        pressAt = p
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
        // Resizing by an edge: the windows around it follow every movement.
        if resizing, !dragging {
            guard now.timeIntervalSince(lastCheck) > 1.0 / 120 else { return }
            lastCheck = now
            (source ?? controller).edgeResize(c.id, final: false)
            return
        }
        guard now.timeIntervalSince(lastCheck) > 1.0 / 60 else { return }
        lastCheck = now

        if !dragging {
            // A window near the press changing size: you're resizing it by an
            // edge (which may be a different window from the one on top there).
            if let r = resized() {
                candidate = r
                resizing = true
                (source ?? controller).edgeResize(r.id, final: false, pressedAt: pressAt)
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
                (source ?? controller).edgeResize(c.id, final: false, pressedAt: pressAt)
                return
            }
            // Pressed right on an edge and pulling in, but the window doesn't
            // budge (it's as small as it goes): still a resize, the gap
            // follows the pointer past it.
            if moved < 2, onEdge(c.bounds) {
                let m = NSEvent.mouseLocation
                if abs(m.x - pressAt.x) > 6 || abs(m.y - pressAt.y) > 6,
                   (source ?? controller).edgeResize(c.id, final: false, pressedAt: pressAt) {
                    resizing = true
                    return
                }
            }
            guard moved > 12 else { return }
            dragging = true
            // Look up the windows on screen now, so the glide after the drop starts at once.
            (source ?? controller).glider.warmUp()
            // Pictures for the stand-ins, taken while you start to move.
            staged = (source ?? controller).prepareStage(dragging: c.id)
        }
        // The screen under the pointer (the drag may cross to another display).
        let here = pick()
        // Over a screen that's on its plain desktop, a live map or left alone:
        // nothing to dock into there.
        guard !here.onSurface, here.screen.frame.contains(NSEvent.mouseLocation) else {
            hideOverlay()
            previewOwner?.endPreview(restore: true)
            previewOwner = nil
            dwellTask?.cancel()
            if staged { (source ?? here).stage.preview(plan: nil, slot: nil) }
            target = nil
            shownKey = "none"
            pendingKey = "none"
            return
        }
        // The stand-ins live on the screen the drag started on.
        if staged, here !== (source ?? here) {
            staged = false
            let o = source ?? here
            Task { @MainActor in
                await o.stage.finish(dropped: false, draggedTo: nil, targetOf: { _ in nil },
                                     frameOf: { o.windows.frame(of: $0) })
            }
        }
        let quiet = isQuiet(here)
        if overlayOwner !== here || overlayQuiet != quiet {
            hideOverlay()
            showOverlay(for: here, quiet: quiet)
        }
        if let old = previewOwner, old !== here { old.endPreview(restore: true) }
        previewOwner = here
        let cancelling = NSEvent.modifierFlags.contains(.option)
        let next = cancelling ? nil : landing(for: here, at: NSEvent.mouseLocation, dragging: c.id)
        let key = DragDock.key(next)
        // Floating in a pool: the windows there make room as it moves (old style).
        if !staged, key == shownKey, case .float? = next?.action {
            target = next
            here.previewDrop(c.id, target: next, leaving: true)
        }
        if key == shownKey {
            pendingKey = key
            return
        }
        if cancelling {
            adopt(next, key: key, on: here, dragged: c.id)
            return
        }
        guard key != pendingKey else { return }   // still waiting on this one
        pendingKey = key
        dwellTask?.cancel()
        // Over the middle of a window: it becomes a tab there at once, with
        // a tick you can feel on the trackpad.
        if case .tab? = next?.action {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            adopt(next, key: key, on: here, dragged: c.id)
            return
        }
        // The first spot comes quickly; after that, a moment's patience.
        let wait = shownKey.isEmpty ? 0.05 : dwell
        let id = c.id
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.dragging, self.pendingKey == key else { return }
            self.adopt(next, key: key, on: here, dragged: id)
        }
    }

    /// The spot the pointer has settled on takes over: the outline moves
    /// there and everything glides to where it'll be.
    private func adopt(_ t: Controller.DropTarget?, key: String, on here: Controller, dragged id: CGWindowID) {
        target = t
        shownKey = key
        if staged {
            // The stage draws the landing slot itself.
            view?.target = nil
            view?.needsDisplay = true
            // The windows making room show where it'll go, and a soft field
            // marks the spot itself.
            here.stage.preview(plan: t?.preview, slot: t.flatMap { DragDock.slot(for: $0) }, tabs: t?.tabNames)
        } else {
            view?.target = t
            view?.needsDisplay = true
            here.previewDrop(id, target: t, leaving: t != nil && here === (source ?? here))
        }
    }

    /// The soft field for a spot: where the window will land when it docks
    /// (none when it just floats where you let go).
    static func slot(for t: Controller.DropTarget) -> CGRect? {
        switch t.action {
        case .float, .desktop: return nil
        default: return t.highlight
        }
    }

    /// What a target is, for telling a new spot from the same one.
    private static func key(_ t: Controller.DropTarget?) -> String {
        guard let t else { return "none" }
        let h = t.highlight
        return "\(t.panel.id)|\(t.label)|\(Int(h.minX / 16))|\(Int(h.minY / 16))|\(Int(h.width / 16))|\(Int(h.height / 16))"
    }



    /// True if you pressed right on one of a window's edges (top-left
    /// screen coordinates for the window, like the press).
    private func onEdge(_ b: CGRect) -> Bool {
        let p = CGPoint(x: pressAt.x, y: primaryHeight - pressAt.y)
        let inY = p.y > b.minY + 8 && p.y < b.maxY - 8
        let inX = p.x > b.minX + 8 && p.x < b.maxX - 8
        return (inY && (abs(p.x - b.minX) < 7 || abs(p.x - b.maxX) < 7))
            || (inX && (abs(p.y - b.minY) < 7 || abs(p.y - b.maxY) < 7))
    }

    /// Pools stay out of sight while dragging, unless you hold Shift.
    private func isQuiet(_ c: Controller) -> Bool {
        c.invisiblePools && !NSEvent.modifierFlags.contains(.shift)
    }

    /// What dropping here would do, the way this drag is showing it.
    private func landing(for c: Controller, at point: CGPoint, dragging id: CGWindowID) -> Controller.DropTarget? {
        isQuiet(c) ? c.dockTarget(at: point, dragging: id, floating: NSEvent.modifierFlags.contains(.command))
                   : c.dropTarget(at: point)
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
        // The pointer had already settled on what's showing (not moved on to a
        // new spot that hadn't had its moment yet).
        let settled = pendingKey == shownKey
        let wasStaged = staged
        dwellTask?.cancel()
        defer {
            candidate = nil
            nearby.removeAll()
            dragging = false
            resizing = false
            trail.removeAll()
            target = nil
            staged = false
            shownKey = ""
            pendingKey = ""
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
            // A resize that started but never took (the pictures went up):
            // they come down with the mouse.
            (source ?? controller).clearEdgeResize()
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
            let fallback = landing(for: dest, at: releasedAt, dragging: c.id)
            if wasStaged, let f = dest.windows.frame(of: id) { dest.stage.cover(draggedAt: f) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                dest.windows.refresh()
                guard dest.windows.exists(id) else {
                    if wasStaged { await DragDock.finishStage(dest, dragged: id, dropped: false) }
                    return
                }
                if !dest.throwWindow(id, from: releasedAt, velocity: v) {
                    if let t = fallback { dest.drop(id, on: t) } else { from.noteManualChange(id) }
                }
                if wasStaged { await DragDock.finishStage(dest, dragged: id, dropped: true) }
            }
            return
        }
        // What you see is what you get: the drop does what the preview was
        // showing, rather than looking again at exactly where you let go (a
        // last twitch onto the Fill pill would otherwise turn a float into a fill).
        let shown = (shownOwner === dest && settled) ? shownTarget : nil
        guard !cancelled, !dest.onSurface, dest.screen.frame.contains(NSEvent.mouseLocation),
              let t = shown ?? landing(for: dest, at: NSEvent.mouseLocation, dragging: c.id) else {
            // Dropped outside the layout or with Option: it stays where you put it,
            // and anything that made room for it goes back.
            dest.endPreview(restore: true)
            from.noteManualChange(c.id)
            if wasStaged {
                let id = c.id
                Task { @MainActor in await DragDock.finishStage(dest, dragged: id, dropped: false) }
            }
            return
        }
        dest.endPreview(restore: false)
        // Moved to another screen's boards: it leaves the boards it came from.
        if from !== dest { from.letGo(of: c.id) }
        // Let the window finish its own move before we place it.
        let id = c.id
        if wasStaged, let f = dest.windows.frame(of: id) { dest.stage.cover(draggedAt: f) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            dest.windows.refresh()
            guard dest.windows.exists(id) else {
                if wasStaged { await DragDock.finishStage(dest, dragged: id, dropped: false) }
                return
            }
            dest.drop(id, on: t)
            if wasStaged { await DragDock.finishStage(dest, dragged: id, dropped: true) }
        }
    }

    /// Ends a drag's stage: on a drop, once the real windows have been sent
    /// to their spots (each picture glides to where its window is going).
    private static func finishStage(_ c: Controller, dragged id: CGWindowID, dropped: Bool) async {
        await c.stage.finish(dropped: dropped, draggedTo: c.windows.target(of: id),
                             targetOf: { c.windows.target(of: $0) },
                             frameOf: { c.windows.frame(of: $0) })
    }

    // MARK: Overlay

    private func showOverlay(for owner: Controller, quiet: Bool) {
        overlayOwner = owner
        overlayQuiet = quiet
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
        v.quiet = quiet
        v.panels = quiet ? [] : owner.dropPanels().map { ($0.panel.id, $0.rect, $0.label) }
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
    /// Pools out of sight: only a soft outline of where the window will land.
    var quiet = false

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1, alpha: 1)
        if quiet {
            // A soft shadow on the spot where it'll land.
            guard let t = target, let spot = DragDock.slot(for: t) else { return }
            let r = local(spot)
            let path = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
            shadow.shadowBlurRadius = 22
            shadow.shadowOffset = .zero
            shadow.set()
            NSColor(white: 0, alpha: 0.30).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 1, alpha: 0.16).setStroke()
            path.lineWidth = 1
            path.stroke()
            // Dropping as a tab: a ghost of the strip of tabs it'll make.
            if let names = t.tabNames, !names.isEmpty, r.height > 60 {
                let strip = CGRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 30)
                NSColor(white: 0.08, alpha: 0.55).setFill()
                NSBezierPath(roundedRect: strip, xRadius: 9, yRadius: 9).fill()
                let gap: CGFloat = 3
                let width = min(220, (strip.width - 6 - gap * CGFloat(names.count - 1)) / CGFloat(names.count))
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                for (i, name) in names.enumerated() {
                    let isNew = i == names.count - 1
                    let chip = CGRect(x: strip.minX + 3 + CGFloat(i) * (width + gap), y: strip.minY + 3,
                                      width: width, height: strip.height - 6)
                    NSColor(white: 1, alpha: isNew ? 0.22 : 0.08).setFill()
                    NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
                    NSAttributedString(string: name, attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: isNew ? .semibold : .regular),
                        .foregroundColor: NSColor(white: 1, alpha: isNew ? 0.95 : 0.65),
                        .paragraphStyle: para,
                    ]).draw(in: CGRect(x: chip.minX + 10, y: chip.midY - 8, width: chip.width - 20, height: 16))
                }
            }
            _ = accent
            return
        }
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
        case .float, .desktop:
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

        case .fill, .newPanel, .dock, .tile, .edge, .tab, .peer:
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
