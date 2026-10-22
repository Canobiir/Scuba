import AppKit
import ApplicationServices

/// Hold Cmd + Shift and drag a box over part of the board: the camera
/// frames the smallest part of the board that holds it (a tile, a group of
/// tiles, or the Desktop), the way you'd zoom into a picture. Escape-free:
/// a box too small to mean anything is ignored.
///
/// Uses an event tap (allowed by the Accessibility permission) so the drag
/// goes to Scuba instead of the app underneath.
@MainActor
final class FrameDrag {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    /// Held for the length of one drag, so it stays on one screen.
    private var locked: Controller?
    fileprivate var tap: CFMachPort?
    private var anchor: CGPoint?
    private var overlay: NSWindow?
    private var view: FrameView?

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
    }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: frameTapCallback,
                                          userInfo: refcon) else {
            NSLog("Scuba: couldn't watch the mouse for framing (needs Accessibility)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Converts event-tap coordinates (top-left origin) to AppKit's (bottom-left).
    private func appKitPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Returns true to swallow the event.
    fileprivate func handle(_ type: CGEventType, at location: CGPoint, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .leftMouseDown:
            // Cmd + Shift only (not Hyper, which has its own drags).
            let wanted = flags.contains(.maskCommand) && flags.contains(.maskShift)
                && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
            let c = pick()
            guard wanted, c.frameDrag, AXIsProcessTrusted(), !c.onSurface, !c.isBusy else { return false }
            locked = c
            let p = appKitPoint(location)
            anchor = p
            showOverlay(on: c.screen)
            update(p)
            return true

        case .leftMouseDragged:
            guard anchor != nil else { return false }
            update(appKitPoint(location))
            return true

        case .leftMouseUp:
            guard let s = anchor, let c = locked else { return false }
            let rect = box(from: s, to: appKitPoint(location))
            anchor = nil
            locked = nil
            hideOverlay()
            if rect.width > 24, rect.height > 24 { c.frameZoom(to: rect) }
            return true

        default:
            return false
        }
    }

    private func box(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func update(_ p: CGPoint) {
        guard let s = anchor, let c = locked else { return }
        let r = box(from: s, to: p)
        view?.box = r
        view?.target = c.frameTarget(for: r)
        view?.needsDisplay = true
    }

    // MARK: Overlay

    private func showOverlay(on screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = FrameView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.origin = screen.frame.origin
        w.contentView = v
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        overlay = w
        view = v
    }

    private func hideOverlay() {
        overlay?.orderOut(nil)
        overlay = nil
        view = nil
    }
}

/// Event tap callbacks are plain C functions; this hands the event to the
/// FrameDrag that registered it. The tap runs on the main run loop.
private func frameTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<FrameDrag>.fromOpaque(refcon).takeUnretainedValue()
    let location = event.location
    let flags = event.flags
    let swallow = MainActor.assumeIsolated {
        owner.handle(type, at: location, flags: flags)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// The box you're drawing, and (faintly) the part of the board it'll frame.
private final class FrameView: NSView {
    var origin: CGPoint = .zero
    var box: CGRect = .zero
    var target: CGRect?

    override func draw(_ dirtyRect: NSRect) {
        // What becomes the room: the same soft pane as a drop's landing spot,
        // with a small "New room" label along its top.
        if let t = target {
            let r = t.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = .zero
            shadow.set()
            NSColor(white: 1, alpha: 0.10).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 1, alpha: 0.28).setStroke()
            path.lineWidth = 1
            path.stroke()
            let text = NSAttributedString(string: "New room", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.9),
            ])
            let size = text.size()
            let pill = CGRect(x: r.midX - size.width / 2 - 12, y: r.maxY - size.height - 18,
                              width: size.width + 24, height: size.height + 8)
            NSColor(white: 0.08, alpha: 0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            text.draw(at: CGPoint(x: pill.minX + 12, y: pill.minY + 4))
        }
        let b = box.offsetBy(dx: -origin.x, dy: -origin.y)
        let path = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
        NSColor(white: 1, alpha: 0.05).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.5).setStroke()
        path.lineWidth = 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}
