import AppKit

/// The Overview: every Main side by side, each with all its boards, pools
/// and windows (each window as its app icon and name). Zooming out past Main
/// lands here, and it opens with Hyper + O (or Hyper + F3). Click a board,
/// pool or window, or swipe down over it, and the camera dives into it; Esc
/// closes it.
@MainActor
final class BoardOverview {
    /// The one Scuba is using, for the boards to open and close it.
    static weak var current: BoardOverview?

    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for as long as it's open, so it stays on one screen.
    private var locked: Controller?
    private var window: NSPanel?
    private var view: OverviewView?
    private var keyMonitor: Any?
    private var shown = false

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
        BoardOverview.current = self
    }

    var isOpen: Bool { window != nil && shown }

    /// Open on this screen's boards.
    func isShowing(on c: Controller) -> Bool { isOpen && locked === c }

    /// Everything on the map, as last laid out.
    var items: [Controller.OverviewItem] { view?.items ?? [] }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        _ = prepare(on: pick())
        show()
    }

    /// Lays out the map for a screen's boards, ready to show (not shown
    /// yet). Returns where the Main you're on sits on it.
    @discardableResult
    func prepare(on c: Controller) -> CGRect {
        close()
        locked = c
        let screen = c.screen
        let vf = screen.visibleFrame
        // Every Main side by side, inside 84% of the screen.
        let area = CGRect(x: vf.minX + vf.width * 0.08, y: vf.minY + vf.height * 0.1,
                          width: vf.width * 0.84, height: vf.height * 0.78)
        let laid = c.overviewIslands(in: area)

        let panel = OverviewPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let v = OverviewView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.origin = screen.frame.origin
        v.map = area
        v.items = laid.items
        v.title = c.onSurface ? "All your boards" : "All your boards  ·  you're in \(c.locationLabel())"
        v.hint = "Click a board, pool or window, or swipe down over it, to go there  ·  Esc to close"
        v.onPick = { [weak self] item in
            guard let self else { return }
            self.controller.goFromOverview(item)
        }
        panel.contentView = v
        panel.setFrame(screen.frame, display: false)
        window = panel
        view = v
        shown = false
        return laid.current
    }

    /// A picture of the map as it will look, drawn before it's shown (for
    /// the zoom out to it).
    func picture() -> CGImage? {
        guard let v = view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    /// Shows the map laid out by `prepare`.
    func show() {
        guard let panel = window, let v = view else { return }
        shown = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(v)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {   // Esc
                    self?.close()
                    return nil
                }
                return event
            }
        }
    }

    /// The most specific thing on the map under a point (screen coordinates).
    func item(at point: CGPoint) -> Controller.OverviewItem? {
        view?.itemAt(screenPoint: point)
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
        view = nil
        shown = false
        locked = nil
    }
}

private final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class OverviewView: NSView {
    var origin: CGPoint = .zero
    var map: CGRect = .zero
    var items: [Controller.OverviewItem] = []
    var title = ""
    var hint = "Click a board, pool or window to go there  ·  Esc to close"
    var onPick: ((Controller.OverviewItem?) -> Void)?
    private var hovered: Int?

    // MARK: Editing (the live map)

    /// The live map lets you rearrange the main screen from here: drag a gap
    /// between panels to resize them, drag a window tile to move it (into
    /// another panel too), drag a tile's edge or corner to resize it.
    var editable = false
    var dividers: [Controller.Divider] = []
    var onEditBegan: (() -> Void)?
    var onMoveDivider: ((Controller.Divider, CGPoint) -> Void)?
    var onEditEnded: (() -> Void)?
    var onPlaceWindow: ((UInt32, UUID, CGRect) -> Void)?
    /// Moving or resizing a window within its own panel: the main screen follows as you drag.
    var onDragWindow: ((UInt32, UUID, CGRect) -> Void)?

    private struct Edges { var left = false, right = false, bottom = false, top = false
        var any: Bool { left || right || bottom || top } }
    private enum Drag {
        case divider(Controller.Divider)
        case window(index: Int, edges: Edges, start: CGRect)   // no edges = moving it
        case click(Controller.OverviewItem?)
    }
    private var drag: Drag?
    private var downAt = CGPoint.zero          // screen coordinates
    private var moved = false
    private var dragRect: CGRect?              // the tile being dragged, as it is now
    private var dropPanel: Int?                // the panel it would land in
    private var hoverDivider: Controller.Divider?

    /// True while the mouse is down on a window tile: the map keeps its
    /// items as they are until it's let go.
    var isHoldingTile: Bool {
        if case .window = drag { return true }
        return false
    }

    private func same(_ a: Controller.Divider?, _ b: Controller.Divider) -> Bool {
        guard let a else { return false }
        return a.split === b.split && a.index == b.index
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + origin.x, y: p.y + origin.y)
    }

    private func divider(at sp: CGPoint) -> Controller.Divider? {
        dividers.first { d in
            d.axis == .h
                ? abs(sp.x - d.position) <= 5 && sp.y >= d.frame.minY && sp.y <= d.frame.maxY
                : abs(sp.y - d.position) <= 5 && sp.x >= d.frame.minX && sp.x <= d.frame.maxX
        }
    }

    /// The front-most window tile under a point, and which of its edges are close.
    private func windowTile(at sp: CGPoint) -> (index: Int, edges: Edges)? {
        var best: Int?
        for (i, it) in items.enumerated() where it.kind == .window && it.rect.contains(sp) {
            if best == nil || it.depth >= items[best!].depth { best = i }
        }
        guard let i = best else { return nil }
        let r = items[i].rect
        let gx = min(10, r.width / 4), gy = min(10, r.height / 4)
        var e = Edges()
        e.left = sp.x - r.minX < gx
        e.right = r.maxX - sp.x < gx
        e.bottom = sp.y - r.minY < gy
        e.top = r.maxY - sp.y < gy
        return (i, e)
    }

    /// A tile's rectangle as a share of a panel (how floating windows are saved).
    private func relative(_ r: CGRect, inPanel k: Int) -> CGRect {
        let inner = items[k].rect.insetBy(dx: 3, dy: 3)
        return CGRect(x: (r.minX - inner.minX) / inner.width, y: (r.minY - inner.minY) / inner.height,
                      width: r.width / inner.width, height: r.height / inner.height)
    }

    private func tileRect(_ i: Int) -> CGRect {
        if case .window(let index, _, _) = drag, index == i, let r = dragRect { return r }
        return items[i].rect
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    /// The most specific thing under a point given in screen coordinates.
    func itemAt(screenPoint sp: CGPoint) -> Controller.OverviewItem? {
        item(at: CGPoint(x: sp.x - origin.x, y: sp.y - origin.y)).map { items[$0] }
    }

    /// The most specific thing under a point: a window, else a panel, else a board.
    private func item(at p: CGPoint) -> Int? {
        let screenPoint = CGPoint(x: p.x + origin.x, y: p.y + origin.y)
        let rank: (Controller.OverviewItem.Kind) -> Int = { $0 == .window ? 3 : ($0 == .panel ? 2 : 1) }
        var best: Int?
        for (i, it) in items.enumerated() where it.rect.contains(screenPoint) {
            guard let b = best else { best = i; continue }
            let a = items[b]
            if (it.depth, rank(it.kind)) > (a.depth, rank(a.kind)) { best = i }
        }
        return best
    }

    override func mouseMoved(with event: NSEvent) {
        let h = item(at: convert(event.locationInWindow, from: nil))
        if h != hovered {
            hovered = h
            needsDisplay = true
        }
        guard editable else { return }
        // Show what a drag here would do.
        let sp = screenPoint(event)
        let d = divider(at: sp)
        if (d == nil) != (hoverDivider == nil) || (d != nil && !same(hoverDivider, d!)) {
            hoverDivider = d
            needsDisplay = true
        }
        if let d {
            (d.axis == .h ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else if let t = windowTile(at: sp) {
            if t.edges.left || t.edges.right { NSCursor.resizeLeftRight.set() }
            else if t.edges.top || t.edges.bottom { NSCursor.resizeUpDown.set() }
            else { NSCursor.openHand.set() }
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard editable else {
            if let i = item(at: p) {
                onPick?(items[i])
            } else {
                onPick?(nil)   // clicked outside the map: just close
            }
            return
        }
        let sp = screenPoint(event)
        downAt = sp
        moved = false
        dragRect = nil
        dropPanel = nil
        if let d = divider(at: sp) {
            drag = .divider(d)
        } else if let t = windowTile(at: sp) {
            drag = .window(index: t.index, edges: t.edges, start: items[t.index].rect)
        } else {
            drag = .click(item(at: p).map { items[$0] })
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard editable, let current = drag else { return }
        let sp = screenPoint(event)
        let dx = sp.x - downAt.x, dy = sp.y - downAt.y
        if !moved {
            guard abs(dx) + abs(dy) > 3 else { return }
            moved = true
            if case .click = current { return }
            onEditBegan?()
        }
        switch current {
        case .divider(let d):
            onMoveDivider?(d, sp)
        case .window(let i, let e, let start):
            var r = start
            if e.any {
                // Drag the edges you grabbed; the opposite ones stay put.
                let least: CGFloat = 24
                if e.left {
                    r.origin.x = min(start.minX + dx, start.maxX - least)
                    r.size.width = start.maxX - r.minX
                }
                if e.right { r.size.width = max(least, start.width + dx) }
                if e.bottom {
                    r.origin.y = min(start.minY + dy, start.maxY - least)
                    r.size.height = start.maxY - r.minY
                }
                if e.top { r.size.height = max(least, start.height + dy) }
            } else {
                r = start.offsetBy(dx: dx, dy: dy)
                NSCursor.closedHand.set()
            }
            dragRect = r
            // The panel it would land in: the deepest one under its middle.
            let mid = CGPoint(x: r.midX, y: r.midY)
            dropPanel = items.indices.filter { items[$0].kind == .panel && items[$0].rect.contains(mid) }
                .max { items[$0].depth < items[$1].depth }
            // Still in its own panel: the real window follows along.
            if let k = dropPanel, let panel = items[k].panel, panel == items[i].panel, let w = items[i].window {
                onDragWindow?(w, panel, relative(r, inPanel: k))
            }
        case .click:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard editable, let current = drag else { return }
        drag = nil
        defer { dragRect = nil; dropPanel = nil; needsDisplay = true; NSCursor.arrow.set() }
        switch current {
        case .click(let item):
            if let item, !moved { onPick?(item) }
        case .divider:
            if moved { onEditEnded?() }
        case .window(let i, _, _):
            guard moved else { onPick?(items[i]); return }   // a plain click: go there
            guard let r = dragRect, let target = dropPanel,
                  let panel = items[target].panel, let w = items[i].window else {
                onEditEnded?()   // dropped outside every panel: it stays put
                return
            }
            onPlaceWindow?(w, panel, relative(r, inPanel: target))
            onEditEnded?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.04, alpha: 0.86).setFill()
        bounds.fill()

        let accent = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: NSColor = .white, in r: CGRect) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]
            let t = NSAttributedString(string: s, attributes: attrs)
            let h = t.size().height
            t.draw(in: CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h))
        }

        let mapRect = local(map)
        text(title, size: 22, weight: .semibold, in: CGRect(x: 0, y: mapRect.maxY + 18, width: bounds.width, height: 30))
        text(hint,
             size: 14, color: NSColor(white: 1, alpha: 0.6),
             in: CGRect(x: 0, y: mapRect.minY - 40, width: bounds.width, height: 22))

        // Panels first (faint), then boards (outlines on top), then windows.
        for (i, it) in items.enumerated() where it.kind == .panel {
            let r = local(it.rect).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            let landing = i == dropPanel
            (landing ? accent.withAlphaComponent(0.22) : NSColor(white: 1, alpha: i == hovered ? 0.14 : 0.05)).setFill()
            path.fill()
            (landing ? accent : NSColor(white: 1, alpha: 0.25)).setStroke()
            path.lineWidth = landing ? 2 : 1
            path.stroke()
            if r.height > 30 {
                text(it.label, size: 11, color: NSColor(white: 1, alpha: 0.45),
                     in: CGRect(x: r.minX, y: r.maxY - 18, width: r.width, height: 14))
            }
        }
        for (i, it) in items.enumerated() where it.kind == .board {
            let r = local(it.rect).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            if i == hovered {
                accent.withAlphaComponent(0.12).setFill()
                path.fill()
            }
            (it.isCurrent ? accent : NSColor(white: 1, alpha: 0.6)).setStroke()
            path.lineWidth = it.isCurrent ? 3 : 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
            let tag = "  " + it.label + (it.isCurrent ? "  ·  you are here" : "") + "  "
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: it.isCurrent ? accent : NSColor.white,
            ]
            NSAttributedString(string: tag, attributes: attrs).draw(at: CGPoint(x: r.minX + 6, y: r.maxY - 18))
        }
        // The gaps you can drag, when editing.
        if editable {
            for d in dividers {
                let line = NSBezierPath()
                if d.axis == .h {
                    line.move(to: CGPoint(x: d.position - origin.x, y: d.frame.minY - origin.y + 6))
                    line.line(to: CGPoint(x: d.position - origin.x, y: d.frame.maxY - origin.y - 6))
                } else {
                    line.move(to: CGPoint(x: d.frame.minX - origin.x + 6, y: d.position - origin.y))
                    line.line(to: CGPoint(x: d.frame.maxX - origin.x - 6, y: d.position - origin.y))
                }
                var active = false
                if case .divider(let held) = drag, same(held, d) { active = true }
                let hover = drag == nil && same(hoverDivider, d)
                (active ? accent : NSColor(white: 1, alpha: hover ? 0.6 : 0.18)).setStroke()
                line.lineWidth = active || hover ? 4 : 2
                line.lineCapStyle = .round
                line.stroke()
            }
        }
        var heldIndex: Int?
        if case .window(let index, _, _) = drag, dragRect != nil { heldIndex = index }
        func drawTile(_ i: Int) {
            let it = items[i]
            let r = local(tileRect(i)).insetBy(dx: 3, dy: 3)
            guard r.width > 6, r.height > 6 else { return }
            let held = i == heldIndex
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            (held ? accent.withAlphaComponent(0.45)
                  : (i == hovered ? accent.withAlphaComponent(0.35) : NSColor(white: 1, alpha: 0.12))).setFill()
            path.fill()
            (held || i == hovered ? accent : NSColor(white: 1, alpha: 0.35)).setStroke()
            path.lineWidth = held || i == hovered ? 2 : 1
            path.stroke()
            let iconSize = max(12, min(48, min(r.width, r.height) * 0.45))
            if let icon = it.icon {
                icon.draw(in: CGRect(x: r.midX - iconSize / 2, y: r.midY - iconSize / 2 + 6,
                                     width: iconSize, height: iconSize))
            }
            if r.height > iconSize + 24 {
                text(it.label, size: 11, in: CGRect(x: r.minX + 4, y: r.midY - iconSize / 2 - 14,
                                                    width: r.width - 8, height: 14))
            }
        }
        // Windows, with the one being dragged drawn on top of the rest.
        for (i, it) in items.enumerated() where it.kind == .window && i != heldIndex { drawTile(i) }
        if let heldIndex, heldIndex < items.count { drawTile(heldIndex) }
    }
}


// MARK: - Live map (a second screen)

/// A second screen set to "Live map": it always shows the board one level
/// above where you are on the main screen (all your boards when you're at the
/// top or on your desktop), with your spot lit up, and follows you as you
/// dive and rise. Click a board, panel or window on it to go there. It sits
/// below app windows, so anything you put on that screen stays on top.
@MainActor
final class LiveMap {
    let displayID: CGDirectDisplayID
    private let source: () -> Controller?
    private var window: NSPanel?
    private var view: OverviewView?

    /// Edits made on the map reach the main screen at most this often while
    /// you drag (moving real windows takes a moment), and once more when you let go.
    private let editInterval: TimeInterval = 0.04
    private var pendingEdit: ((Controller) -> Void)?
    private var editTask: Task<Void, Never>?
    private var lastEdit = Date.distantPast

    init(displayID: CGDirectDisplayID, source: @escaping () -> Controller?) {
        self.displayID = displayID
        self.source = source
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { Controller.displayID(of: $0) == displayID }
    }

    func refresh() {
        guard let c = source(), let screen else { hide(); return }
        // A window tile is in your hand: leave the map as it is until you let go.
        if view?.isHoldingTile == true { return }
        if window == nil {
            let w = OverviewPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            // Behind every app window on that screen.
            w.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = OverviewView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.onPick = { [weak self] item in
                guard let item, let c = self?.source() else { return }
                c.jump(to: item.path, panel: item.panel, window: item.window)
            }
            // Editing: the map is a hands-on view of the main screen's layout.
            v.editable = true
            v.onEditBegan = { [weak self] in
                self?.source()?.checkpoint()   // so Hyper + Z undoes it
            }
            v.onMoveDivider = { [weak self] d, p in
                guard let self, let c = self.source() else { return }
                c.moveDivider(d, to: p)
                self.refresh()                           // the map follows at once,
                self.soon { $0.liveLayout() }            // the main screen right behind it
            }
            v.onDragWindow = { [weak self] w, panel, rel in
                guard let self else { return }
                self.soon { $0.placeWindow(w, inPanel: panel, at: rel) }
            }
            v.onPlaceWindow = { [weak self] w, panel, rel in
                guard let self, let c = self.source() else { return }
                self.cancelEdit()
                c.placeWindow(w, inPanel: panel, at: rel)
            }
            v.onEditEnded = { [weak self] in
                guard let self else { return }
                self.editTask?.cancel()
                self.editTask = nil
                self.flushEdit()
                if let c = self.source(), !c.isBusy { c.applyLayout() }   // the full layout, once you let go
                self.refresh()
            }
            w.contentView = v
            window = w
            view = v
        }
        let vf = screen.visibleFrame
        let map = CGRect(x: vf.minX + vf.width * 0.06, y: vf.minY + vf.height * 0.1,
                         width: vf.width * 0.88, height: vf.height * 0.78)
        let path = c.state.path
        let top: [UUID] = c.onSurface || path.isEmpty ? [] : Array(path.dropLast())
        window?.setFrame(screen.frame, display: false)
        view?.frame = CGRect(origin: .zero, size: screen.frame.size)
        view?.origin = screen.frame.origin
        view?.map = map
        view?.items = c.overviewItems(in: map, from: top)
        view?.dividers = c.mapDividers(in: map, from: top)
        if c.onSurface {
            view?.title = "Your boards  ·  you're on your desktop"
        } else if path.isEmpty {
            view?.title = "You're on Main"
        } else {
            view?.title = "One level up: \(c.locationLabel(top))   ·   you're in \(c.locationLabel())"
        }
        view?.hint = "Live map  ·  click to go there  ·  drag a gap to resize pools  ·  "
            + "drag a window to move it, its edges to resize it  ·  ⌃⌥⌘Z undoes"
        view?.needsDisplay = true
        window?.orderFront(nil)
    }

    func hide() {
        cancelEdit()
        window?.orderOut(nil)
    }

    // MARK: Edits, paced

    /// Runs an edit on the main screen soon: right away if there hasn't been
    /// one for a moment, otherwise as soon as the interval is up. Only the
    /// latest edit runs; earlier ones it replaces are skipped.
    private func soon(_ edit: @escaping (Controller) -> Void) {
        pendingEdit = edit
        guard editTask == nil else { return }
        let wait = max(0, editInterval - Date().timeIntervalSince(lastEdit))
        editTask = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.editTask = nil
            self.flushEdit()
        }
    }

    private func flushEdit() {
        guard let edit = pendingEdit, let c = source() else { return }
        pendingEdit = nil
        guard !c.isBusy else { return }   // mid-flight: the layout lands when it does
        lastEdit = Date()
        edit(c)
    }

    private func cancelEdit() {
        editTask?.cancel()
        editTask = nil
        pendingEdit = nil
    }
}
