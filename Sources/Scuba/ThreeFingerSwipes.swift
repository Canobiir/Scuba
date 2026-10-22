import AppKit
import Foundation
import QuartzCore

// MARK: - Raw trackpad touches

// macOS doesn't hand three-finger gestures to apps, so this reads the
// trackpad's raw touches through the private MultitouchSupport framework (the
// one BetterTouchTool and similar tools use). It's loaded at run time; if it
// can't be loaded, three-finger swipes simply don't work and nothing else is
// affected.

private typealias MTContactCallback =
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback?) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32

/// Where touch frames go (set once at start, read from the touch thread).
private var touchSink: ((Int, CGPoint) -> Void)?

/// Size of one touch record, and where its position sits in it (0–1 across
/// the trackpad, y up).
private let touchStride = 96
private let touchXOffset = 32
private let touchYOffset = 36

/// Called for every frame of touches, on a background thread.
private let contactCallback: MTContactCallback = { _, data, count, _, _ in
    let n = Int(count)
    var cx: Float = 0, cy: Float = 0
    if let data, n > 0 {
        for i in 0..<n {
            let touch = data.advanced(by: i * touchStride)
            cx += touch.load(fromByteOffset: touchXOffset, as: Float.self)
            cy += touch.load(fromByteOffset: touchYOffset, as: Float.self)
        }
        cx /= Float(n)
        cy /= Float(n)
    }
    let centre = CGPoint(x: CGFloat(cx), y: CGFloat(cy))
    DispatchQueue.main.async { touchSink?(n, centre) }
    return 0
}

// MARK: - Three-finger swipes

/// Three fingers on the trackpad, no keys needed:
///  - swipe down: dive into the panel under the pointer (it follows your
///    fingers; lift past about a third of the way and it finishes),
///  - swipe up: come back up a level, the same way,
///  - swipe left / right: step to the next / previous board on this level
///    (from Main: the Main beside it, or a new blank one). A slow swipe shows
///    the next board sliding in and follows your fingers; let go early (or
///    swipe back) and it floats back.
@MainActor
final class ThreeFingerSwipes {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    private var devices: CFArray?

    private enum Mode { case idle, undecided, steering(zoomIn: Bool), sliding(direction: Int), done }
    private var mode: Mode = .idle
    private var origin = CGPoint.zero
    private var progress: CGFloat = 0

    /// Trackpad fractions: how far before a swipe counts, and a whole zoom
    /// or a whole trip sideways.
    private let sideStart: CGFloat = 0.035
    private let sideTravel: CGFloat = 0.22
    private let upDownStart: CGFloat = 0.03
    private let zoomTravel: CGFloat = 0.32
    /// When a sideways swipe started, so a quick flick counts even if short.
    private var slideStarted: CFTimeInterval = 0
    /// A three-finger click (pressed, not just touched), quick and barely
    /// moving: it spotlights the window (or porthole) under the pointer.
    /// A plain three-finger touch does nothing, so it never gets in the way
    /// of the swipes.
    private var downAt: CFTimeInterval = 0
    private var travel: CGFloat = 0
    private var clicked = false
    private let tapSlop: CGFloat = 0.015
    private let tapTime: CFTimeInterval = 0.5

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "threeFinger") }
        set { UserDefaults.standard.set(newValue, forKey: "threeFinger") }
    }

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
    }

    func start() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_NOW),
              let pList = dlsym(lib, "MTDeviceCreateList"),
              let pRegister = dlsym(lib, "MTRegisterContactFrameCallback"),
              let pStart = dlsym(lib, "MTDeviceStart") else {
            NSLog("Scuba: couldn't read the trackpad; three-finger swipes are off")
            return
        }
        let createList = unsafeBitCast(pList, to: MTDeviceCreateListFn.self)
        let register = unsafeBitCast(pRegister, to: MTRegisterFn.self)
        let startDevice = unsafeBitCast(pStart, to: MTDeviceStartFn.self)
        guard let list = createList()?.takeRetainedValue() else { return }
        devices = list   // keep the devices alive
        touchSink = { [weak self] fingers, centre in
            MainActor.assumeIsolated { self?.frame(fingers: fingers, at: centre) }
        }
        for i in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, i) else { continue }
            let ref = UnsafeMutableRawPointer(mutating: device)
            register(ref, contactCallback)
            _ = startDevice(ref, 0)
        }
    }

    private func frame(fingers: Int, at p: CGPoint) {
        guard enabled else { mode = .idle; return }
        guard fingers == 3 else {
            // A quick three-finger click that didn't become a swipe or a drag:
            // Spotlight what's under the pointer.
            if case .undecided = mode, clicked, fingers < 3, CACurrentMediaTime() - downAt < tapTime, travel < tapSlop {
                controller.spotlightAt(NSEvent.mouseLocation)
            }
            // Fingers lifted (or a fourth landed): the gesture is over.
            if case .steering = mode { controller.scrubEnd(commit: progress > 0.3) }
            if case .sliding = mode {
                let flick = CACurrentMediaTime() - slideStarted < 0.25 && progress > 0.15
                controller.sideScrubEnd(commit: progress > 0.3 || flick)
            }
            locked = nil
            mode = .idle
            progress = 0
            return
        }
        switch mode {
        case .idle:
            mode = .undecided
            origin = p
            downAt = CACurrentMediaTime()
            travel = 0
            clicked = false
            // Three fingers down: a swipe may follow. Take the screen's picture
            // now, so the zoom follows your fingers from the first moment.
            let c = pick()
            if !c.isBusy { c.animator.prepare(on: c.screen) }
        case .undecided:
            travel = max(travel, hypot(p.x - origin.x, p.y - origin.y))
            // Three-finger drag (an Accessibility setting) holds the mouse
            // button down: that's moving a window, not a swipe. (Held still,
            // it's a three-finger click, which spotlights like a tap.)
            if NSEvent.pressedMouseButtons != 0 {
                clicked = true
                if travel > tapSlop { mode = .done }
                return
            }
            let dx = p.x - origin.x, dy = p.y - origin.y
            if abs(dx) > sideStart, abs(dx) > abs(dy) * 1.5 {
                // Fingers to the left bring in the board on the right, like Spaces.
                let direction = dx < 0 ? 1 : -1
                let c = pick()
                if c.sideScrubBegin(direction) {
                    locked = c
                    mode = .sliding(direction: direction)
                    slideStarted = CACurrentMediaTime()
                    progress = abs(dx) / sideTravel
                    c.sideScrubUpdate(progress)
                } else {
                    mode = .done
                }
            } else if abs(dy) > upDownStart, abs(dy) >= abs(dx) {
                // Up rises out (like Mission Control); down dives in. With
                // Hyper held, up goes straight to your desktop from anywhere,
                // and down from your desktop lands on Main.
                let zoomIn = dy < 0
                let f = NSEvent.modifierFlags
                let hyper = f.contains(.control) && f.contains(.option) && f.contains(.command)
                let c = pick()
                if c.scrubBegin(zoomIn: zoomIn, at: NSEvent.mouseLocation, viaScroll: hyper, toDesktop: hyper) {
                    locked = c
                    mode = .steering(zoomIn: zoomIn)
                    origin = p
                } else {
                    mode = .done
                }
            }
        case .steering(let zoomIn):
            let travel = zoomIn ? origin.y - p.y : p.y - origin.y
            progress = max(0, travel) / zoomTravel
            controller.scrubUpdate(progress)
        case .sliding(let direction):
            let travel = direction > 0 ? origin.x - p.x : p.x - origin.x
            progress = max(0, travel) / sideTravel
            controller.sideScrubUpdate(progress)
        case .done:
            break
        }
    }
}
