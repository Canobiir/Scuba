import AppKit

/// A small chip at the bottom of the screen while you're holding a window
/// you cut or copied (Hyper + X / Hyper + C): the app's icon, what you're
/// holding, and how to put it down. Click it to put the window back.
@MainActor
final class HeldChip {
    private var window: NSPanel?
    var onClick: (() -> Void)?

    func show(icon: NSImage?, title: String, hint: String, on screen: NSScreen) {
        hide()
        let width: CGFloat = 340, height: CGFloat = 54
        let vf = screen.visibleFrame
        let frame = CGRect(x: vf.midX - width / 2, y: vf.minY + 14, width: width, height: height)
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.level = .statusBar
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = ChipView(frame: CGRect(origin: .zero, size: frame.size))
        view.icon = icon
        view.title = title
        view.hint = hint
        view.onClick = { [weak self] in self?.onClick?() }
        w.contentView = view
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class ChipView: NSView {
    var icon: NSImage?
    var title = ""
    var hint = ""
    var onClick: (() -> Void)?
    private var hovered = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSColor(white: 0.08, alpha: hovered ? 0.92 : 0.84).setFill()
        path.fill()
        NSColor(white: 1, alpha: hovered ? 0.45 : 0.2).setStroke()
        path.lineWidth = 1
        path.stroke()

        let iconSize: CGFloat = 32
        icon?.draw(in: CGRect(x: r.minX + 11, y: r.midY - iconSize / 2, width: iconSize, height: iconSize))
        let textX = r.minX + 11 + iconSize + 10
        let textW = r.maxX - textX - 10
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.95),
            .paragraphStyle: para,
        ]).draw(in: CGRect(x: textX, y: r.midY + 1, width: textW, height: 18))
        NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.65),
            .paragraphStyle: para,
        ]).draw(in: CGRect(x: textX, y: r.midY - 16, width: textW, height: 16))
    }
}
