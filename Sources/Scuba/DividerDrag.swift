import AppKit
import ApplicationServices

/// Hyper + drag on the gap between panels resizes them.
///
/// Uses an event tap (allowed by the Accessibility permission) so the click
/// can be swallowed instead of also reaching the app or desktop underneath.
@MainActor
final class DividerDrag {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    fileprivate var tap: CFMachPort?
    private var active: Controller.Divider?

    private var overlay: NSWindow?
    private var view: DividerView?

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
                                          callback: dividerTapCallback,
                                          userInfo: refcon) else {
            NSLog("Scuba: couldn't watch the mouse for divider dragging (needs Accessibility)")
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
            let hyper = flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
            guard hyper, AXIsProcessTrusted(), !controller.onSurface else { return false }
            let p = appKitPoint(location)
            let c = pick()
            guard let d = c.divider(near: p, tolerance: 24) else { return false }
            locked = c
            controller.checkpoint()
            active = d
            showOverlay()
            update(p)
            return true

        case .leftMouseDragged:
            guard active != nil else { return false }
            update(appKitPoint(location))
            return true

        case .leftMouseUp:
            guard active != nil else { return false }
            active = nil
            hideOverlay()
            controller.applyLayout()
            locked = nil
            return true

        default:
            return false
        }
    }

    private var lastLive = Date.distantPast

    private func update(_ p: CGPoint) {
        guard let d = active else { return }
        controller.moveDivider(d, to: p)
        // The windows follow the gap as you drag.
        if Date().timeIntervalSince(lastLive) > 1.0 / 40 {
            lastLive = Date()
            controller.liveLayout()
        }
        view?.panels = controller.dropPanels().map { ($0.rect, $0.label) }
        view?.dividers = controller.dividers()
        view?.activeSplit = d.split.id
        view?.activeIndex = d.index
        view?.needsDisplay = true
    }

    // MARK: Overlay

    private func showOverlay() {
        let screen = controller.screen
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = DividerView(frame: CGRect(origin: .zero, size: screen.frame.size))
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
/// DividerDrag that registered it. The tap runs on the main run loop.
private func dividerTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<DividerDrag>.fromOpaque(refcon).takeUnretainedValue()
    let location = event.location
    let flags = event.flags
    let swallow = MainActor.assumeIsolated {
        owner.handle(type, at: location, flags: flags)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

private final class DividerView: NSView {
    var origin: CGPoint = .zero
    var panels: [(rect: CGRect, label: String)] = []
    var dividers: [Controller.Divider] = []
    var activeSplit: UUID?
    var activeIndex = -1

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.25).setFill()
        bounds.fill()

        let accent = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        for p in panels {
            let r = local(p.rect).insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.5).setStroke()
            path.lineWidth = 2
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.6),
                .paragraphStyle: para,
            ]
            let text = NSAttributedString(string: p.label, attributes: attrs)
            let h = text.size().height
            text.draw(in: CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h))
        }

        for d in dividers {
            let isActive = d.split.id == activeSplit && d.index == activeIndex
            let line = NSBezierPath()
            if d.axis == .h {
                let x = d.position - origin.x
                line.move(to: CGPoint(x: x, y: d.frame.minY - origin.y))
                line.line(to: CGPoint(x: x, y: d.frame.maxY - origin.y))
            } else {
                let y = d.position - origin.y
                line.move(to: CGPoint(x: d.frame.minX - origin.x, y: y))
                line.line(to: CGPoint(x: d.frame.maxX - origin.x, y: y))
            }
            line.lineWidth = isActive ? 6 : 2
            (isActive ? NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 1) : accent.withAlphaComponent(0.7)).setStroke()
            line.stroke()
        }
    }
}
