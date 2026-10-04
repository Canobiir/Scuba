import AppKit

/// Small transient message in the lower middle of the screen.
@MainActor
enum Toast {
    private static var window: NSWindow?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, seconds: Double = 1.1) {
        // On the screen you're looking at (the one under the pointer).
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first
        else { return }
        window?.orderOut(nil)
        hideTask?.cancel()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 520
        label.sizeToFit()

        let pad: CGFloat = 18
        let size = CGSize(width: label.frame.width + pad * 2, height: label.frame.height + pad * 1.4)
        let vf = screen.visibleFrame
        let frame = CGRect(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.18,
                           width: size.width, height: size.height)

        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let box = NSView(frame: CGRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
        box.layer?.cornerRadius = 12
        label.frame.origin = CGPoint(x: pad, y: (size.height - label.frame.height) / 2)
        box.addSubview(label)
        w.contentView = box
        w.alphaValue = 1
        w.orderFrontRegardless()
        window = w

        hideTask = fadeOut(w, after: seconds)
    }
}

/// Fades a window out after a delay; cancel the task to keep it up.
@MainActor
func fadeOut(_ w: NSWindow, after seconds: Double) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 0
        }
        guard !Task.isCancelled else { return }
        w.orderOut(nil)
    }
}

/// One panel to draw on the numbers overlay.
struct PanelMark {
    let rect: CGRect      // AppKit screen coordinates
    let label: String     // e.g. "2" or "2 › 1"
    let apps: String
    let nested: Bool      // belongs to a desktop nested inside a panel
    let active: Bool
    var container = false // holds a nested desktop: outline + corner label only
}

/// Briefly shows the panel numbers on top of everything.
@MainActor
final class NumbersOverlay {
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    /// Pass `seconds: nil` to keep it up until `hide()`.
    func show(_ marks: [PanelMark], title: String, on screen: NSScreen, seconds: Double? = 1.3) {
        hideTask?.cancel()
        window?.orderOut(nil)

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = MarksView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.marks = marks.map { m in
            PanelMark(rect: m.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                      label: m.label, apps: m.apps, nested: m.nested, active: m.active,
                      container: m.container)
        }
        view.title = title
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        w.alphaValue = 1
        w.orderFrontRegardless()
        window = w

        if let seconds { hideTask = fadeOut(w, after: seconds) }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        window?.orderOut(nil)
        window = nil
    }
}

private final class MarksView: NSView {
    var marks: [PanelMark] = []
    var title = ""

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.22).setFill()
        bounds.fill()

        let accent = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1, alpha: 1)

        let para = NSMutableParagraphStyle()
        para.alignment = .center

        // Containers first, as outlines with a small corner label, so the
        // panels inside them keep the middle to themselves.
        for m in marks where m.container {
            let r = m.rect.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            (m.active ? accent : NSColor(white: 1, alpha: 0.5)).setStroke()
            path.lineWidth = m.active ? 3 : 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: m.active ? accent : NSColor(white: 1, alpha: 0.8),
            ]
            NSAttributedString(string: m.label, attributes: attrs)
                .draw(at: CGPoint(x: r.minX + 10, y: r.maxY - 20))
        }

        for m in marks where !m.container {
            let r = m.rect.insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            (m.active ? accent.withAlphaComponent(0.18) : NSColor(white: 1, alpha: m.nested ? 0.03 : 0.06)).setFill()
            path.fill()
            (m.active ? accent : NSColor(white: 1, alpha: m.nested ? 0.25 : 0.4)).setStroke()
            path.lineWidth = m.active ? 3 : (m.nested ? 1 : 2)
            path.stroke()

            let size = max(18, min(m.nested ? 40 : 96, min(r.width, r.height) / 3))
            let numberAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: m.nested ? 0.55 : 0.8),
                .paragraphStyle: para,
            ]
            let number = NSAttributedString(string: m.label, attributes: numberAttrs)
            let nh = number.size().height
            number.draw(in: CGRect(x: r.minX, y: r.midY - nh / 2 + 8, width: r.width, height: nh))

            let appAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: m.nested ? 11 : 14),
                .foregroundColor: NSColor(white: 1, alpha: 0.65),
                .paragraphStyle: para,
            ]
            let apps = NSAttributedString(string: m.apps, attributes: appAttrs)
            apps.draw(in: CGRect(x: r.minX + 6, y: r.midY - nh / 2 - 14, width: r.width - 12, height: 18))
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        NSAttributedString(string: title, attributes: titleAttrs)
            .draw(in: CGRect(x: 0, y: bounds.height - 70, width: bounds.width, height: 30))
    }
}
