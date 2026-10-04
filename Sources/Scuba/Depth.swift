import AppKit
import ApplicationServices
import ScreenCaptureKit

// MARK: - Depth shade

/// Darkens the desktop background a little more with each level you dive,
/// so depth is felt. It sits just above the desktop icons and below every
/// window, and lets clicks through. On the Surface it disappears: fresh air.
@MainActor
final class DepthShade {
    private var window: NSWindow?
    private var view: ShadeView?
    private var lastDepth = -1
    private var observer: NSObjectProtocol?

    init() {
        // When the display's resolution changes, the screen's size in
        // points changes too. Without this the shade keeps its old, smaller
        // size and shows as a dark square in the bottom-left corner.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refit() }
        }
    }

    /// The display this shade covers (each display has its own).
    private var screenID: CGDirectDisplayID?

    private func refit() {
        guard let screen = NSScreen.screens.first(where: { Controller.displayID(of: $0) == screenID })
                ?? NSScreen.screens.first else { return }
        update(depth: lastDepth, on: screen)
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "depthShade") }
        set { UserDefaults.standard.set(newValue, forKey: "depthShade") }
    }

    func update(depth: Int, on screen: NSScreen) {
        lastDepth = depth
        screenID = Controller.displayID(of: screen)
        guard enabled, depth >= 0 else {
            window?.orderOut(nil)
            return
        }
        if window == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = ShadeView(frame: CGRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            window = w
            view = v
        }
        window?.setFrame(screen.frame, display: true)
        view?.frame = CGRect(origin: .zero, size: screen.frame.size)
        view?.strength = min(0.18 + 0.14 * CGFloat(depth), 0.7)
        view?.needsDisplay = true
        window?.orderFront(nil)
    }
}

private final class ShadeView: NSView {
    var strength: CGFloat = 0.2

    override func draw(_ dirtyRect: NSRect) {
        // An even dim, plus a soft vignette toward the edges.
        NSColor(white: 0, alpha: strength * 0.55).setFill()
        bounds.fill()
        let gradient = NSGradient(colors: [
            NSColor(white: 0, alpha: 0),
            NSColor(white: 0, alpha: strength * 0.6),
        ])
        gradient?.draw(in: bounds, relativeCenterPosition: .zero)
    }
}

// MARK: - Hold Hyper to reveal

/// While you hold Ctrl + Option + Cmd, the board's structure fades in:
/// panel outlines, names and what's inside. Let go and it disappears.
@MainActor
final class HyperReveal {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    private var monitors: [Any] = []
    private var pending: Task<Void, Never>?
    private var hyperDown = false

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
    }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.changed(e.modifierFlags)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.changed(e.modifierFlags)
            return e
        }) { monitors.append(m) }
    }

    private func changed(_ flags: NSEvent.ModifierFlags) {
        let hyper = flags.contains(.control) && flags.contains(.option) && flags.contains(.command)
        if hyper && !hyperDown {
            // A fresh press of Hyper, on the screen under the pointer:
            // nothing's been used during it yet.
            locked = pick()
            controller.hyperUsed = false
            // Hyper usually comes before a dive: take the screen's picture now,
            // so the zoom can start the moment the key lands.
            if !controller.isBusy { controller.animator.prepare(on: controller.screen) }
        }
        hyperDown = hyper
        if hyper {
            guard pending == nil, !controller.revealing, !controller.onSurface, !controller.hyperUsed else { return }
            // A short wait, so quick shortcuts don't flash the overlay.
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pending = nil
                guard !self.controller.hyperUsed, !self.controller.onSurface else { return }
                self.controller.revealing = true
                self.controller.showNumbers(persistent: true)
            }
        } else {
            pending?.cancel()
            pending = nil
            if controller.revealing {
                controller.revealing = false
                controller.numbers.hide()
            }
            locked = nil
        }
    }
}

// MARK: - Hyper + scroll to zoom

/// Hold Hyper and scroll.
///  - Trackpad: the zoom follows your fingers. Pull toward you to dive into
///    the panel under the pointer, push away to come back up; let go past
///    about a third of the way and it finishes, otherwise it floats back.
///  - Mouse wheel: one zoom step per flick.
@MainActor
final class ScrollZoom {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    fileprivate var tap: CFMachPort?

    // Mouse wheel
    private var total: Double = 0
    private var lastEvent = Date.distantPast
    private var quietUntil = Date.distantPast

    // Trackpad
    private var steering = false
    private var ignoring = false
    private var direction: Double = 1
    private var progress: CGFloat = 0
    private var watchdog: Task<Void, Never>?
    private var sideTotal: Double = 0
    /// Sideways scroll distance (points) that steps to the next board.
    private let sideStep: Double = 40
    /// Scroll distance (points) for a whole zoom.
    private let distance: Double = 260
    /// How far you have to scroll before a zoom starts.
    private let deadZone: Double = 6

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
    }

    func start() {
        guard tap == nil else { return }
        let mask = 1 << CGEventType.scrollWheel.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: scrollTapCallback,
                                          userInfo: refcon) else {
            NSLog("Scuba: couldn't watch scrolling (needs Accessibility)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true to swallow the scroll.
    fileprivate func handle(_ type: CGEventType, delta: Double, sideways dx: Double, continuous: Bool,
                            phase: Int64, momentum: Int64,
                            flags: CGEventFlags, location: CGPoint) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .scrollWheel else { return false }
        let hyper = flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
        guard hyper else {
            // Let go of Hyper mid-gesture: finish or float back from where you are.
            if steering { letGo() }
            total = 0
            sideTotal = 0
            ignoring = false
            return false
        }
        // Scrolling with Hyper is for zooming: don't pop up the panel outlines.
        controller.quietReveal()
        let h = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: location.x, y: h - location.y)

        guard continuous else { return wheel(delta, at: point) }

        // The coast after your fingers lift isn't part of the gesture.
        if momentum != 0 { return true }

        let began = phase == 1 || phase == 128
        let ended = phase == 4 || phase == 8
        if began {
            if steering { letGo() }
            total = 0
            sideTotal = 0
            ignoring = false
        }
        if ignoring {
            if ended { ignoring = false; total = 0; sideTotal = 0 }
            return true
        }

        // Natural scrolling: the gesture that pulls content toward you dives in.
        total -= delta
        sideTotal -= dx
        // Mostly sideways: step to the neighbouring board, once per swipe.
        if !steering, abs(sideTotal) > sideStep, abs(sideTotal) > abs(total) * 1.5 {
            controller.stepSideways(sideTotal > 0 ? 1 : -1)
            ignoring = true
            sideTotal = 0
            return true
        }
        if !steering, abs(total) > deadZone, abs(total) >= abs(sideTotal) {
            let zoomIn = total > 0
            let c = pick()
            if c.scrubBegin(zoomIn: zoomIn, at: point, viaScroll: true) {
                locked = c
                steering = true
                direction = zoomIn ? 1 : -1
            } else {
                ignoring = true
            }
        }
        if steering {
            progress = CGFloat(max(0, total * direction - deadZone) / distance)
            controller.scrubUpdate(progress)
            // Some devices never send an end: treat a pause as letting go.
            watchdog?.cancel()
            watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, !Task.isCancelled, self.steering else { return }
                self.letGo()
            }
        }
        if ended {
            if steering { letGo() }
            total = 0
            sideTotal = 0
        }
        return true
    }

    private func letGo() {
        watchdog?.cancel()
        steering = false
        controller.scrubEnd(commit: progress > 0.3)
        locked = nil
        progress = 0
    }

    /// Mouse wheel: one zoom step per flick.
    private func wheel(_ delta: Double, at point: CGPoint) -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastEvent) > 0.3 { total = 0 }
        lastEvent = now
        guard now >= quietUntil else { return true }
        total -= delta
        if total > 2 {
            total = 0
            quietUntil = now.addingTimeInterval(0.6)
            controller.zoomIn(at: point, toMain: true)
        } else if total < -2 {
            total = 0
            quietUntil = now.addingTimeInterval(0.6)
            controller.zoomOutStep(throughToDesktop: true)
        }
        return true
    }
}

private func scrollTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<ScrollZoom>.fromOpaque(refcon).takeUnretainedValue()
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    let delta = continuous
        ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    let dx = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : 0
    let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let flags = event.flags
    let location = event.location
    let swallow = MainActor.assumeIsolated {
        owner.handle(type, delta: delta, sideways: dx, continuous: continuous, phase: phase, momentum: momentum,
                     flags: flags, location: location)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Wallpaper parallax

/// Your desktop picture zooms in a little with each level you dive, and back
/// out as you rise, so diving feels like moving through space. On the
/// Surface it steps aside and your real wallpaper shows.
///
/// The picture is your wallpaper exactly as it's showing right now (a
/// dynamic or moving wallpaper included), taken from the desktop itself.
/// That needs Screen Recording; without it, the wallpaper's file is used.
@MainActor
final class Backdrop {
    private var window: NSWindow?
    private let picture = CALayer()
    private var shownURL: URL?
    /// The wallpaper as it last looked, and when that was.
    private var native: CGImage?
    private var nativeTaken = Date.distantPast
    private var capturing = false
    private var showingNative = false
    private var lastDepth = -1
    private var lastCustom: URL?
    private var observer: NSObjectProtocol?
    private var screenID: CGDirectDisplayID?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "parallax") }
        set { UserDefaults.standard.set(newValue, forKey: "parallax") }
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let screen = NSScreen.screens.first(where: { Controller.displayID(of: $0) == self.screenID })
                        ?? NSScreen.screens.first else { return }
                self.update(depth: self.lastDepth, on: screen, custom: self.lastCustom)
            }
        }
    }

    /// - custom: a board's own wallpaper, shown instead of the Mac's.
    func update(depth: Int, on screen: NSScreen, custom: URL? = nil) {
        lastDepth = depth
        lastCustom = custom
        screenID = Controller.displayID(of: screen)
        // Keep the picture of the real wallpaper fresh, even from the Surface,
        // so it's ready the moment you dive (only when it's used at all).
        if enabled { refreshNative(on: screen) }
        guard enabled || custom != nil, depth >= 0 else {
            window?.orderOut(nil)
            return
        }
        if window == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = .black
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            // Just above the real wallpaper, below the desktop icons and every window.
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let root = CALayer()
            view.layer = root
            view.wantsLayer = true
            root.masksToBounds = true
            picture.contentsGravity = .resizeAspectFill
            root.addSublayer(picture)
            w.contentView = view
            window = w
        }
        // The board's own wallpaper, else the Mac's as it looks right now
        // (else its file, until a picture of it has been taken).
        if let url = custom {
            if url != shownURL || showingNative, let image = NSImage(contentsOf: url) {
                picture.contents = image
                shownURL = url
                showingNative = false
            }
        } else if let image = native {
            if !showingNative {
                picture.contents = image
                showingNative = true
                shownURL = nil
            }
        } else if let url = NSWorkspace.shared.desktopImageURL(for: screen), url != shownURL,
                  let image = NSImage(contentsOf: url) {
            picture.contents = image
            shownURL = url
            showingNative = false
        }
        window?.setFrame(screen.frame, display: false)
        window?.contentView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        let scale = enabled ? 1 + 0.06 * CGFloat(min(depth, 6)) : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // the zoom's camera move carries the motion
        picture.transform = CATransform3DIdentity
        picture.frame = CGRect(origin: .zero, size: screen.frame.size)
        picture.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        window?.orderFront(nil)
    }

    /// Takes a fresh picture of the real wallpaper now and then (it can
    /// change: a new picture, a dynamic one moving through the day).
    private func refreshNative(on screen: NSScreen) {
        guard !capturing, Date().timeIntervalSince(nativeTaken) > 30, CGPreflightScreenCaptureAccess() else { return }
        capturing = true
        let id = Controller.displayID(of: screen)
        let scale = screen.backingScaleFactor
        Task { @MainActor in
            let image = await Backdrop.captureWallpaper(displayID: id, scale: scale)
            self.capturing = false
            self.nativeTaken = Date()
            guard let image else { return }
            self.native = image
            self.showingNative = false   // swap the new picture in
            if self.lastCustom == nil, self.window?.isVisible == true {
                self.picture.contents = image
                self.showingNative = true
                self.shownURL = nil
            }
        }
    }

    /// The desktop picture window on a display, as it's drawn right now.
    nonisolated private static func captureWallpaper(displayID: CGDirectDisplayID, scale: CGFloat) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        // The Dock draws the wallpaper in a window called "Wallpaper-…", a level
        // below the standard desktop level. Failing that: anything the Dock
        // draws at or below the desktop.
        let level = Int(CGWindowLevelForKey(.desktopWindow))
        let dock = content.windows.filter { w in
            w.owningApplication?.bundleIdentifier == "com.apple.dock" && w.frame.intersects(display.frame)
        }
        let named = dock.filter { ($0.title ?? "").hasPrefix("Wallpaper") }
        let walls = named.isEmpty ? dock.filter { $0.windowLayer <= level } : named
        guard let wall = walls.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let c = SCStreamConfiguration()
        c.width = max(1, Int(wall.frame.width * scale))
        c.height = max(1, Int(wall.frame.height * scale))
        c.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: wall)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
    }

}
