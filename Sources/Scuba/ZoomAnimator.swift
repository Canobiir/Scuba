import AppKit
import CoreGraphics
import QuartzCore
import ScreenCaptureKit

/// Makes zooming look like a camera floating in or out.
///
/// macOS can't smoothly scale other apps' live windows, so a zoom is played
/// with still pictures on a cover over the screen:
///  - the "parent" picture: the shallower board,
///  - the "child" picture: the panel you dive into, shown full screen,
/// and a camera that moves between looking at the whole parent and looking at
/// just the panel. The real windows are moved underneath, out of sight, and a
/// fresh picture of the result joins in once the apps have finished redrawing.
///
/// The camera can be played (keyboard, clicks) or steered frame by frame
/// (trackpad: the zoom follows your fingers).
@MainActor
final class ZoomAnimator {
    /// Diving in is quick; coming back up is slower and gentler.
    func duration(_ zoomIn: Bool) -> CFTimeInterval { zoomIn ? 0.38 : 0.48 }

    /// Both settle softly instead of stopping dead; coming up eases out longer.
    private func curve(_ zoomIn: Bool) -> CAMediaTimingFunction {
        zoomIn ? CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.3, 1.0)
               : CAMediaTimingFunction(controlPoints: 0.3, 0.55, 0.15, 1.0)
    }

    /// Time for apps to finish redrawing after their windows move.
    private let settle: UInt64 = 180_000_000
    /// Extra time to wait before the closing picture (say, while windows
    /// come back from being minimized), in nanoseconds.
    var extraSettle: (() -> UInt64)?

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: Pictures of places you've been

    /// The last picture of each place, so a zoom can show where it's going
    /// from the very first frame (e.g. the board you're coming back up to).
    private var snapshots: [String: CGImage] = [:]
    private var order: [String] = []

    private func remember(_ image: CGImage, as key: String) {
        snapshots[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 4 { snapshots[order.removeFirst()] = nil }
    }

    /// A picture of a place made ahead of time (the Overview, drawn before it
    /// opens), so a zoom to it shows it from the very first frame.
    func offer(_ image: CGImage, as key: String) { remember(image, as: key) }

    /// A remembered picture; using it counts as recent, so the places you
    /// keep going back to are the ones kept.
    private func recall(_ key: String) -> CGImage? {
        guard let image = snapshots[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    // MARK: A picture taken ahead of time

    /// A picture of the screen taken the moment a gesture begins (Hyper
    /// pressed, three fingers down), so the zoom can start without waiting
    /// for one. It's only good for a moment, and only until something on
    /// screen changes (each change bumps the generation).
    private var early: (image: CGImage, taken: CFTimeInterval, display: CGDirectDisplayID)?
    private var earlyCapture: (task: Task<CGImage?, Never>, started: CFTimeInterval,
                               display: CGDirectDisplayID, generation: Int)?
    private var generation = 0

    func prepare(on screen: NSScreen) {
        guard hasPermission, earlyCapture == nil else { return }
        if let e = early, CACurrentMediaTime() - e.taken < 0.25 { return }
        let id = displayID(screen)
        let gen = generation
        let started = CACurrentMediaTime()
        let task = Task { @MainActor in await self.captureNow(screen) }
        earlyCapture = (task, started, id, gen)
        Task { @MainActor in
            let image = await task.value
            if let pending = self.earlyCapture, pending.started == started { self.earlyCapture = nil }
            if let image, gen == self.generation { self.early = (image, started, id) }
            // Don't hold on to a full-screen picture for long.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let e = self.early, CACurrentMediaTime() - e.taken > 1.0 { self.early = nil }
        }
    }

    /// Something on screen changed (or a zoom just ended): an earlier picture
    /// no longer shows it.
    func forgetEarlyPicture() {
        early = nil
        earlyCapture = nil
        generation += 1
    }

    /// The screen as it is now: the picture taken as the gesture began (even
    /// one still being taken), if it's fresh, otherwise a new one.
    private func pictureNow(_ screen: NSScreen) async -> CGImage? {
        let id = displayID(screen)
        if let pending = earlyCapture, pending.display == id, pending.generation == generation {
            let image = await pending.task.value
            if let image, pending.generation == generation, CACurrentMediaTime() - pending.started < 0.8 {
                early = nil
                return image
            }
        }
        if let e = early, e.display == id, CACurrentMediaTime() - e.taken < 0.8 {
            early = nil
            return e.image
        }
        return await captureNow(screen)
    }

    /// Starts looking up the screen's windows while the camera is still
    /// moving, so the picture of the result (which leaves the cover out) is
    /// ready sooner when it lands.
    private func lookAhead() -> Task<SCShareableContent?, Never> {
        Task { try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    // MARK: A played zoom

    /// - Parameters:
    ///   - target: where the deeper view sits inside the shallower one
    ///     (AppKit screen coordinates).
    ///   - fromKey / toKey: names for where you are and where you're going.
    ///   - change: updates the layout model.
    ///   - layout: moves the real windows to match it.
    func animate(on screen: NSScreen, zoomIn: Bool, target: CGRect, fromKey: String, toKey: String,
                 change: () -> Void, layout: () -> Void) async {
        guard hasPermission, let before = await pictureNow(screen) else {
            change()
            layout()
            return
        }
        remember(before, as: fromKey)
        let cam = Camera(screen: screen, target: target)
        if zoomIn {
            cam.addParent(before)
            if let known = recall(toKey) { cam.addChild(known) }
        } else {
            cam.addChild(before)
            if let known = recall(toKey) { cam.addParent(known) }
        }
        let q0: CGFloat = zoomIn ? 1 : 0, q1: CGFloat = zoomIn ? 0 : 1
        cam.apply(q0)
        cam.stage.window.orderFrontRegardless()
        CATransaction.flush()

        let lookup = lookAhead()
        let length = duration(zoomIn)
        let start = CACurrentMediaTime()
        cam.play(from: q0, to: q1, start: start, length: length, curve: curve(zoomIn))
        CATransaction.flush()

        await finish(cam, screen: screen, zoomIn: zoomIn, toKey: toKey, end: start + length,
                     lookup: lookup, change: change, layout: layout)
    }

    /// Moves the real windows under the cover, adds a fresh picture of the
    /// result and takes the cover away once the camera has landed.
    private func finish(_ cam: Camera, screen: NSScreen, zoomIn: Bool, toKey: String, end: CFTimeInterval,
                        lookup: Task<SCShareableContent?, Never>?, change: () -> Void, layout: () -> Void) async {
        await Task.yield()
        change()
        layout()
        try? await Task.sleep(nanoseconds: settle)
        if let extra = extraSettle?(), extra > 0 { try? await Task.sleep(nanoseconds: extra) }
        var landed = end
        if let after = await captureExcluding(cam.stage.window, on: screen, lookup: lookup) {
            remember(after, as: toKey)
            if zoomIn { cam.addChild(after, fadeIn: 0.15) } else { cam.addParent(after, fadeIn: 0.15) }
            landed = max(landed, CACurrentMediaTime() + 0.15)
        }
        await cam.stage.dismiss(after: max(0, landed - CACurrentMediaTime()))
        forgetEarlyPicture()
    }

    // MARK: A sideways glide

    /// Steps from one board to its neighbour on the same level: the camera
    /// pulls back just far enough to see both, drifts across, and settles
    /// into the new one.
    /// - Parameters:
    ///   - from / to: where the two boards sit on the board above (AppKit
    ///     screen coordinates).
    ///   - parentKey / fromKey / toKey: names of the board above, the board
    ///     you're leaving and the one you're going to, for remembered pictures.
    func glide(on screen: NSScreen, from a: CGRect, to b: CGRect,
               parentKey: String, fromKey: String, toKey: String,
               change: () -> Void, layout: () -> Void) async {
        guard hasPermission, let before = await pictureNow(screen) else {
            change()
            layout()
            return
        }
        remember(before, as: fromKey)
        let g = Glide(screen: screen, from: a, to: b)
        // The board above, as last seen; without it the gap between is dark.
        if let above = recall(parentKey) { g.addAbove(above) }
        g.addFrom(before)
        if let known = recall(toKey) { g.addTo(known) }
        g.apply(0)
        g.stage.window.orderFrontRegardless()
        CATransaction.flush()

        let lookup = lookAhead()
        let length: CFTimeInterval = 0.62
        let start = CACurrentMediaTime()
        g.play(from: 0, to: 1, start: start, length: length, curve: Glide.playedCurve)
        CATransaction.flush()

        await Task.yield()
        change()
        layout()
        try? await Task.sleep(nanoseconds: settle)
        if let extra = extraSettle?(), extra > 0 { try? await Task.sleep(nanoseconds: extra) }
        var landed = start + length
        if let after = await captureExcluding(g.stage.window, on: screen, lookup: lookup) {
            remember(after, as: toKey)
            g.addTo(after, fadeIn: 0.15)
            landed = max(landed, CACurrentMediaTime() + 0.15)
        }
        await g.stage.dismiss(after: max(0, landed - CACurrentMediaTime()))
        forgetEarlyPicture()
    }

    // MARK: Another Main slides in

    /// Slides across to another Main: the board you're on moves off to one
    /// side as the other comes in from the other, like Spaces.
    func slide(on screen: NSScreen, direction: Int, fromKey: String, toKey: String,
               change: () -> Void, layout: () -> Void) async {
        guard hasPermission, let before = await pictureNow(screen) else {
            change()
            layout()
            return
        }
        remember(before, as: fromKey)
        let scene = Slide(screen: screen, direction: direction)
        scene.addFrom(before)
        if let known = recall(toKey) { scene.addTo(known, fadeIn: 0) }
        scene.apply(0)
        scene.stage.window.orderFrontRegardless()
        CATransaction.flush()
        let lookup = lookAhead()
        let length: CFTimeInterval = 0.5
        let start = CACurrentMediaTime()
        scene.play(from: 0, to: 1, start: start, length: length, curve: Glide.playedCurve)
        CATransaction.flush()
        await land(scene, screen: screen, toKey: toKey, end: start + length, lookup: lookup,
                   change: change, layout: layout)
    }

    /// Moves the real windows under the cover, adds a fresh picture of where
    /// you're going and takes the cover away once the scene has landed.
    private func land(_ scene: SideScene, screen: NSScreen, toKey: String, end: CFTimeInterval,
                      lookup: Task<SCShareableContent?, Never>?, change: () -> Void, layout: () -> Void) async {
        await Task.yield()
        change()
        layout()
        try? await Task.sleep(nanoseconds: settle)
        if let extra = extraSettle?(), extra > 0 { try? await Task.sleep(nanoseconds: extra) }
        var landed = end
        if let after = await captureExcluding(scene.stage.window, on: screen, lookup: lookup) {
            remember(after, as: toKey)
            scene.addTo(after, fadeIn: 0.15)
            landed = max(landed, CACurrentMediaTime() + 0.15)
        }
        await scene.stage.dismiss(after: max(0, landed - CACurrentMediaTime()))
        forgetEarlyPicture()
    }

    // MARK: A steered sideways trip (trackpad)

    private struct SideScrub {
        let toKey: String
        let screen: NSScreen
        var progress: CGFloat = 0
        var scene: SideScene?
        var ready: Task<Void, Never>?
    }
    private var sideScrub: SideScrub?

    /// A glide to a neighbouring board that follows your fingers.
    func beginGlideScrub(on screen: NSScreen, from a: CGRect, to b: CGRect,
                         parentKey: String, fromKey: String, toKey: String) {
        beginSideScrub(on: screen, fromKey: fromKey, toKey: toKey) { before in
            let g = Glide(screen: screen, from: a, to: b)
            if let above = self.recall(parentKey) { g.addAbove(above) }
            g.addFrom(before)
            return g
        }
    }

    /// A slide to another Main that follows your fingers.
    func beginSlideScrub(on screen: NSScreen, direction: Int, fromKey: String, toKey: String) {
        beginSideScrub(on: screen, fromKey: fromKey, toKey: toKey) { before in
            let scene = Slide(screen: screen, direction: direction)
            scene.addFrom(before)
            return scene
        }
    }

    private func beginSideScrub(on screen: NSScreen, fromKey: String, toKey: String,
                                make: @escaping (CGImage) -> SideScene) {
        sideScrub = SideScrub(toKey: toKey, screen: screen)
        sideScrub?.ready = Task { @MainActor in
            guard hasPermission, let before = await pictureNow(screen) else { return }
            remember(before, as: fromKey)
            let scene = make(before)
            if let known = recall(toKey) { scene.addTo(known, fadeIn: 0) }
            scene.apply(sideScrub?.progress ?? 0)
            scene.stage.window.orderFrontRegardless()
            sideScrub?.scene = scene
        }
    }

    /// Follows your fingers: 0 = where you started, 1 = all the way across.
    func updateSideScrub(_ progress: CGFloat) {
        guard var s = sideScrub else { return }
        s.progress = min(max(progress, 0), 1)
        sideScrub = s
        s.scene?.apply(s.progress)
    }

    /// Lets go: finish going across (commit) or float back to where you were.
    /// Returns true if you went across.
    func endSideScrub(commit: Bool, change: () -> Void, layout: () -> Void) async -> Bool {
        guard let s = sideScrub else { return false }
        await s.ready?.value
        let current = sideScrub ?? s
        sideScrub = nil
        guard let scene = current.scene else {
            // No pictures (no Screen Recording permission): just do it.
            if commit { change(); layout() }
            return commit
        }
        let start = CACurrentMediaTime()
        let release = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1.0)
        if commit {
            let lookup = lookAhead()
            let length = max(0.18, 0.5 * Double(1 - current.progress))
            scene.play(from: current.progress, to: 1, start: start, length: length, curve: release)
            CATransaction.flush()
            await land(scene, screen: current.screen, toKey: current.toKey, end: start + length, lookup: lookup,
                       change: change, layout: layout)
            return true
        } else {
            scene.play(from: current.progress, to: 0, start: start, length: 0.22, curve: release)
            CATransaction.flush()
            await scene.stage.dismiss(after: 0.22)
            forgetEarlyPicture()
            return false
        }
    }

    // MARK: A steered zoom (trackpad)

    private struct Scrub {
        let zoomIn: Bool
        let toKey: String
        let screen: NSScreen
        var progress: CGFloat = 0
        var cam: Camera?
        var ready: Task<Void, Never>?
    }
    private var scrub: Scrub?

    /// Camera position for how far along the zoom is (0 = where you started).
    private func q(_ progress: CGFloat, zoomIn: Bool) -> CGFloat { zoomIn ? 1 - progress : progress }

    func beginScrub(on screen: NSScreen, zoomIn: Bool, target: CGRect, fromKey: String, toKey: String) {
        scrub = Scrub(zoomIn: zoomIn, toKey: toKey, screen: screen)
        scrub?.ready = Task { @MainActor in
            guard hasPermission, let before = await pictureNow(screen) else { return }
            remember(before, as: fromKey)
            let cam = Camera(screen: screen, target: target)
            if zoomIn {
                cam.addParent(before)
                if let known = recall(toKey) { cam.addChild(known) }
            } else {
                cam.addChild(before)
                if let known = recall(toKey) { cam.addParent(known) }
            }
            cam.apply(q(scrub?.progress ?? 0, zoomIn: zoomIn))
            cam.stage.window.orderFrontRegardless()
            scrub?.cam = cam
        }
    }

    /// Follows your fingers: 0 = where you started, 1 = all the way there.
    func updateScrub(_ progress: CGFloat) {
        guard var s = scrub else { return }
        s.progress = min(max(progress, 0), 1)
        scrub = s
        s.cam?.apply(q(s.progress, zoomIn: s.zoomIn))
    }

    /// Lets go: finish the zoom (commit) or float back to where you were.
    /// Returns true if the zoom happened.
    func endScrub(commit: Bool, change: () -> Void, layout: () -> Void) async -> Bool {
        guard let s = scrub else { return false }
        await s.ready?.value
        let current = scrub ?? s
        scrub = nil
        guard let cam = current.cam else {
            // No pictures (no Screen Recording permission): just do it.
            if commit { change(); layout() }
            return commit
        }
        let qNow = q(current.progress, zoomIn: current.zoomIn)
        let start = CACurrentMediaTime()
        if commit {
            let lookup = lookAhead()
            let q1: CGFloat = current.zoomIn ? 0 : 1
            let length = max(0.18, duration(current.zoomIn) * Double(abs(q1 - qNow)))
            cam.play(from: qNow, to: q1, start: start, length: length,
                     curve: CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1.0))
            CATransaction.flush()
            await finish(cam, screen: current.screen, zoomIn: current.zoomIn, toKey: current.toKey,
                         end: start + length, lookup: lookup, change: change, layout: layout)
            return true
        } else {
            let q0: CGFloat = current.zoomIn ? 1 : 0
            cam.play(from: qNow, to: q0, start: start, length: 0.24,
                     curve: CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1.0))
            await cam.stage.dismiss(after: 0.24)
            forgetEarlyPicture()
            return false
        }
    }

    // MARK: Capture

    private var display: (id: CGDirectDisplayID, size: CGSize, sc: SCDisplay)?

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Looking up the display takes a moment, so it's done once and reused.
    private func scDisplay(for screen: NSScreen) async -> SCDisplay? {
        let id = displayID(screen)
        if let d = display, d.id == id, d.size == screen.frame.size { return d.sc }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let sc = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
        else { return nil }
        display = (id, screen.frame.size, sc)
        return sc
    }

    private func config(_ sc: SCDisplay, _ screen: NSScreen) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        // Full sharpness, so the hand-off to the real windows doesn't pop.
        c.width = Int(CGFloat(sc.width) * screen.backingScaleFactor)
        c.height = Int(CGFloat(sc.height) * screen.backingScaleFactor)
        c.showsCursor = false
        return c
    }

    /// The screen as it is now, Scuba's own backdrop and tiles included.
    private func captureNow(_ screen: NSScreen) async -> CGImage? {
        guard let sc = await scDisplay(for: screen) else { return nil }
        let filter = SCContentFilter(display: sc, excludingWindows: [])
        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config(sc, screen))
        if image == nil { display = nil }
        return image
    }

    /// The screen without the zoom's own cover.
    private func captureExcluding(_ window: NSWindow, on screen: NSScreen,
                                  lookup: Task<SCShareableContent?, Never>? = nil) async -> CGImage? {
        let cover = CGWindowID(window.windowNumber)
        // The list looked up while the camera moved, if it already has the
        // cover in it (else the picture would show the cover itself).
        var found = await lookup?.value
        if found?.windows.contains(where: { $0.windowID == cover }) != true {
            found = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let content = found,
              let sc = content.displays.first(where: { $0.displayID == displayID(screen) }) ?? content.displays.first
        else { return nil }
        let skip = content.windows.filter { $0.windowID == cover }
        let filter = SCContentFilter(display: sc, excludingWindows: skip)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config(sc, screen))
    }
}

/// Ask for the screen's full refresh rate during animations: 120 frames a
/// second on ProMotion displays, instead of the 60 Core Animation may settle for.
let smoothest = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

// MARK: - Camera

/// The parent and child pictures and the camera between them.
///
/// The camera position `q` runs from 0 (looking at just the panel, so the
/// child fills the screen) to 1 (looking at the whole parent board). In
/// between, the visible area shrinks or grows smoothly (geometrically, so it
/// feels like steady motion rather than speeding up), the child fades as the
/// camera pulls away, and the rest of the board dims around the panel as the
/// camera closes in.
@MainActor
private final class Camera {
    let stage: Stage
    private let target: CGRect
    private let bounds: CGRect
    private let parent = CALayer()
    private let child = CALayer()
    private let dim = CAShapeLayer()
    private let dimAmount: CGFloat = 0.45

    init(screen: NSScreen, target t: CGRect) {
        stage = Stage(frame: screen.frame)
        bounds = stage.bounds
        target = t.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        for holder in [parent, child] {
            holder.anchorPoint = .zero
            holder.frame = bounds
            stage.content.addSublayer(holder)
        }
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRoundedRect(in: target, cornerWidth: 10, cornerHeight: 10)
        dim.frame = bounds
        dim.path = path
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.cgColor
        dim.opacity = 0
        dim.zPosition = 10
        parent.addSublayer(dim)
    }

    func addParent(_ image: CGImage, fadeIn: CFTimeInterval = 0) { add(image, to: parent, fadeIn: fadeIn) }
    func addChild(_ image: CGImage, fadeIn: CFTimeInterval = 0) { add(image, to: child, fadeIn: fadeIn) }

    private func add(_ image: CGImage, to holder: CALayer, fadeIn: CFTimeInterval) {
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = .zero
        layer.frame = bounds
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        holder.addSublayer(layer)   // the dim's zPosition keeps it above the parent pictures
        CATransaction.commit()
        if fadeIn > 0 {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = fadeIn
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "fadeIn")
        }
    }

    // The camera's view of the parent board at position q.
    private func view(_ q: CGFloat) -> CGRect {
        func size(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * pow(b / a, q) }
        let w = size(target.width, bounds.width), h = size(target.height, bounds.height)
        let fx = bounds.width == target.width ? q : (w - target.width) / (bounds.width - target.width)
        let fy = bounds.height == target.height ? q : (h - target.height) / (bounds.height - target.height)
        return CGRect(x: target.minX + (bounds.minX - target.minX) * fx,
                      y: target.minY + (bounds.minY - target.minY) * fy,
                      width: w, height: h)
    }

    private func parentTransform(_ q: CGFloat) -> CATransform3D { mapping(from: view(q), to: bounds) }
    private func childTransform(_ q: CGFloat) -> CATransform3D {
        CATransform3DConcat(mapping(from: bounds, to: target), parentTransform(q))
    }
    private func childOpacity(_ q: CGFloat) -> Float {
        let t = min(max((q - 0.35) / 0.55, 0), 1)
        return Float(1 - t * t * (3 - 2 * t))
    }
    private func dimOpacity(_ q: CGFloat) -> Float { Float(dimAmount * (1 - q)) }

    /// Puts the camera at a position, right away (used while steering).
    func apply(_ q: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.removeAllAnimations(); child.removeAllAnimations(); dim.removeAllAnimations()
        parent.transform = parentTransform(q)
        child.transform = childTransform(q)
        child.opacity = childOpacity(q)
        dim.opacity = dimOpacity(q)
        CATransaction.commit()
    }

    /// Plays the camera from one position to another along its true path.
    func play(from q0: CGFloat, to q1: CGFloat, start: CFTimeInterval, length: CFTimeInterval,
              curve: CAMediaTimingFunction) {
        let steps = 30
        let qs = (0...steps).map { q0 + (q1 - q0) * CGFloat($0) / CGFloat(steps) }
        func keyframes(_ key: String, _ values: [Any], on layer: CALayer) {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values
            a.calculationMode = .linear
            a.timingFunction = curve
            a.duration = length
            a.beginTime = layer.convertTime(start, from: nil)
            a.fillMode = .backwards
            a.preferredFrameRateRange = smoothest   // 120 Hz on ProMotion screens
            layer.add(a, forKey: key)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parent.transform = parentTransform(q1)
        child.transform = childTransform(q1)
        child.opacity = childOpacity(q1)
        dim.opacity = dimOpacity(q1)
        keyframes("transform", qs.map { NSValue(caTransform3D: parentTransform($0)) }, on: parent)
        keyframes("transform", qs.map { NSValue(caTransform3D: childTransform($0)) }, on: child)
        keyframes("opacity", qs.map { NSNumber(value: childOpacity($0)) }, on: child)
        keyframes("opacity", qs.map { NSNumber(value: dimOpacity($0)) }, on: dim)
        CATransaction.commit()
    }

    /// A transform (for a layer anchored at its bottom-left corner) that maps
    /// rectangle `a` onto rectangle `b`.
    private func mapping(from a: CGRect, to b: CGRect) -> CATransform3D {
        let sx = b.width / a.width
        let sy = b.height / a.height
        let scale = CATransform3DMakeScale(sx, sy, 1)
        let move = CATransform3DMakeTranslation(b.minX - a.minX * sx, b.minY - a.minY * sy, 0)
        return CATransform3DConcat(scale, move)
    }
}

// MARK: - Glide

/// Two neighbouring boards on the board above, and a camera drifting from
/// one to the other: it eases back until both are in view, crosses, and
/// eases in again. `t` runs from 0 (looking at the first board, full screen)
/// to 1 (looking at the second).
/// A sideways scene: a glide to a neighbouring board or a slide to another
/// Main. `t` runs from 0 (where you are) to 1 (where you're going).
@MainActor
private protocol SideScene: AnyObject {
    var stage: Stage { get }
    func apply(_ t: CGFloat)
    func play(from t0: CGFloat, to t1: CGFloat, start: CFTimeInterval, length: CFTimeInterval,
              curve: CAMediaTimingFunction)
    func addTo(_ image: CGImage, fadeIn: CFTimeInterval)
}

@MainActor
private final class Glide: SideScene {
    /// The easing of a glide played start to finish.
    static let playedCurve = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.25, 1.0)
    let stage: Stage
    private let a: CGRect
    private let b: CGRect
    private let mid: CGRect
    private let bounds: CGRect
    private let above = CALayer()
    private let fromHolder = CALayer()
    private let toHolder = CALayer()

    init(screen: NSScreen, from: CGRect, to: CGRect) {
        stage = Stage(frame: screen.frame)
        bounds = stage.bounds
        let o = screen.frame.origin
        a = from.offsetBy(dx: -o.x, dy: -o.y)
        b = to.offsetBy(dx: -o.x, dy: -o.y)
        // Far enough back to see both boards, with a little air, inside the screen.
        let both = a.union(b)
        let air = both.insetBy(dx: -both.width * 0.06, dy: -both.height * 0.06)
        mid = air.intersection(bounds).isNull ? bounds : air.intersection(bounds)
        for holder in [above, fromHolder, toHolder] {
            holder.anchorPoint = .zero
            holder.frame = bounds
            stage.content.addSublayer(holder)
        }
    }

    func addAbove(_ image: CGImage) { add(image, to: above, fadeIn: 0) }
    func addFrom(_ image: CGImage) { add(image, to: fromHolder, fadeIn: 0) }
    func addTo(_ image: CGImage, fadeIn: CFTimeInterval = 0) { add(image, to: toHolder, fadeIn: fadeIn) }

    private func add(_ image: CGImage, to holder: CALayer, fadeIn: CFTimeInterval) {
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = .zero
        layer.frame = bounds
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        holder.addSublayer(layer)
        CATransaction.commit()
        if fadeIn > 0 {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 0
            f.toValue = 1
            f.duration = fadeIn
            f.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(f, forKey: "fadeIn")
        }
    }

    /// The view between two rectangles, shrinking or growing smoothly
    /// (geometrically) around the point they share.
    private func between(_ r0: CGRect, _ r1: CGRect, _ u: CGFloat) -> CGRect {
        func size(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * pow(y / x, u) }
        let w = size(r0.width, r1.width), h = size(r0.height, r1.height)
        let fx = abs(r1.width - r0.width) < 0.5 ? u : (w - r0.width) / (r1.width - r0.width)
        let fy = abs(r1.height - r0.height) < 0.5 ? u : (h - r0.height) / (r1.height - r0.height)
        return CGRect(x: r0.minX + (r1.minX - r0.minX) * fx, y: r0.minY + (r1.minY - r0.minY) * fy,
                      width: w, height: h)
    }

    private func view(_ t: CGFloat) -> CGRect {
        t < 0.5 ? between(a, mid, t / 0.5) : between(mid, b, (t - 0.5) / 0.5)
    }

    private func smooth(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let u = min(max((x - e0) / (e1 - e0), 0), 1)
        return u * u * (3 - 2 * u)
    }

    private func aboveT(_ t: CGFloat) -> CATransform3D { mapping(from: view(t), to: bounds) }
    private func fromT(_ t: CGFloat) -> CATransform3D { CATransform3DConcat(mapping(from: bounds, to: a), aboveT(t)) }
    private func toT(_ t: CGFloat) -> CATransform3D { CATransform3DConcat(mapping(from: bounds, to: b), aboveT(t)) }
    // The board you're leaving gives way to the view from above as the
    // camera pulls back; the new one takes over as it closes in.
    private func fromAlpha(_ t: CGFloat) -> Float { Float(1 - smooth(0.04, 0.42, t)) }
    private func toAlpha(_ t: CGFloat) -> Float { Float(smooth(0.58, 0.96, t)) }

    func apply(_ t: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        above.transform = aboveT(t)
        fromHolder.transform = fromT(t)
        toHolder.transform = toT(t)
        fromHolder.opacity = fromAlpha(t)
        toHolder.opacity = toAlpha(t)
        CATransaction.commit()
    }

    func play(from t0: CGFloat, to t1: CGFloat, start: CFTimeInterval, length: CFTimeInterval,
              curve: CAMediaTimingFunction) {
        let steps = 40
        let ts = (0...steps).map { t0 + (t1 - t0) * CGFloat($0) / CGFloat(steps) }
        func keyframes(_ key: String, _ values: [Any], on layer: CALayer) {
            let k = CAKeyframeAnimation(keyPath: key)
            k.values = values
            k.calculationMode = .linear
            k.timingFunction = curve
            k.duration = length
            k.beginTime = layer.convertTime(start, from: nil)
            k.fillMode = .backwards
            k.preferredFrameRateRange = smoothest   // 120 Hz on ProMotion screens
            layer.add(k, forKey: key)
        }
        apply(t1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyframes("transform", ts.map { NSValue(caTransform3D: aboveT($0)) }, on: above)
        keyframes("transform", ts.map { NSValue(caTransform3D: fromT($0)) }, on: fromHolder)
        keyframes("transform", ts.map { NSValue(caTransform3D: toT($0)) }, on: toHolder)
        keyframes("opacity", ts.map { NSNumber(value: fromAlpha($0)) }, on: fromHolder)
        keyframes("opacity", ts.map { NSNumber(value: toAlpha($0)) }, on: toHolder)
        CATransaction.commit()
    }

    private func mapping(from r0: CGRect, to r1: CGRect) -> CATransform3D {
        let sx = r1.width / r0.width
        let sy = r1.height / r0.height
        return CATransform3DConcat(CATransform3DMakeScale(sx, sy, 1),
                                   CATransform3DMakeTranslation(r1.minX - r0.minX * sx, r1.minY - r0.minY * sy, 0))
    }
}

// MARK: - Slide

/// Two Mains side by side, like Spaces: the one you're on slides off to one
/// side as the other comes in, both easing back a little on the way.
@MainActor
private final class Slide: SideScene {
    let stage: Stage
    private let bounds: CGRect
    private let direction: CGFloat
    private let fromHolder = CALayer()
    private let toHolder = CALayer()
    private let gapW: CGFloat = 36

    init(screen: NSScreen, direction: Int) {
        stage = Stage(frame: screen.frame)
        bounds = stage.bounds
        self.direction = direction >= 0 ? 1 : -1
        for holder in [fromHolder, toHolder] {
            holder.anchorPoint = .zero
            holder.frame = bounds
            holder.masksToBounds = true
            holder.cornerRadius = 16
            holder.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            stage.content.addSublayer(holder)
        }
    }

    func addFrom(_ image: CGImage) { add(image, to: fromHolder, fadeIn: 0) }
    func addTo(_ image: CGImage, fadeIn: CFTimeInterval) { add(image, to: toHolder, fadeIn: fadeIn) }

    private func add(_ image: CGImage, to holder: CALayer, fadeIn: CFTimeInterval) {
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = .zero
        layer.frame = bounds
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        holder.addSublayer(layer)
        CATransaction.commit()
        if fadeIn > 0 {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 0
            f.toValue = 1
            f.duration = fadeIn
            f.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(f, forKey: "fadeIn")
        }
    }

    /// Where a board sits `k` screens across (0 = in view), eased back a
    /// little in the middle of the trip.
    private func spot(_ k: CGFloat, _ t: CGFloat) -> CGRect {
        let scale = 1 - 0.08 * sin(.pi * min(max(t, 0), 1))
        let w = bounds.width * scale, h = bounds.height * scale
        let cx = bounds.midX + k * (bounds.width + gapW) * scale
        return CGRect(x: cx - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func fromT(_ t: CGFloat) -> CATransform3D { mapping(from: bounds, to: spot(-direction * t, t)) }
    private func toT(_ t: CGFloat) -> CATransform3D { mapping(from: bounds, to: spot(direction * (1 - t), t)) }

    func apply(_ t: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fromHolder.removeAllAnimations()
        toHolder.removeAllAnimations()
        fromHolder.transform = fromT(t)
        toHolder.transform = toT(t)
        CATransaction.commit()
    }

    func play(from t0: CGFloat, to t1: CGFloat, start: CFTimeInterval, length: CFTimeInterval,
              curve: CAMediaTimingFunction) {
        let steps = 40
        let ts = (0...steps).map { t0 + (t1 - t0) * CGFloat($0) / CGFloat(steps) }
        func keyframes(_ values: [Any], on layer: CALayer) {
            let k = CAKeyframeAnimation(keyPath: "transform")
            k.values = values
            k.calculationMode = .linear
            k.timingFunction = curve
            k.duration = length
            k.beginTime = layer.convertTime(start, from: nil)
            k.fillMode = .backwards
            k.preferredFrameRateRange = smoothest
            layer.add(k, forKey: "transform")
        }
        apply(t1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyframes(ts.map { NSValue(caTransform3D: fromT($0)) }, on: fromHolder)
        keyframes(ts.map { NSValue(caTransform3D: toT($0)) }, on: toHolder)
        CATransaction.commit()
    }

    private func mapping(from r0: CGRect, to r1: CGRect) -> CATransform3D {
        let sx = r1.width / r0.width
        let sy = r1.height / r0.height
        return CATransform3DConcat(CATransform3DMakeScale(sx, sy, 1),
                                   CATransform3DMakeTranslation(r1.minX - r0.minX * sx, r1.minY - r0.minY * sy, 0))
    }
}

// MARK: - Stage

/// The cover over the screen during a zoom.
@MainActor
private final class Stage {
    let window: NSWindow
    let content = CALayer()
    var bounds: CGRect { content.bounds }

    init(frame: CGRect) {
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(frame, display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.anchorPoint = .zero
        content.frame = CGRect(origin: .zero, size: frame.size)
        content.masksToBounds = true
        content.backgroundColor = NSColor.black.cgColor
        root.addSublayer(content)
        CATransaction.commit()
    }

    /// Fades the cover away to reveal the real windows, then removes it.
    func dismiss(after delay: CFTimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64((delay + 0.02) * 1_000_000_000))
        await NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            self.window.animator().alphaValue = 0
        }
        window.orderOut(nil)
    }
}
