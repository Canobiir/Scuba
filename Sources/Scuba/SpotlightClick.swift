import AppKit
import ApplicationServices

/// Hold Hyper (the panels light up) and click a window: it's blown up over
/// the board so you can work in it. Hyper + click it again (or Hyper +
/// Return) puts it back in its panel. Hyper + click another window to switch.
/// Hyper + click a porthole spotlights the window it stands for.
@MainActor
final class SpotlightClick {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    fileprivate var tap: CFMachPort?
    private var swallowNextUp = false

    init(controller pick: @escaping () -> Controller) {
        self.pick = pick
    }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: spotlightTapCallback,
                                          userInfo: refcon) else {
            NSLog("Scuba: couldn't watch clicks for Spotlight (needs Accessibility)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true to swallow the event. `location` is top-left screen coordinates.
    fileprivate func handle(_ type: CGEventType, at location: CGPoint, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .leftMouseDown:
            let hyper = flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
            guard hyper, !flags.contains(.maskShift), !controller.onSurface, AXIsProcessTrusted() else { return false }
            // Clicks on the gaps between panels are for resizing (Hyper + drag).
            let h = NSScreen.screens.first?.frame.height ?? 0
            let p = CGPoint(x: location.x, y: h - location.y)
            if controller.divider(near: p, tolerance: 24) != nil { return false }
            // A porthole: spotlight the window it stands for.
            if let w = controller.portholeWindow(at: p) {
                swallowNextUp = true
                controller.spotlight(w)
                return true
            }
            guard let hit = controller.windows.windowAt(location),
                  controller.isOnScreenBoardWindow(hit.id) else { return false }
            swallowNextUp = true
            controller.spotlight(hit.id)
            return true

        case .leftMouseUp:
            if swallowNextUp {
                swallowNextUp = false
                return true
            }
            return false

        default:
            return false
        }
    }
}

private func spotlightTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<SpotlightClick>.fromOpaque(refcon).takeUnretainedValue()
    let location = event.location
    let flags = event.flags
    let swallow = MainActor.assumeIsolated {
        owner.handle(type, at: location, flags: flags)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
