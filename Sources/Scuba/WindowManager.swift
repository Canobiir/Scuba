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

    /// Debug: forget the smallest size learned for a window, so it's
    /// measured fresh next time it's asked to shrink.
    func forgetMinimum(_ id: CGWindowID) {
        minSizes[id] = nil
        refusedOnce[id] = nil
    }

    // MARK: Lookup

    /// Rebuilds the map of every standard window of every regular app.
    func refresh() {
        lastRefresh = Date()
        let myPid = ProcessInfo.processInfo.processIdentifier
        let alone = WindowManager.leftAlone
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != myPid
                && !alone.contains($0.bundleIdentifier ?? "") }
            .map { $0.processIdentifier }
        // What we knew, by app: kept for an app too busy to answer.
        var old: [pid_t: [CGWindowID: AXUIElement]] = [:]
        for (id, e) in cache {
            var pid: pid_t = 0
            if AXUIElementGetPid(e, &pid) == .success { old[pid, default: [:]][id] = e }
        }
        // Every app is asked at once, so one slow app doesn't hold up the rest.
        let lock = NSLock()
        var found: [CGWindowID: AXUIElement] = [:]
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            var mine: [CGWindowID: AXUIElement] = [:]
            let axApp = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            if result == .cannotComplete {
                // The app is busy and didn't answer in time: its windows are
                // still there, so keep what we knew rather than lose them.
                mine = old[pid] ?? [:]
            } else if result == .success, let windows = value as? [AXUIElement] {
                for w in windows {
                    var id: CGWindowID = 0
                    if _AXUIElementGetWindow(w, &id) == .success, id != 0 { mine[id] = w }
                }
            }
            guard !mine.isEmpty else { return }
            lock.lock()
            found.merge(mine) { a, _ in a }
            lock.unlock()
        }
        cache = found
    }

    /// The same, unless it was just done (a glide asks, then the layout it
    /// plays asks again a moment later: once is enough).
    func refreshIfStale(_ age: TimeInterval = 0.15) {
        guard Date().timeIntervalSince(lastRefresh) > age else { return }
        refresh()
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

    /// Apps left alone: their windows float freely and are never arranged,
    /// tucked or moved (bundle identifiers).
    static var leftAlone: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "leftAloneApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "leftAloneApps") }
    }

    /// The process that owns a window (from the last refresh()).
    func pid(of id: CGWindowID) -> pid_t? {
        guard let e = cache[id] else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(e, &pid) == .success else { return nil }
        return pid
    }

    func appIcon(_ id: CGWindowID) -> NSImage? {
        guard let pid = pid(of: id) else { return nil }
        // One icon per app, kept (so its colour is worked out once).
        if let i = iconCache[pid] { return i }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        if iconCache.count > 120 { iconCache.removeAll() }
        iconCache[pid] = icon
        return icon
    }
    private var iconCache: [pid_t: NSImage] = [:]

    func appName(_ id: CGWindowID) -> String {
        guard let e = element(id) else { return "Window" }
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Window"
    }

    /// Brings a window to the top of its app's windows, without switching apps.
    func raise(_ id: CGWindowID) {
        guard let e = element(id) else { return }
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
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
        let origin = axPoint(for: rect)
        parked.remove(id)
        lastTarget[id] = rect
        liveSent[id] = nil
        // In a layout: gathered, then sent to every app at once (endBatch).
        if batch != nil {
            batch?.append((id, e, rect, origin))
            return
        }
        let r = place(e, origin: origin, size: rect.size)
        settle(id, e, rect, origin: origin, moved: r.moved, restoring: r.restoring)
    }

    // MARK: Batched moves (a layout)
    //
    // A layout used to move windows one after another, each waiting on its
    // app: one slow app (Music, an Electron app) held up every window after
    // it. Now a layout gathers its moves, sends each app its own on that
    // app's queue (the same queues live moves use, so they stay in order),
    // all apps at once, and waits for them together: as long as the slowest
    // app, not all of them added up. Every check is the same as before.

    private var batch: [(id: CGWindowID, element: AXUIElement, rect: CGRect, origin: CGPoint)]?
    private var batchDepth = 0

    func beginBatch() {
        batchDepth += 1
        if batch == nil { batch = [] }
    }

    /// Sends the gathered moves and waits for them, never longer than a
    /// moment: an app that's stuck finishes its own in the background.
    func endBatch() {
        batchDepth = max(0, batchDepth - 1)
        guard batchDepth == 0, let jobs = batch else { return }
        batch = nil
        guard !jobs.isEmpty else { return }
        var byApp: [pid_t: [(id: CGWindowID, element: AXUIElement, rect: CGRect, origin: CGPoint)]] = [:]
        for j in jobs {
            var pid: pid_t = 0
            AXUIElementGetPid(j.element, &pid)
            byApp[pid, default: []].append(j)
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var finished: [(CGWindowID, AXUIElement, CGRect, CGPoint, Bool, Bool)] = []
        var waiting = true
        for (pid, list) in byApp {
            liveQueue(for: pid).async(group: group) { [weak self] in
                guard let self else { return }
                for j in list {
                    let r = self.place(j.element, origin: j.origin, size: j.rect.size)
                    let item = (j.id, j.element, j.rect, j.origin, r.moved, r.restoring)
                    lock.lock()
                    let late = !waiting
                    if !late { finished.append(item) }
                    lock.unlock()
                    // Finished after the layout stopped waiting: checked on its own.
                    if late {
                        DispatchQueue.main.async { [weak self] in
                            self?.settle(item.0, item.1, item.2, origin: item.3, moved: item.4, restoring: item.5)
                        }
                    }
                }
            }
        }
        _ = group.wait(timeout: .now() + 1.2)
        lock.lock()
        waiting = false
        let done = finished
        lock.unlock()
        for d in done { settle(d.0, d.1, d.2, origin: d.3, moved: d.4, restoring: d.5) }
    }

    /// Puts a window at a spot (any thread: Accessibility calls only).
    /// `moved`: false when it was already there.
    private func place(_ e: AXUIElement, origin: CGPoint, size: CGSize) -> (moved: Bool, restoring: Bool) {
        var minimized: CFTypeRef?
        var restoring = false
        if AXUIElementCopyAttributeValue(e, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            restoring = true
        }
        if !restoring, let now = currentFrame(e),
           abs(now.minX - origin.x) < 2, abs(now.minY - origin.y) < 2,
           abs(now.width - size.width) < 2, abs(now.height - size.height) < 2 {
            return (false, false)
        }
        // Position, size, position again: some apps clamp size to the screen
        // based on their old position, so the second move settles it.
        setPosition(e, origin)
        setSize(e, size)
        setPosition(e, origin)
        return (true, restoring)
    }

    /// After a window's been placed (main thread): one coming back from the
    /// Dock is placed again once it's back, and a window that moved is
    /// checked once it has settled, to learn if it refused to get that small.
    private func settle(_ id: CGWindowID, _ e: AXUIElement, _ rect: CGRect, origin: CGPoint,
                        moved: Bool, restoring: Bool) {
        if restoring {
            lastRestore = Date()
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
        guard moved else { return }
        // Did it refuse to get that small? Many apps take a moment to resize,
        // so look again once it has settled (two looks that agree), rather
        // than mistaking a window that's still shrinking for one that won't.
        verifySize(id, e, rect, after: restoring ? 0.7 : 0.35)
    }

    /// Where several windows are, read from every app at once.
    func frames(of ids: [CGWindowID]) -> [CGWindowID: CGRect] {
        let top = primaryHeight
        var byApp: [pid_t: [(CGWindowID, AXUIElement)]] = [:]
        for id in ids {
            guard let e = cache[id] else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(e, &pid)
            byApp[pid, default: []].append((id, e))
        }
        let groups = Array(byApp.values)
        let lock = NSLock()
        var out: [CGWindowID: CGRect] = [:]
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            var mine: [CGWindowID: CGRect] = [:]
            for (id, e) in groups[i] {
                guard let f = self.currentFrame(e) else { continue }
                mine[id] = CGRect(x: f.minX, y: top - f.minY - f.height, width: f.width, height: f.height)
            }
            lock.lock()
            out.merge(mine) { a, _ in a }
            lock.unlock()
        }
        return out
    }

    // MARK: Live moves (while you drag an edge or a gap)
    //
    // A layout that runs on every mouse movement can't wait on each app in
    // turn: one slow app (Music) would hold up every other window, and the
    // neighbours would catch up in jumps. So live moves go out on a queue of
    // their own per app, only the newest spot for each window is kept (a
    // window that's still busy with the last one just gets the latest when
    // it's ready), nothing is read back, and nothing is checked afterwards.
    // Apps that animate their own resizes when an accessibility client is
    // about (AXEnhancedUserInterface, Chrome and Electron apps) have that
    // turned off for the drag, so they keep up instead of easing behind.

    private var liveQueues: [pid_t: DispatchQueue] = [:]
    /// The last spot sent live for each window (main thread only).
    private var liveSent: [CGWindowID: CGRect] = [:]
    private let liveLock = NSLock()
    /// Guarded by liveLock: the newest spot waiting for each window, the
    /// windows with a queue job running, and where each one was last put.
    private var livePending: [CGWindowID: (element: AXUIElement, origin: CGPoint, size: CGSize)] = [:]
    private var liveBusy: Set<CGWindowID> = []
    private var liveApplied: [CGWindowID: CGRect] = [:]
    /// Apps whose own resize animation is off for the drag (main thread only).
    private var liveCalmed: Set<pid_t> = []
    private var liveRestore: DispatchWorkItem?

    /// Moves and resizes a window right away, without waiting on its app.
    func setFrameLive(_ id: CGWindowID, _ rect: CGRect) {
        guard let e = cache[id] else { return }
        if let last = liveSent[id], abs(last.minX - rect.minX) < 0.5, abs(last.minY - rect.minY) < 0.5,
           abs(last.width - rect.width) < 0.5, abs(last.height - rect.height) < 0.5 { return }
        if liveSent[id] == nil, let t = lastTarget[id] {
            liveLock.lock(); liveApplied[id] = CGRect(origin: axPoint(for: t), size: t.size); liveLock.unlock()
        }
        liveSent[id] = rect
        lastTarget[id] = rect
        parked.remove(id)
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        let q = liveQueue(for: pid)
        calm(pid, on: q)
        liveLock.lock()
        livePending[id] = (e, axPoint(for: rect), rect.size)
        let start = liveBusy.insert(id).inserted
        liveLock.unlock()
        if start { q.async { [weak self] in self?.drainLive(id) } }
    }

    /// Waits until every live move sent so far has gone out (before a final
    /// layout that reads windows back).
    func flushLive() {
        for q in liveQueues.values { q.sync {} }
        liveSent.removeAll()
    }

    private func liveQueue(for pid: pid_t) -> DispatchQueue {
        if let q = liveQueues[pid] { return q }
        let q = DispatchQueue(label: "scuba.live.\(pid)", qos: .userInteractive)
        liveQueues[pid] = q
        return q
    }

    /// Runs on the app's queue: puts the window at its newest spot, again
    /// while newer ones keep arriving.
    private func drainLive(_ id: CGWindowID) {
        while true {
            liveLock.lock()
            guard let job = livePending.removeValue(forKey: id) else {
                liveBusy.remove(id)
                liveLock.unlock()
                return
            }
            let was = liveApplied[id]
            liveApplied[id] = CGRect(origin: job.origin, size: job.size)
            liveLock.unlock()
            let samePlace = was.map { abs($0.minX - job.origin.x) < 0.5 && abs($0.minY - job.origin.y) < 0.5 } ?? false
            let sameSize = was.map { abs($0.width - job.size.width) < 0.5 && abs($0.height - job.size.height) < 0.5 } ?? false
            if samePlace && sameSize { continue }
            if samePlace {
                setSize(job.element, job.size)
            } else if sameSize {
                setPosition(job.element, job.origin)
            } else if let w = was, job.size.width < w.width || job.size.height < w.height {
                // Getting smaller: shrink first, so it never pokes past its
                // neighbour on the way.
                setSize(job.element, job.size)
                setPosition(job.element, job.origin)
            } else {
                setPosition(job.element, job.origin)
                setSize(job.element, job.size)
            }
        }
    }

    /// Turns off an app's own resize animation for the drag; it's turned
    /// back on a moment after the last live move.
    private func calm(_ pid: pid_t, on q: DispatchQueue) {
        if !liveCalmed.contains(pid) {
            liveCalmed.insert(pid)
            q.async {
                let app = AXUIElementCreateApplication(pid)
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &v) == .success,
                   (v as? Bool) == true {
                    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
                    DispatchQueue.main.async { [weak self] in self?.calmedOn.insert(pid) }
                }
            }
        }
        liveRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.uncalm() }
        liveRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Apps that had their resize animation on before the drag.
    private var calmedOn: Set<pid_t> = []

    private func uncalm() {
        for pid in calmedOn {
            liveQueue(for: pid).async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
        calmedOn.removeAll()
        liveCalmed.removeAll()
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
                // A window in your hand (you're dragging its edge, say) is the
                // size you're holding it at, not the smallest it will go: while
                // the mouse is down, only learn that it went smaller.
                let held = NSEvent.pressedMouseButtons != 0
                self.learnSize(id, got: got.size, asked: rect.size, raise: !held)
            }
        }
    }

    /// Checks, without bringing it back, whether a tucked-away window will go
    /// as small as `size` after all. A size on record can be wrong (an app
    /// that was slow to resize when it was measured, or one still in your
    /// hand), and a window frosted over because of it never otherwise gets
    /// the chance to show it. Records what it finds; `done` gets true when
    /// the size on record changed.
    func probeMinSize(_ id: CGWindowID, to size: CGSize, done: @escaping (Bool) -> Void) {
        guard parked.contains(id), let e = element(id) else { done(false); return }
        resizeParked(id, e, to: size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.parked.contains(id), let first = self.currentFrame(e) else { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.parked.contains(id), let got = self.currentFrame(e),
                      abs(got.width - first.width) < 2, abs(got.height - first.height) < 2 else { done(false); return }
                let before = self.minSizes[id]
                let known = before ?? .zero
                // What it does now replaces what's on record, either way.
                let width = got.width > size.width + 4 ? got.width : (known.width > got.width + 4 ? 0 : known.width)
                let height = got.height > size.height + 4 ? got.height : (known.height > got.height + 4 ? 0 : known.height)
                let learned = CGSize(width: width, height: height)
                self.minSizes[id] = (width == 0 && height == 0) ? nil : learned
                done(self.minSizes[id] != before)
            }
        }
    }

    /// A refusal seen once (a window that stayed bigger than asked): it only
    /// counts as how small the window goes once a second look, a moment
    /// later, agrees. A window still on its way somewhere (sliding, or slow
    /// to redraw) otherwise looks like one that won't shrink.
    private var refusedOnce: [CGWindowID: (size: CGSize, at: Date)] = [:]

    private func learnSize(_ id: CGWindowID, got: CGSize, asked: CGSize, raise: Bool = true) {
        var tooWide = raise && got.width > asked.width + 4, tooTall = raise && got.height > asked.height + 4
        if tooWide || tooTall {
            if let first = refusedOnce[id], Date().timeIntervalSince(first.at) > 0.6,
               abs(first.size.width - got.width) < 12, abs(first.size.height - got.height) < 12 {
                refusedOnce[id] = nil
            } else {
                // First sight: ask again in a moment, and only believe it if it holds.
                if refusedOnce[id] == nil { refusedOnce[id] = (got, Date()) }
                tooWide = false
                tooTall = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, let r = self.lastTarget[id], !self.parked.contains(id) else { return }
                    self.liveSent[id] = nil
                    if let e = self.element(id) {
                        let o = self.axPoint(for: r)
                        self.setPosition(e, o)
                        self.setSize(e, r.size)
                        self.setPosition(e, o)
                        self.verifySize(id, e, r, after: 0.35)
                    }
                }
            }
        } else {
            refusedOnce[id] = nil
        }
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
        let size = currentFrame(e)?.size ?? CGSize(width: 800, height: 600)
        let spot = parkSpot(size, on: screen)
        // Where it was, if it was showing: macOS sometimes leaves a stale
        // picture of a window behind after it's moved off screen (Safari
        // especially), until something else redraws there.
        let before = frame(of: id)
        setPosition(e, axPoint(for: spot))
        parked.insert(id)
        parkedOn[id] = screen
        if let before {
            let vf = screen.visibleFrame
            let showing = before.intersection(vf)
            if !showing.isNull, showing.width > 8, showing.height > 8 { ScreenRepaint.flash(showing) }
        }
    }

    /// The screen each tucked-away window was tucked into a corner of.
    private var parkedOn: [CGWindowID: NSScreen] = [:]

    /// Resizes a tucked-away window without letting it show. Many apps
    /// (Chrome, for one) pull a window back on screen when it's resized
    /// while mostly off it, which flashed it into view at its new size
    /// before Scuba tucked it away again. So it's moved to its corner for
    /// the new size first, resized, put back in the corner at once, and
    /// checked again a moment later.
    private func resizeParked(_ id: CGWindowID, _ e: AXUIElement, to size: CGSize) {
        let screen = parkedOn[id] ?? NSScreen.main ?? NSScreen.screens[0]
        let spot = parkSpot(size, on: screen)
        setPosition(e, axPoint(for: spot))
        setSize(e, size)
        let got = currentFrame(e)?.size ?? size
        setPosition(e, axPoint(for: parkSpot(got, on: screen)))
        for wait in [0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.parked.contains(id), let e = self.element(id),
                      let f = self.frame(of: id) else { return }
                let showing = f.intersection(screen.visibleFrame)
                guard !showing.isNull, showing.width > 8, showing.height > 8 else { return }
                let now = self.currentFrame(e)?.size ?? size
                self.setPosition(e, self.axPoint(for: self.parkSpot(now, on: screen)))
            }
        }
    }

    /// The corner a window of this size tucks into: one whose overhang
    /// doesn't land on another display (with a screen to the right, tuck
    /// bottom-left instead, and so on).
    private func parkSpot(_ size: CGSize, on screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
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
        return corners.first { c in
            let overhang = c.insetBy(dx: 2, dy: 2)
            return !others.contains { $0.intersects(overhang) }
        } ?? corners[0]
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

    /// True if the window has a sheet open on it (a "save changes?" question, say).
    func hasSheet(_ id: CGWindowID) -> Bool {
        guard let e = element(id) else { return false }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = kids as? [AXUIElement] else { return false }
        return list.contains { child in
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success
                && (role as? String) == (kAXSheetRole as String)
        }
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
        resizeParked(id, e, to: size)
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

    /// Lets a window go: not parked any more, and in view (in the middle of
    /// the screen if it was tucked away).
    func letGo(_ id: CGWindowID, on screen: NSScreen) {
        guard let e = element(id) else { return }
        let vf = screen.visibleFrame
        let f = frame(of: id)
        let showing = f.map { $0.intersection(vf) } ?? .null
        if parked.contains(id) || showing.isNull || showing.width < 80 || showing.height < 60 {
            let size = f?.size ?? CGSize(width: vf.width * 0.6, height: vf.height * 0.6)
            let fit = CGSize(width: min(size.width, vf.width * 0.8), height: min(size.height, vf.height * 0.8))
            setPosition(e, axPoint(for: CGRect(x: vf.midX - fit.width / 2, y: vf.midY - fit.height / 2,
                                               width: fit.width, height: fit.height)))
        }
        parked.remove(id)
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
