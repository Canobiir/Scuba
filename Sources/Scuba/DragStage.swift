import AppKit
import QuartzCore
import ScreenCaptureKit

/// Smooth drag previews, played the way zooms and glides are: with stand-ins.
///
/// As a drag starts, Scuba quietly takes a picture of the screen behind the
/// board's windows, and one of each window in view. When the drag settles on
/// a spot, a stage goes up just below the window you're dragging, and the
/// pictures glide (on a spring) to where everything will be; a window that
/// shrinks a lot frosts over with its app's icon, and a soft slot opens
/// where yours will land. The real windows don't move at all until you let
/// go; then they move once, out of sight under the stage, your window's
/// picture glides into its slot, and the stage fades as the real windows
/// arrive.
@MainActor
final class DragStage {
    /// From the moment a drag is prepared until the stage has gone.
    private(set) var isActive = false

    private var window: NSWindow?
    private let root = CALayer()
    private var origin: CGPoint = .zero
    private var screenFrame: CGRect = .zero
    private var scale: CGFloat = 2
    private var dragged: UInt32 = 0
    private var startFrames: [UInt32: CGRect] = [:]
    private var icons: [UInt32: NSImage] = [:]
    private var pictures: [UInt32: CGImage] = [:]
    private var draggedPicture: CGImage?
    private var backdrop: CGImage?
    private var ready = false
    /// The pictures are in and the stage can go up.
    var isReady: Bool { ready }
    /// A resize (a gap or a window's edge), not a window being carried:
    /// Scuba's own tiles and strips stay live above the stage.
    private(set) var resizing = false
    private var preparing: Task<Void, Never>?
    /// The latest preview asked for before the pictures were ready.
    private var waiting: (plan: [UInt32: CGRect]?, slot: CGRect?)?
    private var generation = 0

    private final class StandIn {
        let layer = CALayer()      // the window's picture, shrinking or growing
        let frost = CALayer()      // a tint over it when it's shrunk a lot
        let icon = CALayer()       // its app's icon, on the frost
        let original: CGRect
        init(original: CGRect) { self.original = original }
    }
    private var standIns: [UInt32: StandIn] = [:]
    private let slot = CALayer()
    /// Dropping as a tab: a ghost of the strip of tabs it'll make, along
    /// the top of the slot.
    private let ghost = CALayer()
    private var ghostNames: [String] = []

    /// A window shrunk below this share of its size (either way) frosts over.
    private let frostBelow: CGFloat = 0.55

    // MARK: Getting ready

    /// Starts taking the pictures as a drag begins. False when there's no
    /// stage to be had (no Screen Recording permission): previews then move
    /// the real windows, as before.
    func prepare(on screen: NSScreen, dragged: UInt32, windows: [UInt32: CGRect],
                 icons: [UInt32: NSImage], resizing: Bool = false) -> Bool {
        tearDown()
        guard CGPreflightScreenCaptureAccess() else { return false }
        isActive = true
        self.resizing = resizing
        let ownPID = ProcessInfo.processInfo.processIdentifier
        generation += 1
        let gen = generation
        self.dragged = dragged
        startFrames = windows
        self.icons = icons
        origin = screen.frame.origin
        screenFrame = screen.frame
        scale = screen.backingScaleFactor
        let size = screen.frame.size
        let scale = self.scale
        let id = DragStage.displayID(screen)
        let wanted = Set(windows.keys).union([dragged])
        preparing = Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == id }) else { return }
            let mine = content.windows.filter { wanted.contains(UInt32($0.windowID)) }
            // Resizing: Scuba's own tiles and strips stay live above the
            // stage, so they're left out of the picture behind it.
            let own = resizing ? content.windows.filter { $0.owningApplication?.processID == ownPID } : []
            async let back = DragStage.capture(display, excluding: mine + own, size: size, scale: scale)
            var pics: [UInt32: CGImage] = [:]
            await withTaskGroup(of: (UInt32, CGImage?).self) { group in
                for w in mine {
                    group.addTask {
                        let image = await DragStage.capture(w, scale: scale)
                        return (UInt32(w.windowID), image)
                    }
                }
                for await (w, image) in group {
                    if let image { pics[w] = image }
                }
            }
            let b = await back
            guard let self, gen == self.generation, self.isActive else { return }
            self.backdrop = b
            self.draggedPicture = pics[dragged]
            pics[dragged] = nil
            self.pictures = pics
            self.ready = b != nil
            if !self.ready {
                self.isActive = false
                return
            }
            if let w = self.waiting {
                self.waiting = nil
                self.preview(plan: w.plan, slot: w.slot)
            }
        }
        return true
    }

    // MARK: Previews

    /// Shows where everything will be: each window's picture glides to its
    /// spot in `plan` (back where it was when there's no plan), and the slot
    /// opens at `slot`.
    /// - keep: windows missing from the plan stay where they are (a resize
    ///   only plans the windows it moves); `hide` fades some out anyway
    ///   (frosted over).
    func preview(plan: [UInt32: CGRect]?, slot spot: CGRect?, tabs: [String]? = nil,
                 keep: Bool = false, hide: Set<UInt32> = []) {
        guard isActive else { return }
        guard ready, let backdrop else {
            waiting = (plan, spot)
            return
        }
        if window == nil, !show(backdrop) {
            tearDown()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (w, s) in standIns {
            if hide.contains(w) {
                fade(s.layer, to: 0)
                continue
            }
            if keep, plan?[w] == nil { continue }
            let to = plan?[w] ?? (plan == nil ? s.original : nil)
            if let to, screenFrame.intersects(to) {
                place(s, at: to)
                fade(s.layer, to: 1)
            } else {
                // Out of view once it's dropped (tucked away): it fades.
                fade(s.layer, to: 0)
            }
        }
        if let spot {
            if slot.opacity < 0.5 {
                slot.frame = local(spot)
            } else {
                move(slot, to: local(spot))
            }
            fade(slot, to: 1)
        } else {
            fade(slot, to: 0)
        }
        setGhost(tabs)
        CATransaction.commit()
    }

    // MARK: Letting go

    /// Letting go onto a spot: your window's picture joins the stage where
    /// you let go, and the stage comes up over everything, so the real
    /// windows can move underneath without a flicker. Call before the drop.
    func cover(draggedAt frame: CGRect) {
        guard isActive, ready, let window, let pic = draggedPicture else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = makeStandIn(dragged, at: frame, picture: pic)
        standIns[dragged] = s
        root.addSublayer(s.layer)
        CATransaction.commit()
        window.level = .floating
        window.orderFrontRegardless()
    }

    /// The drag is over.
    /// - dropped: the real windows have just been sent to their spots:
    ///   your window's picture glides into its slot, every picture to where
    ///   its window is really going, and the stage fades once they're there.
    ///   Otherwise everything glides back and the stage fades.
    func finish(dropped: Bool, draggedTo: CGRect?, targetOf: (UInt32) -> CGRect?,
                frameOf: @escaping (UInt32) -> CGRect?) async {
        guard isActive else { return }
        preparing?.cancel()
        guard let window, ready else {
            tearDown()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade(slot, to: 0)
        var goals: [UInt32: CGRect] = [:]
        if dropped {
            // Your window's picture (put up when you let go) glides into its slot.
            if let s = standIns[dragged], let to = draggedTo, screenFrame.intersects(to) {
                place(s, at: to)
                goals[dragged] = to
            }
            for (w, s) in standIns where w != dragged {
                if let to = targetOf(w), screenFrame.intersects(to) {
                    place(s, at: to)
                    fade(s.layer, to: 1)
                    goals[w] = to
                } else {
                    fade(s.layer, to: 0)
                }
            }
        } else {
            for (w, s) in standIns where w != dragged {
                place(s, at: s.original)
                fade(s.layer, to: 1)
            }
        }
        CATransaction.commit()

        // The springs settle, and the real windows get where they're going
        // (or stop moving: an app that won't shrink that far).
        try? await Task.sleep(nanoseconds: 420_000_000)
        if dropped {
            let deadline = CACurrentMediaTime() + 0.6
            var last: [UInt32: CGRect] = [:]
            func near(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> Bool {
                abs(a.minX - b.minX) < t && abs(a.minY - b.minY) < t
                    && abs(a.width - b.width) < t && abs(a.height - b.height) < t
            }
            while CACurrentMediaTime() < deadline {
                var done = true
                for (w, goal) in goals {
                    guard let f = frameOf(w) else { continue }
                    let still = last[w].map { near($0, f, 1) } ?? false
                    last[w] = f
                    if !near(f, goal, 3) && !still { done = false }
                }
                if done { break }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            // Then a moment for the apps to draw at their new size, so what
            // shows through is never an old layout stretched (Electron apps
            // take the longest).
            try? await Task.sleep(nanoseconds: resizing ? 180_000_000 : 60_000_000)
        }
        await NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reveal
            window.animator().alphaValue = 0
        }
        tearDown()
    }

    /// Takes everything down at once (a new drag, or nothing to show).
    func tearDown() {
        preparing?.cancel()
        preparing = nil
        generation += 1
        window?.orderOut(nil)
        window = nil
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        standIns.removeAll()
        pictures.removeAll()
        icons.removeAll()
        startFrames.removeAll()
        draggedPicture = nil
        backdrop = nil
        ready = false
        waiting = nil
        isActive = false
        resizing = false
    }

    // MARK: The stage

    /// Puts the stage up just below the window you're dragging: the screen
    /// behind the windows, and each window's picture where it is now.
    private func show(_ backdrop: CGImage) -> Bool {
        let w = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.level = .normal
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        view.layer = root
        view.wantsLayer = true
        root.frame = view.bounds
        root.contents = backdrop
        root.contentsGravity = .resize
        root.masksToBounds = true
        w.contentView = view

        // Back to front, the way they're stacked on screen.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? Int).map { UInt32($0) } }
        let ids = Array(startFrames.keys)
        let stacked = order.reversed().filter { ids.contains($0) } + ids.filter { !order.contains($0) }
        for id in stacked {
            guard let f = startFrames[id], let pic = pictures[id] else { continue }
            let s = makeStandIn(id, at: f, picture: pic)
            standIns[id] = s
            root.addSublayer(s.layer)
        }
        // Where it'll land: a soft shadow on the spot, no colour.
        slot.cornerRadius = 16
        slot.backgroundColor = NSColor(white: 0, alpha: 0.30).cgColor
        slot.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        slot.borderWidth = 1
        slot.shadowColor = NSColor.black.cgColor
        slot.shadowOpacity = 0.6
        slot.shadowRadius = 22
        slot.shadowOffset = .zero
        slot.opacity = 0
        root.addSublayer(slot)
        ghost.cornerRadius = 9
        ghost.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        ghost.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]
        ghost.opacity = 0
        slot.addSublayer(ghost)

        // Just below your window, so it stays on top while you drag. A gap
        // being dragged has no window in hand: over every window.
        if dragged == 0 {
            w.orderFrontRegardless()
        } else {
            w.order(.below, relativeTo: Int(dragged))
        }
        guard w.isVisible else {
            w.orderOut(nil)
            return false
        }
        window = w
        return true
    }

    private func makeStandIn(_ id: UInt32, at frame: CGRect, picture: CGImage) -> StandIn {
        let s = StandIn(original: frame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.layer.frame = local(frame)
        s.layer.contents = picture
        s.layer.contentsGravity = .resizeAspectFill
        s.layer.contentsScale = scale
        s.layer.cornerRadius = 10
        s.layer.masksToBounds = true
        s.layer.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        s.layer.borderWidth = 1
        s.frost.backgroundColor = NSColor(white: 0.1, alpha: 0.62).cgColor
        if let tint = AppColour.of(icons[id]) {
            // A little of the app's own colour in the frost.
            s.frost.backgroundColor = NSColor(white: 0.1, alpha: 0.62)
                .blended(withFraction: AppColour.amount * 1.4, of: tint)?.cgColor ?? s.frost.backgroundColor
        }
        s.frost.frame = s.layer.bounds
        s.frost.opacity = 0
        s.layer.addSublayer(s.frost)
        s.icon.contents = icons[id]
        s.icon.contentsGravity = .resizeAspect
        s.icon.bounds = CGRect(origin: .zero, size: iconSize(for: s.layer.bounds.size))
        s.icon.position = CGPoint(x: s.layer.bounds.midX, y: s.layer.bounds.midY)
        s.icon.opacity = 0
        s.layer.addSublayer(s.icon)
        CATransaction.commit()
        return s
    }

    private func iconSize(for size: CGSize) -> CGSize {
        let side = max(16, min(56, min(size.width, size.height) * 0.38))
        return CGSize(width: side, height: side)
    }

    /// Moves a stand-in (its frost and icon with it), frosting it over when
    /// it's shrunk a lot and clearing when it's back near its own size.
    private func place(_ s: StandIn, at frame: CGRect) {
        let to = local(frame)
        move(s.layer, to: to)
        let inside = CGRect(origin: .zero, size: to.size)
        move(s.frost, to: inside)
        let iconFrame = CGRect(origin: CGPoint(x: inside.midX - iconSize(for: to.size).width / 2,
                                               y: inside.midY - iconSize(for: to.size).height / 2),
                               size: iconSize(for: to.size))
        move(s.icon, to: iconFrame)
        let shrink = min(frame.width / max(s.original.width, 1), frame.height / max(s.original.height, 1))
        let frosted: Float = shrink < frostBelow ? 1 : 0
        fade(s.frost, to: frosted)
        fade(s.icon, to: frosted)
    }

    /// Glides a layer to a frame on a gentle spring, from wherever it is right
    /// now (mid-glide too), so a change of mind never jumps.
    private func move(_ layer: CALayer, to frame: CGRect) {
        let now = layer.presentation() ?? layer
        let fromPosition = now.position, fromBounds = now.bounds
        layer.frame = frame
        spring(layer, "position", from: NSValue(point: fromPosition), to: NSValue(point: layer.position))
        spring(layer, "bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds))
    }

    private func spring(_ layer: CALayer, _ key: String, from: Any, to: Any) {
        let a = CASpringAnimation(keyPath: key)
        a.mass = 1
        a.stiffness = 340
        a.damping = 35
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        a.preferredFrameRateRange = smoothest
        layer.add(a, forKey: key)
    }

    private func fade(_ layer: CALayer, to value: Float) {
        let now = (layer.presentation() ?? layer).opacity
        guard abs(now - value) > 0.01 || abs(layer.opacity - value) > 0.01 else { return }
        layer.opacity = value
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = NSNumber(value: now)
        a.toValue = NSNumber(value: value)
        a.duration = Motion.fade
        layer.add(a, forKey: "opacity")
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    /// Shows (or hides) the ghost strip of tabs along the slot's top.
    private func setGhost(_ names: [String]?) {
        guard let names, !names.isEmpty else {
            fade(ghost, to: 0)
            return
        }
        let height: CGFloat = 30
        ghost.frame = CGRect(x: 0, y: max(0, slot.bounds.height - height), width: slot.bounds.width, height: height)
        if names != ghostNames {
            ghostNames = names
            ghost.sublayers?.forEach { $0.removeFromSuperlayer() }
            let gap: CGFloat = 3
            let width = min(220, (ghost.bounds.width - 6 - gap * CGFloat(names.count - 1)) / CGFloat(names.count))
            for (i, name) in names.enumerated() {
                let chip = CALayer()
                chip.frame = CGRect(x: 3 + CGFloat(i) * (width + gap), y: 3, width: width, height: height - 6)
                chip.cornerRadius = 6
                // The one you're dropping is the new front tab.
                chip.backgroundColor = NSColor(white: 1, alpha: i == names.count - 1 ? 0.22 : 0.08).cgColor
                let text = CATextLayer()
                text.string = name
                text.font = NSFont.systemFont(ofSize: 12, weight: i == names.count - 1 ? .semibold : .regular)
                text.fontSize = 12
                text.foregroundColor = NSColor(white: 1, alpha: i == names.count - 1 ? 0.95 : 0.65).cgColor
                text.truncationMode = .end
                text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                text.frame = CGRect(x: 10, y: (chip.bounds.height - 16) / 2, width: chip.bounds.width - 20, height: 16)
                chip.addSublayer(text)
                ghost.addSublayer(chip)
            }
        }
        fade(ghost, to: 1)
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
