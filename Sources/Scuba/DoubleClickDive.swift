import AppKit
import ApplicationServices

/// Double-click a window's title bar: a window on a board nested inside the
/// one you're on takes you straight to that board, and a window on the
/// board you're on goes into Spotlight (double-click again to put it back).
/// Double-clicks on the bar's buttons, tabs and text fields are left to the
/// app. Inactive on your plain desktop.
@MainActor
final class DoubleClickDive {
    /// The boards of the screen under the pointer (each display has its own).
    private let pick: () -> Controller
    private var controller: Controller { locked ?? pick() }
    /// Held for the length of one gesture, so it stays on one screen.
    private var locked: Controller?
    fileprivate var tap: CFMachPort?
    private var swallowNextUp = false

    /// Title bar plus toolbar height counted as "the banner" (points).
    private let bannerHeight: CGFloat = 56

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
                                          callback: doubleClickTapCallback,
                                          userInfo: refcon) else {
            NSLog("Scuba: couldn't watch double-clicks (needs Accessibility)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true to swallow the event. `location` is top-left screen coordinates.
    fileprivate func handle(_ type: CGEventType, at location: CGPoint, clicks: Int64,
                            flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .leftMouseDown:
            guard clicks == 2, !controller.onSurface, AXIsProcessTrusted() else { return false }
            // Leave modified clicks (Hyper + drag etc.) alone.
            let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            guard flags.intersection(mods).isEmpty else { return false }
            guard let hit = controller.windows.windowAt(location),
                  location.y - hit.bounds.minY <= bannerHeight else { return false }
            if let target = controller.diveTarget(for: hit.id) {
                swallowNextUp = true
                controller.jump(to: target.path, panel: target.panel, window: hit.id)
                return true
            }
            // On the board you're on: Spotlight it (or put it back).
            guard controller.isOnScreenBoardWindow(hit.id), isBareBar(at: location) else { return false }
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

    /// True when the point is on the bar itself (the title bar or empty
    /// toolbar), not on a button, tab or text field in it.
    private func isBareBar(at p: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &found) == .success,
              let element = found else { return true }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let r = role as? String ?? ""
        return ["AXWindow", "AXToolbar", "AXGroup", "AXUnknown"].contains(r)
    }
}

private func doubleClickTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                    refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<DoubleClickDive>.fromOpaque(refcon).takeUnretainedValue()
    let location = event.location
    let clicks = event.getIntegerValueField(.mouseEventClickState)
    let flags = event.flags
    let swallow = MainActor.assumeIsolated {
        owner.handle(type, at: location, clicks: clicks, flags: flags)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
