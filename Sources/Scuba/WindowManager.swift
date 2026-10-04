import AppKit
import ApplicationServices

// Private but long-standing API (used by Rectangle, AeroSpace, yabai and
// others) that maps an accessibility window element to its window number.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Finds, moves and resizes other apps' windows through the Accessibility API.
/// All rectangles passed in are AppKit screen coordinates (origin bottom-left).
final class WindowManager {
    private var cache: [CGWindowID: AXUIElement] = [:]
    private var lastRefresh = Date.distantPast
    private(set) var parked: Set<CGWindowID> = []
    /// The smallest size each window has agreed to (some apps won't shrink
    /// below a minimum). Learned when a window refuses a smaller size.
    private(set) var minSizes: [CGWindowID: CGSize] = [:]

    func minSize(_ id: CGWindowID) -> CGSize? { minSizes[id] }

    // MARK: Lookup

    /// Rebuilds the map of every standard window of every regular app.
    func refresh() {
        lastRefresh = Date()
        let old = cache
        cache.removeAll()
        let myPid = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPid {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            if result == .cannotComplete {
                // The app is busy and didn't answer in time: its windows are
                // still there, so keep what we knew rather than lose them.
                for (id, e) in old {
                    var pid: pid_t = 0
                    if AXUIElementGetPid(e, &pid) == .success, pid == app.processIdentifier { cache[id] = e }
                }
                continue
            }
            guard result == .success, let windows = value as? [AXUIElement] else { continue }
            for w in windows {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(w, &id) == .success, id != 0 {
                    cache[id] = w
                }
            }
        }
    }

    func exists(_ id: CGWindowID) -> Bool { cache[id] != nil }

    private func element(_ id: CGWindowID) -> AXUIElement? {
        if let e = cache[id] { return e }
        // A window we don't know (often one that just closed): look again,
        // but not more than twice a second, so a few closed windows can't
        // set off a storm of full scans.
        guard Date().timeIntervalSince(lastRefresh) > 0.5 else { return nil }
        refresh()
        return cache[id]
    }

    /// The window you're using, in any app. Tries several ways, because
    /// macOS doesn't always answer the first one.
    func focusedWindowID() -> CGWindowID? {
        let myPid = ProcessInfo.processInfo.processIdentifier
        var pid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // If our own menu or overlay is in front, use the app under it.
        if pid == nil || pid == myPid {
            pid = frontmostWindowOwner(excluding: myPid)
        }
        guard let pid else { return nil }

        // 1) Ask the app for its focused window, then its main window.
        let axApp = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attribute as CFString, &ref) == .success,
               let value = ref {
                let window = value as! AXUIElement
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(window, &id) == .success, id != 0 {
                    cache[id] = window
                    return id
                }
            }
        }

        // 2) Fall back to the app's frontmost window on screen.
        if let id = topWindow(of: pid) {
            refresh()
            if cache[id] != nil { return id }
        }
        return nil
    }

    /// Ordinary on-screen windows, front to back.
    private func onScreenWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    private func topWindow(of pid: pid_t) -> CGWindowID? {
        for info in onScreenWindows() where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            if let n = info[kCGWindowNumber as String] as? Int { return CGWindowID(n) }
        }
        return nil
    }

    private func bounds(of info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    /// The frontmost ordinary window under a point (top-left screen coordinates).
    func windowAt(_ point: CGPoint) -> (id: CGWindowID, bounds: CGRect)? {
        let myPid = ProcessInfo.processInfo.processIdentifier
        for info in onScreenWindows() {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != myPid,
                  let n = info[kCGWindowNumber as String] as? Int,
                  let b = bounds(of: info), b.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            return (CGWindowID(n), b)
        }
        return nil
    }

    /// The window right under a point (top-left screen coordinates), with no
    /// leeway around its edges, not counting Scuba's own.
    func windowExactlyAt(_ point: CGPoint) -> CGWindowID? {
        let myPid = ProcessInfo.processInfo.processIdentifier
        for info in onScreenWindows() {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != myPid,
                  let n = info[kCGWindowNumber as String] as? Int,
                  let b = bounds(of: info), b.contains(point) else { continue }
            return CGWindowID(n)
        }
        return nil
    }

    /// Every window whose edge or inside is within reach of a point, front
    /// to back. Grabbing a window's edge can land just outside it, over the
    /// window next door, so a resize has to look at all of them.
    func windowsNear(_ point: CGPoint) -> [(id: CGWindowID, bounds: CGRect)] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        var out: [(id: CGWindowID, bounds: CGRect)] = []
        for info in onScreenWindows() {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != myPid,
                  let n = info[kCGWindowNumber as String] as? Int,
                  let b = bounds(of: info), b.insetBy(dx: -10, dy: -10).contains(point) else { continue }
            out.append((CGWindowID(n), b))
        }
        return out
    }

    /// Current bounds of a window (top-left screen coordinates).
    func bounds(of id: CGWindowID) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return list.first.flatMap { bounds(of: $0) }
    }

    private func frontmostWindowOwner(excluding myPid: pid_t) -> pid_t? {
        for info in onScreenWindows() {
            if let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != myPid { return owner }
        }
        return nil
    }

    /// Every window found by the last refresh().
    func allIDs() -> [CGWindowID] { Array(cache.keys) }

    /// The process that owns a window (from the last refresh()).
    func pid(of id: CGWindowID) -> pid_t? {
        guard let e = cache[id] else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(e, &pid) == .success else { return nil }
        return pid
    }

    func appIcon(_ id: CGWindowID) -> NSImage? {
        guard let pid = pid(of: id) else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }

    func appName(_ id: CGWindowID) -> String {
        guard let e = element(id) else { return "Window" }
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Window"
    }

    func focus(_ id: CGWindowID) {
        guard let e = element(id) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: Geometry

    /// Height of the primary screen; AX coordinates are measured down from its top.
    private var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private func axPoint(for rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX, y: primaryHeight - rect.maxY)
    }

    private func currentFrame(_ e: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private func setPosition(_ e: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v)
        }
    }

    private func setSize(_ e: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v)
        }
    }

    /// Ordinary windows currently on screen, by window number.
    /// The windows on one display (by where their middle is). Cheap: no app is asked.
    func onScreenIDs(on screen: NSScreen) -> Set<CGWindowID> {
        let top = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        let area = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)   // top-left origin
        var out = Set<CGWindowID>()
        for info in onScreenWindows() {
            guard let n = info[kCGWindowNumber as String] as? Int, let b = bounds(of: info),
                  area.contains(CGPoint(x: b.midX, y: b.midY)) else { continue }
            out.insert(CGWindowID(n))
        }
        return out
    }

    func onScreenIDs() -> Set<CGWindowID> {
        var out = Set<CGWindowID>()
        for info in onScreenWindows() {
            if let n = info[kCGWindowNumber as String] as? Int { out.insert(CGWindowID(n)) }
        }
        return out
    }

    /// True for normal document/app windows (not dialogs, sheets or panels).
    /// Uses only windows already found by refresh(), so it's cheap.
    func isStandard(_ id: CGWindowID) -> Bool {
        guard let e = cache[id] else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &ref) == .success,
              let subrole = ref as? String else { return false }
        return subrole == kAXStandardWindowSubrole
    }

    /// A window's current frame in AppKit coordinates.
    func frame(of id: CGWindowID) -> CGRect? {
        guard let e = element(id), let f = currentFrame(e) else { return nil }
        return CGRect(x: f.minX, y: primaryHeight - f.minY - f.height, width: f.width, height: f.height)
    }

    /// Moves and resizes a window to an AppKit-coordinate rectangle.
    func setFrame(_ id: CGWindowID, _ rect: CGRect) {
        guard let e = element(id) else { return }
        var minimized: CFTypeRef?
        var restoring = false
        if AXUIElementCopyAttributeValue(e, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            restoring = true
            lastRestore = Date()
        }
        let origin = axPoint(for: rect)
        let target = CGRect(origin: origin, size: rect.size)
        parked.remove(id)
        lastTarget[id] = rect
        if restoring {
            // Coming back from the Dock takes a moment, and a move made during
            // it can be lost: place it again once it's back (wherever it's
            // meant to be by then).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.parked.contains(id), let r = self.lastTarget[id] else { return }
                let o = self.axPoint(for: r)
                self.setPosition(e, o)
                self.setSize(e, r.size)
                self.setPosition(e, o)
            }
        }
        if let now = currentFrame(e),
           abs(now.minX - target.minX) < 2, abs(now.minY - target.minY) < 2,
           abs(now.width - target.width) < 2, abs(now.height - target.height) < 2 {
            return
        }
        // Position, size, position again: some apps clamp size to the screen
        // based on their old position, so the second move settles it.
        setPosition(e, origin)
        setSize(e, rect.size)
        setPosition(e, origin)
        // Did it refuse to get that small? Many apps take a moment to resize,
        // so look again once it has settled (two looks that agree), rather
        // than mistaking a window that's still shrinking for one that won't.
        verifySize(id, e, rect, after: restoring ? 0.7 : 0.35)
    }

    /// Called when a window turns out not to shrink as far as asked (so a
    /// pool can grow to fit it).
    var onMinSizeLearned: (() -> Void)?

    /// Checks, once a window has had time to settle, whether it took the size
    /// it was asked for; learns (or forgets) how small it will go.
    private func verifySize(_ id: CGWindowID, _ e: AXUIElement, _ rect: CGRect, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Only if this is still where it's meant to be (not moved again since).
            guard let self, self.lastTarget[id] == rect, !self.parked.contains(id),
                  let first = self.currentFrame(e) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.lastTarget[id] == rect, !self.parked.contains(id),
                      let got = self.currentFrame(e),
                      abs(got.width - first.width) < 2, abs(got.height - first.height) < 2 else { return }
                self.learnSize(id, got: got.size, asked: rect.size)
            }
        }
    }

    private func learnSize(_ id: CGWindowID, got: CGSize, asked: CGSize) {
        let tooWide = got.width > asked.width + 4, tooTall = got.height > asked.height + 4
        let known = minSizes[id] ?? .zero
        // It took this size: anything bigger on record was wrong.
        let width = tooWide ? max(known.width, got.width) : (known.width > got.width + 4 ? 0 : known.width)
        let height = tooTall ? max(known.height, got.height) : (known.height > got.height + 4 ? 0 : known.height)
        let learned = CGSize(width: width, height: height)
        minSizes[id] = (learned.width == 0 && learned.height == 0) ? nil : learned
        if (tooWide && got.width > known.width + 2) || (tooTall && got.height > known.height + 2) {
            onMinSizeLearned?()
        }
    }

    /// Tucks a window into the bottom-right corner, out of the way.
    func park(_ id: CGWindowID, on screen: NSScreen) {
        guard !parked.contains(id), let e = element(id) else { return }
        let vf = screen.visibleFrame
        let size = currentFrame(e)?.size ?? CGSize(width: 800, height: 600)
        let (w, h) = (size.width, size.height)
        // A corner whose overhang doesn't land on another display (with a
        // screen to the right, tuck bottom-left instead, and so on).
        let corners = [
            CGRect(x: vf.maxX - 1, y: vf.minY - h + 1, width: w, height: h),   // bottom-right
            CGRect(x: vf.minX + 1 - w, y: vf.minY - h + 1, width: w, height: h), // bottom-left
            CGRect(x: vf.maxX - 1, y: vf.maxY - 1, width: w, height: h),       // top-right
            CGRect(x: vf.minX + 1 - w, y: vf.maxY - 1, width: w, height: h),   // top-left
        ]
        let others = NSScreen.screens.filter { $0 != screen }.map { $0.frame }
        let spot = corners.first { c in
            let overhang = c.insetBy(dx: 2, dy: 2)
            return !others.contains { $0.intersects(overhang) }
        } ?? corners[0]
        // Where it was, if it was showing: macOS sometimes leaves a stale
        // picture of a window behind after it's moved off screen (Safari
        // especially), until something else redraws there.
        let before = frame(of: id)
        setPosition(e, axPoint(for: spot))
        parked.insert(id)
        if let before {
            let showing = before.intersection(vf)
            if !showing.isNull, showing.width > 8, showing.height > 8 { ScreenRepaint.flash(showing) }
        }
    }

    /// A window's frame measured down from the top of the main screen (the
    /// way AppleScript reports a window's bounds).
    func scriptFrame(of id: CGWindowID) -> CGRect? {
        guard let e = element(id) else { return nil }
        return currentFrame(e)
    }

    /// Changes a window's size where it sits (tucked away or not).
    func nudgeSize(_ id: CGWindowID, to size: CGSize) {
        guard let e = element(id) else { return }
        setSize(e, size)
    }

    /// A window's title, as its app reports it.
    func title(of id: CGWindowID) -> String? {
        guard let e = element(id) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Closes a window the way its close button does (its app may ask to
    /// save first).
    func close(_ id: CGWindowID) {
        guard let e = element(id) else { return }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXCloseButtonAttribute as CFString, &button) == .success, let b = button {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
        }
        parked.remove(id)
    }

    /// Asks a tucked-away window to take a size without bringing it into
    /// view, to see whether it will shrink that far.
    func resizeTucked(_ id: CGWindowID, to size: CGSize) {
        guard parked.contains(id), let e = element(id) else { return }
        setSize(e, size)
    }

    /// Tucked-away windows an app dragged back into view. Some apps (Safari,
    /// for one) pull an off-screen window back on screen when they come
    /// forward. Only one app's windows when `pid` is given.
    func escaped(on screen: NSScreen, pid: pid_t? = nil) -> [CGWindowID] {
        // Any real part of it showing counts, not just its middle: a window
        // pulled half back into a corner is still in the way. A tucked
        // window shows a sliver at most (macOS keeps a strip of it on screen).
        let vf = screen.visibleFrame
        return Array(parked).filter { id in
            if let pid, self.pid(of: id) != pid { return false }
            guard let f = frame(of: id) else { return false }
            let showing = f.intersection(vf)
            return !showing.isNull && showing.width > 8 && showing.height > 8
        }
    }

    /// Tucks a window away again after an app pulled it back into view.
    func repark(_ id: CGWindowID, on screen: NSScreen) {
        parked.remove(id)
        park(id, on: screen)
    }

    // MARK: Minimized while tucked away

    /// Where each window was last asked to go.
    private var lastTarget: [CGWindowID: CGRect] = [:]

    /// Where a window was last asked to go (AppKit coordinates).
    func target(of id: CGWindowID) -> CGRect? { lastTarget[id] }

    /// When a window last came back from being minimized.
    private(set) var lastRestore = Date.distantPast

    func isMinimized(_ id: CGWindowID) -> Bool {
        guard let e = cache[id] else { return false }
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, kAXMinimizedAttribute as CFString, &v) == .success && (v as? Bool) == true
    }

    /// Minimizes a tucked-away window, which takes it out of Mission Control
    /// even while its app has other windows in view. It stays tucked away;
    /// placing it anywhere (setFrame) brings it back.
    func minimize(_ id: CGWindowID) {
        guard parked.contains(id), let e = cache[id] else { return }
        AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Brings a minimized window back (where it was: still tucked away if it was).
    func unminimize(_ id: CGWindowID) {
        guard let e = cache[id] else { return }
        AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        lastRestore = Date()
    }

    /// Brings every parked window back to the middle of the screen.
    func unparkAll(on screen: NSScreen) {
        let vf = screen.visibleFrame
        for id in parked {
            guard let e = element(id) else { continue }
            let size = currentFrame(e)?.size ?? CGSize(width: vf.width * 0.6, height: vf.height * 0.6)
            let rect = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                              width: size.width, height: size.height)
            setPosition(e, axPoint(for: rect))
        }
        parked.removeAll()
    }
}


/// Makes macOS redraw part of the screen, wiping a stale picture a window
/// left behind when it moved away: a see-through window is put over the spot
/// for a moment and taken away again.
enum ScreenRepaint {
    static func flash(_ rect: CGRect) {
        for delay in [0.05, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = NSColor(white: 0, alpha: 0.01)
                w.hasShadow = false
                w.ignoresMouseEvents = true
                w.isReleasedWhenClosed = false
                w.level = .floating
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { w.orderOut(nil) }
            }
        }
    }
}
