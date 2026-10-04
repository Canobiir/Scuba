import AppKit

/// What the lobby shows: the way back up, a little map of the board above
/// with your spot on it, and doors to the neighbouring boards.
struct LobbyModel {
    struct Door {
        let id: UUID
        let title: String
        let apps: String
        let icons: [NSImage]
        let isHere: Bool
    }
    struct Cell {
        let rect: CGRect      // 0–1 within the map, y up
        let door: UUID
        let isHere: Bool
        let label: String
    }
    let rect: CGRect          // the empty panel it lives in (AppKit screen coordinates)
    let upLabel: String       // the board above, e.g. "Main"
    let here: String          // where you are, e.g. "Main › Work"
    let doors: [Door]         // every board on this level, in order (yours included)
    let map: [Cell]
    let mapAspect: CGFloat    // height / width of the board above
    let emptyBoard: Bool      // the whole board is empty (the room is all of it)
}

/// The breathing-room panel, when empty, becomes a lobby: a calm spot that
/// shows where you can go from here. It sits just above the desktop and below
/// every app window, and doesn't take focus from the app you're using.
@MainActor
final class Lobby {
    private var window: NSPanel?
    private var view: LobbyView?
    var onUp: (() -> Void)?
    var onDoor: ((UUID) -> Void)?

    func show(_ model: LobbyModel?) {
        guard let model else { hide(); return }
        if window == nil {
            let w = NSPanel(contentRect: model.rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            // Above the desktop, its icons and widgets; below every app window.
            w.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = LobbyView(frame: CGRect(origin: .zero, size: model.rect.size))
            v.onUp = { [weak self] in self?.onUp?() }
            v.onDoor = { [weak self] id in self?.onDoor?(id) }
            w.contentView = v
            window = w
            view = v
        }
        window?.setFrame(model.rect, display: false)
        view?.frame = CGRect(origin: .zero, size: model.rect.size)
        view?.model = model
        view?.needsDisplay = true
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

private final class LobbyView: NSView {
    var model: LobbyModel? { didSet { hovered = nil } }
    var onUp: (() -> Void)?
    var onDoor: ((UUID) -> Void)?

    private enum Target: Equatable { case up, door(UUID) }
    private var hovered: Target?

    // Layout, worked out on every draw and used for clicks too.
    private struct Layout {
        var col: CGRect = .zero        // the column everything sits in
        var backing: CGRect?           // a soft card behind it, in a big room
        var emptyNoteY: CGFloat?
        var up: CGRect = .zero
        var upText = ""
        var hereY: CGFloat = 0
        var map: CGRect?
        var doorsTitleY: CGFloat?
        var cards: [(rect: CGRect, door: LobbyModel.Door, compact: Bool)] = []
        var more = 0
        var hint: CGRect?
    }

    private let pad: CGFloat = 18
    private let ink = NSColor(white: 1, alpha: 0.92)
    private let quiet = NSColor(white: 1, alpha: 0.62)
    private let accent = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1, alpha: 1)

    override var isFlipped: Bool { true }   // lay out top-down
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func width(_ s: String, _ f: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: f]).width
    }

    private func computeLayout() -> Layout {
        var L = Layout()
        guard let m = model else { return L }
        // A column at most 360 wide. In a narrow room (breathing room) it fills
        // the room; in a big one (a whole empty board) it's a centred card.
        let avail = bounds.insetBy(dx: pad, dy: pad)
        let colW = min(avail.width, 360)
        let big = avail.width > colW + 80
        let colH = big ? min(avail.height - 40, 560) : avail.height
        let inner = CGRect(x: big ? avail.midX - colW / 2 : avail.minX,
                           y: big ? avail.midY - colH / 2 : avail.minY,
                           width: colW, height: colH)
        L.col = inner
        if big { L.backing = inner.insetBy(dx: -22, dy: -22) }
        var y = inner.minY

        // ↑ the way back up
        L.upText = "↑  " + m.upLabel
        let upW = min(inner.width, width(L.upText, font(13, .semibold)) + 28)
        L.up = CGRect(x: inner.minX, y: y, width: upW, height: 30)
        y += 30 + 18

        // You're in …
        L.hereY = y
        y += 40
        if m.emptyBoard {
            L.emptyNoteY = y
            y += 44
        }

        // The map of the board above, when there's room for it.
        let others = m.doors.filter { !$0.isHere }
        let cardsNeed = CGFloat(max(others.count, 1)) * 50 + 30
        let mapH = min(150, inner.width * m.mapAspect)
        if !m.map.isEmpty, inner.maxY - y - mapH - 24 > cardsNeed + 40 {
            L.map = CGRect(x: inner.minX, y: y, width: mapH / m.mapAspect, height: mapH)
            y += mapH + 22
        }

        // Doors to the other boards on this level.
        if !others.isEmpty {
            L.doorsTitleY = y
            y += 22
            let hintH: CGFloat = 36
            let room = inner.maxY - y - hintH - 8
            let full: CGFloat = 60, compact: CGFloat = 40, gap: CGFloat = 8
            let useFull = CGFloat(others.count) * (full + gap) <= room
            let h = useFull ? full : compact
            let fits = max(0, Int((room + gap) / (h + gap)))
            let shown = others.count <= fits ? others.count : max(0, fits - 1)
            for door in others.prefix(shown) {
                L.cards.append((CGRect(x: inner.minX, y: y, width: inner.width, height: h), door, !useFull))
                y += h + gap
            }
            L.more = others.count - shown
            if L.more > 0 { y += 18 }
        }

        // A quiet hint at the bottom.
        let hintRect = CGRect(x: inner.minX, y: inner.maxY - 34, width: inner.width, height: 34)
        if hintRect.minY > y { L.hint = hintRect }
        return L
    }

    // MARK: Drawing

    private func text(_ s: String, _ f: NSFont, _ color: NSColor, in r: CGRect,
                      align: NSTextAlignment = .left, shadow: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: para]
        if shadow {
            let sh = NSShadow()
            sh.shadowColor = NSColor(white: 0, alpha: 0.6)
            sh.shadowBlurRadius = 4
            sh.shadowOffset = NSSize(width: 0, height: -1)
            attrs[.shadow] = sh
        }
        (s as NSString).draw(in: r, withAttributes: attrs)
    }

    private func card(_ r: CGRect, radius: CGFloat, hot: Bool) {
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor(white: 0.08, alpha: hot ? 0.72 : 0.5).setFill()
        path.fill()
        (hot ? accent.withAlphaComponent(0.8) : NSColor(white: 1, alpha: 0.16)).setStroke()
        path.lineWidth = hot ? 1.5 : 1
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model else { return }
        let L = computeLayout()
        let x0 = L.col.minX, cw = L.col.width

        if let b = L.backing {
            let path = NSBezierPath(roundedRect: b, xRadius: 20, yRadius: 20)
            NSColor(white: 0.06, alpha: 0.42).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.12).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // ↑ Main
        card(L.up, radius: 15, hot: hovered == .up)
        text(L.upText, font(13, .semibold), ink, in: L.up.insetBy(dx: 14, dy: 6))

        // You're in …
        text("YOU'RE IN", font(10.5, .semibold), quiet,
             in: CGRect(x: x0, y: L.hereY, width: cw, height: 14), shadow: true)
        text(m.here, font(15, .semibold), ink,
             in: CGRect(x: x0, y: L.hereY + 15, width: cw, height: 20), shadow: true)
        if let ny = L.emptyNoteY {
            text("This board is empty. Drag a window here,\nor Hyper + N to split it into pools.",
                 font(12), quiet, in: CGRect(x: x0, y: ny, width: cw, height: 34), shadow: true)
        }

        // The map of the board above.
        if let map = L.map {
            card(map.insetBy(dx: -6, dy: -6), radius: 10, hot: false)
            for c in m.map {
                // Map cells are stored y-up; this view is flipped.
                let r = CGRect(x: map.minX + c.rect.minX * map.width,
                               y: map.minY + (1 - c.rect.maxY) * map.height,
                               width: c.rect.width * map.width, height: c.rect.height * map.height)
                    .insetBy(dx: 1.5, dy: 1.5)
                let hot = hovered == .door(c.door)
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                if c.isHere {
                    accent.withAlphaComponent(0.35).setFill()
                    path.fill()
                    accent.setStroke()
                    path.lineWidth = 2
                } else {
                    NSColor(white: 1, alpha: hot ? 0.28 : 0.1).setFill()
                    path.fill()
                    NSColor(white: 1, alpha: hot ? 0.8 : 0.35).setStroke()
                    path.lineWidth = 1
                }
                path.stroke()
                if r.width > 26, r.height > 16 {
                    text(c.label, font(10.5, c.isHere ? .bold : .medium), c.isHere ? .white : ink,
                         in: CGRect(x: r.minX + 2, y: r.midY - 7, width: r.width - 4, height: 14), align: .center)
                }
            }
        }

        // Doors.
        if let ty = L.doorsTitleY {
            text("OTHER BOARDS HERE", font(10.5, .semibold), quiet,
                 in: CGRect(x: x0, y: ty, width: cw, height: 14), shadow: true)
        }
        for (r, door, compact) in L.cards {
            let hot = hovered == .door(door.id)
            card(r, radius: 12, hot: hot)
            let icon: CGFloat = compact ? 22 : 28
            var x = r.minX + 12
            for (i, img) in door.icons.prefix(3).enumerated() {
                img.draw(in: CGRect(x: x + CGFloat(i) * (icon * 0.62), y: r.midY - icon / 2, width: icon, height: icon),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if !door.icons.isEmpty { x += icon + CGFloat(min(door.icons.count, 3) - 1) * icon * 0.62 + 10 }
            let textW = r.maxX - 26 - x
            if compact {
                text(door.title, font(13, .semibold), ink, in: CGRect(x: x, y: r.midY - 9, width: textW, height: 18))
            } else {
                text(door.title, font(13, .semibold), ink, in: CGRect(x: x, y: r.minY + 12, width: textW, height: 18))
                text(door.apps, font(11.5), quiet, in: CGRect(x: x, y: r.minY + 31, width: textW, height: 16))
            }
            text("›", font(18, .medium), hot ? accent : quiet, in: CGRect(x: r.maxX - 22, y: r.midY - 12, width: 14, height: 22))
        }
        if L.more > 0, let last = L.cards.last {
            text("+\(L.more) more  ·  Hyper + O for the full map", font(11), quiet,
                 in: CGRect(x: x0, y: last.rect.maxY + 6, width: cw, height: 14), shadow: true)
        }

        // Hint.
        if let h = L.hint {
            text("Hyper + swipe sideways or Hyper + [ ] to step through.\nDrop a window here to keep this space.",
                 font(11), quiet, in: h, shadow: true)
        }
    }

    // MARK: Mouse

    private func target(at p: CGPoint) -> Target? {
        let L = computeLayout()
        if L.up.contains(p) { return .up }
        for (r, door, _) in L.cards where r.contains(p) { return .door(door.id) }
        if let map = L.map, let m = model {
            for c in m.map where !c.isHere {
                let r = CGRect(x: map.minX + c.rect.minX * map.width,
                               y: map.minY + (1 - c.rect.maxY) * map.height,
                               width: c.rect.width * map.width, height: c.rect.height * map.height)
                if r.contains(p) { return .door(c.door) }
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let t = target(at: convert(event.locationInWindow, from: nil))
        if t != hovered {
            hovered = t
            needsDisplay = true
            if t != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        switch target(at: convert(event.locationInWindow, from: nil)) {
        case .up: onUp?()
        case .door(let id): onDoor?(id)
        case nil: break
        }
    }
}
