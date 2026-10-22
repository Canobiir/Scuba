import AppKit
import ApplicationServices

/// Pinch on the trackpad to move through depth: spread your fingers to dive
/// into the panel under the pointer (or from your desktop into your boards),
/// pinch them together to come back up. One step per pinch.
///
/// Works with no keys held when the pointer is over empty space (the
/// desktop, a gap, an empty panel), so apps that use pinch to zoom their own
/// content (Safari, Preview, Maps) keep it. Hold Hyper to pinch anywhere.
@MainActor
final class PinchZoom {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    fileprivate var tap: CFMachPort?

    private var total: CGFloat = 0
    private var claimed = false     // this gesture is ours (swallow the rest of it)
    private var fired = false       // already took a step during this gesture
    private var withHyper = false   // Hyper held: goes between your desktop and Main
    private var quietUntil = Date.distantPast
    /// The zoom follows your fingers: spread and it dives, as far as your
    /// fingers go; let go past a third of the way and it finishes.
    private var following = false
    private var startSign: FloatingPointSign = .plus
    private var progress: CGFloat = 0
    /// How far a pinch goes for a whole zoom (magnification units).
    private let fullPinch: CGFloat = 0.55

    var follows: Bool {
        get { UserDefaults.standard.bool(forKey: "pinchFollows") }
        set { UserDefaults.standard.set(newValue, forKey: "pinchFollows") }
    }

    /// How far to pinch before it counts (magnification units, ~0.0–1.0).
    private let threshold: CGFloat = 0.22

    // Raw event type for trackpad pinches (not one of CGEventType's named cases).
    nonisolated fileprivate static let magnifyType: UInt32 = 30

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << PinchZoom.magnifyType
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: pinchTapCallback,
                                          userInfo: refcon) else {
            NSLog("Scuba: couldn't watch pinch gestures (needs Accessibility)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the event. `location` is top-left screen coordinates.
    fileprivate func handleMagnify(_ magnification: CGFloat, phase: NSEvent.Phase,
                                   location: CGPoint, flags: CGEventFlags) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        if phase.contains(.began) || phase.contains(.mayBegin) {
            total = 0
            fired = false
            let hyper = flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
            // Ours if Hyper is held, or nothing is under the pointer.
            claimed = hyper || controller.windows.windowAt(location) == nil
            withHyper = hyper
            following = false
            progress = 0
            // Take the screen's picture now, so the zoom follows from the
            // first moment.
            if claimed, follows, !controller.isBusy { controller.animator.prepare(on: controller.screen) }
        }
        guard claimed else { return false }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            claimed = false
            if following {
                following = false
                controller.scrubEnd(commit: !phase.contains(.cancelled) && progress > 0.3)
                locked = nil
            }
            return true
        }

        if follows {
            if following {
                total += magnification
                // Pinching back the other way undoes it, down to where you started.
                progress = max(0, abs(total) / fullPinch * (total.sign == startSign ? 1 : -1))
                controller.scrubUpdate(min(progress, 1.2))
                return true
            }
            guard !fired else { return true }
            total += magnification
            guard abs(total) > 0.04 else { return true }
            let h = NSScreen.screens.first?.frame.height ?? 0
            let point = CGPoint(x: location.x, y: h - location.y)
            let c = controller
            if c.scrubBegin(zoomIn: total > 0, at: point, viaScroll: withHyper, toDesktop: withHyper && total < 0) {
                locked = c
                following = true
                startSign = total.sign
                progress = abs(total) / fullPinch
                c.scrubUpdate(progress)
            } else {
                fired = true   // nowhere to go that way: the rest of this pinch is ignored
            }
            return true
        }

        guard !fired, Date() >= quietUntil else { return true }
        total += magnification
        if total > threshold {
            fired = true
            quietUntil = Date().addingTimeInterval(0.5)
            let h = NSScreen.screens.first?.frame.height ?? 0
            controller.zoomIn(at: CGPoint(x: location.x, y: h - location.y), toMain: withHyper)
        } else if total < -threshold {
            fired = true
            quietUntil = Date().addingTimeInterval(0.5)
            // With Hyper, pinching in from Main goes on to your desktop.
            if !controller.onSurface { controller.zoomOutStep(throughToDesktop: withHyper) }
        }
        return true
    }
}

private func pinchTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<PinchZoom>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { owner.reenable() }
        return Unmanaged.passUnretained(event)
    }

    let raw = type.rawValue
    if raw == PinchZoom.magnifyType, let ns = NSEvent(cgEvent: event), ns.type == .magnify {
        let magnification = ns.magnification
        let phase = ns.phase
        let location = event.location
        let flags = event.flags
        let swallow = MainActor.assumeIsolated {
            owner.handleMagnify(magnification, phase: phase, location: location, flags: flags)
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
    return Unmanaged.passUnretained(event)
}
