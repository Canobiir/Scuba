import AppKit
import QuartzCore
import ScreenCaptureKit

/// Makes rearrangements glide instead of jump.
///
/// macOS can't animate other apps' windows smoothly, so, like the zoom, a
/// glide is played with pictures: a cover goes over the screen showing it
/// without the windows that are about to move, plus a picture of each of
/// those windows where it is now. The real windows move underneath, out of
/// sight, while the pictures slide to where the windows ended up; then the
/// cover fades and the real windows are there.
@MainActor
final class LayoutGlide {
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Long enough to follow, short enough never to feel like waiting.
    private let length: CFTimeInterval = 0.26
    /// Time for apps to finish redrawing at their new size.
    private let settle: UInt64 = 70_000_000
    /// The longest the cover waits for windows still on their way.
    private let patience: CFTimeInterval = 0.7

    /// The list of windows on screen, looked up ahead of time (when a drag
    /// starts, or as you let go), so a glide doesn't wait for it.
    private var warm: (content: SCShareableContent, taken: CFTimeInterval)?

    func warmUp() {
        guard hasPermission else { return }
        let started = CACurrentMediaTime()   // the list is as old as the moment it was asked for
        Task { @MainActor in
            if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                self.warm = (c, started)
            }
        }
    }

    /// - Parameters:
    ///   - before: the moving windows and where they are now (AppKit coordinates).
    ///   - change: moves the real windows; returns where they're going.
    ///   - frameOf: where a real window is right now. The cover stays (showing
    ///     the end of the glide) until every window has got where it's going,
    ///     or stopped moving, so an app that's slow to resize never shows.
    func play(on screen: NSScreen, before: [UInt32: CGRect], change: () -> [UInt32: CGRect],
              frameOf: ((UInt32) -> CGRect?)? = nil) async {
        let id = LayoutGlide.displayID(screen)
        // The warmed-up list if it's recent and has every window in it.
        var found: SCShareableContent?
        // (Sizes too: a window's picture is taken at the size the list gives.)
        if let w = warm, CACurrentMediaTime() - w.taken < 1.5,
           before.allSatisfy({ e in
               w.content.windows.contains { UInt32($0.windowID) == e.key
                   && abs($0.frame.width - e.value.width) < 2 && abs($0.frame.height - e.value.height) < 2 }
           }) {
            found = w.content
        }
        warm = nil
        if found == nil {
            found = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let content = found, let display = content.displays.first(where: { $0.displayID == id }) else {
            _ = change()
            return
        }
        let moving = content.windows.filter { before[UInt32($0.windowID)] != nil }
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        // Every picture at once: the backdrop alongside the windows.
        async let backdropPicture = LayoutGlide.capture(display, excluding: moving, size: size, scale: scale)
        var pictures: [UInt32: CGImage] = [:]
        await withTaskGroup(of: (UInt32, CGImage?).self) { group in
            for w in moving {
                group.addTask {
                    let image = await LayoutGlide.capture(w, scale: scale)
                    return (UInt32(w.windowID), image)
                }
            }
            for await (w, image) in group {
                if let image { pictures[w] = image }
            }
        }
        let backdrop = await backdropPicture
        guard let backdrop, !pictures.isEmpty else {
            _ = change()
            return
        }

        // The cover: the screen without the moving windows, and each of them on top.
        let cover = Cover(frame: screen.frame, backdrop: backdrop)
        // Back to front, the way they're stacked on screen.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? Int).map { UInt32($0) } }
        let stacked = order.reversed().filter { pictures[$0] != nil } + pictures.keys.filter { !order.contains($0) }
        var layers: [UInt32: CALayer] = [:]
        for w in stacked {
            guard let image = pictures[w], let from = before[w] else { continue }
            layers[w] = cover.add(image, at: from)
        }
        cover.show()
        try? await Task.sleep(nanoseconds: 20_000_000)   // on screen before anything moves

        let after = change()

        let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1.0)
        func animate(_ layer: CALayer, _ key: String, from: Any, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = length
            a.timingFunction = curve
            a.preferredFrameRateRange = smoothest   // 120 Hz on ProMotion screens
            layer.add(a, forKey: key)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (w, layer) in layers {
            if let to = after[w] {
                let fromPosition = layer.position, fromBounds = layer.bounds
                layer.frame = cover.local(to)
                animate(layer, "position", from: NSValue(point: fromPosition), to: NSValue(point: layer.position))
                animate(layer, "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds))
            } else {
                // Gone from view (tucked away, or moved to another board): it fades.
                layer.opacity = 0
                animate(layer, "opacity", from: NSNumber(value: 1), to: NSNumber(value: 0))
            }
        }
        CATransaction.commit()

        try? await Task.sleep(nanoseconds: UInt64(length * 1_000_000_000))
        if let frameOf {
            // Wait out the stragglers: each window either reaches its spot or
            // stops moving (one that won't shrink that far, say).
            let deadline = CACurrentMediaTime() + patience
            var last: [UInt32: CGRect] = [:]
            func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
                abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
                    && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
            }
            while CACurrentMediaTime() < deadline {
                var done = true
                for (w, goal) in after {
                    guard let f = frameOf(w) else { continue }
                    let still = last[w].map { near($0, f, 1) } ?? false
                    last[w] = f
                    if !near(f, goal, 3) && !still { done = false }
                }
                if done { break }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: settle)
        await cover.dismiss()
    }

    // MARK: Pictures

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    nonisolated private static func capture(_ display: SCDisplay, excluding: [SCWindow],
                                            size: CGSize, scale: CGFloat) async -> CGImage? {
        let c = SCStreamConfiguration()
        c.width = Int(size.width * scale)
        c.height = Int(size.height * scale)
        c.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
    }

    nonisolated private static func capture(_ window: SCWindow, scale: CGFloat) async -> CGImage? {
        let c = SCStreamConfiguration()
        c.width = max(1, Int(window.frame.width * scale))
        c.height = max(1, Int(window.frame.height * scale))
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
    }
}

/// The cover over the screen during a glide.
@MainActor
private final class Cover {
    private let window: NSWindow
    private let root = CALayer()
    private let origin: CGPoint

    init(frame: CGRect, backdrop: CGImage) {
        origin = frame.origin
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(frame, display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: frame.size)
        root.contents = backdrop
        root.contentsGravity = .resize
        CATransaction.commit()
    }

    /// A rectangle in screen coordinates, in the cover's own.
    func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    func add(_ image: CGImage, at rect: CGRect) -> CALayer {
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsGravity = .resize
        layer.frame = local(rect)
        root.addSublayer(layer)
        CATransaction.commit()
        return layer
    }

    func show() {
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.displayIfNeeded()
    }

    func dismiss() async {
        await NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            self.window.animator().alphaValue = 0
        }
        window.orderOut(nil)
    }
}
