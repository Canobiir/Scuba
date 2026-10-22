import AppKit
import CoreServices
import UniformTypeIdentifiers

/// The brains: owns the layout, reacts to commands, and lays out windows.
@MainActor
final class Controller {
    private(set) var state: AppState
    let windows = WindowManager()
    let animator = ZoomAnimator()
    let numbers = NumbersOverlay()
    let backdrop = Backdrop()
    let bounds = PoolBounds()
    /// Smooth drag previews: stand-ins glide while you drag (see DragStage).
    let stage = DragStage()
    let shade = DepthShade()
    let tiles = CrowdTiles()
    let tabStrips = TabStrips()
    let moreInside = MoreInsideHints()
    /// Live pictures for this display's portholes.
    let live = LivePortholes()
    let lobby = Lobby()
    private var busy = false

    /// On the Surface: your normal Mac desktop. Scuba stays out of
    /// the way until you dive in.
    private(set) var onSurface = true
    /// Where your normal desktop windows were when you dived in.
    private var surfaceFrames: [UInt32: CGRect] = [:]
    /// Windows you released (Hyper + X); they never join a board on their own.
    private var ignored = Set<UInt32>()
    /// Called whenever where you are changes (for the menu bar breadcrumb).
    var onLocationChange: (() -> Void)?
    /// True while you hold Hyper and the structure is shown.
    var revealing = false
    /// Set when a shortcut (or Hyper + scroll) was used during this hold of
    /// Hyper: then holding Hyper was for that, not for a look at the panels.
    var hyperUsed = false

    /// A zoom is starting: hide the panel outlines and keep them hidden until
    /// Hyper is let go, so they don't flash over the new board.
    func quietReveal() {
        hyperUsed = true
        if revealing {
            revealing = false
            numbers.hide()
        }
    }
    /// The window blown up in Spotlight, if any. It goes back to its panel
    /// when you Spotlight it again, or leave the board.
    private(set) var spotlit: UInt32?

    /// -1 on the Surface, 0 on the main board, 1+ inside nested boards.
    var depth: Int { onSurface ? -1 : state.path.count }
    /// A panel chosen with the arrow keys, and the window that had focus then.
    private var selection: (panel: UUID, focusedAt: UInt32?)?

    let gap: CGFloat = 12

    /// The display these boards live on, and where they're saved.
    let displayID: CGDirectDisplayID
    private let stateURL: URL

    /// Every display's boards (one Controller each), so a window that belongs
    /// to one screen is never claimed by another.
    static var all: [Controller] = []

    init(displayID: CGDirectDisplayID, stateURL: URL) {
        self.displayID = displayID
        self.stateURL = stateURL
        state = AppState.load(from: stateURL)
        // Windows docked side by side in one pool become a tile each.
        if UserDefaults.standard.bool(forKey: "tileWindows") {
            state.root.tileize()
            for d in state.otherMains ?? [] { d.tileize() }
        }
        // Always start at Home (the top level unless you've set another),
        // on the Main it's on.
        if let hm = state.homeMain, hm != state.root.id {
            let all = allMains
            if let i = all.firstIndex(where: { $0.id == hm }) { setMains(all, current: i) }
        }
        normalizePath()
        state.path = state.home ?? []
        // The Desktop's windows are your normal desktop until you're inside:
        // they join it again, right where they are, when you go in.
        if let desk = current.freePanel() {
            desk.windows.removeAll()
            desk.floating = nil
        }
        tiles.onOpen = { [weak self] t in self?.openTile(t) }
        tiles.onClose = { [weak self] t in self?.closeTile(t) }
        tiles.onSwipe = { [weak self] t, phase, up in self?.inflateGesture(t, phase: phase, up: up) }
        tiles.onDragMove = { [weak self] t, p in self?.tileDragMove(t, at: p) }
        tiles.onDragEnd = { [weak self] t, p in self?.tileDragEnd(t, at: p) }
        tabStrips.onSelect = { [weak self] panel, w in self?.selectTab(w, in: panel) }
        tabStrips.onPopOut = { [weak self] panel, w in self?.popOutTab(w, from: panel) }
        moreInside.onOpen = { [weak self] id in self?.stepInto(panel: id) }
        tabStrips.onMore = { [weak self] id in self?.stepInto(panel: id) }
        tabStrips.onSwipeOut = { [weak self] panel, w, before in self?.popOutTab(w, from: panel, before: before, axis: .h) }
        tabStrips.onClose = { [weak self] _, w in self?.closeWindowHere(w) }
        tiles.live = live
        lobby.onUp = { [weak self] in self?.zoomOutStep() }
        lobby.onDoor = { [weak self] id in self?.stepSideways(to: id) }
        // An app turned out not to shrink as far as its pool: let the pool
        // grow to fit it (once you've let go of the mouse).
        windows.onMinSizeLearned = { [weak self] in
            Task { @MainActor in self?.minSizeLearned() }
        }
        // Windows just back from being minimized need a moment to land
        // before the zoom's closing picture.
        animator.extraSettle = { [weak self] in
            guard let self else { return 0 }
            var wait: TimeInterval = Date().timeIntervalSince(self.windows.lastRestore) < 0.4 ? 0.38 : 0
            // A pending check for windows spilling out of nested pools: let it
            // turn them into portholes before the closing picture.
            if self.overflowTimer != nil {
                wait = max(wait, self.overflowCheckDue.timeIntervalSinceNow + 0.12)
            }
            return wait > 0 ? UInt64(wait * 1_000_000_000) : 0
        }
    }

    // MARK: Geometry

    var screen: NSScreen {
        NSScreen.screens.first { Controller.displayID(of: $0) == displayID } ?? NSScreen.screens.first ?? NSScreen.main!
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// True if a window's middle is on this display.
    private func isOnMyScreen(_ w: UInt32) -> Bool {
        guard let f = windows.frame(of: w) else { return false }
        return screen.frame.contains(CGPoint(x: f.midX, y: f.midY))
    }

    /// True if another display's boards (or its plain desktop) hold this window.
    private func belongsElsewhere(_ w: UInt32) -> Bool {
        Controller.all.contains { $0 !== self && $0.claims(w) }
    }

    func claims(_ w: UInt32) -> Bool {
        everyWindow().contains(w) || surfaceFrames[w] != nil
    }

    /// A window dragged off to another screen's boards leaves these.
    func letGo(of w: UInt32) {
        remove(window: w)
        if spotlit == w { spotlit = nil }
        saveState()
    }

    var viewport: CGRect { screen.visibleFrame.insetBy(dx: gap / 2, dy: gap / 2) }

    struct Placed {
        let panel: Panel
        let rect: CGRect
        let depth: Int        // 0 = a panel of the desktop on screen
        let label: String     // "2", or "2 › 1" for nested panels
        let owner: Desktop    // the desktop this panel belongs to
    }

    /// Where every panel of a desktop (and its nested desktops) sits.
    func frames(_ desktop: Desktop, in rect: CGRect, depth: Int = 0, prefix: String = "") -> [Placed] {
        var out: [Placed] = []
        place(desktop.root, rect, depth, prefix, desktop, &out)
        return out
    }

    private func place(_ node: Node, _ r: CGRect, _ depth: Int, _ prefix: String,
                       _ owner: Desktop, _ out: inout [Placed]) {
        switch node {
        case .panel(let p):
            let label = prefix.isEmpty ? displayName(p) : "\(prefix) › \(displayName(p))"
            out.append(Placed(panel: p, rect: r, depth: depth, label: label, owner: owner))
            if let nested = p.desktop {
                out += frames(nested, in: r.insetBy(dx: gap / 2, dy: gap / 2), depth: depth + 1, prefix: label)
            }
        case .split(let s):
            var pos: CGFloat = 0
            for item in shownChildren(s, of: owner) {
                let f = item.share
                let cr: CGRect
                if s.axis == .h {
                    cr = CGRect(x: r.minX + r.width * pos, y: r.minY, width: r.width * f, height: r.height)
                } else {
                    // AppKit's y axis points up, so the first child is the top one.
                    cr = CGRect(x: r.minX, y: r.maxY - r.height * (pos + f), width: r.width, height: r.height * f)
                }
                place(item.node, cr, depth, prefix, owner, &out)
                pos += f
            }
        }
    }

    // MARK: Room panels stay inside

    /// Panels that began as breathing room and that you put something in
    /// only show on their own board. From anywhere above, they fold away and
    /// the board shows its original arrangement.
    var roomInsideOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "roomInsideOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "roomInsideOnly"); applyLayout() }
    }

    /// The board on screen (nil on the Surface).
    private var shownBoardID: UUID? { viewingAs ?? (onSurface ? nil : current.id) }

    /// Set while working out how another board looks when you're on it
    /// (the lobby's map, the zoom back up, a sideways glide).
    private var viewingAs: UUID?

    /// A board's panels as they look when that board is the one on screen.
    private func framesAsShown(_ d: Desktop) -> [Placed] {
        let saved = viewingAs
        viewingAs = d.id
        defer { viewingAs = saved }
        return frames(d, in: viewport)
    }

    /// Hyper + Shift + L: the panel you're in only shows on this board (or
    /// shows everywhere again). Works on any panel, not just breathing room.
    func toggleInsideOnly() {
        guard !onSurface else { return }
        guard !state.path.isEmpty else {
            Toast.show("Main is the top — there's nothing above it to hide from", seconds: 1.2)
            return
        }
        let p = activePanel()
        guard p.scratch == true || !p.windows.isEmpty || p.desktop != nil else {
            Toast.show("Put something in this pool first — empty pools fold away from above", seconds: 1.4)
            return
        }
        checkpoint()
        let above = siblings()
        previewFold(on: above?.parent, path: above?.parentPath ?? [], focus: p.id) {
            p.scratch = p.scratch == true ? nil : true
            if p.scratch == true && !roomInsideOnly { roomInsideOnly = true }
            applyLayout()
        }
        Toast.show(p.scratch == true ? "Pool \(displayName(p)) hidden when you zoom out"
                                     : "Pool \(displayName(p)) shows when you zoom out", seconds: 1.2)
    }

    /// Hyper + Shift + P: makes the pool under the pointer private (or shows
    /// it everywhere again), without diving in first. A pool on the board
    /// you're on hides from the boards above; one on a board inside it
    /// folds away from here.
    private func togglePrivateUnderPointer() {
        guard !onSurface, !busy else { return }
        let point = NSEvent.mouseLocation
        guard let hit = frames(current, in: viewport).filter({ $0.rect.contains(point) }).max(by: { $0.depth < $1.depth })
        else { return }
        let p = hit.panel
        if hit.depth == 0, state.path.isEmpty {
            Toast.show("Main is the top — point at a pool inside a board to hide it", seconds: 1.3)
            return
        }
        flipPrivate(p, label: hit.label, onThisBoard: hit.depth == 0)
    }

    /// Makes a pool private, or shows it everywhere again. A pool on this
    /// board changes how the board above looks; one deeper down changes how
    /// this board looks.
    private func flipPrivate(_ p: Panel, label: String, onThisBoard: Bool) {
        guard p.scratch == true || !p.windows.isEmpty || p.desktop != nil else {
            Toast.show("Put something in this pool first — empty pools fold away from above", seconds: 1.4)
            return
        }
        checkpoint()   // Hyper + Z puts it back
        let above = onThisBoard ? siblings() : nil
        let board: Desktop? = onThisBoard ? above?.parent : current
        let path = onThisBoard ? (above?.parentPath ?? []) : state.path
        previewFold(on: board, path: path, focus: p.id) {
            p.scratch = p.scratch == true ? nil : true
            if p.scratch == true && !roomInsideOnly { roomInsideOnly = true }
            applyLayout()
        }
        Toast.show(p.scratch == true ? "Pool \(label) hidden when you zoom out"
                                     : "Pool \(label) shows when you zoom out", seconds: 1.2)
    }

    /// The board window under the pointer, if one is live there.
    private func windowUnderPointer() -> UInt32? {
        let m = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        guard let hit = windows.windowAt(CGPoint(x: m.x, y: h - m.y)), liveIn[hit.id] != nil else { return nil }
        return hit.id
    }

    /// Hyper + P: hides the window under the pointer when you zoom out (it
    /// only shows at its own depth), or shows it again. Over a hidden
    /// window's tile, shows it again. No window under the
    /// pointer: the focused one.
    func hideWindowHere() {
        guard !onSurface, !busy else { return }
        let point = NSEvent.mouseLocation
        if let t = shownTiles.first(where: { $0.badge == "eye.slash.fill" && $0.rect.contains(point) }),
           isInsideOnly(t.window) {
            toggleWindowInsideOnly(t.window)
            return
        }
        toggleWindowInsideOnly(windowUnderPointer())
    }

    /// Hyper + Shift + P: hides the whole pool under the pointer when you zoom
    /// out, or shows it again. A pool on the board you're on hides from the
    /// view above; one on a board inside it hides from this view.
    func hidePoolHere() {
        guard !onSurface, !busy else { return }
        let point = NSEvent.mouseLocation
        if let t = shownTiles.first(where: { $0.badge == "eye.slash.fill" && $0.rect.contains(point) }),
           let placed = frames(current, in: viewport).first(where: { $0.panel.id == t.panel }),
           placed.panel.scratch == true {
            flipPrivate(placed.panel, label: placed.label, onThisBoard: placed.depth == 0)
            return
        }
        togglePrivateUnderPointer()
    }

    // MARK: Previewing the fold

    let foldPreview = FoldPreview()

    /// Before and after a private change, a small map of the board it changes
    /// shows how that board looks both ways.
    var previewsFold: Bool {
        get { UserDefaults.standard.bool(forKey: "foldPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "foldPreview") }
    }

    private func previewFold(on board: Desktop?, path: [UUID], focus: UUID?, change: () -> Void) {
        guard previewsFold, let board else { change(); return }
        let before = foldMap(of: board, focus: focus)
        change()
        let after = foldMap(of: board, focus: focus)
        foldPreview.show(title: locationLabel(path) + " from here on", before: before, after: after, on: screen)
    }

    /// A board as it looks when you're on it: its pools, with their apps,
    /// private ones marked. Scaled to 0–1.
    private func foldMap(of board: Desktop, focus: UUID?) -> FoldPreview.Map {
        let saved = viewingAs
        viewingAs = board.id
        defer { viewingAs = saved }
        let v = viewport
        var cells: [FoldPreview.Cell] = []
        for placed in frames(board, in: v) where placed.panel.desktop == nil {
            let r = placed.rect
            let list = shownWindows(placed.panel, of: placed.owner)
            var seen = Set<String>()
            let names = list.map { windows.appName($0) }.filter { seen.insert($0).inserted }
            let seenFromAbove = placed.owner.id != board.id && roomInsideOnly
            let isPrivate = seenFromAbove && (placed.panel.scratch == true || list.contains { isInsideOnly($0) })
            var title = "empty"
            if !names.isEmpty {
                title = names.prefix(2).joined(separator: ", ")
                if names.count > 2 { title += " +\(names.count - 2)" }
            }
            let cell = CGRect(x: (r.minX - v.minX) / v.width, y: (r.minY - v.minY) / v.height,
                              width: r.width / v.width, height: r.height / v.height)
            cells.append(FoldPreview.Cell(rect: cell, title: title, isPrivate: isPrivate,
                                          isFocus: placed.panel.id == focus))
        }
        return FoldPreview.Map(cells: cells, aspect: v.height / v.width)
    }

    /// True for a room panel that's folded away when its board isn't the one on screen.
    /// Seen from any other board, a board folds away its inside-only panels
    /// and its empty ones, and the panels left spread out over their space
    /// (so Safari takes the whole of panel 2 from Main, not just its old slot).
    private func isHiddenRoom(_ p: Panel, of owner: Desktop?) -> Bool {
        guard roomInsideOnly, owner?.id != shownBoardID else { return false }
        let visible = owner.map { shownWindows(p, of: $0) } ?? p.windows
        if p.scratch == true {
            // Shown as a tile from above instead of folding away (one holding
            // a whole board of its own still folds away).
            if privateLook != .hidden, p.desktop == nil, !visible.isEmpty { return false }
            return true
        }
        return visible.isEmpty && p.desktop == nil
    }

    /// How private pools and windows look from the boards above them.
    enum PrivateLook: String { case hidden, frosted, icon }

    var privateLook: PrivateLook {
        get { PrivateLook(rawValue: UserDefaults.standard.string(forKey: "privateLook") ?? "") ?? .hidden }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "privateLook"); applyLayout() }
    }

    /// A private pool seen from above, as one app-icon tile with a lock.
    /// Clicking it goes to its board.
    private func privateTile(_ list: [UInt32], of placed: Placed, in target: CGRect) -> CrowdTile? {
        let p = placed.panel
        let main = list.first { p.floatRect($0) == nil }
            ?? list.max { a, b in
                let ra = p.floatRect(a) ?? .zero, rb = p.floatRect(b) ?? .zero
                return ra.width * ra.height < rb.width * rb.height
            }
        guard let w = main else { return nil }
        var t = CrowdTile(rect: target, icon: windows.appIcon(w), name: windows.appName(w),
                          extra: list.count - 1, panel: p.id, owner: placed.owner.id, window: w)
        t.badge = "eye.slash.fill"
        t.jumpOnly = true
        return t
    }

    /// True for a window marked to only show on its own board (Hyper + P).
    func isInsideOnly(_ w: UInt32) -> Bool { state.insideOnly?.contains(w) == true }

    /// A panel's windows as they show from where you are: inside-only
    /// windows are left out unless their board is the one on screen.
    private func shownWindows(_ p: Panel, of owner: Desktop) -> [UInt32] {
        let list = tabMembers(p, of: owner)
        // Tabs: only the one in front shows.
        guard p.tabs == true, list.count > 1 else { return list }
        return [p.front.flatMap { list.contains($0) ? $0 : nil } ?? list.last!]
    }

    /// A pool's windows as they'd show if it weren't tabbed (every tab).
    private func tabMembers(_ p: Panel, of owner: Desktop) -> [UInt32] {
        var list = p.windows
        // A cut window (and its tabs) is on its way somewhere else: its pool
        // carries on without it.
        if let h = held, h.kind == .cut { list.removeAll { $0 == h.window || heldTabs.contains($0) } }
        // Minimized into the Dock: the rest of the pool takes its space until
        // it comes back, to the same spot.
        if !docked.isEmpty { list.removeAll { docked.contains($0) } }
        guard roomInsideOnly, owner.id != shownBoardID, privateLook == .hidden,
              let marked = state.insideOnly, !marked.isEmpty else { return list }
        return list.filter { !marked.contains($0) }
    }

    /// Hyper + P: the window you're using only shows on its own board (or
    /// shows everywhere again). From above it's tucked away and the windows
    /// beside it spread into its space, like a breathing-room panel.
    func toggleWindowInsideOnly(_ target: UInt32? = nil) {
        guard !onSurface, let w = target ?? windows.focusedWindowID(), let c = chain(for: w) else {
            Toast.show("Point at a window on a board first")
            return
        }
        checkpoint()   // Hyper + Z puts it back
        var marked = state.insideOnly ?? []
        let name = windows.appName(w)
        let making = !marked.contains(w)
        if making {
            marked.append(w)
            Toast.show("\(name) hidden when you zoom out", seconds: 1.2)
        } else {
            marked.removeAll { $0 == w }
            Toast.show("\(name) shows when you zoom out", seconds: 1.2)
        }
        // The board this changes: the one above, for a window on this board;
        // this one, for a window on a board inside it.
        let holder = liveIn[w] ?? c.last?.id
        let nested = frames(current, in: viewport).first { $0.panel.id == holder }.map { $0.depth >= 1 } ?? false
        let above = nested ? nil : siblings()
        let board: Desktop? = nested ? current : above?.parent
        let path = nested ? state.path : (above?.parentPath ?? [])
        previewFold(on: board, path: path, focus: holder) {
            if making, !roomInsideOnly { roomInsideOnly = true }
            state.insideOnly = marked.isEmpty ? nil : marked
            applyLayout()
        }
    }

    /// A split's children as they're shown, with their shares of the space
    /// (folded-away room panels left out, the rest sharing their space).
    private func shownChildren(_ s: Split, of owner: Desktop?) -> [(index: Int, node: Node, share: CGFloat)] {
        let all = s.children.enumerated().map { (index: $0.offset, node: $0.element, share: CGFloat(s.ratios[$0.offset])) }
        let shown = all.filter { !isHiddenNode($0.node, of: owner) }
        let total = shown.reduce(0) { $0 + $1.share }
        guard !shown.isEmpty, total > 0, shown.count < all.count else { return all }
        return shown.map { (index: $0.index, node: $0.node, share: $0.share / total) }
    }

    /// True for a folded-away pool, or a group of pools that are all folded
    /// away (say, a private room and the private pool above it): the whole
    /// group gives its space to the rest, instead of holding it empty.
    private func isHiddenNode(_ node: Node, of owner: Desktop?) -> Bool {
        switch node {
        case .panel(let p): return isHiddenRoom(p, of: owner) || isAway(p) || p.tucked == true
        case .split(let s): return !s.children.isEmpty && s.children.allSatisfy { isHiddenNode($0, of: owner) }
        }
    }

    // MARK: Fitting the screen shape

    var autoRotate: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRotate") }
        set { UserDefaults.standard.set(newValue, forKey: "autoRotate"); applyLayout() }
    }

    /// Wide (true), tall (false), or too close to square to say (nil). The
    /// margin is small: a half-screen panel is often only a little taller than
    /// it is wide once the menu bar and Dock are taken out.
    private func shapeOf(_ r: CGRect) -> Bool? {
        if r.width > r.height * 1.03 { return true }
        if r.height > r.width * 1.03 { return false }
        return nil
    }

    private var turnShapes = true
    private var shapedPath: [UUID]?

    /// Clearly wide (true) or clearly tall (false): at least 1.4 times as
    /// long one way as the other. Anything closer to square keeps its shape.
    private func clearShape(_ r: CGRect) -> Bool? {
        if r.width > r.height * 1.4 { return true }
        if r.height > r.width * 1.4 { return false }
        return nil
    }

    /// A board arranged in a tall space (say, stacked in the left half of
    /// Home) turns side by side when it's shown in a wide one (when you dive
    /// in), and back again. Each split remembers the shape it was last shown
    /// in, so the way you arranged it is kept for that shape.
    private func adapt(_ node: Node, _ r: CGRect, _ owner: Desktop) {
        switch node {
        case .panel(let p):
            if let nested = p.desktop {
                adapt(nested.root, r.insetBy(dx: gap / 2, dy: gap / 2), nested)
            } else {
                adaptFloats(p, r)
            }
        case .split(let s):
            // Only clearly wide or clearly tall spaces turn a group (diving
            // into a stacked board, say). Widening a column by hand never
            // does: it stays the way you arranged it, and nothing flips mid-drag.
            let shape = clearShape(r)
            // Only when you've moved to another board: on the board you're
            // on, resizing never turns a group (it keeps its old shape on
            // record, so diving in later still turns it).
            if let shape, turnShapes {
                if let was = s.landscape, was != shape { s.axis = s.axis.flipped }
                s.landscape = shape
            }
            var pos: CGFloat = 0
            for item in shownChildren(s, of: owner) {
                let f = item.share
                let cr = s.axis == .h
                    ? CGRect(x: r.minX + r.width * pos, y: r.minY, width: r.width * f, height: r.height)
                    : CGRect(x: r.minX, y: r.maxY - r.height * (pos + f), width: r.width, height: r.height * f)
                adapt(item.node, cr, owner)
                pos += f
            }
        }
    }

    /// Same idea inside one panel: two or more windows floating in a stack
    /// (e.g. Claude over Google) sit side by side when the panel is wide.
    private func adaptFloats(_ p: Panel, _ r: CGRect) {
        guard p.free != true, let shape = shapeOf(r)
        else { return }
        let floats = p.windows.compactMap { p.floatRect($0) }
        if p.windows.count >= 2, !floats.isEmpty, let was = p.landscape, was != shape {
            // Turn the arrangement when it's a stack: every floating window is
            // a band across the panel (Claude over Google, or Messages along the
            // bottom with Discord filling the rest). A small window tucked in a
            // corner keeps its spot instead.
            let bands = floats.allSatisfy { was ? $0.height >= 0.85 : $0.width >= 0.85 }
            if bands { p.rotateFloats(toLandscape: shape) }
        }
        p.landscape = shape
    }

    func rect(ofTopPanel id: UUID) -> CGRect? {
        frames(current, in: viewport).first { $0.depth == 0 && $0.panel.id == id }?.rect
    }

    // MARK: Where we are

    /// Desktops from the top level down to the one on screen.
    func desktopStack() -> [Desktop] {
        var out = [state.root]
        for pid in state.path {
            guard let p = out.last!.panel(id: pid), let d = p.desktop else { break }
            out.append(d)
        }
        return out
    }

    var current: Desktop { desktopStack().last! }

    private func normalizePath() {
        let depth = desktopStack().count - 1
        if depth < state.path.count { state.path = Array(state.path.prefix(depth)) }
        if let home = state.home, state.homeMain == nil || state.homeMain == state.root.id, !isValid(home) {
            state.home = nil
        }
    }

    /// The board at a path, if there is one.
    func desktop(at path: [UUID]) -> Desktop? {
        var d = state.root
        for pid in path {
            guard let p = d.panel(id: pid), let nd = p.desktop else { return nil }
            d = nd
        }
        return d
    }

    private func isValid(_ path: [UUID]) -> Bool {
        var d = state.root
        for pid in path {
            guard let p = d.panel(id: pid), let nd = p.desktop else { return false }
            d = nd
        }
        return true
    }

    func displayName(_ p: Panel) -> String { p.name ?? "\(p.number)" }

    /// The boards from the main one down to where you are, e.g. "Main › Work › 2".
    func breadcrumb(_ path: [UUID]? = nil) -> String {
        let path = path ?? state.path
        var d = state.root
        var parts = [mainName(state.root)]
        for pid in path {
            guard let p = d.panel(id: pid), let nd = p.desktop else { break }
            parts.append(displayName(p))
            d = nd
        }
        return parts.joined(separator: " › ")
    }

    /// "Desktop" on the Surface, otherwise the breadcrumb.
    func locationLabel(_ path: [UUID]? = nil) -> String {
        if onSurface && path == nil { return "Desktop" }
        return breadcrumb(path)
    }

    // MARK: Back and forward

    /// Where you've been, like a browser's history: the menu bar's ‹ › (and
    /// Cmd + Option + ← →) go back to where you were, and forward again.
    private var backStack: [[UUID]] = []
    private var forwardStack: [[UUID]] = []
    private var historyAt: [UUID]?
    private var historyMain: UUID?
    /// Going back or forward: where to, and since when (the stops on the
    /// way aren't history).
    private var travelTarget: (path: [UUID], since: Date)?

    /// Called on every layout: a new place goes on the history.
    private func noteHistory() {
        guard !onSurface else { return }
        let here = state.path
        // Another Main: a fresh history.
        if historyMain != state.root.id {
            historyMain = state.root.id
            backStack.removeAll()
            forwardStack.removeAll()
            historyAt = here
            return
        }
        if let t = travelTarget {
            if here == t.path || Date().timeIntervalSince(t.since) > 4 {
                travelTarget = nil
                historyAt = here
            }
            return
        }
        guard let was = historyAt else { historyAt = here; return }
        guard was != here else { return }
        historyAt = here
        backStack.append(was)
        if backStack.count > 60 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    var canGoBack: Bool { backStack.contains { isValid($0) } }
    var canGoForward: Bool { forwardStack.contains { isValid($0) } }

    func goBack() { travel(back: true) }
    func goForward() { travel(back: false) }

    private func travel(back: Bool) {
        guard !busy, !onSurface else { return }
        while let p = back ? backStack.popLast() : forwardStack.popLast() {
            guard isValid(p), p != state.path else { continue }
            if back { forwardStack.append(state.path) } else { backStack.append(state.path) }
            travelTarget = (p, Date())
            navigate(to: p)
            return
        }
        Toast.show(back ? "Nowhere further back" : "Nowhere further forward", seconds: 0.9)
    }

    // MARK: Saved views

    /// Save where you're looking (Hyper + Shift + a number) and
    /// come straight back to it (Control + Option + that number), from
    /// anywhere, your desktop included.
    private var savedViews: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "savedViews") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "savedViews") }
    }

    func saveView(_ n: Int) {
        guard !onSurface else {
            Toast.show("Dive in first — then save what you're looking at", seconds: 1.2)
            return
        }
        var all = savedViews
        all["\(n)"] = [state.root.id.uuidString] + state.path.map { $0.uuidString }
        savedViews = all
        Toast.show("Saved \(breadcrumb())  ·  \(CapsKey.label) + \(n) comes back here", seconds: 1.5)
    }

    func goToView(_ n: Int) {
        guard !busy else { return }
        guard let ids = savedViews["\(n)"], let first = ids.first else {
            Toast.show("Nothing saved on \(n)  ·  \(CapsKey.label) + Shift + \(n) saves this view", seconds: 1.4)
            return
        }
        guard first == state.root.id.uuidString else {
            Toast.show("That view is on another Main", seconds: 1.2)
            return
        }
        let path = ids.dropFirst().compactMap { UUID(uuidString: $0) }
        guard isValid(path) else {
            Toast.show("That view isn't there any more", seconds: 1.2)
            return
        }
        if onSurface {
            enterBoards(at: path)
        } else if path == state.path {
            Toast.show(breadcrumb(), seconds: 0.9)
        } else {
            navigate(to: path)
        }
    }

    /// The views saved on 1–9, for the menu.
    func savedViewList() -> [(number: Int, label: String)] {
        let all = savedViews
        return (1...9).compactMap { (n: Int) -> (number: Int, label: String)? in
            guard let ids = all["\(n)"], ids.first == state.root.id.uuidString else { return nil }
            let path = ids.dropFirst().compactMap { UUID(uuidString: $0) }
            guard isValid(path) else { return nil }
            return (number: n, label: breadcrumb(path))
        }
    }

    var isHome: Bool {
        state.path == (state.home ?? []) && (state.homeMain == nil || state.homeMain == state.root.id)
    }

    /// The panel chain (outermost first) that holds a window.
    private func chain(for window: UInt32) -> [Panel]? {
        search(state.root, window, [])
    }

    private func search(_ d: Desktop, _ w: UInt32, _ chain: [Panel]) -> [Panel]? {
        for p in d.panels() {
            if p.windows.contains(w) { return chain + [p] }
            if let nd = p.desktop, let found = search(nd, w, chain + [p]) { return found }
        }
        return nil
    }

    /// The panel commands act on: the focused window's panel on this desktop,
    /// else the last one used, else panel 1.
    func activePanel() -> Panel {
        let focused = windows.focusedWindowID()
        // A panel picked with the arrow keys (e.g. an empty one) stays active
        // until you focus a different window.
        if let sel = selection, sel.focusedAt == focused, let p = current.panel(id: sel.panel) {
            return p
        }
        if let w = focused, let c = chain(for: w), c.count > state.path.count {
            let matches = zip(c, state.path).allSatisfy { $0.id == $1 }
            if matches { return c[state.path.count] }
        }
        if let id = state.lastPanelId, let p = current.panel(id: id) { return p }
        return current.lowestNumbered()
    }

    private func forEachPanel(_ d: Desktop, _ body: (Panel) -> Void) {
        for p in d.panels() {
            body(p)
            if let nd = p.desktop { forEachPanel(nd, body) }
        }
    }

    private func remove(window w: UInt32, reflow: Bool = true) {
        for main in allMains {
            forEachPanel(main) { p in
                guard p.windows.contains(w) else { return }
                // The windows left behind grow into the space it leaves.
                if reflow { self.fillVacancy(left: w, in: p) }
                p.windows.removeAll { $0 == w }
                p.setFloat(w, nil)
                if p.windows.isEmpty { self.vacated.insert(p.id) }
            }
        }
        lastApplied[w] = nil
        onTop.remove(w)
    }

    // MARK: Every window its own tile

    /// Docking gives each window a pool of its own (a tile), split off the
    /// window it docks beside, and a tile left empty goes away so the tiles
    /// around it take the space.
    var tileWindows: Bool {
        get { UserDefaults.standard.bool(forKey: "tileWindows") }
        set { UserDefaults.standard.set(newValue, forKey: "tileWindows") }
    }

    /// Pools that windows have left since the last layout.
    private var vacated = Set<UUID>()

    /// A pool a window has left, with nothing left in it, goes (breathing
    /// room, the Desktop and pools holding a board stay): the tiles around
    /// it take its space. Runs at the start of every layout.
    private func pruneVacated() {
        guard !vacated.isEmpty else { return }
        let ids = vacated
        vacated.removeAll()
        guard tileWindows else { return }
        for main in allMains {
            for id in ids {
                guard let found = main.deepFind(panel: id) else { continue }
                // Inside a space you've stepped into, free space stays free:
                // the spot a window left becomes breathing room. On Main the
                // tiles around it take the space.
                if found.owner !== main, found.panel.windows.isEmpty, found.panel.desktop == nil,
                   found.panel.free != true, found.owner.panels().count > 1 {
                    found.panel.scratch = true
                    continue
                }
                guard found.owner.pruneTile(found.panel) else { continue }
                if state.lastPanelId == id { state.lastPanelId = nil }
                if selection?.panel == id { selection = nil }
            }
        }
    }

    /// A pool whose windows are all minimized into the Dock: it folds away
    /// until one comes back, and the tiles around it take its space.
    private func isAway(_ p: Panel) -> Bool {
        p.desktop == nil && p.free != true && !p.windows.isEmpty && p.windows.allSatisfy { docked.contains($0) }
    }

    /// A board's id and the ids of every board inside it.
    private func boardIDs(in d: Desktop) -> Set<UUID> {
        var out: Set<UUID> = [d.id]
        for p in d.panels() { if let n = p.desktop { out.formUnion(boardIDs(in: n)) } }
        return out
    }

    /// The way to split a space so both halves come out closest to the
    /// screen's own shape (side by side on a tie). Halves of a screen-shaped
    /// space are tall; split one of those and its halves are screen-shaped
    /// again, so tiles stay little copies of the screen at every depth.
    private func screenShapedAxis(for r: CGRect) -> Axis {
        let screen = Double(max(viewport.width, 1) / max(viewport.height, 1))
        let shape = Double(max(r.width, 1) / max(r.height, 1))
        let sideBySide = abs(log((shape / 2) / screen))
        let stacked = abs(log((shape * 2) / screen))
        return stacked < sideBySide - 0.05 ? .v : .h
    }

    /// The Desktop on the board on screen, where it sits.
    private func desktopPlaced() -> Placed? {
        dropPanels().first { $0.panel.free == true }
    }

    // MARK: Several Mains

    /// Every Main, left to right (the one you're on included).
    var allMains: [Desktop] {
        var all = state.otherMains ?? []
        all.insert(state.root, at: min(max(state.mainIndex ?? 0, 0), all.count))
        return all
    }

    /// Where the Main you're on sits among them (0 = leftmost).
    var mainPosition: Int { min(max(state.mainIndex ?? 0, 0), state.otherMains?.count ?? 0) }

    /// Makes `all[i]` the Main you're on.
    private func setMains(_ all: [Desktop], current i: Int) {
        state.root = all[i]
        var others = all
        others.remove(at: i)
        state.otherMains = others.isEmpty ? nil : others
        state.mainIndex = others.isEmpty ? nil : i
    }

    /// Every window on every Main.
    private func everyWindow() -> [UInt32] { allMains.flatMap { $0.allWindows() } }

    func mainName(_ d: Desktop) -> String { d.name ?? "Main" }

    /// A Main with nothing in it: one empty pool.
    private func isBlank(_ d: Desktop) -> Bool {
        let ps = d.panels()
        return ps.count == 1 && ps[0].desktop == nil && ps[0].windows.isEmpty
    }

    /// "Main 2", "Main 3"…: the lowest number no other Main uses.
    private func nextMainName() -> String {
        let used = Set(allMains.compactMap { d -> Int? in
            guard let n = d.name, n.hasPrefix("Main ") else { return nil }
            return Int(n.dropFirst(5))
        })
        var n = 2
        while used.contains(n) { n += 1 }
        return "Main \(n)"
    }

    /// Where we last put each floating window, to notice when you move or
    /// resize it by hand.
    private struct Applied {
        let frame: CGRect
        let panelRect: CGRect
        let panel: UUID
        let filled: Bool
    }

    /// Moves a panel's windows (and where they float) into another panel.
    private func moveContents(from a: Panel, to b: Panel) {
        // An arrangement moving into an empty panel keeps the shape it was made for.
        if b.floating == nil, a.floating != nil { b.landscape = a.landscape }
        for w in a.windows {
            b.windows.append(w)
            b.setFloat(w, a.floatRect(w))
            if let last = lastApplied[w] {
                lastApplied[w] = Applied(frame: last.frame, panelRect: last.panelRect,
                                         panel: b.id, filled: last.filled)
            }
        }
        a.windows = []
        a.floating = nil
        // Tabs stay tabs wherever their windows go.
        if a.tabs == true {
            b.tabs = true
            b.front = a.front
        }
        a.tabs = nil
        a.front = nil
    }

    /// Notices windows you moved or resized by hand since we last placed them
    /// and remembers their new spot. A filled window you resize or move turns
    /// into a floating one at that size.
    private func captureManualMoves() {
        let candidates = touched
        touched.removeAll()
        for w in candidates {
            guard let last = lastApplied[w],
                  let p = panelHere(last.panel), p.windows.contains(w),
                  let now = windows.frame(of: w) else { continue }
            // Some apps nudge their own size a little (text grids, minimum
            // sizes), so filled windows need a bigger change to count.
            let threshold: CGFloat = last.filled ? 12 : 3
            guard abs(now.minX - last.frame.minX) > threshold || abs(now.minY - last.frame.minY) > threshold ||
                  abs(now.width - last.frame.width) > threshold || abs(now.height - last.frame.height) > threshold
            else { continue }
            p.setFloat(w, relative(now, in: last.panelRect))
            lastApplied[w] = nil
        }
    }
    private var lastApplied: [UInt32: Applied] = [:]
    /// Windows you moved or resized with the mouse since the last layout.
    /// Only these are re-captured, so an app refusing to shrink (minimum
    /// window sizes) can never creep into the saved layout.
    private var touched = Set<UInt32>()

    func noteManualChange(_ w: UInt32) {
        // An outside window stays wherever you put it.
        if isFloater(w) {
            if let f = windows.frame(of: w) { floatFrames[w] = f }
            return
        }
        // Locked: dragged or resized by hand, it glides back to its tile.
        if !onSurface, liveIn[w] != nil, placementsLocked || isLocked(w) {
            lastApplied[w] = nil
            glideLayout()
            return
        }
        touched.insert(w)
        // A floating window resized or moved by hand: the filled windows in
        // its panel make room for its new size right away.
        guard makeRoom, !onSurface, spotlit != w, let p = chain(for: w)?.last,
              p.windows.contains(where: { $0 != w && p.floatRect($0) == nil }) else { return }
        pendingRoom?.cancel()
        pendingRoom = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)   // let the app settle its size
            guard let self, !Task.isCancelled, !self.busy else { return }
            self.applyLayout()
        }
    }
    private var pendingRoom: Task<Void, Never>?

    private func absolute(_ rel: CGRect, in r: CGRect) -> CGRect {
        CGRect(x: r.minX + rel.minX * r.width, y: r.minY + rel.minY * r.height,
               width: rel.width * r.width, height: rel.height * r.height)
    }

    private func relative(_ f: CGRect, in r: CGRect) -> CGRect {
        CGRect(x: (f.minX - r.minX) / r.width, y: (f.minY - r.minY) / r.height,
               width: f.width / r.width, height: f.height / r.height)
    }

    private func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 3 || abs(a.minY - b.minY) > 3 ||
        abs(a.width - b.width) > 3 || abs(a.height - b.height) > 3
    }

    // MARK: Layout

    /// Moves every managed window into place and tucks away the rest.
    func applyLayout() {
        planCache = nil
        noteHistory()
        windows.refreshIfStale()
        for main in allMains {
            forEachPanel(main) { p in
                // Closed windows: the ones left grow into their space.
                for w in p.windows where !self.windows.exists(w) { self.fillVacancy(left: w, in: p) }
                let had = !p.windows.isEmpty
                p.windows.removeAll { !self.windows.exists($0) }
                if had, p.windows.isEmpty { self.vacated.insert(p.id) }
            }
        }
        // Rooms left empty go first, so a step-in you didn't use folds back.
        foldAwayRoom()
        foldLenses()
        pruneVacated()
        if let h = held, !windows.exists(h.window) {
            held = nil
            chip.hide()
        }
        if onSurface {
            layoutSurface()
            tendFloaters()
            finishLayout()
            return
        }
        captureManualMoves()
        if autoRotate {
            // Groups turn to fit only when you arrive on a board, never while
            // you resize on it.
            turnShapes = shapedPath != state.path
            shapedPath = state.path
            adapt(current.root, viewport, current)
            turnShapes = true
        }

        var visible = Set<UInt32>()
        var crowd: [CrowdTile] = []
        var deep: [UInt32: (spot: CGRect, placed: Placed, target: CGRect)] = [:]
        var liveSpots: [UInt32: CGRect] = [:]
        // Where each live window is meant to go (portholes fit around these
        // until the windows have settled at their real size).
        var intended: [UInt32: CGRect] = [:]
        // Each nested board's pools as they look on that board itself.
        var ownPools: [UUID: [UUID: CGRect]] = [:]
        func bigOnOwnBoard(_ placed: Placed) -> Bool {
            let board = placed.owner
            if ownPools[board.id] == nil {
                var pools: [UUID: CGRect] = [:]
                for f in framesAsShown(board) where f.depth == 0 { pools[f.panel.id] = f.rect }
                ownPools[board.id] = pools
            }
            guard let r = ownPools[board.id]?[placed.panel.id] else { return false }
            let v = viewport
            return r.width * r.height >= v.width * v.height * 0.45
        }
        let placedAll = frames(current, in: viewport)
        // A window copied into more than one pool (Hyper + C, Hyper + V) is
        // live in one place, the shallowest, and a porthole everywhere else.
        var copies: [UInt32: Int] = [:]
        var shallowest: [UInt32: Int] = [:]
        for placed in placedAll where placed.panel.desktop == nil {
            for w in shownWindows(placed.panel, of: placed.owner) {
                copies[w, default: 0] += 1
                shallowest[w] = min(shallowest[w] ?? Int.max, placed.depth)
            }
        }
        var liveTaken = Set<UInt32>()
        var nowMirrored = Set<UInt32>()
        var nowPortholed = Set<UInt32>()
        liveIn.removeAll()
        var leaves: [(placed: Placed, target: CGRect)] = []
        var frostChecks: [UInt32: CGSize] = [:]
        // A board seen from above that's too small for any of its pools to be
        // of use: one tile, a miniature of the board itself (its splits, each
        // pool's app), instead of a crowd of icons. Click it to dive in.
        var miniatures = Set<UUID>()   // boards drawn as one, and every board inside them
        if crowdIcons {
            for placed in placedAll {
                guard let nested = placed.panel.desktop, !miniatures.contains(placed.owner.id) else { continue }
                let boards = boardIDs(in: nested)
                let inside = placedAll.filter { $0.panel.desktop == nil && boards.contains($0.owner.id) }
                    .filter { !shownWindows($0.panel, of: $0.owner).isEmpty }
                guard inside.count >= 2, inside.allSatisfy({ l in
                    frostsWhole(l, shownWindows(l.panel, of: l.owner), l.rect.insetBy(dx: gap / 2, dy: gap / 2))
                }) else { continue }
                miniatures.formUnion(boards)
                var tile = CrowdTile(rect: placed.rect.insetBy(dx: gap / 2, dy: gap / 2), icon: nil,
                                     name: displayName(placed.panel), extra: inside.count,
                                     panel: placed.panel.id, owner: placed.owner.id, window: 0)
                tile.cells = inside.map { $0.rect.insetBy(dx: gap / 2, dy: gap / 2) }
                tile.cellIcons = inside.map { l in shownWindows(l.panel, of: l.owner).first.flatMap { windows.appIcon($0) } }
                crowd.append(tile)
            }
        }
        var strips: [TabStrip] = []
        // Window moves go out to every app at once (endBatch, below); where
        // each one really landed is read once they're all done.
        var placedNow: [(window: UInt32, fallback: CGRect, record: (CGRect) -> Applied?)] = []
        windows.beginBatch()
        for placed in placedAll where placed.panel.desktop == nil {
            // Inside a board drawn as a miniature: its windows tuck away.
            if miniatures.contains(placed.owner.id) { continue }
            let p0 = placed.panel
            // A tabbed pool down to one window isn't tabbed any more.
            if p0.tabs == true, p0.windows.count <= 1 { p0.tabs = nil; p0.front = nil }
            let whole = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
            var target = whole
            var strip: TabStrip?
            if let r = tabStripRect(for: p0, of: placed.owner, in: whole) {
                target = tabBody(below: r, in: whole)
                let all = tabMembers(p0, of: placed.owner)
                let front = shownWindows(p0, of: placed.owner).first ?? all.last!
                strip = TabStrip(rect: r, panel: p0.id, tabs: all.map { w in
                    TabStrip.Tab(window: w, name: tabLabel(w, among: all), icon: windows.appIcon(w))
                }, front: front)
            }
            leaves.append((placed, target))
            let shown = shownWindows(placed.panel, of: placed.owner)
            let fill = fillRect(for: placed.panel, in: target, only: shown)
            // Private things seen from above (when they don't simply fold
            // away): a tile in their place, the windows tucked away.
            let privateHere = privateLook != .hidden && roomInsideOnly && placed.owner.id != shownBoardID
            if privateHere, placed.panel.scratch == true, !shown.isEmpty {
                if privateLook == .icon {
                    if let t = privateTile(shown, of: placed, in: target) { crowd.append(t) }
                } else {
                    for w in shown {
                        let sp = self.spot(for: w, in: placed.panel, target: target, fill: fill, stretch: nil)
                        if var t = portholeTile(w, spot: sp, placed: placed, target: target) {
                            t.badge = "eye.slash.fill"
                            t.live = false
                            crowd.append(t)
                        }
                        nowPortholed.insert(w)
                    }
                }
                continue
            }
            // Too small to be useful: the main window, shrunk into the spot and
            // frosted over with its app's icon (its windows are tucked away
            // until you dive in). Its picture is kept fresh like a porthole's.
            if let tile = crowdTile(for: placed, in: whole) {
                crowd.append(tile)
                if tile.shrunk { nowPortholed.insert(tile.window) }
                // Frosted only because of a size on record, in a roomy spot:
                // check, tucked away, that the size on record is right.
                if stickyFrost[placed.panel.id] == nil {
                    for w in shown where outgrows(w, target) { frostChecks[w] = target.size }
                }
                continue
            }
            if let strip { strips.append(strip) }
            // Some windows here are hidden from this view (inside-only) and
            // everything left floats: stretch what's left, as a group, over
            // the whole panel, so nothing sits beside an empty gap.
            var stretch: CGRect?
            if shown.count < placed.panel.windows.count {
                let rels = shown.compactMap { placed.panel.floatRect($0) }
                if !rels.isEmpty, rels.count == shown.count {
                    let box = rels.dropFirst().reduce(rels[0]) { $0.union($1) }
                    if box.width > 0.05, box.height > 0.05, box.width < 0.99 || box.height < 0.99 { stretch = box }
                }
            }
            for w in shown {
                // A private window seen from above: a tile in its spot.
                if privateHere, isInsideOnly(w) {
                    let sp = self.spot(for: w, in: placed.panel, target: target, fill: fill, stretch: stretch)
                    if privateLook == .icon {
                        let r = sp.intersection(target)
                        if !r.isNull, r.width > 8, r.height > 8 {
                            var t = CrowdTile(rect: r, icon: windows.appIcon(w), name: windows.appName(w), extra: 0,
                                              panel: placed.panel.id, owner: placed.owner.id, window: w)
                            t.badge = "eye.slash.fill"
                            t.jumpOnly = true
                            crowd.append(t)
                        }
                    } else {
                        if var t = portholeTile(w, spot: sp, placed: placed, target: target) {
                            t.badge = "eye.slash.fill"
                            t.live = false
                            crowd.append(t)
                        }
                        nowPortholed.insert(w)
                    }
                    continue
                }
                // A copy: live only in its first, shallowest place.
                if (copies[w] ?? 0) > 1 {
                    if placed.depth == shallowest[w], !liveTaken.contains(w) {
                        liveTaken.insert(w)
                    } else {
                        let sp = self.spot(for: w, in: placed.panel, target: target, fill: fill, stretch: stretch)
                        if var t = portholeTile(w, spot: sp, placed: placed, target: target) {
                            t.badge = "square.on.square"
                            crowd.append(t)
                        }
                        nowMirrored.insert(w)
                        continue
                    }
                }
                // On a nested board, a window that won't shrink to its spot
                // becomes a porthole instead of spilling over its neighbours.
                // A window that had a big pool on its own board (half the
                // screen or more, like Maps beside a stack of two) stays live.
                if placed.depth >= 1, portholes, !bigOnOwnBoard(placed) {
                    let spot = self.spot(for: w, in: placed.panel, target: target, fill: fill, stretch: stretch)
                    deep[w] = (spot, placed, target)
                    if (cramped(w, in: spot) || probing.contains(w)) && w != spotlit { continue }
                }
                visible.insert(w)
                liveIn[w] = placed.panel.id
                intended[w] = self.spot(for: w, in: placed.panel, target: target, fill: fill, stretch: stretch)
                if placed.depth == 0, overflowAt[w] != nil {
                    liveSpots[w] = self.spot(for: w, in: placed.panel, target: target, fill: fill, stretch: stretch)
                }
                if w == edgeWindow { continue }   // you're resizing it by hand: leave it be
                // On a Desktop too small to use anything in (narrower than a
                // usable tile, or shorter), whatever's there frosts: filling
                // it or floating in it alike.
                if placed.panel.free == true, placed.depth == 0, crowdIcons,
                   target.width < Self.usableWidth || target.height < Self.usableHeight {
                    visible.remove(w)
                    liveIn[w] = nil
                    intended[w] = nil
                    lastApplied[w] = nil
                    var tile = CrowdTile(rect: target, icon: windows.appIcon(w), name: windows.appName(w), extra: 0,
                                         panel: placed.panel.id, owner: placed.owner.id, window: w)
                    if CGPreflightScreenCaptureAccess() {
                        tile.shrunk = true
                        tile.picture = portholePictures[w]?.image
                        nowPortholed.insert(w)
                    }
                    crowd.append(tile)
                    continue
                }
                guard var rel = placed.panel.floatRect(w) else {
                    windows.setFrame(w, fill)
                    let pid = placed.panel.id
                    placedNow.append((w, fill, { Applied(frame: $0, panelRect: target, panel: pid, filled: true) }))
                    continue
                }
                if let box = stretch {
                    rel = CGRect(x: (rel.minX - box.minX) / box.width, y: (rel.minY - box.minY) / box.height,
                                 width: rel.width / box.width, height: rel.height / box.height)
                }
                var f = absolute(rel, in: target)
                // Floating on the Desktop: it stays inside the Desktop, never
                // hanging off the screen. One too big to fit there at all (as
                // small as its app goes, or as big as it is) frosts over in
                // its spot instead.
                if placed.panel.free == true, placed.depth == 0, stretch == nil {
                    let m = windows.minSize(w) ?? .zero
                    // Too big for the Desktop only because of its size: it's made to fit.
                    f.size.width = min(f.width, target.width)
                    f.size.height = min(f.height, target.height)
                    let needW = max(f.width, m.width), needH = max(f.height, m.height)
                    // A Desktop too small to use anything in (like a strip
                    // left under a tile) frosts what floats there, the same
                    // as a tiny tile does.
                    let tiny = target.width < Self.usableWidth || target.height < Self.usableHeight
                    if crowdIcons, tiny || m.width > target.width + 6 || m.height > target.height + 6 {
                        visible.remove(w)
                        liveIn[w] = nil
                        intended[w] = nil
                        lastApplied[w] = nil
                        let tw = min(f.width, target.width), th = min(f.height, target.height)
                        let spot = CGRect(x: min(max(f.minX, target.minX), target.maxX - tw),
                                          y: min(max(f.minY, target.minY), target.maxY - th), width: tw, height: th)
                        var tile = CrowdTile(rect: spot, icon: windows.appIcon(w), name: windows.appName(w), extra: 0,
                                             panel: placed.panel.id, owner: placed.owner.id, window: w)
                        if CGPreflightScreenCaptureAccess() {
                            tile.shrunk = true
                            tile.picture = portholePictures[w]?.image
                            nowPortholed.insert(w)
                        }
                        crowd.append(tile)
                        continue
                    }
                    f.origin.x = min(max(f.minX, target.minX), target.maxX - min(needW, target.width))
                    f.origin.y = min(max(f.minY, target.minY), target.maxY - min(needH, target.height))
                }
                windows.setFrame(w, f)
                // A stretched spot is only how it looks from here: don't save it as the window's own.
                let pid = placed.panel.id
                let stretched = stretch != nil
                placedNow.append((w, f, { stretched ? nil : Applied(frame: $0, panelRect: target, panel: pid, filled: false) }))
            }
        }
        windows.endBatch()
        let landed = windows.frames(of: placedNow.map { $0.window })
        for item in placedNow { lastApplied[item.window] = item.record(landed[item.window] ?? item.fallback) }
        // Portholes: windows that spilled out of a spot this size before are
        // tucked away below and a frosted picture shows in their place. The
        // rest are checked once they've settled at their new size. New
        // windows still having their size checked show as portholes too.
        var toCheck: [UInt32: (spot: CGRect, nested: Bool)] = [:]
        var probeSpots: [UInt32: CGRect] = [:]
        // Windows with a size on record, shown live on the board itself:
        // see whether they can get smaller after all.
        for (w, spot) in liveSpots where overflowAt[w] != nil { toCheck[w] = (spot, false) }
        for (w, d) in deep where w != spotlit {
            if cramped(w, in: d.spot) || probing.contains(w) {
                visible.remove(w)
                liveIn[w] = nil
                lastApplied[w] = nil
                nowPortholed.insert(w)
                if let t = portholeTile(w, spot: d.spot, placed: d.placed, target: d.target) { crowd.append(t) }
                if probing.contains(w), !cramped(w, in: d.spot) { probeSpots[w] = d.spot }
            } else {
                toCheck[w] = (d.spot, true)
            }
        }
        // Only windows still waiting for their check here stay in it.
        probing.formIntersection(probeSpots.keys)
        portholed = nowPortholed
        mirrored = nowMirrored
        scheduleOverflowCheck(toCheck)
        // Spotlight: one window blown up over the board, a margin of the
        // board still showing around it.
        if let s = spotlit {
            if visible.contains(s) {
                windows.setFrame(s, spotlightRect)
                lastApplied[s] = nil   // never saved as a manual move
            } else {
                spotlit = nil
            }
        }
        for w in everyWindow() where !visible.contains(w) && !docked.contains(w) {
            windows.park(w, on: screen)
            lastApplied[w] = nil   // tucked away, not a manual move
        }
        // Your normal desktop windows step aside while you're inside.
        for w in surfaceFrames.keys where windows.exists(w) {
            windows.park(w, on: screen)
        }
        tendFloaters()
        runProbes(probeSpots)
        // An app that won't shrink to its panel: widen the panel to fit it,
        // then lay out once more.
        if growToFit, !refitting, refitPanels(leaves) || refitDocks(leaves) {
            refitting = true
            applyLayout()
            refitting = false
            return
        }
        checkFrost(frostChecks)
        // More inside a tile: a ball at the end of the strip along its top,
        // or, with no strip there, a ball on its own in the same place.
        var loose: [MoreInside] = []
        for h in moreInsideHints(placedAll) {
            if let i = strips.firstIndex(where: { st in
                abs(st.rect.maxY - h.rect.maxY) < 24 && st.rect.minX >= h.rect.minX - 2 && st.rect.maxX <= h.rect.maxX + 2
                    && abs(st.rect.maxX - h.rect.maxX) < 24
            }) {
                strips[i].more = h
            } else {
                loose.append(h)
            }
        }
        tabStrips.show(strips)
        moreInside.show(loose)
        crowd = shelve(crowd)
        shownTiles = crowd
        // The coach: the first bubble, and the first window that frosts by itself.
        if let h = loose.first ?? strips.compactMap({ $0.more }).first {
            Coach.shared.note(.bubbleSeen(MoreInsideHints.spot(in: h.rect)))
        }
        if let t = crowd.first(where: { !$0.porthole && $0.cells.isEmpty && $0.badge == nil && $0.window != 0
                                        && !handFrost.contains($0.panel) }) {
            Coach.shared.note(.frostSeen(t.rect))
        }
        if let sp = spotlit, visible.contains(sp) { intended[sp] = spotlightRect }
        fitPortholes(redraw: true, around: intended)
        // Live windows can take a while to reach their real size (Maps is
        // slow): fit again as they settle.
        portholeFit?.cancel()
        portholeFit = nil
        if crowd.contains(where: { $0.porthole }) {
            portholeFit = Task { @MainActor [weak self] in
                for wait in [0.3, 0.5, 0.7, 1.0, 1.5] {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.fitPortholes(redraw: false)
                }
            }
        }
        refreshPortholePictures()
        finishLayout()
    }

    /// The Surface: every board window tucked away, your desktop put back.
    private func layoutSurface() {
        portholeFit?.cancel()
        portholeFit = nil
        shownTiles = []
        tiles.hide()
        tabStrips.hide()
        moreInside.hide()
        live.stopAll()
        shownTiles = []
        portholed = []
        mirrored = []
        // The Desktop's windows go back to being your normal desktop, right
        // where they are (docked windows step aside as before).
        for main in allMains {
            guard let desk = main.freePanel() else { continue }
            var handed: [UInt32] = []
            for w in desk.windows where liveIn[w] != nil && windows.exists(w) && !windows.parked.contains(w) {
                if let f = windows.frame(of: w) {
                    surfaceFrames[w] = f
                    handed.append(w)
                }
            }
            for w in handed {
                desk.setFloat(w, nil)
                lastApplied[w] = nil
            }
            desk.windows.removeAll { handed.contains($0) }
        }
        for w in everyWindow() where !docked.contains(w) {
            windows.park(w, on: screen)
            lastApplied[w] = nil
        }
        for (w, f) in surfaceFrames where windows.exists(w) {
            windows.setFrame(w, f)
        }
        surfaceFrames.removeAll()
    }

    // MARK: Making room for floating windows

    var makeRoom: Bool {
        get { UserDefaults.standard.bool(forKey: "makeRoom") }
        set { UserDefaults.standard.set(newValue, forKey: "makeRoom"); applyLayout() }
    }

    /// Where a panel's filled windows go: the whole panel, or, when windows
    /// float in it, the biggest open area beside them so nothing is covered.
    /// If the open area would be too cramped, filled windows take the whole
    /// panel and the floats sit on top, as before.
    /// - Parameters:
    ///   - extra: floating areas to make room for that aren't in the panel
    ///     yet (a window being dragged in), in screen coordinates.
    ///   - excluding: a window to leave out (the one being dragged).
    func fillRect(for panel: Panel, in target: CGRect, extra: [CGRect] = [], excluding: UInt32? = nil,
                  only: [UInt32]? = nil) -> CGRect {
        guard makeRoom else { return target }
        let members = (only ?? panel.windows).filter { $0 != excluding && !onTop.contains($0) && !docked.contains($0) }
        let floats = (members.compactMap { w in panel.floatRect(w).map { absolute($0, in: target) } } + extra)
            .map { $0.insetBy(dx: -gap / 2, dy: -gap / 2).intersection(target) }
            .filter { !$0.isNull && $0.width > 1 && $0.height > 1 }
        guard !floats.isEmpty, members.contains(where: { panel.floatRect($0) == nil }) else { return target }

        // Try every rectangle whose edges line up with the panel or a float
        // edge, and keep the biggest one that overlaps no float.
        let xs = Array(Set([target.minX, target.maxX] + floats.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set([target.minY, target.maxY] + floats.flatMap { [$0.minY, $0.maxY] })).sorted()
        var best = CGRect.zero
        for (i, x1) in xs.enumerated() {
            for x2 in xs[(i + 1)...] {
                for (j, y1) in ys.enumerated() {
                    for y2 in ys[(j + 1)...] {
                        let r = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
                        guard r.width * r.height > best.width * best.height else { continue }
                        if floats.allSatisfy({ !$0.insetBy(dx: 1, dy: 1).intersects(r) }) { best = r }
                    }
                }
            }
        }
        let roomy = best.width >= 320 && best.height >= 240 &&
                    best.width * best.height >= target.width * target.height * 0.3
        return roomy ? best : target
    }

    // MARK: Editing from the live map

    /// True while a zoom or glide is under way.
    var isBusy: Bool { busy }

    /// The dividers of the board the live map shows, in the map's rectangle.
    func mapDividers(in map: CGRect, from top: [UUID]) -> [Divider] {
        guard let board = desktop(at: top) else { return [] }
        return dividers(of: board, in: map)
    }

    /// A window moved or resized on the live map: it floats at that spot in
    /// that panel (moving it there from another panel if need be).
    func placeWindow(_ w: UInt32, inPanel id: UUID, at rel: CGRect) {
        var found: Panel?
        forEachPanel(state.root) { if $0.id == id { found = $0 } }
        guard let p = found, p.desktop == nil else { return }
        if !p.windows.contains(w) {
            remove(window: w)
            p.windows.append(w)
        }
        p.setFloat(w, rel)
        lastApplied[w] = nil
        applyLayout()
    }

    // MARK: Wallpaper for a board

    /// The wallpaper behind the board you're on: its own, else the nearest
    /// board above it that has one. Nil: your Mac's wallpaper.
    var currentWallpaper: URL? {
        guard !onSurface else { return nil }
        for d in desktopStack().reversed() {
            if let path = d.wallpaper, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Picks a picture to be this board's wallpaper (and the boards inside it).
    /// Your Mac's own wallpaper stays as it is.
    func chooseWallpaper() {
        guard !onSurface else { return }
        let board = current
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Wallpaper"
        panel.message = "A wallpaper for \(locationLabel()) and the boards inside it"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.checkpoint()
            board.wallpaper = url.path
            self.state.save(to: self.stateURL)
            self.backdrop.update(depth: self.depth, on: self.screen, custom: self.currentWallpaper)
        }
    }

    /// Back to the wallpaper of the board above (or your Mac's).
    func clearWallpaper() {
        guard !onSurface, current.wallpaper != nil else { return }
        checkpoint()
        current.wallpaper = nil
        saveState()
        backdrop.update(depth: depth, on: screen, custom: currentWallpaper)
    }

    // MARK: Motion and feel

    /// Rearrangements glide instead of jump.
    var glideMotion: Bool {
        get { UserDefaults.standard.bool(forKey: "glideMotion") }
        set { UserDefaults.standard.set(newValue, forKey: "glideMotion") }
    }
    /// Dragging a filled window's edge moves the gap beside it.
    var edgeGaps: Bool {
        get { UserDefaults.standard.bool(forKey: "edgeGaps") }
        set { UserDefaults.standard.set(newValue, forKey: "edgeGaps") }
    }
    /// Dragging right in the gap between pools resizes them, no keys needed.
    var gapDrag: Bool {
        get { UserDefaults.standard.bool(forKey: "gapDrag") }
        set { UserDefaults.standard.set(newValue, forKey: "gapDrag") }
    }
    /// New windows go to an empty pool first.
    var openWater: Bool {
        get { UserDefaults.standard.bool(forKey: "openWater") }
        set { UserDefaults.standard.set(newValue, forKey: "openWater") }
    }
    /// A window flung across the board lands in the pool it was heading for.
    var throwing: Bool {
        get { UserDefaults.standard.bool(forKey: "throwing") }
        set { UserDefaults.standard.set(newValue, forKey: "throwing") }
    }

    let glider = LayoutGlide()
    private var gliding = false

    /// Lays out with motion: the windows slide to their new places instead
    /// of jumping there. Falls back to a plain layout when it can't (no
    /// Screen Recording, mid-zoom, or a glide already playing).
    func glideLayout() {
        // A drag's stage is covering the screen: it plays the motion itself.
        guard glideMotion, !busy, !gliding, !onSurface, edgeWindow == nil, !stage.isActive,
              glider.hasPermission, AXIsProcessTrusted() else {
            applyLayout()
            return
        }
        windows.refresh()
        // Every board window in view now (some may be on their way out of
        // view), read from every app at once.
        let inView = Set(state.root.allWindows()).filter { windows.exists($0) && !windows.parked.contains($0) }
        var seen: [UInt32: CGRect] = [:]
        for (w, f) in windows.frames(of: Array(inView)) where screen.frame.intersects(f) { seen[w] = f }
        let before = seen
        guard !before.isEmpty else {
            applyLayout()
            return
        }
        gliding = true
        busy = true
        Task { @MainActor in
            await glider.play(on: screen, before: before, change: {
                self.applyLayout()
                // Where each window is going: where it was sent, if it hasn't
                // got there yet (apps take a moment to resize).
                var after: [UInt32: CGRect] = [:]
                let still = before.keys.filter { self.windows.exists($0) && !self.windows.parked.contains($0) }
                for (w, f) in self.windows.frames(of: still) where self.screen.frame.intersects(f) {
                    after[w] = self.windows.target(of: w) ?? f
                }
                return after
            }, frameOf: { self.windows.frame(of: $0) })
            self.animator.forgetEarlyPicture()
            self.busy = false
            self.gliding = false
        }
    }

    // MARK: Pool boundaries

    /// Faint outlines around the pools of the board you're on (not the ones
    /// inside its nested boards).
    func showBounds() {
        guard bounds.enabled || bounds.windowOutlines || bounds.gapHandles, !onSurface else {
            bounds.hide()
            return
        }
        // Every docked window in view (not on the Desktop, where windows
        // float like on any Mac), where it sits.
        var edges: [CGRect] = []
        if bounds.windowOutlines {
            for placed in frames(current, in: viewport) where placed.panel.desktop == nil && placed.panel.free != true {
                let target = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
                let shown = shownWindows(placed.panel, of: placed.owner)
                let fill = fillRect(for: placed.panel, in: target, only: shown)
                for w in shown where liveIn[w] == placed.panel.id && !portholed.contains(w) && w != spotlit {
                    edges.append(spot(for: w, in: placed.panel, target: target, fill: fill, stretch: nil))
                }
            }
        }
        bounds.show(frames(current, in: viewport).filter { $0.depth == 0 }.map { $0.rect }, windows: edges,
                    handles: bounds.gapHandles ? gapHandleRects() : [], on: screen)
    }

    /// Where the pill goes in each draggable gap on the board you're on: in
    /// the middle of the gap, a fifth of its length (between 36 and 80 points).
    private func gapHandleRects() -> [CGRect] {
        let thick: CGFloat = 4
        guard !placementsLocked else { return [] }
        return dividers().filter { gapMoves($0) }.compactMap { d in
            let r = d.frame
            let at = shownPosition(d)
            if d.axis == .h {
                let len = min(80, max(36, r.height * 0.2))
                guard r.height > len + 2 * gap else { return nil }
                return CGRect(x: at - thick / 2, y: r.midY - len / 2, width: thick, height: len)
            } else {
                let len = min(80, max(36, r.width * 0.2))
                guard r.width > len + 2 * gap else { return nil }
                return CGRect(x: r.midX - len / 2, y: at - thick / 2, width: len, height: thick)
            }
        }
    }

    // MARK: Live layout while dragging

    /// A quick layout for while you drag a gap or a window's edge: only
    /// windows whose spot changed move, and nothing else happens (no saving,
    /// no lobby or map redraw, no app-wide refresh), so it can keep up with
    /// your hand. The full layout runs when you let go.
    func liveLayout() {
        guard !onSurface else { return }
        animator.forgetEarlyPicture()
        showBounds()
        var strips: [TabStrip] = []
        var frostChanges = false
        // A resize playing as pictures: the windows' pictures glide to their
        // spots, and the real windows wait until you let go.
        let staged = resizeStaged && stage.isReady
        var plan: [UInt32: CGRect] = [:]
        var hidden = Set<UInt32>()
        for placed in frames(current, in: viewport) where placed.panel.desktop == nil {
            var target = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
            // Frosted over (too small for its app) or not: when that changes
            // as you drag, a full layout swaps it over right away; a frosted
            // tile follows the gap meanwhile.
            if placed.panel.free != true, crowdIcons {
                let list = shownWindows(placed.panel, of: placed.owner)
                if shownTiles.contains(where: { $0.shelfPanels.contains(placed.panel.id) }) {
                    // On a shelf: a full layout redraws the shelf as you drag.
                    frostChanges = true
                    if staged { hidden.formUnion(list) }
                    continue
                }
                let frosted = shownTiles.contains { $0.panel == placed.panel.id && !$0.porthole && $0.cells.isEmpty }
                let wants = !list.isEmpty && wantsFrost(placed, list, target)
                if frosted != wants { frostChanges = true }
                if frosted {
                    tiles.move(panel: placed.panel.id, to: target)
                    for i in shownTiles.indices where shownTiles[i].panel == placed.panel.id { shownTiles[i].rect = target }
                    if staged { hidden.formUnion(list) }
                    continue
                }
            }
            if let r = tabStripRect(for: placed.panel, of: placed.owner, in: target) {
                let all = tabMembers(placed.panel, of: placed.owner)
                let front = shownWindows(placed.panel, of: placed.owner).first ?? all.last!
                // The window in your hand: the strip stays on its top edge.
                let held = front == edgeWindow ? edgeNow.map { stripAbove($0) } : nil
                strips.append(TabStrip(rect: held ?? r, panel: placed.panel.id, tabs: all.map { w in
                    TabStrip.Tab(window: w, name: tabLabel(w, among: all), icon: windows.appIcon(w))
                }, front: front))
                target = tabBody(below: r, in: target)
            }
            let shown = shownWindows(placed.panel, of: placed.owner)
            let fill = fillRect(for: placed.panel, in: target, only: shown)
            for w in shown where w != edgeWindow && w != spotlit && !windows.parked.contains(w) && !portholed.contains(w)
                && liveIn[w] == placed.panel.id {
                let to = placed.panel.floatRect(w).map { absolute($0, in: target) } ?? fill
                if staged {
                    plan[w] = to
                } else {
                    windows.setFrameLive(w, to)
                }
            }
        }
        if !strips.isEmpty { tabStrips.show(strips) }
        if staged {
            // A window squeezed small frosts over on the stage; the real
            // layout (frosting included) waits until you let go.
            stage.preview(plan: plan, slot: nil, keep: true, hide: hidden)
            return
        }
        if frostChanges, Date().timeIntervalSince(lastFrostSwap) > 0.12 {
            lastFrostSwap = Date()
            windows.flushLive()
            applyLayout()
        }
    }

    /// When a drag last swapped a tile between frosted and live.
    private var lastFrostSwap = Date.distantPast

    // MARK: Resizing as pictures

    /// While you drag a gap or a window's edge, the windows around it move
    /// as pictures on a spring, so nothing zips around and slow apps
    /// (Discord, other Electron apps) aren't asked for a new size sixty times
    /// a second. When you let go, the real windows are resized once, out of
    /// sight under the pictures, and the pictures fade once the apps have
    /// drawn at their new size. Needs Screen Recording; without it, the real
    /// windows follow live, as before.
    var pictureResize: Bool {
        get { UserDefaults.standard.bool(forKey: "pictureResize") }
        set { UserDefaults.standard.set(newValue, forKey: "pictureResize") }
    }
    private var resizeStaged = false

    /// A gap (no window in hand) or a window's edge starts moving.
    func beginResizeStage(holding w: UInt32?) {
        guard pictureResize, !resizeStaged, !onSurface, glider.hasPermission, !stage.isActive else { return }
        var frames: [UInt32: CGRect] = [:]
        var icons: [UInt32: NSImage] = [:]
        for x in liveIn.keys where x != w && !windows.parked.contains(x) && !portholed.contains(x) {
            guard let f = windows.frame(of: x), screen.frame.intersects(f) else { continue }
            frames[x] = f
            if let i = windows.appIcon(x) { icons[x] = i }
        }
        guard !frames.isEmpty,
              stage.prepare(on: screen, dragged: w ?? 0, windows: frames, icons: icons, resizing: true)
        else { return }
        resizeStaged = true
        tiles.lifted = true
        tabStrips.lifted = true
        bounds.lifted = true
    }

    /// The resize is over and the real windows have been sent to their
    /// spots: the pictures settle there, and the stage fades once the apps
    /// have caught up.
    func endResizeStage() {
        guard resizeStaged else { return }
        resizeStaged = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stage.finish(dropped: true, draggedTo: nil,
                                    targetOf: { self.windows.target(of: $0) ?? self.windows.frame(of: $0) },
                                    frameOf: { [weak self] in self?.windows.frame(of: $0) })
            // (A new resize may have started meanwhile.)
            if !self.resizeStaged {
                self.tiles.lifted = false
                self.tabStrips.lifted = false
                self.bounds.lifted = false
            }
        }
    }

    // MARK: Window edges move the gaps

    private enum Edge { case left, right, top, bottom }
    private struct EdgeGrip {
        let split: Split
        let index: Int
        let edge: Edge
        /// How far the gap sits from the window's edge (half a gap, more
        /// for a pool inside a nested board).
        let offset: CGFloat
        /// How far the window's edge was from the pointer when it was
        /// picked up: past the point where the window won't shrink any
        /// more, the gap follows the pointer (by this much) instead.
        let pointer: CGFloat
    }
    private struct EdgeSession {
        let window: UInt32
        let start: CGRect      // the window's frame before the drag
        let pool: CGRect       // its pool, before the drag
        let depth: Int
        var grips: [EdgeGrip]
        let poolID: UUID
        let wasFloating: Bool
        /// The other windows floating in its pool, where they started (pool fractions).
        let neighbours: [(window: UInt32, rel: CGRect)]
        var checkpointed = false
        /// Where you pressed (AppKit coordinates).
        var press: CGPoint = .zero
    }
    private var edgeSession: EdgeSession?
    /// Where the window in your hand is right now (when it's a tab in front).
    private var edgeNow: CGRect?

    /// The tab showing in a tabbed pool.
    private func tabStripFront(_ p: Panel) -> UInt32? {
        p.front.flatMap { p.windows.contains($0) ? $0 : nil } ?? p.windows.last
    }

    /// A strip of tabs sitting on a window's top edge.
    private func stripAbove(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX, y: f.maxY + 4, width: f.width, height: Self.tabStripHeight)
    }
    /// The window being resized by hand: layouts leave it alone until you let go.
    private var edgeWindow: UInt32?
    private var edgeLastLayout = Date.distantPast

    /// While you drag a filled window's edge, the gap on that side follows
    /// it: the neighbours give way as you drag and the window stays filled.
    /// Edges along the outside of the board don't count. Returns true when
    /// the resize was taken up this way (so it isn't turned into a float).
    @discardableResult
    func edgeResize(_ w: UInt32, final: Bool, pressedAt: CGPoint? = nil) -> Bool {
        defer {
            if final {
                edgeSession = nil
                edgeWindow = nil
                edgeNow = nil
                // Let go some other way: the stage still comes down.
                if resizeStaged {
                    applyLayout()
                    endResizeStage()
                }
            }
        }
        guard edgeGaps, !onSurface, !busy, spotlit != w, let now = windows.frame(of: w) else { return false }
        // A tab in front, being resized by hand: its strip of tabs rides along
        // on its top edge.
        if let p = chain(for: w)?.last, p.tabs == true, p.windows.count > 1, tabStripFront(p) == w {
            edgeNow = final ? nil : now
            tabStrips.move(panel: p.id, to: stripAbove(now))
        }
        if edgeSession?.window != w {
            guard let last = lastApplied[w],
                  let placed = frames(current, in: viewport)
                    .first(where: { $0.panel.id == last.panel && $0.panel.desktop == nil })
            else { return false }
            let p = placed.panel
            // Windows on the Desktop resize freely, like on a normal Mac.
            guard p.free != true else { return false }
            let others = shownWindows(p, of: placed.owner).filter {
                $0 != w && !onTop.contains($0) && !windows.parked.contains($0)
            }
            let floats = others.compactMap { o in p.floatRect(o).map { (window: o, rel: $0) } }
            edgeSession = EdgeSession(window: w, start: last.frame, pool: placed.rect, depth: placed.depth, grips: [],
                                      poolID: p.id, wasFloating: !last.filled && p.floatRect(w) != nil,
                                      neighbours: floats)
            edgeSession?.press = pressedAt ?? NSEvent.mouseLocation
            beginResizeStage(holding: w)
        }
        guard var session = edgeSession else { return false }

        // Pick up every edge that has started to move and has a gap beside it
        // (a corner drag can start out moving just one of them).
        let p = session.pool, was = session.start, half = gap / 2
        let slack = 3 + CGFloat(session.depth) * half
        let all = dividers()
        func gapAt(_ axis: Axis, _ position: CGFloat) -> Divider? {
            all.first { d in
                guard d.axis == axis, abs(d.position - position) < slack else { return false }
                return axis == .h ? (p.midY > d.frame.minY && p.midY < d.frame.maxY)
                                  : (p.midX > d.frame.minX && p.midX < d.frame.maxX)
            }
        }
        func have(_ e: Edge) -> Bool { session.grips.contains { $0.edge == e } }
        let moved: CGFloat = 4, near: CGFloat = 8
        // Only a change of size counts: a nudge by the title bar moves both edges.
        let wide = abs(now.width - was.width) > moved, tall = abs(now.height - was.height) > moved
        let hadGrips = !session.grips.isEmpty
        // A window already as small as it goes doesn't change size when you
        // drag its edge in: the press on its edge, and the pointer moving in,
        // say what you mean.
        let mouse = NSEvent.mouseLocation, press = session.press
        let atMin = windows.minSize(w)
        let stuckW = atMin.map { now.width <= $0.width + 3 } ?? false
        let stuckH = atMin.map { now.height <= $0.height + 3 } ?? false
        func pressedOn(_ edge: CGFloat, _ at: CGFloat) -> Bool { at > edge - 6 && at < edge + 7 || abs(at - edge) < 7 }
        let inRight = !wide && stuckW && pressedOn(was.maxX, press.x) && mouse.x < press.x - moved
        let inLeft = !wide && stuckW && pressedOn(was.minX, press.x) && mouse.x > press.x + moved
        let inTop = !tall && stuckH && pressedOn(was.maxY, press.y) && mouse.y < press.y - moved
        let inBottom = !tall && stuckH && pressedOn(was.minY, press.y) && mouse.y > press.y + moved
        if (wide && abs(now.maxX - was.maxX) > moved) || inRight, !have(.right), abs(was.maxX - (p.maxX - half)) < near,
           let d = gapAt(.h, p.maxX) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .right, offset: d.position - was.maxX,
                                          pointer: inRight ? was.maxX - press.x : now.maxX - mouse.x))
        }
        if (wide && abs(now.minX - was.minX) > moved) || inLeft, !have(.left), abs(was.minX - (p.minX + half)) < near,
           let d = gapAt(.h, p.minX) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .left, offset: d.position - was.minX,
                                          pointer: inLeft ? was.minX - press.x : now.minX - mouse.x))
        }
        // A tabbed tile's window starts under its strip of tabs.
        let tabbed = dropPanels().first { $0.panel.id == session.poolID }
            .map { tabStripRect(for: $0.panel, of: $0.owner, in: $0.rect.insetBy(dx: half, dy: half)) != nil } ?? false
        let topInset: CGFloat = tabbed ? Self.tabStripHeight + 4 : 0
        if (tall && abs(now.maxY - was.maxY) > moved) || inTop, !have(.top),
           abs(was.maxY - (p.maxY - half - topInset)) < near, let d = gapAt(.v, p.maxY) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .top, offset: d.position - was.maxY,
                                          pointer: inTop ? was.maxY - press.y : now.maxY - mouse.y))
        }
        if (tall && abs(now.minY - was.minY) > moved) || inBottom, !have(.bottom),
           abs(was.minY - (p.minY + half)) < near, let d = gapAt(.v, p.minY) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .bottom, offset: d.position - was.minY,
                                          pointer: inBottom ? was.minY - press.y : now.minY - mouse.y))
        }
        _ = hadGrips
        // Windows in the same pool make room as it grows (and docked ones
        // follow as it shrinks).
        let pushing = pushNeighbours(of: session, to: now, final: final)
        guard !session.grips.isEmpty || pushing || session.checkpointed else {
            edgeSession = session
            return false
        }
        // Back to (about) its starting size: the windows it pushed go back too.
        if !pushing, session.checkpointed,
           let pl = dropPanels().first(where: { $0.panel.id == session.poolID }) {
            for nb in session.neighbours { pl.panel.setFloat(nb.window, nb.rel) }
        }
        if !session.checkpointed {
            session.checkpointed = true
            checkpoint()   // Hyper + Z puts everything back (taken before the first change below)
            edgeWindow = w
        }
        edgeSession = session
        if pushing { _ = pushNeighbours(of: session, to: now, final: final, apply: true) }

        let fresh = dividers()
        for g in session.grips {
            let axis: Axis = (g.edge == .left || g.edge == .right) ? .h : .v
            guard let d = fresh.first(where: { $0.split === g.split && $0.index == g.index }), d.axis == axis
            else { continue }
            switch g.edge {
            // The window's edge, or, past where it won't shrink any more,
            // the pointer: the tile goes smaller than its app (and frosts
            // when you let go).
            case .right: moveDivider(d, to: CGPoint(x: min(now.maxX, mouse.x + g.pointer) + g.offset, y: now.midY))
            case .left: moveDivider(d, to: CGPoint(x: max(now.minX, mouse.x + g.pointer) + g.offset, y: now.midY))
            case .top: moveDivider(d, to: CGPoint(x: now.midX, y: min(now.maxY, mouse.y + g.pointer) + g.offset))
            case .bottom: moveDivider(d, to: CGPoint(x: now.midX, y: max(now.minY, mouse.y + g.pointer) + g.offset))
            }
        }
        if final {
            // Let go: the window settles into its pool (a filled one still
            // filling it, a floating one at its new size).
            if session.wasFloating, let pl = dropPanels().first(where: { $0.panel.id == session.poolID }) {
                let inner = pl.rect.insetBy(dx: gap / 2, dy: gap / 2)
                pl.panel.setFloat(w, relative(now.intersection(inner).isNull ? now : now.intersection(inner), in: inner))
            }
            edgeWindow = nil
            touched.remove(w)
            lastApplied[w] = nil
            windows.flushLive()
            settleEmpty()
            applyLayout()
            endResizeStage()
        } else {
            edgeLastLayout = Date()
            liveLayout()
        }
        return true
    }

    /// A new press of the mouse: any edge drag that never saw its release is over.
    func clearEdgeResize() {
        guard edgeSession != nil || edgeWindow != nil || resizeStaged else { return }
        edgeSession = nil
        edgeWindow = nil
        edgeNow = nil
        windows.flushLive()
        applyLayout()
        endResizeStage()
    }

    // MARK: Windows in a pool make room for one being resized

    /// While you resize a window by an edge or corner, the windows floating
    /// beside it in its pool give way as it grows into them; one docked right
    /// against it follows as it shrinks back. Filled windows in the pool make
    /// room on their own once the floats have moved (the layout fits them
    /// around). With `apply` false it only says whether anything would move.
    private func pushNeighbours(of session: EdgeSession, to now: CGRect, final: Bool, apply: Bool = false) -> Bool {
        guard let placed = dropPanels().first(where: { $0.panel.id == session.poolID }) else { return false }
        let p = placed.panel
        let inner = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
        guard inner.width > 1, inner.height > 1 else { return false }
        let was = session.start, moved: CGFloat = 4
        guard abs(now.width - was.width) > moved || abs(now.height - was.height) > moved else { return false }
        // Has anything to make room: floats beside it, or filled windows
        // that will fit around it (it floats itself).
        let hasFilled = shownWindows(p, of: placed.owner).contains {
            $0 != session.window && p.floatRect($0) == nil && !onTop.contains($0)
        }
        guard !session.neighbours.isEmpty || (session.wasFloating && hasFilled) else { return false }
        var changes: [(UInt32, CGRect)] = []
        for nb in session.neighbours {
            // Where it started, at the pool's size now.
            let f0 = absolute(nb.rel, in: inner)
            var f = f0
            let m = windows.minSize(nb.window) ?? .zero
            let minW = max(m.width, 220), minH = max(m.height, 160)
            let besideRows = f.maxY > was.minY + 1 && f.minY < was.maxY - 1
            let besideCols = f.maxX > was.minX + 1 && f.minX < was.maxX - 1
            func touching(_ d: CGFloat) -> Bool { d >= -2 && d <= gap + 6 }
            if besideRows, f.minX >= was.maxX - 2,
               now.maxX + gap > f.minX || (touching(f.minX - was.maxX) && now.maxX < was.maxX - moved) {
                let edge = min(now.maxX + gap, f.maxX - minW)
                f = CGRect(x: edge, y: f.minY, width: f.maxX - edge, height: f.height)
            }
            if besideRows, f.maxX <= was.minX + 2,
               now.minX - gap < f.maxX || (touching(was.minX - f.maxX) && now.minX > was.minX + moved) {
                let edge = max(now.minX - gap, f.minX + minW)
                f = CGRect(x: f.minX, y: f.minY, width: edge - f.minX, height: f.height)
            }
            if besideCols, f.minY >= was.maxY - 2,
               now.maxY + gap > f.minY || (touching(f.minY - was.maxY) && now.maxY < was.maxY - moved) {
                let edge = min(now.maxY + gap, f.maxY - minH)
                f = CGRect(x: f.minX, y: edge, width: f.width, height: f.maxY - edge)
            }
            if besideCols, f.maxY <= was.minY + 2,
               now.minY - gap < f.maxY || (touching(was.minY - f.maxY) && now.minY > was.minY + moved) {
                let edge = max(now.minY - gap, f.minY + minH)
                f = CGRect(x: f.minX, y: f.minY, width: f.width, height: edge - f.minY)
            }
            if abs(f.minX - f0.minX) > 1 || abs(f.minY - f0.minY) > 1 || abs(f.width - f0.width) > 1 || abs(f.height - f0.height) > 1 {
                changes.append((nb.window, f))
            }
        }
        guard !changes.isEmpty || session.wasFloating else { return false }
        guard apply else { return true }
        for (n, f) in changes {
            p.setFloat(n, relative(f, in: inner))
            lastApplied[n] = nil
        }
        // The window you're resizing, if it floats, is where you've put it
        // (so filled windows fit around it as you go).
        if session.wasFloating {
            let mine = now.intersection(inner)
            if !mine.isNull { p.setFloat(session.window, relative(mine, in: inner)) }
        }
        return true
    }

    // MARK: Throwing windows

    /// A window flung across the board lands in the pool it was heading
    /// for: the throw carries on past where you let go (further the faster
    /// it was going) until it runs out or meets the edge of the screen.
    /// An empty pool takes it whole; in a pool that's in use, it lands in
    /// the half where it came down and the windows there make room.
    /// Returns false when the throw doesn't carry it to another pool.
    func throwWindow(_ w: UInt32, from start: CGPoint, velocity: CGVector) -> Bool {
        guard throwing, !onSurface, !busy else { return false }
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed > 1 else { return false }
        let pools = dropPanels()
        func pool(at q: CGPoint) -> Placed? {
            pools.filter { $0.rect.contains(q) }.max { $0.depth < $1.depth }
        }
        let area = viewport
        let reach = min(speed * 0.3, 1600)
        let dx = velocity.dx / speed, dy = velocity.dy / speed
        var landing = start
        var travelled: CGFloat = 0
        while travelled < reach {
            let next = CGPoint(x: start.x + dx * (travelled + 12), y: start.y + dy * (travelled + 12))
            guard area.contains(next) else { break }
            landing = next
            travelled += 12
        }
        guard let to = pool(at: landing), to.panel.id != pool(at: start)?.panel.id else { return false }
        checkpoint()
        removeLive(w)
        // An empty pool takes it whole; in one that's in use it lands in the
        // half where it came down (a tile of its own); on the Desktop it floats.
        landInHalf(w, of: to, at: landing)
        state.lastPanelId = to.panel.id
        lastApplied[w] = nil
        glideLayout()
        windows.focus(w)
        return true
    }

    // MARK: Panels grow to fit apps that won't shrink

    var growToFit: Bool {
        get { UserDefaults.standard.bool(forKey: "growToFit") }
        set { UserDefaults.standard.set(newValue, forKey: "growToFit"); applyLayout() }
    }
    private var refitting = false
    private var refitPending = false

    /// A window settled bigger than its spot: lay out again so its pool grows
    /// to fit. Not while a mouse button is down (you're dragging a gap or a
    /// window); letting go lays out anyway.
    private func minSizeLearned() {
        guard growToFit, !refitPending else { return }
        refitPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.refitPending = false
            guard !self.busy, !self.onSurface, !self.gliding, self.edgeWindow == nil,
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.applyLayout()
        }
    }

    /// Some apps (Apple Music, for one) have a minimum window size. When a
    /// panel on the board you're on is smaller than that, the panel grows
    /// along its row or column just enough to hold the window (never more
    /// than 80% of the row). The space comes only from neighbours that can
    /// spare it, most from the roomiest (usually the Desktop): no neighbour
    /// is squished below a usable size or below what its own app needs. A
    /// pool that has already been squished that small grows back the same way.
    /// Returns true if anything changed.
    private func refitPanels(_ leaves: [(placed: Placed, target: CGRect)]) -> Bool {
        var changed = false
        for (placed, target) in leaves where placed.depth == 0 {
            let p = placed.panel
            var need = CGSize.zero
            for w in p.windows where p.floatRect(w) == nil {
                if let m = windows.minSize(w) {
                    need.width = max(need.width, m.width)
                    need.height = max(need.height, m.height)
                }
            }
            // A pool with windows in it is never left too small to use.
            if p.free != true, p.desktop == nil, !p.windows.isEmpty {
                need.width = max(need.width, Self.usableWidth)
                need.height = max(need.height, Self.usableHeight)
            }
            let wantW = need.width > target.width + 4, wantH = need.height > target.height + 4
            guard wantW || wantH, let loc = current.parent(of: p.id) else { continue }
            let s = loc.split
            // Sized by hand: your sizes stand (an app that won't fit frosts).
            guard s.seated != true else { continue }
            guard (s.axis == .h && wantW) || (s.axis == .v && wantH) else { continue }
            let span = s.axis == .h ? placed.rect.width : placed.rect.height
            let share = s.ratios[loc.index]
            guard share > 0.001 else { continue }
            let rowLength = span / CGFloat(share)
            let needed = Double(((s.axis == .h ? need.width : need.height) + gap + 2) / rowLength)
            let deficit = min(needed, 0.8) - share
            guard deficit > 0.005 else { continue }
            // What each neighbour can give without dropping below its own floor.
            var spare = [Double](repeating: 0, count: s.ratios.count)
            for (j, child) in s.children.enumerated() where j != loc.index && j < s.ratios.count {
                let floorShare = Double(floorLength(child, along: s.axis) / rowLength)
                spare[j] = max(0, s.ratios[j] - floorShare)
            }
            let totalSpare = spare.reduce(0, +)
            let take = min(deficit, totalSpare)
            guard take > 0.005 else { continue }
            for j in spare.indices where spare[j] > 0 { s.ratios[j] -= take * spare[j] / totalSpare }
            s.ratios[loc.index] += take
            changed = true
        }
        return changed
    }

    static let usableWidth: CGFloat = 220
    static let usableHeight: CGFloat = 150

    /// The least room a tile (or a group of tiles) can be given along a row
    /// or column and stay usable: a usable size, or more if an app in it
    /// won't go that small. Gaps included.
    private func floorLength(_ node: Node, along axis: Axis) -> CGFloat {
        switch node {
        case .panel(let p):
            var m = axis == .h ? Self.usableWidth : Self.usableHeight
            if p.desktop == nil {
                for w in p.windows where p.floatRect(w) == nil {
                    if let s = windows.minSize(w) { m = max(m, axis == .h ? s.width : s.height) }
                }
            }
            return m + gap
        case .split(let sp):
            let fs = sp.children.map { floorLength($0, along: axis) }
            return sp.axis == axis ? fs.reduce(0, +) : (fs.max() ?? 0)
        }
    }

    // MARK: Breathing room

    /// Diving in opens breathing room by itself. Off by default: you arrive to
    /// your windows filling the screen, and Hyper + B opens room when you want it.
    var breathingRoom: Bool {
        get { UserDefaults.standard.bool(forKey: "breathingRoom") }
        set { UserDefaults.standard.set(newValue, forKey: "breathingRoom") }
    }

    /// Diving into a board opens an empty panel along its side, so you arrive
    /// somewhere with space. It goes on the side facing the middle of the
    /// screen (dive into a left-hand panel and the room opens on the right).
    private func addBreathingRoom(entering target: CGRect) {
        lastRoomTarget = target
        guard breathingRoom, !onSurface else { return }
        let d = current
        // Already has room: an empty panel, or an inside-only panel (it opens up
        // as you arrive, which is breathing room of its own).
        guard !d.panels().contains(where: { ($0.windows.isEmpty && $0.desktop == nil) || $0.scratch == true })
        else { return }
        placeRoom(on: d, entering: target)
    }

    /// Hyper + B: opens breathing room on the board you're on, or folds it away
    /// again. It's private: it, and anything you put in it, only shows on this
    /// board. Leave it empty and it also folds away by itself when you leave.
    func toggleBreathingRoom() {
        guard !onSurface, !busy, !lockRefuses() else { return }
        let d = current
        let rooms = d.panels().filter { $0.scratch == true && $0.windows.isEmpty && $0.desktop == nil }
        if rooms.isEmpty {
            checkpoint()   // Hyper + Z folds it away again
            placeRoom(on: d, entering: lastRoomTarget ?? screen.frame)
            // The coach: a room, or a room inside a room.
            let holder = state.path.last.flatMap { id in desktopStack().dropLast().last?.panel(id: id) }
            let roomRect = frames(d, in: viewport).first {
                $0.depth == 0 && $0.panel.scratch == true && $0.panel.windows.isEmpty && $0.panel.desktop == nil
            }?.rect
            Coach.shared.note(.roomOpened(roomRect, deeper: holder?.scratch == true))
            Toast.show("Breathing room  ·  drop a window in to give it a tile of its own", seconds: 1.2)
        } else {
            // Folding it away isn't saved for undo: Hyper + B opens it again.
            for p in rooms { d.removeRoom(p) }
        }
        glideLayout()
    }

    /// Hyper + Shift + B: brings the Desktop back (pushed closed, or tucked
    /// away), or tucks it out of the layout.
    func toggleDesktopArea() {
        guard !onSurface, !busy else { return }
        let d = current
        if let desk = d.panels().first(where: { $0.free == true && $0.scratch != true && $0.tucked != true }) {
            checkpoint()
            desk.tucked = true
            glideLayout()
            Toast.show("Desktop tucked away  ·  the menu bar brings it back", seconds: 1.2)
            return
        }
        guard let desk = d.panels().first(where: { $0.tucked == true }) else {
            Toast.show("No Desktop on this board", seconds: 1.0)
            return
        }
        do {
            checkpoint()
            desk.tucked = nil
            if let loc = d.parent(of: desk.id) {
                let s = loc.split, share = 0.25
                let others = 1 - s.ratios[loc.index]
                if others > 0.001 {
                    s.ratios = s.ratios.enumerated().map { $0.offset == loc.index ? share : $0.element * (1 - share) / others }
                }
            }
            glideLayout()
            Toast.show("The Desktop is back", seconds: 0.9)
        }
    }

    /// Opens the room on a board: a quarter of the screen or a strip, on the side
    /// the settings say.
    private func placeRoom(on d: Desktop, entering target: CGRect) {
        let onRight: Bool
        var bottom = !roomAtTop
        switch roomSide {
        case .left: onRight = false
        case .right: onRight = true
        case .middle: onRight = target.midX <= screen.frame.midX
        case .pointer:
            // The corner nearest the pointer: the room opens where you're looking.
            let mouse = NSEvent.mouseLocation
            let f = screen.frame
            onRight = f.contains(mouse) ? mouse.x > f.midX : target.midX <= f.midX
            if f.contains(mouse) { bottom = mouse.y < f.midY }
        }
        let room: Panel
        if roomQuarter {
            // Turn the board to suit the screen it's about to fill first, so the
            // corner is worked out from the arrangement you'll actually see.
            if autoRotate { adapt(d.root, viewport, d) }
            room = d.addQuadrantRoom(right: onRight, bottom: bottom)
        } else {
            room = d.addRoom(onRight: onRight, share: roomShare)
        }
        // Every level can have a Desktop: breathing room is one, a little
        // Desktop of its own where windows float, and you can dive into it.
        if tileWindows { room.free = true }
    }

    /// The room is a quarter of the screen in a corner (the screen's own
    /// shape, a little desktop to dive into), or a strip along the side.
    var roomQuarter: Bool { UserDefaults.standard.bool(forKey: "roomQuarter") }

    /// For a quarter: the top corner instead of the bottom one.
    var roomAtTop: Bool { UserDefaults.standard.bool(forKey: "roomAtTop") }

    /// Switches the room's shape and redoes the room on the board you're on.
    func setRoomShape(quarter: Bool, top: Bool? = nil, share: Double? = nil) {
        let d = UserDefaults.standard
        d.set(quarter, forKey: "roomQuarter")
        if let top { d.set(top, forKey: "roomAtTop") }
        if let share { d.set(share, forKey: "roomShare") }
        refreshRoom()
    }

    /// Which side the breathing room opens on.
    enum RoomSide: String { case middle, left, right, pointer }

    var roomSide: RoomSide {
        get { RoomSide(rawValue: UserDefaults.standard.string(forKey: "roomSide") ?? "") ?? .middle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "roomSide"); refreshRoom() }
    }

    /// How much of the board's width the breathing room takes.
    var roomShare: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "roomShare")
            return v > 0.05 && v < 0.6 ? v : 0.22
        }
        set { UserDefaults.standard.set(newValue, forKey: "roomShare"); refreshRoom() }
    }

    /// Where the board you're on was entered from, for the "toward the middle" side.
    private var lastRoomTarget: CGRect?

    /// A room setting changed: redo the room on the board you're on, right away.
    private func refreshRoom() {
        guard !onSurface, !busy else { return }
        let d = current
        let rooms = d.panels().filter { $0.scratch == true && $0.windows.isEmpty && $0.desktop == nil }
        guard !rooms.isEmpty else { return }   // no room open here: the new shape applies next time
        for p in rooms { d.removeRoom(p) }
        placeRoom(on: d, entering: lastRoomTarget ?? screen.frame)
        applyLayout()
    }

    /// Breathing room only lives on the board you're on: anywhere else, an
    /// empty one folds away. One you've put something in becomes a normal panel.
    private func foldAwayRoom() {
        let here: UUID? = onSurface ? nil : current.id
        func walk(_ d: Desktop) {
            for p in d.panels() {
                // Filled: a normal panel, unless room panels stay inside. (Diving
                // into the room and leaving it empty doesn't count as filling it.)
                let filled = !p.windows.isEmpty || !(p.desktop?.allWindows().isEmpty ?? true)
                if p.scratch == true, filled, !roomInsideOnly { p.scratch = nil; p.roomFit = nil }
                if let nested = p.desktop { walk(nested) }
            }
            guard d.id != here else { return }
            for p in d.panels() where p.scratch == true && p.windows.isEmpty && p.desktop == nil {
                d.removeRoom(p)
            }
        }
        walk(state.root)
    }

    // MARK: The lobby, and stepping sideways

    /// Whether the room shows the lobby (doors, map, ↑) or stays plain empty space.
    var showLobby: Bool {
        get { UserDefaults.standard.bool(forKey: "showLobby") }
        set { UserDefaults.standard.set(newValue, forKey: "showLobby"); refreshLobby() }
    }

    func refreshLobby() {
        lobby.show(onSurface || !showLobby ? nil : lobbyModel())
    }

    /// Hyper + L: show or hide the lobby.
    func toggleLobby() {
        showLobby.toggle()
        Toast.show(showLobby ? "Lobby on" : "Lobby off — just space", seconds: 0.8)
    }

    /// The other boards on this level: the panels of the board above, in
    /// reading order (yours included).
    private func siblings() -> (parent: Desktop, parentPath: [UUID], panels: [Panel])? {
        guard !onSurface, !state.path.isEmpty else { return nil }
        let stack = desktopStack()
        guard stack.count >= 2 else { return nil }
        let parent = stack[stack.count - 2]
        let saved = viewingAs
        viewingAs = parent.id
        defer { viewingAs = saved }
        return (parent, Array(state.path.dropLast()), parent.panels().filter { !isHiddenRoom($0, of: parent) })
    }

    /// What the lobby shows, or nil when there's no empty room to show it in.
    private func lobbyModel() -> LobbyModel? {
        guard let sib = siblings(), let here = state.path.last else { return nil }
        // The room: the breathing-room panel, else any empty panel on this board.
        // Next to a quarter-screen room there can be a second open quarter;
        // the lobby goes there and the room stays clear, ready to dive into.
        let empty = frames(current, in: viewport)
            .filter { $0.depth == 0 && $0.panel.desktop == nil && $0.panel.windows.isEmpty }
        guard let room = empty.first(where: { $0.panel.scratch == true && $0.panel.roomFit == nil })
                ?? empty.first(where: { $0.panel.scratch == true }) ?? empty.first,
              room.rect.width >= 220, room.rect.height >= 260 else { return nil }

        func apps(of p: Panel) -> (names: [String], icons: [NSImage]) {
            var seen = Set<String>(), names: [String] = [], icons: [NSImage] = []
            for w in p.desktop?.allWindows() ?? p.windows {
                let n = windows.appName(w)
                guard seen.insert(n).inserted else { continue }
                names.append(n)
                if let i = windows.appIcon(w) { icons.append(i) }
            }
            return (names, icons)
        }
        let doors = sib.panels.map { p -> LobbyModel.Door in
            let a = apps(of: p)
            let title = p.name ?? "Pool \(p.number)"
            let list = a.names.isEmpty ? "Empty" : a.names.prefix(3).joined(separator: ", ")
                + (a.names.count > 3 ? " +\(a.names.count - 3)" : "")
            return LobbyModel.Door(id: p.id, title: title, apps: list, icons: a.icons, isHere: p.id == here)
        }
        // The little map: the board above as it looks there, scaled to 0–1.
        let v = viewport
        let cells = framesAsShown(sib.parent).filter { $0.depth == 0 }.map { placed -> LobbyModel.Cell in
            let r = placed.rect
            return LobbyModel.Cell(rect: CGRect(x: (r.minX - v.minX) / v.width, y: (r.minY - v.minY) / v.height,
                                                width: r.width / v.width, height: r.height / v.height),
                                   door: placed.panel.id, isHere: placed.panel.id == here,
                                   label: displayName(placed.panel))
        }
        return LobbyModel(rect: room.rect.insetBy(dx: gap / 2, dy: gap / 2),
                          upLabel: locationLabel(sib.parentPath), here: locationLabel(),
                          doors: doors, map: cells, mapAspect: v.height / v.width,
                          emptyBoard: current.allWindows().isEmpty && current.panels().count == 1)
    }

    /// A sideways trip, worked out before it happens, so it can be played
    /// (keys, a quick swipe) or steered (a slow swipe that follows your fingers).
    private struct Sideways {
        enum Kind {
            case glide(from: CGRect, to: CGRect, parentKey: String)   // to a neighbouring board
            case slide(direction: Int)                                // to another Main
        }
        let kind: Kind
        let toKey: String
        let change: () -> Void
    }

    /// Hyper + [ / ], or a sideways swipe: the previous / next board on this
    /// level. From Main: the Main beside it, or a new blank one.
    func stepSideways(_ direction: Int) {
        guard !onSurface, !busy, !overviewOpen, let s = sideways(direction) else { return }
        playSideways(s)
    }

    /// Glides across to a neighbouring board on the same level.
    func stepSideways(to id: UUID) {
        guard !busy, let s = siblingMove(to: id) else { return }
        playSideways(s)
    }

    private func sideways(_ direction: Int) -> Sideways? {
        if state.path.isEmpty { return mainMove(direction) }
        guard let sib = siblings(), let here = state.path.last, sib.panels.count > 1,
              let i = sib.panels.firstIndex(where: { $0.id == here }) else {
            Toast.show("Nothing beside this board", seconds: 1)
            return nil
        }
        let n = sib.panels.count
        return siblingMove(to: sib.panels[((i + direction) % n + n) % n].id)
    }

    private func siblingMove(to id: UUID) -> Sideways? {
        guard let sib = siblings(), let here = state.path.last, id != here,
              let target = sib.parent.panel(id: id), let fromPanel = sib.parent.panel(id: here) else { return nil }
        let placed = framesAsShown(sib.parent).filter { $0.depth == 0 }
        guard let a = placed.first(where: { $0.panel.id == here })?.rect,
              let b = placed.first(where: { $0.panel.id == id })?.rect else { return nil }
        let leaving = current
        let newPath = sib.parentPath + [id]
        return Sideways(kind: .glide(from: a, to: b, parentKey: placeKey(sib.parentPath)), toKey: placeKey(newPath)) {
            self.leaveSpotlight()
            self.makeBoard(of: target)
            self.state.path = newPath
            self.foldAwayRoom()                       // the room you left folds away
            self.collapseIfTrivial(leaving, into: fromPanel)
            self.addBreathingRoom(entering: b)
        }
    }

    /// From Main: the Main beside it, or past the last (or before the
    /// first) a fresh, blank one to work in.
    private func mainMove(_ direction: Int) -> Sideways? {
        let all = allMains
        let j = mainPosition + direction
        guard j >= 0, j < all.count else {
            // A blank Main you leave folds away, so another blank one would
            // just put you back where you are.
            if isBlank(state.root) {
                Toast.show("You're on a blank Main — put something here first", seconds: 1.2)
                return nil
            }
            return mainSwitch(to: nil, newAt: direction > 0 ? all.count : 0, direction: direction)
        }
        return mainSwitch(to: all[j].id, direction: direction)
    }

    /// Goes to another Main (or a new blank one, put in at `newAt`), landing
    /// on `landing` there. A blank Main you leave without using folds away.
    private func mainSwitch(to id: UUID?, newAt: Int? = nil, direction: Int, landing: [UUID] = []) -> Sideways {
        var fresh: Desktop?
        if newAt != nil {
            let d = Desktop.single()
            d.name = nextMainName()
            fresh = d
        }
        let targetID = fresh?.id ?? id ?? state.root.id
        return Sideways(kind: .slide(direction: direction), toKey: placeKey(landing, main: targetID)) {
            self.leaveSpotlight()
            var all = self.allMains
            let leaving = self.state.root
            if let fresh, let at = newAt { all.insert(fresh, at: min(at, all.count)) }
            if all.count > 1, leaving.id != targetID, self.isBlank(leaving) { all.removeAll { $0 === leaving } }
            guard let k = all.firstIndex(where: { $0.id == targetID }) else { return }
            self.setMains(all, current: k)
            self.state.path = self.isValid(landing) ? landing : []
            self.foldAwayRoom()
        }
    }

    private func playSideways(_ s: Sideways, then next: (() -> Void)? = nil) {
        busy = true
        quietReveal()
        windows.refresh()
        captureManualMoves()
        let fromKey = hereKey
        Task { @MainActor in
            switch s.kind {
            case .glide(let a, let b, let parentKey):
                await animator.glide(on: screen, from: a, to: b, parentKey: parentKey, fromKey: fromKey,
                                     toKey: s.toKey, change: s.change, layout: { self.applyLayout() })
            case .slide(let direction):
                await animator.slide(on: screen, direction: direction, fromKey: fromKey, toKey: s.toKey,
                                     change: s.change, layout: { self.applyLayout() })
            }
            busy = false
            if let next { next() } else { Toast.show(locationLabel(), seconds: 0.7) }
        }
    }

    // MARK: Sideways swipes follow your fingers

    private var sideSteering: Sideways?

    /// Starts a sideways swipe that follows your fingers: a slow swipe shows
    /// the next board sliding in, and letting go early floats back. False
    /// when there's nowhere to go that way.
    func sideScrubBegin(_ direction: Int) -> Bool {
        guard !onSurface, !busy, !overviewOpen, AXIsProcessTrusted(), let s = sideways(direction) else { return false }
        busy = true
        quietReveal()
        windows.refresh()
        captureManualMoves()
        sideSteering = s
        switch s.kind {
        case .glide(let a, let b, let parentKey):
            animator.beginGlideScrub(on: screen, from: a, to: b, parentKey: parentKey, fromKey: hereKey, toKey: s.toKey)
        case .slide(let direction):
            animator.beginSlideScrub(on: screen, direction: direction, fromKey: hereKey, toKey: s.toKey)
        }
        return true
    }

    /// 0 = where you started, 1 = all the way across.
    func sideScrubUpdate(_ progress: CGFloat) {
        guard sideSteering != nil else { return }
        animator.updateSideScrub(progress)
    }

    /// Let go: finish going across, or float back.
    func sideScrubEnd(commit: Bool) {
        guard let s = sideSteering else { return }
        sideSteering = nil
        Task { @MainActor in
            let moved = await animator.endSideScrub(commit: commit, change: s.change, layout: { self.applyLayout() })
            busy = false
            if moved { Toast.show(locationLabel(), seconds: 0.7) }
        }
    }

    // MARK: Crowded panels become app icons

    var crowdIcons: Bool {
        get { UserDefaults.standard.bool(forKey: "crowdIcons") }
        set { UserDefaults.standard.set(newValue, forKey: "crowdIcons"); applyLayout() }
    }

    private func crowdTile(for placed: Placed, in target: CGRect) -> CrowdTile? {
        let p = placed.panel
        let list = shownWindows(p, of: placed.owner)
        let frost = crowdIcons && !list.isEmpty && p.free != true && wantsFrost(placed, list, target)
        // Frosted stays frosted, at this size, until you make the spot bigger.
        stickyFrost[p.id] = frost ? target.size : nil
        guard frost,
              spotlit.map({ !list.contains($0) }) ?? true,
              // The window in your hand frosts when you let go, not under your fingers.
              edgeWindow.map({ !list.contains($0) }) ?? true else { return nil }
        // The main app: a filled window if there is one, else the biggest float.
        let main = list.first { p.floatRect($0) == nil }
            ?? list.max { a, b in
                let ra = p.floatRect(a) ?? .zero, rb = p.floatRect(b) ?? .zero
                return ra.width * ra.height < rb.width * rb.height
            }
        guard let w = main else { return nil }
        var tile = CrowdTile(rect: target, icon: windows.appIcon(w), name: windows.appName(w),
                             extra: tabMembers(p, of: placed.owner).count - 1, panel: p.id,
                             owner: placed.owner.id, window: w)
        // The window itself, shrunk and frosted, once there's a picture of it.
        if CGPreflightScreenCaptureAccess() {
            tile.shrunk = true
            tile.picture = portholePictures[w]?.image
        }
        return tile
    }

    /// Whether a whole pool frosts over as one tile. A tiny pool always does.
    /// On a nested board seen from above, an app that won't shrink that far
    /// becomes a porthole of its own (or stays live, if its pool is big on its
    /// own board) and the pool's other windows stay live, so one big app
    /// (Music) doesn't frost everything beside it.
    /// Pools frosted over, and the size of their spot when they were: they
    /// stay frosted until the spot gets bigger than that (you widen it with
    /// the pill or an edge, or swipe it up). Zooming in and back out, or a
    /// quiet check that an app would squeeze in after all, doesn't bring
    /// them back: some apps (Discord, Electron apps) take a size they can't
    /// really show.
    private var stickyFrost: [UUID: CGSize] = [:]

    private func wantsFrost(_ placed: Placed, _ list: [UInt32], _ target: CGRect) -> Bool {
        if handFrost.contains(placed.panel.id) { return true }
        if frostsWhole(placed, list, target) { return true }
        guard let was = stickyFrost[placed.panel.id] else { return false }
        return target.width <= was.width + 8 && target.height <= was.height + 8
    }

    private func frostsWhole(_ placed: Placed, _ list: [UInt32], _ target: CGRect) -> Bool {
        if target.width < Self.usableWidth || target.height < Self.usableHeight { return true }
        // Seen from above, a big app goes live on its own (a big pool on its own
        // board) or becomes a porthole, never taking the whole pool with it.
        if placed.depth >= 1 { return false }
        return tooSmall(list, for: target)
    }

    /// When a window's spot is too small for it to be of use, so it frosts
    /// over: smaller than the app will go (once Scuba has seen how small
    /// that is), or simply tiny. Until then it stays live and just shrinks.
    /// Frosting means the app can't be used in that spot: the spot is tiny,
    /// or the app won't fit inside it. Windows respect their tile's edges:
    /// one that would spill past them frosts instead.
    private func tooSmall(_ list: [UInt32], for spot: CGRect) -> Bool {
        if spot.width < 220 || spot.height < 150 { return true }
        return list.contains { w in
            guard let m = windows.minSize(w) else { return false }
            return m.width > spot.width + 6 || m.height > spot.height + 6
        }
    }

    /// Frosted because of the smallest size on record for it, though the spot
    /// itself is roomy (a tiny spot frosts whatever's in it).
    private func outgrows(_ w: UInt32, _ spot: CGRect) -> Bool {
        guard spot.width >= 220, spot.height >= 150, let m = windows.minSize(w) else { return false }
        return m.width > spot.width + 6 || m.height > spot.height + 6
    }

    /// The spot size each frosted window was last checked at (one check per
    /// size, so a window that really won't fit isn't asked over and over).
    private var frostChecked: [UInt32: CGSize] = [:]

    /// Windows frosted over because of a size on record get a quiet check:
    /// tucked away, asked to take the spot. If they take it, the size on
    /// record was wrong and they come back live.
    private func checkFrost(_ spots: [UInt32: CGSize]) {
        for (w, size) in spots {
            if let last = frostChecked[w], abs(last.width - size.width) < 4, abs(last.height - size.height) < 4 {
                continue
            }
            frostChecked[w] = size
            windows.probeMinSize(w, to: size) { [weak self] changed in
                guard changed else { return }
                Task { @MainActor in self?.frostRechecked() }
            }
        }
    }

    private func frostRechecked() {
        // Otherwise the next layout picks it up.
        guard !busy, !onSurface, !gliding, edgeWindow == nil, !stage.isActive,
              NSEvent.pressedMouseButtons == 0 else { return }
        glideLayout()
    }

    /// Clicking an app-icon tile dives straight into that panel.
    /// The X on a frosted window: closes it, the way its own close button
    /// does. It's tucked out of sight, so if its app asks something first
    /// (save changes?), it comes forward in Spotlight to answer.
    func closeTile(_ t: CrowdTile) {
        guard t.window != 0 else { return }
        closeWindowHere(t.window)
    }

    func openTile(_ t: CrowdTile) {
        if !t.shelfPanels.isEmpty {
            openShelf(t)
            return
        }
        guard !busy, !onSurface, let ownerPath = boardPaths()[t.owner] else { return }
        if t.porthole || t.jumpOnly {
            jump(to: ownerPath, panel: t.panel, window: t.window)
            return
        }
        var found: Panel?
        forEachPanel(state.root) { if $0.id == t.panel { found = $0 } }
        guard let p = found else { return }
        makeBoard(of: p)
        state.lastPanelId = nil
        jump(to: ownerPath + [p.id], panel: nil, window: t.window)
    }

    // MARK: Live preview while dragging

    /// Where each window we've nudged for a preview was before, to put back.
    private var previewOriginals: [UInt32: CGRect] = [:]
    private var previewKey = ""
    private var lastPreview = Date.distantPast

    /// While you drag a window over a panel, the panel's own windows move out
    /// of the way to show where it'll land: filled windows make room beside
    /// it, and on an edge bar they slide into the half they'll keep.
    func previewDrop(_ dragged: UInt32, target: DropTarget?, leaving: Bool = false) {
        guard !onSurface else { return }
        var moves: [(UInt32, CGRect)] = []
        var key = ""
        // The pool it's leaving closes up behind it as soon as it's away.
        if leaving, target?.preview == nil {
            let behind = absenceMoves(of: dragged, unless: target)
            moves += behind
            if !behind.isEmpty { key = "away-" }
        }
        if let t = target, let plan = t.preview {
            // Worked out on a copy of the board: every window that's in view
            // goes where it'll be after the drop.
            for (w, r) in plan where w != dragged && liveIn[w] != nil && !portholed.contains(w)
                && !windows.parked.contains(w) {
                moves.append((w, r))
            }
            key = "plan-\(t.panel.id)-\(t.label)-\(Int(t.highlight.minX))-\(Int(t.highlight.minY))-\(Int(t.highlight.width))-\(Int(t.highlight.height))"
        } else if let t = target {
            let p = t.panel
            let inner = t.panelRect.insetBy(dx: gap / 2, dy: gap / 2)
            let others = p.windows.filter { $0 != dragged && !windows.parked.contains($0) && !docked.contains($0) }
            switch t.action {
            case .float:
                // Where the dragged window is now, in screen coordinates.
                if makeRoom, let b = windows.bounds(of: dragged) {
                    let h = NSScreen.screens.first?.frame.height ?? 0
                    let now = CGRect(x: b.minX, y: h - b.maxY, width: b.width, height: b.height).intersection(inner)
                    if !now.isNull {
                        let fill = fillRect(for: p, in: inner, extra: [now], excluding: dragged)
                        for w in others where p.floatRect(w) == nil { moves.append((w, fill)) }
                        // Snap to a coarse grid, so tiny wiggles don't resize apps over and over.
                        key += "\(p.id)-f-\(Int(fill.minX / 24))-\(Int(fill.minY / 24))-\(Int(fill.width / 24))-\(Int(fill.height / 24))"
                    }
                }
            case .newPanel:
                if let keep = t.remaining?.insetBy(dx: gap / 2, dy: gap / 2) {
                    for w in others {
                        if let rel = p.floatRect(w) { moves.append((w, absolute(rel, in: keep))) }
                        else { moves.append((w, fillRect(for: p, in: keep, excluding: dragged))) }
                    }
                    key += "\(p.id)-n-\(t.label)-\(keep.minX)-\(keep.minY)"
                }
            case .fill:
                key += "\(p.id)-fill"
            case .dock(let rel, let partner, let partnerRel):
                // The window it docks beside slides into its half, and the
                // rest of the pool makes room for both.
                guard let placed = dropPanels().first(where: { $0.panel.id == p.id }) else { break }
                let changes = liveIn[dragged] == p.id
                    ? closingChanges(dragged, in: p, owner: t.owner, inner: inner) : [:]
                var all = changes
                all[partner] = partnerRel
                moves += planned(placed, without: dragged, changes: all, extra: [absolute(rel, in: inner)])
                    .map { ($0.window, $0.rect) }
                key += "\(p.id)-d-\(partner)-\(Int(rel.minX * 100))-\(Int(rel.minY * 100))-\(Int(rel.width * 100))-\(Int(rel.height * 100))"
            case .tile, .edge, .desktop, .tab, .peer:
                // Always come with a worked-out preview (above).
                break
            }
        }
        if key.isEmpty { key = "none" }
        guard key != previewKey else { return }
        // Moving windows is slow for some apps: at most about 12 times a second.
        let now = Date()
        guard now.timeIntervalSince(lastPreview) > 0.08 || moves.isEmpty else { return }
        lastPreview = now
        previewKey = key

        // Put back anything nudged earlier that this preview doesn't move.
        let moving = Set(moves.map { $0.0 })
        for (w, f) in previewOriginals where !moving.contains(w) {
            windows.setFrame(w, f)
            previewOriginals[w] = nil
        }
        for (w, f) in moves {
            if previewOriginals[w] == nil, let orig = windows.frame(of: w) { previewOriginals[w] = orig }
            windows.setFrame(w, f)
        }
    }

    /// The drag is over. Dropped: the drop's own layout takes it from here.
    /// Cancelled: everything nudged goes back where it was.
    func endPreview(restore: Bool) {
        if restore {
            for (w, f) in previewOriginals { windows.setFrame(w, f) }
        }
        previewOriginals.removeAll()
        previewKey = ""
    }

    // MARK: Spotlight

    private var spotlightRect: CGRect {
        let v = viewport
        return v.insetBy(dx: v.width * 0.06, dy: v.height * 0.06)
    }

    /// True for a window showing on the board you're on (nested boards included).
    func isOnScreenBoardWindow(_ w: UInt32) -> Bool {
        guard !onSurface else { return false }
        return frames(current, in: viewport).contains { $0.panel.desktop == nil && $0.panel.windows.contains(w) }
    }

    /// Blows a window up over the board so you can work in it. Doing it
    /// again on the same window puts it back in its panel.
    func spotlight(_ w: UInt32) {
        guard !busy, isOnScreenBoardWindow(w) else { return }
        if spotlit == w {
            endSpotlight()
            return
        }
        windows.refresh()
        captureManualMoves()
        spotlit = w
        // Let the window be seen: drop the Hyper outlines.
        if revealing {
            revealing = false
            numbers.hide()
        }
        applyLayout()
        windows.focus(w)
    }

    func endSpotlight() {
        guard let w = spotlit else { return }
        spotlit = nil
        applyLayout()
        windows.focus(w)
    }

    /// Hyper + D: sends the window in Spotlight (or else the one you're
    /// using) to your normal desktop. It leaves your boards and steps aside
    /// with the rest of your desktop; Hyper + Esc and it's there, in the
    /// middle of the screen.
    func sendToDesktop() {
        if onSurface { chooseDestinationPool(); return }
        guard !busy else { return }
        guard let w = spotlit ?? windows.focusedWindowID(), everyWindow().contains(w) else {
            Toast.show("Spotlight a window (or click one) first")
            return
        }
        checkpoint()
        moveToDesktop(w)
        glideLayout()
        Toast.show("Sent \(windows.appName(w)) to your desktop  ·  \(CapsKey.label) + Esc to see it", seconds: 1.6)
    }

    /// Takes a window off your boards and puts it on your normal desktop,
    /// in the middle of the screen (the layout that follows tucks it away
    /// with the rest of your desktop while you're inside).
    private func moveToDesktop(_ w: UInt32) {
        if spotlit == w { spotlit = nil }
        if newInSpotlight == w { newInSpotlight = nil }
        if let h = held, h.window == w {
            held = nil
            chip.hide()
        }
        remove(window: w)
        let vf = screen.visibleFrame
        let size = windows.frame(of: w)?.size ?? CGSize(width: vf.width * 0.6, height: vf.height * 0.6)
        let fit = CGSize(width: min(size.width, vf.width * 0.7), height: min(size.height, vf.height * 0.7))
        surfaceFrames[w] = CGRect(x: vf.midX - fit.width / 2, y: vf.midY - fit.height / 2,
                                  width: fit.width, height: fit.height)
    }

    /// A new window that opened in Spotlight because every pool was in use,
    /// and when. If it isn't placed (dragged onto a pool, or floated with
    /// Hyper + Return) before you move on, it goes to your desktop.
    private var newInSpotlight: UInt32?
    private var newSpotlightAt = Date.distantPast

    /// Spotlight ends because you're going somewhere: a new window you never
    /// placed goes to your desktop.
    private func leaveSpotlight() {
        if let n = newInSpotlight, spotlit == n { moveToDesktop(n) }
        newInSpotlight = nil
        spotlit = nil
    }

    /// Once a second: a new window waiting in Spotlight that you've moved
    /// on from (you're using another window) goes to your desktop.
    private func settleNewSpotlight() -> Bool {
        guard let n = newInSpotlight else { return false }
        guard spotlit == n, windows.exists(n) else {
            newInSpotlight = nil
            return false
        }
        guard Date().timeIntervalSince(newSpotlightAt) > 1.5,
              let f = windows.focusedWindowID(), f != n else { return false }
        let name = windows.appName(n)
        checkpoint()
        moveToDesktop(n)
        glideLayout()
        Toast.show("\(name) went to your desktop  ·  \(CapsKey.label) + Esc to see it", seconds: 1.4)
        return true
    }

    // MARK: From your desktop into a pool

    /// Hyper + D on your desktop: pick a pool (named ones first) to send the
    /// window you're using to. It fits in as best it can and is hidden from
    /// the view above, so the board looks the same from outside.
    func chooseDestinationPool() {
        guard onSurface, !busy, AXIsProcessTrusted() else { return }
        windows.refresh()
        guard let w = windows.focusedWindowID(), windows.isStandard(w), isOnMyScreen(w), !belongsElsewhere(w) else {
            Toast.show("Click the window you want to send first")
            return
        }
        let name = windows.appName(w)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: "Send \(name) to…", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        var named: [(title: String, main: UUID, pool: UUID)] = []
        var byMain: [(title: String, pools: [(title: String, main: UUID, pool: UUID)])] = []
        for d in allMains {
            var list: [(title: String, main: UUID, pool: UUID)] = []
            for placed in frames(d, in: viewport) where placed.panel.desktop == nil {
                let entry = (title: "\(mainName(d)) › \(placed.label)", main: d.id, pool: placed.panel.id)
                list.append(entry)
                if placed.panel.name != nil { named.append(entry) }
            }
            byMain.append((title: mainName(d), pools: list))
        }
        for e in named {
            menu.addItem(ActionItem("   " + e.title) { [weak self] in self?.send(w, toPool: e.pool, on: e.main) })
        }
        if !named.isEmpty { menu.addItem(.separator()) }
        for group in byMain where !group.pools.isEmpty {
            let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for e in group.pools {
                sub.addItem(ActionItem(e.title) { [weak self] in self?.send(w, toPool: e.pool, on: e.main) })
            }
            item.submenu = sub
            menu.addItem(item)
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Puts a window from your desktop into a pool: the whole pool if it's
    /// empty, otherwise the half that makes room. It's hidden from the view
    /// above (Hyper + P to show it there).
    private func send(_ w: UInt32, toPool pool: UUID, on mainID: UUID) {
        guard windows.exists(w), let d = allMains.first(where: { $0.id == mainID }),
              let placed = frames(d, in: viewport).first(where: { $0.panel.id == pool && $0.panel.desktop == nil })
        else { return }
        checkpoint()
        surfaceFrames[w] = nil
        ignored.remove(w)
        remove(window: w)
        let r = placed.rect
        landInHalf(w, of: placed, at: CGPoint(x: r.midX + r.width / 4, y: r.midY - r.height / 4))
        var marked = state.insideOnly ?? []
        if !marked.contains(w) { marked.append(w) }
        state.insideOnly = marked
        saveState()
        applyLayout()   // on your desktop: it steps aside with your boards
        Toast.show("Sent \(windows.appName(w)) to \(mainName(d)) › \(placed.label)  ·  hidden from the view above",
                   seconds: 1.6)
    }

    /// A three-finger tap or click: Spotlight the window (or the porthole's
    /// window) under the pointer, or put it back. `point` is AppKit screen
    /// coordinates.
    func spotlightAt(_ point: CGPoint) {
        guard !onSurface, !busy, !overviewOpen, AXIsProcessTrusted() else { return }
        if let w = portholeWindow(at: point) {
            spotlight(w)
            return
        }
        let top = NSScreen.screens.first?.frame.height ?? 0
        windows.refresh()
        guard let hit = windows.windowAt(CGPoint(x: point.x, y: top - point.y)),
              isOnScreenBoardWindow(hit.id) else { return }
        spotlight(hit.id)
    }

    /// Hyper + Return: Spotlight the window you're using, or put it back.
    func toggleSpotlightFocused() {
        if spotlit != nil {
            newInSpotlight = nil   // floated on purpose: it stays
            endSpotlight()
            return
        }
        guard let w = windows.focusedWindowID(), isOnScreenBoardWindow(w) else {
            Toast.show("Click a window on this board first")
            return
        }
        spotlight(w)
    }

    private func finishLayout() {
        updateAppVisibility()
        quietUntil = Date().addingTimeInterval(1.0)
        animator.forgetEarlyPicture()   // the screen just changed
        noteSettledFrames()
        showBounds()
        saveState()
        backdrop.update(depth: depth, on: screen, custom: currentWallpaper)
        shade.update(depth: depth, on: screen)
        refreshLobby()
        if revealing { showNumbers(persistent: true) }
        onLocationChange?()
    }

    func showNumbers(persistent: Bool = false) {
        guard !onSurface else { return }
        let active = activePanel().id
        // Where you are, as panel names: inside panel 3 the panels read "3 › 1", "3 › 2".
        let prefix = breadcrumb().components(separatedBy: " › ").dropFirst()
        // Only the panels of the board on screen; boards nested inside them
        // show as one panel with a summary of their apps, not a breakdown.
        let marks = frames(current, in: viewport).filter { $0.depth == 0 }.map { placed -> PanelMark in
            let p = placed.panel
            let apps: String
            if let nested = p.desktop {
                var seen = Set<String>()
                let names = nested.allWindows().map { windows.appName($0) }.filter { seen.insert($0).inserted }
                apps = names.isEmpty ? "empty board"
                    : names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " +\(names.count - 4)" : "")
            } else {
                let names = p.windows.map { windows.appName($0) }
                apps = names.isEmpty ? "empty · \(CapsKey.label) + scroll here to dive in" : names.joined(separator: ", ")
            }
            let label = (prefix + [displayName(p)]).joined(separator: " › ")
            return PanelMark(rect: placed.rect, label: label, apps: apps,
                             nested: false, active: p.id == active, container: false)
        }
        let title = locationLabel() + (isHome ? "   ·   ⌂ Home" : "")
        numbers.show(marks, title: title, on: screen, seconds: (persistent || revealing) ? nil : 1.3)
    }

    // MARK: Windows

    func placeFocused(inPanel number: Int) {
        guard let w = windows.focusedWindowID() else { Toast.show("No focused window"); return }
        guard let p = current.panel(number: number) else { Toast.show("There's no pool \(number) here"); return }
        put(w, in: p)
        windows.focus(w)
        Toast.show("\(windows.appName(w)) → pool \(number)")
    }

    func put(_ w: UInt32, in p: Panel) {
        let target = p.desktop?.landingPanel() ?? p
        // Already there on its own: nothing to change.
        if target.windows == [w] {
            glideLayout()
            return
        }
        checkpoint()
        // Where it'll go, worked out before it leaves its own pool.
        let placed = dropPanels().first { $0.panel.id == target.id }
        removeLive(w)   // also clears floating: a placed window fills its panel
        if let placed, target.free == true || (tileWindows && !target.windows.isEmpty) {
            // The Desktop: it floats. A pool in use: it splits, and the window
            // takes the right (or bottom) half as a tile of its own.
            let r = placed.rect
            landInHalf(w, of: placed, at: CGPoint(x: r.maxX - 1, y: r.minY + 1))
        } else {
            target.windows.append(w)
        }
        state.lastPanelId = p.id
        glideLayout()
    }

    // MARK: Apps left alone

    /// Leaves an app alone: its windows come off your boards, back into
    /// view, and from now on float freely, never arranged.
    func leaveAlone(_ app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier else { return }
        checkpoint()
        let pid = app.processIdentifier
        for w in windows.allIDs() where windows.pid(of: w) == pid {
            if spotlit == w { spotlit = nil }
            remove(window: w)
            windows.letGo(w, on: screen)
        }
        WindowManager.leftAlone.insert(bid)
        applyLayout()
        Toast.show("\(app.localizedName ?? "That app") is left alone — its windows float freely", seconds: 1.5)
    }

    /// Arranges an app's windows again (new ones join the board you're on).
    func stopLeavingAlone(_ bundleID: String) {
        WindowManager.leftAlone.remove(bundleID)
        applyLayout()
    }

    func releaseFocused() {
        guard let w = windows.focusedWindowID() else { Toast.show("No focused window"); return }
        checkpoint()
        if held?.window == w { held = nil; chip.hide() }
        remove(window: w)
        ignored.insert(w)
        saveState()
        Toast.show("Released \(windows.appName(w))")
    }

    // MARK: Cut, copy and paste

    enum HoldKind { case cut, copy }
    /// The window you cut or copied, waiting to be put down (one at a time).
    private(set) var held: (window: UInt32, kind: HoldKind, from: UUID)?
    /// The rest of a tabbed tile's tabs, held along with the window you cut
    /// or copied: they go together.
    private var heldTabs: [UInt32] = []
    let chip = HeldChip()

    /// Hyper + X: cuts the window you're using. Its pool carries on without
    /// it and a chip shows you're holding it; go anywhere and Hyper + V puts
    /// it down. Hyper + X on it again, or a click on the chip, puts it back.
    func cutFocused() { hold(.cut) }

    /// Hyper + C: copies the window you're using. Pasted, the same window is
    /// in both pools: live in one, a porthole in the other.
    func copyFocused() { hold(.copy) }

    private func hold(_ kind: HoldKind) {
        guard !onSurface, !busy else { return }
        guard let w = windows.focusedWindowID(), let from = liveIn[w] ?? chain(for: w)?.last?.id else {
            Toast.show("Click a window on a board first")
            return
        }
        if let h = held, h.window == w, h.kind == kind {
            putBack()
            return
        }
        if kind == .cut, lockRefuses(w) { return }
        // A tab takes its whole tile of tabs with it.
        if let p = chain(for: w)?.last, p.tabs == true, p.windows.count > 1 {
            heldTabs = p.windows.filter { $0 != w && windows.exists($0) }
        } else {
            heldTabs = []
        }
        // One at a time: whatever you were holding goes back first.
        let wasCut = held?.kind == .cut
        held = (w, kind, from)
        if spotlit == w { spotlit = nil }
        let name = windows.appName(w) + (heldTabs.isEmpty ? "" : " + \(heldTabs.count) tab\(heldTabs.count == 1 ? "" : "s")")
        chip.onClick = { [weak self] in self?.putBack() }
        chip.show(icon: windows.appIcon(w), title: kind == .cut ? "Cut: \(name)" : "Copied: \(name)",
                  hint: kind == .cut ? "\(CapsKey.label) + V puts it down · click to put it back"
                                     : "\(CapsKey.label) + V pastes a copy · click to cancel",
                  on: screen)
        if kind == .cut || wasCut { glideLayout() }
    }

    /// Lets go of what you're holding: a cut window goes back where it was.
    func putBack() {
        guard let h = held else { return }
        held = nil
        chip.hide()
        if h.kind == .cut {
            glideLayout()
            Toast.show("\(windows.appName(h.window)) is back", seconds: 0.8)
        }
    }

    /// Hyper + V: puts what you're holding into the pool under the pointer
    /// (on any board, any Main). An empty pool takes it whole; in one that's
    /// in use, it takes the half the pointer is in.
    func paste() {
        guard !onSurface, !busy else { return }
        guard let h = held else {
            Toast.show("Nothing to paste — \(CapsKey.label) + X cuts a window, \(CapsKey.label) + C copies one", seconds: 1.4)
            return
        }
        guard windows.exists(h.window) else {
            held = nil
            chip.hide()
            Toast.show("That window has closed")
            return
        }
        let point = NSEvent.mouseLocation
        let pools = dropPanels()
        let active = activePanel().id
        guard let target = pools.filter({ $0.rect.contains(point) }).max(by: { $0.depth < $1.depth })
                ?? pools.first(where: { $0.panel.id == active }) ?? pools.first else { return }
        let w = h.window
        let name = windows.appName(w)
        if target.panel.windows.contains(w) {
            if h.kind == .cut { putBack() } else { Toast.show("\(name) is already in this pool") }
            return
        }
        if (state.lockedBoards ?? []).contains(target.owner.id) {
            Toast.show("Placements are locked there  ·  \(CapsKey.label) + P unlocks", seconds: 1.2)
            return
        }
        checkpoint()
        let tabs = heldTabs.filter { windows.exists($0) }
        held = nil
        heldTabs = []
        chip.hide()
        if h.kind == .cut {
            removeMembership(w, from: h.from)
            for t in tabs { removeMembership(t, from: h.from) }
        }
        landInHalf(w, of: target, at: point)
        // Its tabs come along: the tile it landed in is tabbed again, it in front.
        if !tabs.isEmpty, let landed = target.owner.deepFind(window: w)?.panel {
            for t in tabs where !landed.windows.contains(t) {
                landed.windows.insert(t, at: max(0, landed.windows.count - 1))
                lastApplied[t] = nil
            }
            landed.tabs = true
            landed.front = w
        }
        if target.depth >= 1, portholes { probing.insert(w) }
        state.lastPanelId = target.panel.id
        glideLayout()
        windows.focus(w)
        let what = tabs.isEmpty ? name : "\(name) + \(tabs.count) tab\(tabs.count == 1 ? "" : "s")"
        Toast.show(h.kind == .cut ? "\(what) → pool \(target.label)" : "\(what) in pool \(target.label) too", seconds: 1)
    }

    /// Takes a window out of one pool (on any Main).
    private func removeMembership(_ w: UInt32, from id: UUID) {
        var removed = false
        for main in allMains {
            forEachPanel(main) { p in
                guard p.id == id, p.windows.contains(w) else { return }
                self.fillVacancy(left: w, in: p)
                p.windows.removeAll { $0 == w }
                p.setFloat(w, nil)
                if p.windows.isEmpty { self.vacated.insert(p.id) }
                removed = true
            }
        }
        if !removed { remove(window: w) }
        lastApplied[w] = nil
    }

    /// Takes a window out of the pool it's live in before it goes somewhere
    /// else. A window with copies keeps its other pools.
    private func removeLive(_ w: UInt32, reflow: Bool = true) {
        if held?.window == w {
            held = nil
            chip.hide()
        }
        var holders = 0
        for main in allMains { forEachPanel(main) { if $0.windows.contains(w) { holders += 1 } } }
        if holders > 1, let id = liveIn[w] ?? chain(for: w)?.last?.id {
            removeMembership(w, from: id)
        } else {
            remove(window: w, reflow: reflow)
        }
    }

    /// A pool on the Main you're on, by id.
    private func panelHere(_ id: UUID) -> Panel? {
        var found: Panel?
        forEachPanel(state.root) { if $0.id == id { found = $0 } }
        return found
    }

    // MARK: Panels

    func addPanel(_ axis: Axis, nextTo target: Panel? = nil) {
        let anchor = target ?? activePanel()
        checkpoint()
        let fresh = current.addPanel(nextTo: anchor, axis: axis)
        state.lastPanelId = fresh.id
        glideLayout()
        showNumbers()
    }

    func deletePanel(_ target: Panel? = nil) {
        let doomed = target ?? activePanel()
        guard doomed.free != true else {
            Toast.show("The Desktop stays — dock windows around it")
            return
        }
        checkpoint()
        let orphans = doomed.windows + (doomed.desktop?.allWindows() ?? [])
        guard let heir = current.removePanel(doomed) else {
            Toast.show("Can't delete the only pool")
            return
        }
        (heir.desktop?.landingPanel() ?? heir).windows += orphans
        if state.lastPanelId == doomed.id { state.lastPanelId = heir.id }
        if let home = state.home, home.contains(doomed.id) { state.home = nil }
        glideLayout()
        showNumbers()
    }

    /// Hyper + Shift + Delete: deletes every empty pool on the board you're
    /// on (nothing in it, not even a board with windows), and the pools left
    /// share the space. Hyper + Z brings them back.
    func deleteEmptyPools() {
        guard !onSurface, !busy else { return }
        let d = current
        func unused(_ p: Panel) -> Bool {
            p.free != true && p.windows.isEmpty && (p.desktop?.allWindows().isEmpty ?? true)
        }
        var doomed = d.panels().filter(unused)
        // A board always keeps at least one pool.
        if doomed.count == d.panels().count { doomed.removeFirst() }
        guard !doomed.isEmpty else {
            Toast.show("No empty pools here", seconds: 0.9)
            return
        }
        checkpoint()
        for p in doomed {
            _ = d.removePanel(p)
            if state.lastPanelId == p.id { state.lastPanelId = nil }
            if let home = state.home, home.contains(p.id) { state.home = nil }
        }
        selection = nil
        glideLayout()
        Toast.show(doomed.count == 1 ? "Deleted 1 empty pool" : "Deleted \(doomed.count) empty pools", seconds: 1)
    }

    func flip(_ target: Panel? = nil) {
        checkpoint()
        guard let axis = current.flip(target ?? activePanel()) else {
            Toast.show("Only one pool here, nothing to flip")
            return
        }
        glideLayout()
        Toast.show(axis == .v ? "Stacked (top / bottom)" : "Side by side")
    }

    func grow(_ dir: Desktop.Direction) {
        checkpoint()
        if current.grow(activePanel(), toward: dir) { applyLayout() }
    }

    func shrink(_ dir: Desktop.Direction) {
        if current.shrink(activePanel(), from: dir) { applyLayout() }
    }

    // MARK: Locks (Hyper + P: placements on this board · Hyper + L: a window)

    /// The board on screen has its placements locked.
    var placementsLocked: Bool { !onSurface && (state.lockedBoards ?? []).contains(current.id) }

    func isLocked(_ w: UInt32) -> Bool { (state.lockedWindows ?? []).contains(w) }

    /// A tile (or group) holding a window locked in place: its size stays.
    private func holdsLocked(_ n: Node) -> Bool {
        guard let locked = state.lockedWindows, !locked.isEmpty else { return false }
        return panelsIn(n).contains { p in p.windows.contains { locked.contains($0) } }
    }

    /// True (with a word about why) when a lock keeps this from happening.
    private func lockRefuses(_ w: UInt32? = nil) -> Bool {
        if placementsLocked {
            Toast.show("Placements are locked here  ·  \(CapsKey.label) + P unlocks", seconds: 1.2)
            return true
        }
        if let w, isLocked(w) {
            Toast.show("\(windows.appName(w)) is locked in place  ·  \(CapsKey.label) + L unlocks", seconds: 1.2)
            return true
        }
        return false
    }

    // MARK: Outside windows

    /// Hyper + P on an outside window: it joins the board where it is, as a
    /// tab of the tile under it (on the Desktop, it floats there; in an empty
    /// pool, it fills it). Locked or not, nothing else moves.
    private func punchIn(_ w: UInt32) {
        guard let f = windows.frame(of: w) else { return }
        let center = CGPoint(x: f.midX, y: f.midY)
        guard let under = frames(current, in: viewport)
            .filter({ $0.depth == 0 && $0.panel.desktop == nil && $0.rect.contains(center) })
            .first else {
            Toast.show("Move it over a tile first, then \(CapsKey.label) + P", seconds: 1.2)
            return
        }
        checkpoint()   // Hyper + Z puts it back outside
        removeFloater(w)
        let p = under.panel
        if p.free == true {
            if !p.windows.contains(w) { p.windows.append(w) }
            p.setFloat(w, relative(f, in: under.rect.insetBy(dx: gap / 2, dy: gap / 2)))
        } else if p.windows.isEmpty {
            p.windows = [w]
            p.free = nil
        } else {
            makeTab(w, in: p)
        }
        state.lastPanelId = p.id
        lastApplied[w] = nil
        glideLayout()
        windows.focus(w)
        Toast.show("\(windows.appName(w)) is in  ·  \(p.free == true ? "on the Desktop" : "a tab of this tile")", seconds: 1.2)
    }

    /// Every outside window, on any board.
    private var allFloaters: Set<UInt32> { Set((state.floaters ?? [:]).values.flatMap { $0 }) }

    func isFloater(_ w: UInt32) -> Bool { (state.floaters ?? [:]).values.contains { $0.contains(w) } }

    /// Where each outside window was when it was tucked away, to come back to.
    private var floatFrames: [UInt32: CGRect] = [:]

    private func addFloater(_ w: UInt32, to board: UUID) {
        var all = state.floaters ?? [:]
        all[board.uuidString, default: []].append(w)
        state.floaters = all
    }

    private func removeFloater(_ w: UInt32) {
        guard var all = state.floaters else { return }
        for (k, v) in all { all[k] = v.filter { $0 != w } }
        all = all.filter { !$0.value.isEmpty }
        state.floaters = all.isEmpty ? nil : all
        floatFrames[w] = nil
    }

    /// Outside windows float on top of their own board, right where you put
    /// them, and tuck away (remembering where they were) whenever you're
    /// anywhere else, your normal desktop included.
    private func tendFloaters() {
        guard var all = state.floaters else { return }
        let here = onSurface ? nil : current.id.uuidString
        for (board, list) in all {
            let alive = list.filter { windows.exists($0) }
            all[board] = alive.isEmpty ? nil : alive
            for w in alive {
                if board == here {
                    if windows.parked.contains(w) {
                        windows.setFrame(w, floatFrames[w] ?? screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.2,
                                                                                         dy: screen.visibleFrame.height * 0.2))
                        windows.raise(w)
                    }
                } else if !windows.parked.contains(w) {
                    if let f = windows.frame(of: w) { floatFrames[w] = f }
                    windows.park(w, on: screen)
                }
            }
        }
        state.floaters = all.isEmpty ? nil : all
    }

    /// Hyper + P: locks this board's placements (or unlocks them). Nothing
    /// docks, snaps, resizes, joins or opens room here: new windows float on
    /// top, and a window dragged around glides back to its tile.
    func togglePlacementLock() {
        guard !onSurface else { return }
        // Pointing at an outside window: punch it into the board instead.
        let m = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.height ?? 0
        if let hit = windows.windowAt(CGPoint(x: m.x, y: top - m.y)), isFloater(hit.id) {
            punchIn(hit.id)
            return
        }
        var all = state.lockedBoards ?? []
        if let i = all.firstIndex(of: current.id) {
            all.remove(at: i)
            Toast.show("Placements unlocked", seconds: 0.9)
        } else {
            all.append(current.id)
            Toast.show("Placements locked on this board  ·  \(CapsKey.label) + P unlocks", seconds: 1.4)
        }
        state.lockedBoards = all.isEmpty ? nil : all
        saveState()
        showBounds()
    }

    /// Hyper + L: locks the window under the pointer in place (or unlocks
    /// it): it stays in its tile, at its size, whatever happens around it.
    func toggleWindowLock() {
        guard !onSurface, !busy else { return }
        guard let w = windowUnderPointer() ?? windows.focusedWindowID().flatMap({ liveIn[$0] != nil ? $0 : nil }) else {
            Toast.show("Point at a window on a board, then \(CapsKey.label) + L", seconds: 1.2)
            return
        }
        var all = state.lockedWindows ?? []
        if let i = all.firstIndex(of: w) {
            all.remove(at: i)
            Toast.show("\(windows.appName(w)) unlocked", seconds: 0.9)
        } else {
            all.append(w)
            Toast.show("\(windows.appName(w)) locked in place  ·  \(CapsKey.label) + L unlocks", seconds: 1.4)
        }
        state.lockedWindows = all.isEmpty ? nil : all
        saveState()
        showBounds()
    }

    // MARK: Snapping (Hyper + arrows, the way Windows 11 does it)

    /// Where a window was snapped with Hyper + arrows.
    private enum SnapSpot: Equatable {
        case half(right: Bool)
        case quarter(right: Bool, top: Bool)

        var right: Bool {
            switch self {
            case .half(let r): return r
            case .quarter(let r, _): return r
            }
        }
    }

    /// Windows snapped with Hyper + arrows, while they stay where they were
    /// snapped. Only these turn Hyper + ↑ / ↓ into quarters; everywhere
    /// else Hyper + ↑ / ↓ dive in and come back up as always.
    private var snapped: [UInt32: SnapSpot] = [:]
    /// The undo point each quarter snap made, so going back to the half puts
    /// the board back exactly as it was.
    private var quarterUndo: [UInt32: Int] = [:]

    /// Hyper + arrow.
    /// - ← / →: the window you're using takes that half of the board, the
    ///   rest share the other half. Snapped already: it crosses over.
    /// - ↑ / ↓ on a window snapped to a side: it takes the top or bottom
    ///   quarter of that side (the tile nearest that corner takes the other
    ///   quarter, or breathing room if there's nothing to take it). The other
    ///   way goes back to the half. Anything else: dive in / come back up.
    func snapFocused(_ dir: Desktop.Direction) {
        let vertical = dir == .up || dir == .down
        func upOrDown() { if dir == .up { zoomInStep() } else { zoomOutStep() } }
        if onSurface || overviewOpen {
            if vertical { upOrDown() }
            return
        }
        guard !busy else { return }
        guard let w = windows.focusedWindowID() else {
            if vertical { upOrDown() } else { Toast.show("Click a window first — \(CapsKey.label) + ← / → snaps it", seconds: 1.2) }
            return
        }
        let spot = validSnap(w)
        if vertical {
            guard let spot else { upOrDown(); return }
            if lockRefuses(w) { return }
            let up = dir == .up
            switch spot {
            case .half(let right):
                snapQuarter(w, right: right, top: up)
            case .quarter(let right, let top):
                if top == up {
                    // As far as it goes that way: the next press dives / comes up.
                    snapped[w] = nil
                    Toast.show(up ? "Top quarter  ·  \(CapsKey.label) + ↑ again dives in"
                                  : "Bottom quarter  ·  \(CapsKey.label) + ↓ again comes back up", seconds: 1.1)
                } else {
                    backToHalf(w, right: right)
                }
            }
            return
        }
        let right = dir == .right
        if lockRefuses(w) { return }
        if let spot {
            if spot.right == right {
                Toast.show(right ? "Already on the right" : "Already on the left", seconds: 0.8)
            } else {
                crossOver(w, spot, to: right)
            }
        } else {
            snapHalf(w, right: right)
        }
    }

    /// The tile holding just this window on the board you're on.
    private func soleTile(_ w: UInt32, on d: Desktop) -> Panel? {
        d.panels().first { $0.windows == [w] && $0.desktop == nil && $0.free != true }
    }

    /// Where a window is snapped, if it's still there (you haven't moved it,
    /// or the board, since).
    private func validSnap(_ w: UInt32) -> SnapSpot? {
        guard let s = snapped[w] else { return nil }
        let d = current
        guard case .split(let root) = d.root, root.axis == .h, root.children.count >= 2,
              let p = soleTile(w, on: d) else {
            snapped[w] = nil
            return nil
        }
        let end = root.children[s.right ? root.children.count - 1 : 0]
        switch s {
        case .half:
            if end.id == p.id { return s }
        case .quarter(_, let top):
            if case .split(let col) = end, col.axis == .v, col.children.count == 2,
               col.children[top ? 0 : 1].id == p.id { return s }
        }
        snapped[w] = nil
        return nil
    }

    /// The window in a tile of its own, taken off the board, ready to dock
    /// somewhere else. Nil when it's alone on the board (nothing to snap
    /// beside).
    private func lift(_ w: UInt32, from d: Desktop) -> Panel? {
        if let p = soleTile(w, on: d), p.scratch != true, p.tabs != true {
            guard d.panels().count > 1 else { return nil }
            d.pluck(p.id)
            return p
        }
        let old = d.deepFind(window: w)
        removeLive(w)
        // The tile it leaves on this board goes; the tiles around it take the space.
        if let old, old.owner === d, old.panel.windows.isEmpty, old.panel.desktop == nil,
           old.panel.free != true, old.panel.scratch != true, d.panels().count > 1 {
            d.pluck(old.panel.id)
            vacated.remove(old.panel.id)
        }
        let p = Panel(number: d.nextNumber())
        p.windows = [w]
        return p
    }

    private func finishSnap(_ w: UInt32, _ p: Panel, _ spot: SnapSpot) {
        Coach.shared.note(.docked)
        snapped[w] = spot
        spotlit = nil
        state.lastPanelId = p.id
        lastApplied[w] = nil
        glideLayout()
        windows.focus(w)
    }

    private func snapHalf(_ w: UInt32, right: Bool) {
        let d = current
        checkpoint()   // Hyper + Z puts it back
        guard let p = lift(w, from: d) else {
            _ = undoStack.popLast()
            Toast.show("Nothing here to snap beside", seconds: 1.0)
            return
        }
        quarterUndo[w] = nil
        d.dockAlongSide(.panel(p), right: right)
        finishSnap(w, p, .half(right: right))
    }

    /// Snapped to one side, Hyper + the other arrow: it goes to the same spot
    /// on the other side (a half stays a half, a quarter a quarter).
    private func crossOver(_ w: UInt32, _ spot: SnapSpot, to right: Bool) {
        let d = current
        guard case .split(let root) = d.root, let p = soleTile(w, on: d) else { return }
        checkpoint()
        quarterUndo[w] = nil
        let from = right ? 0 : root.children.count - 1
        let node = root.children.remove(at: from)
        let share = root.ratios.remove(at: from)
        if right {
            root.children.append(node)
            root.ratios.append(share)
        } else {
            root.children.insert(node, at: 0)
            root.ratios.insert(share, at: 0)
        }
        switch spot {
        case .half: finishSnap(w, p, .half(right: right))
        case .quarter(_, let top): finishSnap(w, p, .quarter(right: right, top: top))
        }
    }

    private func snapQuarter(_ w: UInt32, right: Bool, top: Bool) {
        let d = current
        guard let p = soleTile(w, on: d) else { return }
        checkpoint()
        let mark = undoStack.count
        d.pluck(p.id)
        // What shares the side with it: the tile (or group) of the rest that's
        // nearest that corner, or breathing room when there's only one tile left.
        var partner: Node?
        if case .split(let rest) = d.root, rest.children.count >= 2 {
            let last = rest.children.count - 1
            let i = rest.axis == .v ? (top ? last : 0) : (right ? last : 0)
            partner = d.pluck(rest.children[i].id)
        }
        let other: Node
        if let partner {
            other = partner
        } else {
            let room = Panel(number: d.nextNumber())
            room.scratch = true
            if tileWindows { room.free = true }
            other = .panel(room)
        }
        let column = Split(axis: .v, children: top ? [.panel(p), other] : [other, .panel(p)])
        column.ratios = [0.5, 0.5]
        d.dockAlongSide(.split(column), right: right)
        quarterUndo[w] = mark
        finishSnap(w, p, .quarter(right: right, top: top))
    }

    private func backToHalf(_ w: UInt32, right: Bool) {
        // Nothing else changed since the quarter: put the board back exactly.
        if let mark = quarterUndo[w], mark == undoStack.count {
            quarterUndo[w] = nil
            undo(quiet: true)
            snapped[w] = .half(right: right)
            windows.focus(w)
            return
        }
        quarterUndo[w] = nil
        let d = current
        guard case .split(let root) = d.root, let p = soleTile(w, on: d),
              case .split(let column) = root.children[right ? root.children.count - 1 : 0],
              let other = column.children.first(where: { $0.id != p.id }) else { return }
        checkpoint()
        d.pluck(other.id)   // the column closes up: the window has the whole side again
        // What shared the side goes in beside the tile next to it (breathing
        // room left empty just goes).
        var emptyRoom = false
        if case .panel(let q) = other, q.scratch == true, q.windows.isEmpty, q.desktop == nil { emptyRoom = true }
        if !emptyRoom, case .split(let now) = d.root, now.children.count >= 2 {
            let next = now.children[right ? now.children.count - 2 : 1]
            d.pair(other, with: next.id, axis: .v, after: true)
        }
        finishSnap(w, p, .half(right: right))
    }

    // MARK: Breathing room into the board (Hyper + Y)

    /// Breathing rooms you tiled into the board with Hyper + Y, and the undo
    /// point that did it, so Hyper + Y again puts the room back exactly.
    private var tiledRooms: [UUID: Int] = [:]

    /// Hyper + Y on breathing room: it stops being a place of its own and
    /// joins the board as a tile, side by side with the tile nearest it (in
    /// that tile's group). Tiles around it make room for what's inside, down
    /// to their own smallest sizes. Hyper + Y on it again: breathing room
    /// again, its own depth.
    func toggleRoomTile() {
        guard !onSurface, !busy, !lockRefuses() else { return }
        let point = NSEvent.mouseLocation
        let d = current
        let placed = frames(d, in: viewport).filter { $0.depth == 0 }
        guard let hit = placed.first(where: { $0.rect.contains(point) }) else {
            Toast.show("Point at a breathing room, then \(CapsKey.label) + Y", seconds: 1.2)
            return
        }
        let p = hit.panel
        if p.scratch == true {
            tileRoom(p, at: hit.rect, among: placed)
            return
        }
        if let mark = tiledRooms[p.id] {
            tiledRooms[p.id] = nil
            if mark == undoStack.count {
                undo(quiet: true)
            } else {
                checkpoint()
                p.scratch = true
                glideLayout()
            }
            Toast.show("Breathing room again  ·  its own place to dive into", seconds: 1.2)
            return
        }
        Toast.show("Point at a breathing room  ·  \(CapsKey.label) + Y tiles it in beside its neighbour", seconds: 1.4)
    }

    private func tileRoom(_ room: Panel, at rect: CGRect, among placed: [Placed]) {
        let d = current
        checkpoint()   // Hyper + Z (or Hyper + Y again) puts it back
        let mark = undoStack.count
        // Beside a group (where Hyper + B put it): it joins the group, side
        // by side with the tile in it nearest the room.
        if let loc = d.parent(of: room.id), loc.split.children.count == 2,
           case .split(let group) = loc.split.children[1 - loc.index] {
            let ids = Set(panelsIn(.split(group)).map { $0.id })
            func distance(_ r: CGRect) -> CGFloat { hypot(r.midX - rect.midX, r.midY - rect.midY) }
            if let near = placed.filter({ ids.contains($0.panel.id) }).min(by: { distance($0.rect) < distance($1.rect) }) {
                d.pluck(room.id)
                d.pair(.panel(room), with: near.panel.id, axis: .h, after: rect.midX >= near.rect.midX)
            }
        }
        room.scratch = nil
        room.roomFit = nil
        room.free = nil
        tiledRooms[room.id] = mark
        Toast.show("Tiled into the board  ·  \(CapsKey.label) + Y again makes it breathing room", seconds: 1.4)
        if let w = room.windows.first { growTile(room, w) } else { glideLayout() }
    }

    /// The tile grows to a size its app can use (as small as it goes, when
    /// that's known), taken from the tiles around it that can spare it,
    /// gliding there. Nothing to grow: it just lays out.
    private func growTile(_ p: Panel, _ w: UInt32) {
        let stub = CrowdTile(rect: .zero, icon: nil, name: "", extra: 0, panel: p.id, owner: current.id, window: w)
        guard inflating == nil, let plan = planInflate(stub) else {
            glideLayout()
            return
        }
        settleGrow(plan)
        glideLayout()
    }

    /// Puts a planned grow in place at once (the glide shows the motion).
    private func settleGrow(_ plan: Inflate) {
        for e in plan.splits where e.target.count == e.split.ratios.count {
            e.split.ratios = e.target
            e.split.seated = true
        }
        handFrost.remove(plan.panel)
    }

    // MARK: Keyboard docking (Ctrl + Option + arrows)

    /// Ctrl + Option + arrow: pushes the window you're using that way, one
    /// level of the board at a time. Beside a tile that way, it swaps places
    /// with it; at the end of its group it docks beside the whole group; at
    /// the top, along that edge of the board. Off the Desktop (or out of a
    /// pool it shares), it docks as a tile of its own on that side.
    func pushFocused(_ dir: Desktop.Direction) {
        guard !onSurface, !busy, let w = windows.focusedWindowID(), !lockRefuses(w) else { return }
        guard let found = current.deepFind(window: w) else {
            Toast.show("Put the window on a board first")
            return
        }
        let p = found.panel, d = found.owner
        let axis: Axis = (dir == .left || dir == .right) ? .h : .v
        let before = dir == .left || dir == .up
        checkpoint()
        if p.free == true || p.windows.count > 1 {
            removeLive(w)
            let fresh = d.addPanel(nextTo: p, axis: axis, before: before)
            fresh.windows = [w]
            state.lastPanelId = fresh.id
        } else if !d.push(p, toward: dir) {
            _ = undoStack.popLast()
            Toast.show("Already against that edge", seconds: 0.8)
            return
        }
        spotlit = nil
        lastApplied[w] = nil
        glideLayout()
        windows.focus(w)
    }

    /// Ctrl + Option + Shift + arrow: moves a gap beside the window you're
    /// using that way: the one on that side if there is one (it grows), else
    /// the one on the other side (it shrinks).
    func nudgeGap(_ dir: Desktop.Direction) {
        guard !onSurface, !busy, let w = windows.focusedWindowID(), !lockRefuses(w),
              let found = current.deepFind(window: w) else { return }
        let opposite: Desktop.Direction
        switch dir {
        case .left: opposite = .right
        case .right: opposite = .left
        case .up: opposite = .down
        case .down: opposite = .up
        }
        checkpoint()
        let d = found.owner, p = found.panel
        guard d.grow(p, toward: dir) || d.shrink(p, from: opposite) else {
            _ = undoStack.popLast()
            return
        }
        applyLayout()
    }

    /// Moves to the previous (-1) or next (+1) panel in reading order and
    /// focuses its window.
    func focusNeighbor(_ step: Int) {
        let ps = current.panels()
        guard ps.count > 1 else { Toast.show("Only one pool here"); return }
        let here = activePanel()
        let i = ps.firstIndex { $0.id == here.id } ?? 0
        let next = ps[(i + step + ps.count) % ps.count]
        state.lastPanelId = next.id

        let landing = next.desktop?.landingPanel() ?? next
        if let w = landing.windows.last ?? next.desktop?.allWindows().first {
            selection = nil
            windows.focus(w)
        } else {
            selection = (next.id, windows.focusedWindowID())
        }
        // Give the app a moment to take focus before highlighting.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.showNumbers()
        }
    }

    /// Hyper + ↑: dive in from the Surface, or zoom into the panel you're in.
    func zoomInStep() {
        if onSurface { enterBoards(); return }
        if overviewOpen {
            if !busy, let m = moveFromOverview(nil) { perform(m) }
            return
        }
        zoomIntoActive()
    }

    /// Hyper + ↓: zoom out a level; from the main board, back to the Surface
    /// (unless zooming out stops at Main).
    /// - throughToDesktop: Hyper + scroll goes on to your desktop from Main
    ///   even when zooming out stops at Main.
    func zoomOutStep(throughToDesktop: Bool = false) {
        if onSurface { return }
        if overviewOpen {
            if throughToDesktop { surface() } else { topHint() }
            return
        }
        if !state.path.isEmpty { zoomOut(); return }
        if !throughToDesktop, !busy, let m = moveOverview() {
            perform(m)
            return
        }
        if stopAtMain && !throughToDesktop { stopHint() } else { surface() }
    }

    // MARK: Zooming out past Main: the Overview

    /// Zooming out past Main keeps going: Main shrinks into its place among
    /// all your Mains, on the Overview.
    var overviewZoom: Bool {
        get { UserDefaults.standard.bool(forKey: "overviewZoom") }
        set { UserDefaults.standard.set(newValue, forKey: "overviewZoom") }
    }

    /// The Overview is open on this screen.
    var overviewOpen: Bool { BoardOverview.current?.isShowing(on: self) == true }

    private var lastTopHint = Date.distantPast

    private func topHint() {
        guard Date().timeIntervalSince(lastTopHint) > 1.5 else { return }
        lastTopHint = Date()
        Toast.show("That's everything · \(CapsKey.label) + Esc for your desktop", seconds: 1.1)
    }

    /// The key for the Overview's remembered picture.
    private let overviewKey = "overview"

    // MARK: Stepping through to your desktop

    /// A three-finger swipe down on bare background (the gaps between
    /// windows, or wallpaper a pool leaves showing) steps through it to your
    /// desktop, which sits behind your boards.
    var stepThrough: Bool {
        get { UserDefaults.standard.bool(forKey: "stepThrough") }
        set { UserDefaults.standard.set(newValue, forKey: "stepThrough") }
    }

    /// True when a point (AppKit screen coordinates) is on the board's bare
    /// background: not on a window, a porthole or tile, or an empty pool
    /// (diving into one of those means something else).
    private func isBareBackground(_ p: CGPoint) -> Bool {
        guard viewport.insetBy(dx: -gap, dy: -gap).contains(p) else { return false }
        let top = NSScreen.screens.first?.frame.height ?? 0
        if windows.windowExactlyAt(CGPoint(x: p.x, y: top - p.y)) != nil { return false }
        if shownTiles.contains(where: { $0.rect.contains(p) }) { return false }
        for placed in frames(current, in: viewport) where placed.panel.desktop == nil {
            let inner = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
            if inner.contains(p), shownWindows(placed.panel, of: placed.owner).isEmpty { return false }
            // The Desktop is a place of its own, not a way through.
            if inner.contains(p), placed.panel.free == true { return false }
        }
        return true
    }

    /// Through the background to your desktop: the camera dives into the
    /// spot under your fingers, and your desktop is on the other side.
    private func moveThrough(at p: CGPoint) -> Move? {
        guard stepThrough, !onSurface, !overviewOpen, isBareBackground(p) else { return nil }
        let f = screen.frame
        let w = f.width * 0.1, h = f.height * 0.1
        let x = min(max(p.x - w / 2, f.minX), f.maxX - w)
        let y = min(max(p.y - h / 2, f.minY), f.maxY - h)
        let hole = CGRect(x: x, y: y, width: w, height: h)
        return Move(zoomIn: true, target: hole, toKey: placeKey(nil)) {
            self.onSurface = true
            self.steppedThrough = hole
        }
    }

    /// Where you last stepped through to your desktop, so a swipe up from
    /// your desktop can take you back out the way you came.
    private var steppedThrough: CGRect?

    /// From your desktop, after stepping through: back out through the same
    /// spot to where you were (your desktop shrinks back into it).
    private func moveBackThrough() -> Move? {
        guard onSurface, let hole = steppedThrough, let enter = moveEnter(at: nil) else { return nil }
        return Move(zoomIn: false, target: hole, toKey: enter.toKey, change: enter.change)
    }

    /// From Main out to the Overview: the screen shrinks into Main's place on
    /// the map, and the other Mains come into view around it.
    private func moveOverview() -> Move? {
        guard overviewZoom, !onSurface, state.path.isEmpty, let ov = BoardOverview.current, !ov.isOpen else { return nil }
        let target = ov.prepare(on: self)
        if let picture = ov.picture() { animator.offer(picture, as: overviewKey) }
        return Move(zoomIn: false, target: target, toKey: overviewKey, announce: false) {
            ov.show()
        }
    }

    /// From the Overview into a board on it (nil: back to where you were).
    /// The camera dives into that board's place on the map.
    private func moveFromOverview(_ item: OverviewItem?) -> Move? {
        guard !onSurface, let ov = BoardOverview.current, ov.isShowing(on: self) else { return nil }
        let mains = allMains
        let mainID = item?.main ?? state.root.id
        guard let main = mains.first(where: { $0.id == mainID }) else { return nil }
        let wanted = item?.path ?? (main === state.root ? state.path : [])
        let items = ov.items
        func onMain(_ it: OverviewItem) -> Bool { (it.main ?? state.root.id) == mainID }
        let target = items.first(where: { $0.kind == .board && onMain($0) && $0.path == wanted })?.rect
            ?? items.first(where: { $0.kind == .board && onMain($0) && $0.depth == -1 })?.rect
            ?? screen.frame
        let panel = item?.panel
        return Move(zoomIn: true, target: target, toKey: placeKey(wanted, main: mainID)) {
            ov.close()
            if main !== self.state.root {
                var all = self.allMains
                let leaving = self.state.root
                // A blank Main you leave folds away, as it does when you swipe off it.
                if all.count > 1, self.isBlank(leaving) { all.removeAll { $0 === leaving } }
                if let k = all.firstIndex(where: { $0 === main }) { self.setMains(all, current: k) }
            }
            self.state.path = self.isValid(wanted) ? wanted : []
            if let panel { self.state.lastPanelId = panel }
        }
    }

    /// A click on the Overview (nil: outside the map). On your boards, the
    /// camera dives into it; from your desktop, it's a jump.
    func goFromOverview(_ item: OverviewItem?) {
        guard let ov = BoardOverview.current else { return }
        if !onSurface, !busy, let m = moveFromOverview(item) {
            let window = item?.window
            perform(m) { [weak self] in
                guard let self else { return }
                Toast.show(self.locationLabel() + (self.isHome && !self.onSurface ? "  ·  ⌂ Home" : ""), seconds: 0.7)
                if let window { self.windows.focus(window) }
            }
            return
        }
        ov.close()
        guard let item else { return }
        if onSurface, let id = item.main, id != state.root.id {
            let all = allMains
            if let k = all.firstIndex(where: { $0.id == id }) { setMains(all, current: k) }
        }
        jump(to: item.path, panel: item.panel, window: item.window)
    }

    /// Zooming out stops at Main: swipes, scrolls, pinches and Hyper + ↓
    /// don't drop you on your desktop. Hyper + Esc still does.
    var stopAtMain: Bool {
        get { UserDefaults.standard.bool(forKey: "stopAtMain") }
        set { UserDefaults.standard.set(newValue, forKey: "stopAtMain") }
    }
    private var lastStopHint = Date.distantPast

    private func stopHint() {
        guard Date().timeIntervalSince(lastStopHint) > 1.5 else { return }
        lastStopHint = Date()
        Toast.show("\(mainName(state.root)) is the top · \(CapsKey.label) + Esc for your desktop", seconds: 1.1)
    }

    /// Hyper + scroll: dive into whatever is under the pointer. From your
    /// desktop, `toMain` lands on Main (Hyper + scroll) instead of where you
    /// left off.
    func zoomIn(at point: CGPoint, toMain: Bool = false) {
        if onSurface { enterBoards(at: toMain ? [] : nil); return }
        if overviewOpen {
            if !busy, let m = moveFromOverview(BoardOverview.current?.item(at: point)) { perform(m) }
            return
        }
        guard let hit = frames(current, in: viewport).first(where: { $0.depth == 0 && $0.rect.contains(point) })
        else { return }
        zoomInto(hit.panel)
    }

    /// Zooms into the panel you're working in.
    func zoomIntoActive() {
        // Hyper + ↑ steps in, like a swipe.
        let p = activePanel()
        guard !busy, let m = moveInto(p) else { return }
        perform(m)
    }



    /// True when a panel already fills the board on its own (breathing room
    /// aside), so diving into it would only give the same view again.
    private func isAsFarIn(_ p: Panel) -> Bool {
        func emptyRoom(_ q: Panel) -> Bool { q.scratch == true && q.windows.isEmpty && q.desktop == nil }
        guard !state.path.isEmpty, p.desktop == nil, !emptyRoom(p) else { return false }
        return current.panels().allSatisfy { $0 === p || emptyRoom($0) }
    }

    /// Renumbers every desktop in reading order, folds away nested desktops
    /// that only ever had one panel, and drops windows that no longer exist.
    func tidyUp() {
        checkpoint()
        var removed = Set<UUID>()   // panels dropped from the chain of levels

        func tidy(_ d: Desktop) {
            for p in d.panels() {
                guard let nested = p.desktop else { continue }
                tidy(nested)
                let ps = nested.panels()
                guard ps.count == 1 else { continue }
                let only = ps[0]
                if let inner = only.desktop {
                    // A desktop whose only panel holds another desktop is an
                    // empty extra level: skip straight to the inner one.
                    moveContents(from: only, to: inner.landingPanel())
                    p.desktop = inner
                    removed.insert(only.id)
                } else if !state.path.contains(p.id) {
                    p.desktop = nil
                    moveContents(from: only, to: p)
                }
            }
            d.renumber()
        }
        tidy(state.root)

        // Same for the top level itself.
        while state.root.panels().count == 1, let only = state.root.panels().first,
              let inner = only.desktop {
            moveContents(from: only, to: inner.landingPanel())
            // The Main keeps its name, and Home stays on it.
            inner.name = state.root.name
            if state.homeMain == state.root.id { state.homeMain = inner.id }
            state.root = inner
            removed.insert(only.id)
        }

        state.path.removeAll { removed.contains($0) }
        state.home?.removeAll { removed.contains($0) }
        if let home = state.home, home.isEmpty || !isValid(home) { state.home = nil }
        selection = nil
        glideLayout()
        showNumbers()
        Toast.show("Pools renumbered", seconds: 0.9)
    }

    /// For testing: closes every window on every board and Main (apps may
    /// ask to save first), then starts over with one Main of two empty pools.
    /// Asks first, and can't be undone.
    func hardReset() {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Close every window on your boards and start over?"
        alert.informativeText = "Every window on every board and every Main is closed (apps may ask to save first, "
            + "and Safari or Chrome windows close with their tabs). Your boards go back to one Main with two "
            + "empty pools. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close All & Start Over")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        windows.refresh()
        let doomed = Set(everyWindow())
        // Bring everything back into reach first, so any "save?" sheets show.
        held = nil
        chip.hide()
        spotlit = nil
        for w in windows.parked.union(docked) where windows.isMinimized(w) { windows.unminimize(w) }
        docked.removeAll()
        for pid in hiddenByUs { NSRunningApplication(processIdentifier: pid)?.unhide() }
        hiddenByUs.removeAll()
        windows.unparkAll(on: screen)
        for w in doomed { windows.close(w) }
        // A fresh start: one Main, two empty pools, nothing remembered.
        state = AppState()
        undoStack.removeAll()
        lastApplied.removeAll()
        liveIn.removeAll()
        portholed = []
        mirrored = []
        probing.removeAll()
        overflowAt.removeAll()
        overflowSeen.removeAll()
        portholePictures.removeAll()
        selection = nil
        saveState()
        if !onSurface { applyLayout() }
        Toast.show("Fresh start: one Main, all Desktop", seconds: 1.4)
    }

    func resetLayout() {
        windows.unparkAll(on: screen)
        state = AppState()
        saveState()
        Toast.show("Reset: one Main, all Desktop")
    }

    // MARK: Drag and drop

    enum DropAction {
        case fill                          // snap to fill the panel
        case newPanel(Axis, before: Bool)  // split off a new panel on that side
        case float                         // stay where dropped, inside the panel
        /// Dock beside a window: the dragged window takes `rel` of the pool,
        /// and `partner` (the window it docked beside) shrinks to `partnerRel`.
        case dock(rel: CGRect, partner: UInt32, partnerRel: CGRect)
        /// A tile of its own beside a docked window: that window's pool
        /// splits along `axis`, the new tile first (left / above) if `before`.
        case tile(axis: Axis, before: Bool)
        /// Docked along a whole side of the board, beside everything.
        case edge(axis: Axis, before: Bool)
        /// Floats on the Desktop, where you let go.
        case desktop
        /// Joins the tile of the window it was dropped on, as a tab.
        case tab(partner: UInt32)
        /// A tile of its own in the row (or column) of a small tile, the
        /// same size as it: a peer, not half of it.
        case peer(before: Bool)
    }

    struct SnapBar {
        let action: DropAction
        let rect: CGRect       // AppKit screen coordinates
    }

    struct DropTarget {
        let panel: Panel
        let owner: Desktop
        let action: DropAction
        let panelRect: CGRect
        let highlight: CGRect  // AppKit screen coordinates
        let label: String
        let remaining: CGRect? // where the existing panel ends up (new-panel drops)
        let panelLabel: String // the existing panel's own label, e.g. "2"
        let bars: [SnapBar]    // the hovered panel's snap bars
        let activeBar: Int?    // which bar the pointer is on
        /// Where every window on the board will be once it's dropped (worked
        /// out on a copy of the board), for the preview.
        var preview: [UInt32: CGRect]? = nil
        /// Dropping as a tab: the tabs it'll make, the new one last.
        var tabNames: [String]? = nil
    }

    /// The snap bars shown in a panel while dragging: Fill in the middle and a
    /// slim bar along each edge for a new panel on that side.
    func snapBars(in r: CGRect) -> [SnapBar] {
        // Edge bars are short pills hugging the edges, so a window dragged by
        // its title bar near the top of a panel doesn't hit one by accident.
        let inset: CGFloat = 4
        let thick = max(10, min(16, min(r.width, r.height) * 0.05))
        let lenH = min(r.height * 0.25, 160)
        let lenW = min(r.width * 0.25, 160)
        let fillW = min(240, r.width * 0.42)
        let fillH = min(56, r.height * 0.18)
        return [
            SnapBar(action: .fill,
                    rect: CGRect(x: r.midX - fillW / 2, y: r.midY - fillH / 2, width: fillW, height: fillH)),
            SnapBar(action: .newPanel(.h, before: true),
                    rect: CGRect(x: r.minX + inset, y: r.midY - lenH / 2, width: thick, height: lenH)),
            SnapBar(action: .newPanel(.h, before: false),
                    rect: CGRect(x: r.maxX - inset - thick, y: r.midY - lenH / 2, width: thick, height: lenH)),
            SnapBar(action: .newPanel(.v, before: true),
                    rect: CGRect(x: r.midX - lenW / 2, y: r.maxY - inset - thick, width: lenW, height: thick)),
            SnapBar(action: .newPanel(.v, before: false),
                    rect: CGRect(x: r.midX - lenW / 2, y: r.minY + inset, width: lenW, height: thick)),
        ]
    }

    /// Plain panels on screen (not ones that hold a nested desktop).
    func dropPanels() -> [Placed] {
        frames(current, in: viewport).filter { $0.panel.desktop == nil }
    }

    /// What dropping a window at this point (AppKit coordinates) would do.
    func dropTarget(at point: CGPoint) -> DropTarget? {
        guard !placementsLocked else { return nil }
        guard let hit = dropPanels().filter({ $0.rect.contains(point) }).max(by: { $0.depth < $1.depth })
        else { return nil }
        let r = hit.rect
        let bars = snapBars(in: r)
        // The Fill pill is forgiving; edge bars only count when you're on them.
        let index = bars.firstIndex { bar in
            if case .fill = bar.action { return bar.rect.insetBy(dx: -10, dy: -10).contains(point) }
            return bar.rect.contains(point)
        }

        guard let i = index else {
            return DropTarget(panel: hit.panel, owner: hit.owner, action: .float, panelRect: r,
                              highlight: r, label: "Float in pool \(hit.label)",
                              remaining: nil, panelLabel: hit.label, bars: bars, activeBar: nil)
        }
        switch bars[i].action {
        case .fill, .float, .dock, .tile, .edge, .desktop, .tab, .peer:
            return DropTarget(panel: hit.panel, owner: hit.owner, action: .fill, panelRect: r,
                              highlight: r, label: "Fill pool \(hit.label)",
                              remaining: nil, panelLabel: hit.label, bars: bars, activeBar: i)
        case .newPanel(let axis, let before):
            let left = CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
            let right = CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
            let top = CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
            let bottom = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
            let (newHalf, keep): (CGRect, CGRect) = axis == .h
                ? (before ? (left, right) : (right, left))
                : (before ? (top, bottom) : (bottom, top))
            return DropTarget(panel: hit.panel, owner: hit.owner, action: bars[i].action, panelRect: r,
                              highlight: newHalf, label: "New pool",
                              remaining: keep, panelLabel: hit.label, bars: bars, activeBar: i)
        }
    }

    // MARK: Smooth drag previews

    /// While you drag, stand-ins glide to where everything will go (instead
    /// of the real windows moving under your hand), after the pointer has
    /// rested on a spot for a moment.
    var smoothDrags: Bool {
        get { UserDefaults.standard.bool(forKey: "stageDrag") }
        set { UserDefaults.standard.set(newValue, forKey: "stageDrag") }
    }

    /// As a drag starts: pictures of the windows in view, ready for the stage.
    /// False when there's no stage (no Screen Recording, or turned off).
    func prepareStage(dragging w: UInt32) -> Bool {
        guard smoothDrags, !onSurface, glider.hasPermission else { return false }
        var frames: [UInt32: CGRect] = [:]
        var icons: [UInt32: NSImage] = [:]
        for x in liveIn.keys where x != w && !windows.parked.contains(x) && !portholed.contains(x) {
            guard let f = windows.frame(of: x), screen.frame.intersects(f) else { continue }
            frames[x] = f
            if let i = windows.appIcon(x) { icons[x] = i }
        }
        return stage.prepare(on: screen, dragged: w, windows: frames, icons: icons)
    }

    // MARK: Docking as tiles

    /// The last worked-out drop (a drag asks many times a second). Cleared
    /// by every layout, since the board may have changed.
    private var planCache: (key: String, plan: [UInt32: CGRect])?

    /// Works out a drop on a copy of the board on screen: the dragged window
    /// leaves its pool (a tile left empty goes), `edit` puts it somewhere,
    /// and the copy is laid out. Returns where every window would be.
    private func planDrop(_ key: String, dragging w: UInt32, _ edit: (Desktop) -> Bool) -> [UInt32: CGRect]? {
        if let c = planCache, c.key == key { return c.plan }
        // Windows you've moved or resized by hand stay where you put them.
        captureManualMoves()
        guard let data = try? JSONEncoder().encode(current),
              let copy = try? JSONDecoder().decode(Desktop.self, from: data) else { return nil }
        if let found = copy.deepFind(window: w) {
            fillVacancy(left: w, in: found.panel)
            found.panel.windows.removeAll { $0 == w }
            found.panel.setFloat(w, nil)
            if tileWindows { found.owner.pruneTile(found.panel) }
        }
        guard edit(copy) else { return nil }
        if autoRotate { adapt(copy.root, viewport, copy) }
        var out: [UInt32: CGRect] = [:]
        for placed in frames(copy, in: viewport) where placed.panel.desktop == nil {
            var target = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
            if let r = tabStripRect(for: placed.panel, of: placed.owner, in: target) {
                target = tabBody(below: r, in: target)
            }
            let shown = shownWindows(placed.panel, of: placed.owner)
            let fill = fillRect(for: placed.panel, in: target, only: shown)
            for x in shown { out[x] = spot(for: x, in: placed.panel, target: target, fill: fill, stretch: nil) }
        }
        planCache = (key, out)
        return out
    }

    /// Without pools on show, every window its own tile: what dropping `w`
    /// here would do.
    /// - At a screen edge (or up in the menu bar): docked along that whole
    ///   side, beside everything.
    /// - On the Desktop: it floats where you let go.
    /// - Over an empty pool: it fills it.
    /// - Over a window: a tile of its own beside it, on the side you're
    ///   nearest to; that window gives up the half on that side.
    private func tileTarget(at point: CGPoint, dragging w: UInt32) -> DropTarget? {
        let v = viewport
        let board = current
        let band: CGFloat = 24
        var side: (axis: Axis, before: Bool)?
        if point.y > v.maxY - 2 { side = (.v, true) }
        else if point.x < v.minX + band { side = (.h, true) }
        else if point.x > v.maxX - band { side = (.h, false) }
        else if point.y < v.minY + band { side = (.v, false) }
        if let side {
            let key = "edge-\(w)-\(side.axis.rawValue)-\(side.before)"
            guard let p = planDrop(key, dragging: w, { d in
                let fresh = d.addEdgePanel(axis: side.axis, before: side.before)
                fresh.windows = [w]
                return true
            }) else { return nil }
            return DropTarget(panel: board.lowestNumbered(), owner: board, action: .edge(axis: side.axis, before: side.before),
                              panelRect: v, highlight: p[w] ?? v, label: "Docked along the edge", remaining: nil,
                              panelLabel: "", bars: [], activeBar: nil, preview: p)
        }
        guard let hit = dropPanels().filter({ $0.rect.contains(point) }).max(by: { $0.depth < $1.depth })
        else { return nil }
        let r = hit.rect
        let inner = r.insetBy(dx: gap / 2, dy: gap / 2)
        let pid = hit.panel.id
        func make(_ action: DropAction, _ label: String, _ key: String, _ edit: (Desktop) -> Bool) -> DropTarget? {
            guard let p = planDrop(key, dragging: w, edit) else { return nil }
            return DropTarget(panel: hit.panel, owner: hit.owner, action: action, panelRect: r, highlight: p[w] ?? inner,
                              label: label, remaining: nil, panelLabel: hit.label, bars: [], activeBar: nil, preview: p)
        }
        // Empty breathing room: a tile of its own, the room's exact size.
        if hit.panel.scratch == true, hit.panel.windows.isEmpty, hit.panel.desktop == nil {
            return make(.fill, "Breathing room", "room-\(w)-\(pid)") { d in
                guard let found = d.deepFind(panel: pid) else { return false }
                found.panel.free = nil
                found.panel.windows.append(w)
                return true
            }
        }
        // The Desktop: it floats, right where you let go.
        if hit.panel.free == true {
            return make(.desktop, "Desktop", "desk-\(w)-\(pid)") { _ in true }
        }
        let others = shownWindows(hit.panel, of: hit.owner).filter { $0 != w && !onTop.contains($0) }
        guard !others.isEmpty else {
            // Its own tile (or its own tabs): it settles back where it was.
            if hit.panel.windows == [w] || (hit.panel.tabs == true && hit.panel.windows.contains(w)) {
                return DropTarget(panel: hit.panel, owner: hit.owner, action: .fill, panelRect: r, highlight: inner,
                                  label: "Pool \(hit.label)", remaining: nil, panelLabel: hit.label, bars: [], activeBar: nil)
            }
            // An empty pool: it fills it.
            return make(.fill, "Pool \(hit.label)", "fill-\(w)-\(pid)") { d in
                guard let found = d.deepFind(panel: pid) else { return false }
                found.panel.windows.append(w)
                return true
            }
        }
        // The window under the pointer, and the side of it you're nearest to.
        let spots = planned(hit, without: w, changes: [:]).filter { others.contains($0.window) }
        let under = spots.filter { $0.rect.contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        let s = under?.rect ?? inner
        let fx = (point.x - s.minX) / max(s.width, 1), fy = (point.y - s.minY) / max(s.height, 1)
        let dx = min(fx, 1 - fx), dy = min(fy, 1 - fy)
        // The middle of a window: it joins that window's tile as a tab. Once
        // it's a tab, it stays one until you're well out toward an edge, so
        // it doesn't flicker at the border.
        let zone = (tabCandidate != nil && tabCandidate == under?.window) ? Self.tabZoneHeld : Self.tabZone
        if let u = under, dx > zone, dy > zone {
            tabCandidate = u.window
            let names = tabMembers(hit.panel, of: hit.owner).filter { $0 != w }.map { tabName($0) } + [tabName(w)]
            guard var t = make(.tab(partner: u.window), "Tab with \(windows.appName(u.window))", "tab-\(w)-\(pid)", { d in
                guard let found = d.deepFind(panel: pid) else { return false }
                self.makeTab(w, in: found.panel)
                return true
            }) else { return nil }
            t = DropTarget(panel: t.panel, owner: t.owner, action: t.action, panelRect: r, highlight: inner,
                           label: t.label, remaining: nil, panelLabel: t.panelLabel, bars: [], activeBar: nil,
                           preview: t.preview, tabNames: names)
            return t
        }
        tabCandidate = nil
        // Near a corner, where either side would do: the split that keeps
        // both tiles closest to the screen's own shape.
        let axis: Axis = abs(dx - dy) < 0.08 ? screenShapedAxis(for: s) : (dx <= dy ? .h : .v)
        let before = axis == .h ? fx < 0.5 : fy > 0.5
        let name = under.map { windows.appName($0.window) } ?? "pool \(hit.label)"
        // A small tile in a strip (a row of short ones, say): the window joins
        // the strip as a peer, the same size, instead of squeezing in beside
        // it the other way.
        if let loc = hit.owner.parent(of: pid) {
            let row = loc.split.axis
            let across = row == .h ? r.height / max(viewport.height, 1) : r.width / max(viewport.width, 1)
            if across < 0.4 {
                let peerBefore = row == .h ? fx < 0.5 : fy > 0.5
                return make(.peer(before: peerBefore), "Beside \(name)", "peer-\(w)-\(pid)-\(peerBefore)") { d in
                    guard let found = d.deepFind(panel: pid),
                          let fresh = found.owner.addPeer(nextTo: found.panel, before: peerBefore) else { return false }
                    fresh.windows = [w]
                    return true
                }
            }
        }
        return make(.tile(axis: axis, before: before), "Beside \(name)", "tile-\(w)-\(pid)-\(axis.rawValue)-\(before)") { d in
            guard let found = d.deepFind(panel: pid) else { return false }
            let fresh = found.owner.addPanel(nextTo: found.panel, axis: axis, before: before)
            fresh.windows = [w]
            return true
        }
    }

    // MARK: Dragging a frosted window by its bar

    /// A frosted window dragged by its bar: the windows where it would land
    /// make room for it, the way they do for a real window.
    func tileDragMove(_ t: CrowdTile, at p: CGPoint) {
        guard !onSurface, !busy, t.window != 0 else { return }
        let target = dockTarget(at: p, dragging: t.window)
        previewDrop(t.window, target: target, leaving: true)
    }

    /// Let go: it docks where it was over (live again if it fits there),
    /// or goes back where it was.
    func tileDragEnd(_ t: CrowdTile, at p: CGPoint) {
        guard !onSurface, t.window != 0 else { return }
        let target = busy ? nil : dockTarget(at: p, dragging: t.window)
        endPreview(restore: target == nil)
        if let target { drop(t.window, on: target) } else { applyLayout() }
    }

    // MARK: Shelves

    /// Frosted tiles side by side on the board you're on (two or more in a
    /// row of the same group) are drawn as one shelf: a frosted shape with
    /// each app's icon in its place. Click it to step into them together,
    /// full size, with the app you clicked in front; come back up and they
    /// fold back into the shelf. Swipe up on an app to inflate just that one.
    private func shelve(_ crowd: [CrowdTile]) -> [CrowdTile] {
        func frostedTile(_ t: CrowdTile) -> Bool {
            !t.porthole && t.cells.isEmpty && t.badge == nil && !t.jumpOnly && t.window != 0 && t.owner == current.id
        }
        var byPanel: [UUID: Int] = [:]
        for (i, t) in crowd.enumerated() where frostedTile(t) { byPanel[t.panel] = i }
        guard byPanel.count >= 2 else { return crowd }
        var used = Set<Int>()
        var shelves: [CrowdTile] = []
        var seen = Set<ObjectIdentifier>()
        for (pid, _) in byPanel {
            guard let loc = current.parent(of: pid), seen.insert(ObjectIdentifier(loc.split)).inserted else { continue }
            let s = loc.split
            // Runs of neighbours in this group that are all frosted tiles.
            var run: [Int] = []
            func close() {
                defer { run.removeAll() }
                guard run.count >= 2 else { return }
                let tiles = run.compactMap { k -> CrowdTile? in
                    guard case .panel(let p) = s.children[k], let i = byPanel[p.id] else { return nil }
                    used.insert(i)
                    return crowd[i]
                }
                guard let first = tiles.first else { return }
                var shelf = CrowdTile(rect: tiles.dropFirst().reduce(first.rect) { $0.union($1.rect) }, icon: nil,
                                      name: tiles.map { $0.name }.joined(separator: ", "), extra: 0,
                                      panel: first.panel, owner: first.owner, window: 0)
                shelf.cells = tiles.map { $0.rect }
                shelf.cellIcons = tiles.map { $0.icon }
                shelf.shelfPanels = tiles.map { $0.panel }
                shelf.shelfWindows = tiles.map { $0.window }
                shelves.append(shelf)
            }
            for (k, child) in s.children.enumerated() {
                if case .panel(let p) = child, byPanel[p.id] != nil { run.append(k) } else { close() }
            }
            close()
        }
        guard !shelves.isEmpty else { return crowd }
        return crowd.enumerated().filter { !used.contains($0.offset) }.map { $0.element } + shelves
    }

    /// Clicking a shelf: steps into its apps together (for now: coming back
    /// up folds them back into the shelf), the one you clicked in front.
    private func openShelf(_ t: CrowdTile) {
        guard !busy, !onSurface, let first = t.shelfPanels.first,
              let loc = current.parent(of: first) else { return }
        let s = loc.split
        let indices = t.shelfPanels.compactMap { id in s.children.firstIndex { $0.id == id } }
        guard let lo = indices.min(), let hi = indices.max(), hi > lo else { return }
        // The shelf's tiles as a group of their own (the whole group, if that's all it is).
        let group: Split
        if lo == 0 && hi == s.children.count - 1 {
            // The shelf is the whole board: it's already all there is to see.
            if case .split(let top) = current.root, top === s { return }
            group = s
        } else {
            let shares = Array(s.ratios[lo...hi])
            let total = shares.reduce(0, +)
            group = Split(axis: s.axis, children: Array(s.children[lo...hi]))
            if total > 0 { group.ratios = shares.map { $0 / total } }
            s.children.replaceSubrange(lo...hi, with: [.split(group)])
            s.ratios.replaceSubrange(lo...hi, with: [total])
        }
        let focus = t.picked.flatMap { $0 < t.shelfWindows.count ? t.shelfWindows[$0] : nil } ?? t.shelfWindows.first
        guard let m = moveIntoGroup(group, rect: t.rect) else { return }
        perform(m) { [weak self] in
            if let w = focus { self?.windows.focus(w) }
        }
    }

    // MARK: Swipe up to inflate

    /// A frosted tile being swiped up: where its rows and columns started,
    /// where they're going, and how far along you are.
    private struct Inflate {
        let panel: UUID
        let splits: [(split: Split, start: [Double], target: [Double])]
        var travel: CGFloat = 0
        var finishing = false
    }
    private var inflating: Inflate?
    /// How far (points) a swipe goes for a whole inflate.
    private let inflateDistance: CGFloat = 200

    /// Two fingers up (or sideways) on a frosted tile: it grows to a size its app can use,
    /// following your fingers. A tile that's only short grows taller (one
    /// that's only narrow, wider); one that's small both ways grows both
    /// ways. The space comes from the tiles around it that can spare it.
    /// Let go past a third of the way and it finishes; before that, it
    /// settles back.
    func inflateGesture(_ t: CrowdTile, phase: SwipePhase, up: CGFloat) {
        guard !onSurface, !busy || inflating != nil else { return }
        switch phase {
        case .began:
            // Already under way (the tile was redrawn mid-swipe): carry on.
            if inflating != nil { return }
            inflating = planInflate(t)
            if inflating != nil { checkpoint() }   // Hyper + Z puts it back
            // Frosted by hand in a spot that's already roomy: nothing to
            // grow, it just comes back live.
            else if handFrost.contains(t.panel) {
                handFrost.remove(t.panel)
                applyLayout()
            }
        case .changed:
            guard var i = inflating, !i.finishing else { return }
            i.travel = max(0, i.travel + up)
            inflating = i
            let p = min(1, i.travel / inflateDistance)
            setInflate(p)
            liveLayout()
            // It fits now and has come back live: your fingers are over the
            // app itself from here on, so it finishes growing on its own.
            if !shownTiles.contains(where: { $0.panel == i.panel }) {
                finishInflate(from: p, keep: true)
            }
        case .ended:
            guard let i = inflating, !i.finishing else { return }
            let p = min(1, i.travel / inflateDistance)
            finishInflate(from: p, keep: p >= 0.33)
        }
    }

    enum SwipePhase { case began, changed, ended }

    private func setInflate(_ progress: CGFloat) {
        guard let i = inflating else { return }
        let f = Double(progress)
        for e in i.splits where e.start.count == e.split.ratios.count && e.target.count == e.start.count {
            e.split.ratios = zip(e.start, e.target).map { $0 + ($1 - $0) * f }
        }
    }

    /// Eases the rest of the way (or back), then lays out for real.
    private func finishInflate(from progress: CGFloat, keep: Bool) {
        inflating?.finishing = true
        let end: CGFloat = keep ? 1 : 0
        let frames = 10
        Task { @MainActor [weak self] in
            for k in 1...frames {
                guard let self else { return }
                let x = CGFloat(k) / CGFloat(frames)
                let eased = 1 - (1 - x) * (1 - x)
                self.setInflate(progress + (end - progress) * eased)
                self.liveLayout()
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard let self, let i = self.inflating else { return }
            if keep { for e in i.splits { e.split.seated = true } }
            if keep { self.handFrost.remove(i.panel) }
            self.inflating = nil
            self.windows.flushLive()
            self.applyLayout()
        }
    }

    /// Works out what inflating a tile would do: for each way it's too small
    /// for its app (or, for an app whose size isn't known yet, for a
    /// comfortable size), the nearest row or column running that way grows
    /// its share, taken from the others in proportion to what they can spare.
    private func planInflate(_ t: CrowdTile) -> Inflate? {
        // (The Desktop too: a frosted window on a Desktop too small unrolls it.)
        guard let placed = frames(current, in: viewport).first(where: { $0.panel.id == t.panel && $0.depth == 0 })
        else { return nil }
        let v = viewport
        let min = t.window != 0 ? windows.minSize(t.window) : nil
        // What it needs, within reason (never more than three quarters of the screen).
        let needW = Swift.min((min?.width ?? Swift.min(720, v.width * 0.5)) + gap, v.width * 0.75)
        let needH = Swift.min((min?.height ?? Swift.min(480, v.height * 0.5)) + gap, v.height * 0.75)
        let rects = splitRects()
        var plans: [(split: Split, start: [Double], target: [Double])] = []
        for axis in [Axis.h, .v] {
            let have = axis == .h ? placed.rect.width : placed.rect.height
            let need = axis == .h ? needW : needH
            guard need > have + 4 else { continue }
            // The nearest group running this way, and which of its members holds the tile.
            var id = placed.panel.id
            var found: (split: Split, index: Int)?
            while let loc = current.parent(of: id) {
                if loc.split.axis == axis { found = loc; break }
                id = loc.split.id
            }
            guard let loc = found, let area = rects[loc.split.id] else { continue }
            let s = loc.split
            let length = axis == .h ? area.width : area.height
            guard length > 1, s.ratios.indices.contains(loc.index) else { continue }
            let start = s.ratios
            let want = Swift.min(0.85, Double(need / length))
            let grow = want - start[loc.index]
            guard grow > 0.005 else { continue }
            var spare = [Double](repeating: 0, count: start.count)
            for (j, child) in s.children.enumerated() where j != loc.index && j < start.count && !holdsLocked(child) {
                let floor = Double(minLength(of: child, along: axis, apps: false) / length)
                spare[j] = Swift.max(0, start[j] - floor)
            }
            let total = spare.reduce(0, +)
            let take = Swift.min(grow, total)
            guard take > 0.005 else { continue }
            var target = start
            for j in target.indices where spare[j] > 0 { target[j] -= take * spare[j] / total }
            target[loc.index] += take
            plans.append((s, start, target))
        }
        guard !plans.isEmpty else { return nil }
        return Inflate(panel: placed.panel.id, splits: plans)
    }

    /// Where each group on the board you're on sits (its own pools only, not
    /// inside nested boards).
    private func splitRects() -> [UUID: CGRect] {
        var out: [UUID: CGRect] = [:]
        func walk(_ node: Node, _ r: CGRect) {
            guard case .split(let s) = node else { return }
            out[s.id] = r
            var pos: CGFloat = 0
            for item in shownChildren(s, of: current) {
                let f = item.share
                let cr = s.axis == .h
                    ? CGRect(x: r.minX + r.width * pos, y: r.minY, width: r.width * f, height: r.height)
                    : CGRect(x: r.minX, y: r.maxY - r.height * (pos + f), width: r.width, height: r.height * f)
                walk(item.node, cr)
                pos += f
            }
        }
        walk(current.root, viewport)
        return out
    }

    // MARK: More inside

    /// Tiles on the board you're on that hold a space with windows you can't
    /// see from here (hidden from above, in folded-away breathing room): each
    /// gets a "More inside" ball with the hidden app's icon. Background tabs
    /// don't count (the tab strip already shows them).
    private func moreInsideHints(_ placedAll: [Placed]) -> [MoreInside] {
        var out: [MoreInside] = []
        for placed in placedAll where placed.depth == 0 {
            guard let nested = placed.panel.desktop else { continue }
            let boards = boardIDs(in: nested)
            let inner = placedAll.filter { $0.depth >= 1 && boards.contains($0.owner.id) }
            let seen = Set(inner.flatMap { tabMembers($0.panel, of: $0.owner) })
            let hidden = nested.allWindows().filter { !seen.contains($0) && windows.exists($0) && !docked.contains($0) }
            guard !hidden.isEmpty else { continue }
            var unique: [UInt32] = []
            for w in hidden where !unique.contains(w) { unique.append(w) }
            out.append(MoreInside(rect: placed.rect.insetBy(dx: gap / 2, dy: gap / 2), panel: placed.panel.id,
                                  icons: unique.map { windows.appIcon($0) }, count: unique.count))
        }
        return out
    }

    /// The "More inside" hint, clicked: step into that tile.
    func stepInto(panel id: UUID) {
        guard !busy, !onSurface, let p = current.panel(id: id) else { return }
        zoomInto(p)
    }

    // MARK: Tabs

    /// How tall the strip of tabs along the top of a tabbed tile is.
    static let tabStripHeight: CGFloat = 30
    /// Dropping a window this far in from every edge of another window (as a
    /// share of it) makes it a tab there; nearer an edge it docks beside.
    static let tabZone: CGFloat = 0.2
    /// Once it's showing as a tab, how near an edge it has to get to stop.
    static let tabZoneHeld: CGFloat = 0.12
    /// The window a drag is currently showing as a tab with.
    private var tabCandidate: UInt32?

    /// Where a tabbed pool's strip of tabs goes (along its top), if it shows:
    /// two or more tabs, and room enough for a strip and a window under it.
    private func tabStripRect(for p: Panel, of owner: Desktop, in target: CGRect) -> CGRect? {
        guard p.tabs == true, p.free != true, p.desktop == nil,
              tabMembers(p, of: owner).count > 1,
              target.width >= Self.usableWidth, target.height >= Self.tabStripHeight + Self.usableHeight
        else { return nil }
        return CGRect(x: target.minX, y: target.maxY - Self.tabStripHeight,
                      width: target.width, height: Self.tabStripHeight)
    }

    /// What's left of a tile under its strip of tabs, for the window in front.
    private func tabBody(below strip: CGRect, in target: CGRect) -> CGRect {
        CGRect(x: target.minX, y: target.minY, width: target.width,
               height: max(1, strip.minY - target.minY - 4))
    }

    /// A tab's label: the window's title if it has one, else its app.
    private func tabTitle(_ w: UInt32) -> String {
        let app = windows.appName(w)
        guard let t = windows.title(of: w)?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t != app else { return app }
        return t
    }

    /// A tab's label in its strip: its app, plus the window's title when
    /// another tab there is the same app (two Safari windows, say).
    private func tabLabel(_ w: UInt32, among all: [UInt32]) -> String {
        let app = windows.appName(w)
        let twin = all.contains { $0 != w && windows.appName($0) == app }
        return twin ? tabTitle(w) : app
    }

    /// A short name for a tab: its app.
    private func tabName(_ w: UInt32) -> String { windows.appName(w) }

    /// Closes a window on a board the way its own close button does, and
    /// takes it off the board straight away (some apps only hide a closed
    /// window, which would otherwise linger). If its app asks something
    /// first (save changes?), the window comes forward to answer instead.
    func closeWindowHere(_ w: UInt32) {
        guard windows.exists(w) else { return }
        let name = windows.appName(w)
        windows.close(w)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.windows.refresh()
            if self.windows.exists(w), self.windows.hasSheet(w), !self.onSurface {
                if let p = self.chain(for: w)?.last, p.tabs == true, p.windows.count > 1 {
                    self.selectTab(w, in: p.id)
                } else {
                    self.spotlit = w
                    self.glideLayout()
                    self.windows.focus(w)
                }
                Toast.show("\(name) has a question before it closes", seconds: 1.6)
                return
            }
            if let p = self.chain(for: w)?.last, p.front == w { p.front = nil }
            self.remove(window: w)
            self.glideLayout()
        }
    }

    /// Makes `w` a tab of pool `p`, in front. Every window there fills the
    /// pool (tabs don't float).
    private func makeTab(_ w: UInt32, in p: Panel) {
        Coach.shared.note(.tabbed)
        if !p.windows.contains(w) { p.windows.append(w) }
        for x in p.windows { p.setFloat(x, nil) }
        p.tabs = true
        p.front = w
    }

    /// A window that's a tab behind another: puts it in front. True if it was behind.
    @discardableResult
    private func bringTabForward(_ w: UInt32) -> Bool {
        guard let p = chain(for: w)?.last, p.tabs == true, p.windows.count > 1, p.windows.contains(w) else { return false }
        let front = p.front.flatMap { p.windows.contains($0) ? $0 : nil } ?? p.windows.last
        guard front != w else { return false }
        p.front = w
        lastApplied[w] = nil
        return true
    }

    /// Clicking a tab: it comes to the front.
    func selectTab(_ w: UInt32, in panel: UUID) {
        guard !onSurface, !busy, let p = panelHere(panel), p.windows.contains(w) else { return }
        if p.front != w {
            p.front = w
            lastApplied[w] = nil
            applyLayout()
        }
        windows.focus(w)
    }

    /// Hyper + Shift + [ or ]: the previous or next tab in the tile you're using.
    func cycleTab(_ step: Int) {
        guard !onSurface, !busy, let w = windows.focusedWindowID(), let p = chain(for: w)?.last,
              p.tabs == true, p.windows.count > 1, let i = p.windows.firstIndex(of: w) else {
            Toast.show("No tabs here — drop a window onto the middle of another")
            return
        }
        let n = p.windows.count
        let next = p.windows[((i + step) % n + n) % n]
        selectTab(next, in: p.id)
    }

    /// Hyper + Shift + T: the window you're using joins the tile under the
    /// pointer as a tab; if it's already a tab, it pops back out to a tile
    /// of its own.
    func toggleTab() {
        guard !onSurface, !busy, let w = windows.focusedWindowID(), let c = chain(for: w), let mine = c.last else {
            Toast.show("Point at a window on a board first")
            return
        }
        if mine.tabs == true, mine.windows.count > 1 {
            popOutTab(w, from: mine.id)
            return
        }
        let m = NSEvent.mouseLocation
        guard let hit = dropPanels().filter({ $0.rect.contains(m) }).max(by: { $0.depth < $1.depth }),
              hit.panel.id != mine.id, hit.panel.free != true, hit.panel.desktop == nil,
              !shownWindows(hit.panel, of: hit.owner).isEmpty else {
            Toast.show("Point at the tile to tab \(windows.appName(w)) into")
            return
        }
        checkpoint()
        removeLive(w)
        pruneVacated()
        makeTab(w, in: hit.panel)
        for x in hit.panel.windows { lastApplied[x] = nil }
        state.lastPanelId = hit.panel.id
        glideLayout()
        windows.focus(w)
        Toast.show("\(windows.appName(w)) tabbed  ·  \(CapsKey.label) + Shift + [ ] to switch", seconds: 1.2)
    }

    /// A tab dragged out of its strip (or Hyper + Shift + T): a tile of its
    /// own beside the one it was in.
    func popOutTab(_ w: UInt32, from panel: UUID, before: Bool = false, axis: Axis? = nil) {
        guard !onSurface, !busy, let p = panelHere(panel), p.windows.contains(w), p.windows.count > 1,
              let found = state.root.deepFind(panel: panel) else { return }
        checkpoint()
        let rect = dropPanels().first { $0.panel.id == panel }?.rect ?? viewport
        // Where the tabs sit now: the tab coming out (and the one that comes
        // to the front in its place, if it was in front) starts right there,
        // so you see it slide out of the group into its own tile.
        let shownBefore = tabStripFront(p)
        let body = shownBefore.flatMap { windows.frame(of: $0) }
        p.windows.removeAll { $0 == w }
        p.setFloat(w, nil)
        if p.front == w { p.front = p.windows.last }
        if p.windows.count <= 1 { p.tabs = nil; p.front = nil }
        if let body {
            let nowFront = tabStripFront(p) ?? p.windows.first
            for x in [w, nowFront].compactMap({ $0 }) where windows.parked.contains(x) {
                windows.setFrame(x, body)
            }
            // The one coming out sits on top while it slides.
            windows.raise(w)
        }
        // Out to the side: a swipe left or right says which.
        let fresh = found.owner.addPanel(nextTo: p, axis: axis ?? screenShapedAxis(for: rect), before: before)
        fresh.windows = [w]
        // A tab that comes out is never frosted: its tile grows to a size its
        // app can use, from the tiles around it that can spare the room. With
        // no room to be had, it stays a tab.
        if found.owner === current {
            let stub = CrowdTile(rect: .zero, icon: nil, name: "", extra: 0, panel: fresh.id, owner: current.id, window: w)
            if let plan = planInflate(stub) { for e in plan.splits { e.split.ratios = e.target } }
            if let spot = frames(current, in: viewport).first(where: { $0.panel.id == fresh.id && $0.depth == 0 }),
               tooSmall([w], for: spot.rect.insetBy(dx: gap / 2, dy: gap / 2)) {
                undo()
                Toast.show("No room to pull \(windows.appName(w)) out here  ·  make some space first", seconds: 1.6)
                return
            }
        }
        for x in p.windows + [w] { lastApplied[x] = nil }
        state.lastPanelId = fresh.id
        glideLayout()
        windows.focus(w)
    }

    // MARK: Docking by approach (pools stay invisible)

    /// Dragging a window shows nothing but where it'll land: the windows
    /// already there make room as it comes close. Holding Shift while you
    /// drag shows the pools and their snap bars instead.
    var invisiblePools: Bool {
        get { UserDefaults.standard.bool(forKey: "invisiblePools") }
        set { UserDefaults.standard.set(newValue, forKey: "invisiblePools") }
    }

    /// The pool a live window sits in on the board on screen.
    private func placedPool(of w: UInt32) -> Placed? {
        guard let id = liveIn[w] else { return nil }
        return dropPanels().first { $0.panel.id == id }
    }

    /// Windows grow into the space a window leaves in their pool.
    var fillVacancies: Bool {
        get { UserDefaults.standard.bool(forKey: "fillVacancy") }
        set { UserDefaults.standard.set(newValue, forKey: "fillVacancy") }
    }

    /// The floats in a pool that change when `w` leaves it (nil: fills the
    /// pool), for previews and drop targets. See `vacancyChanges`.
    private func closingChanges(_ w: UInt32, in p: Panel, owner: Desktop, inner: CGRect) -> [UInt32: CGRect?] {
        vacancyChanges(w, in: p)
    }

    /// `w` is leaving pool `p`: the windows left behind grow into its space.
    private func fillVacancy(left w: UInt32, in p: Panel) {
        for (o, r) in vacancyChanges(w, in: p) {
            p.setFloat(o, r)
            lastApplied[o] = nil
        }
    }

    /// How the windows floating in a pool grow when `w` leaves it:
    /// - the windows right beside its spot that together cover that whole
    ///   side grow across it (the fewest that do: the one it was docked
    ///   beside, or the two stacked beside it);
    /// - otherwise, if a filled window is still there, it fits into the
    ///   space by itself and nothing changes;
    /// - otherwise (only floats left) they stretch as a group, keeping their
    ///   arrangement, to fill the pool.
    /// A float that ends up covering the whole pool goes back to filling it.
    private func vacancyChanges(_ w: UInt32, in p: Panel) -> [UInt32: CGRect?] {
        guard fillVacancies, p.free != true, p.windows.contains(w) else { return [:] }
        let others = p.windows.filter { $0 != w }
        guard !others.isEmpty else { return [:] }
        let floats = others.compactMap { o in p.floatRect(o).map { (window: o, rect: $0) } }
        let anyFilled = floats.count < others.count
        let tol: CGFloat = 0.04
        func settle(_ r: CGRect) -> CGRect? {
            (r.minX < tol && r.minY < tol && r.maxX > 1 - tol && r.maxY > 1 - tol) ? nil : r
        }
        var out: [UInt32: CGRect?] = [:]
        if let g = p.floatRect(w) {
            if let grown = edgeGroupGrowth(into: g, floats: floats, tol: tol) {
                for (o, r) in grown { out[o] = settle(r) }
                return out
            }
            guard !anyFilled else { return [:] }
        } else {
            // A filled window: any other filled window still fills the pool.
            guard !anyFilled else { return [:] }
        }
        guard let first = floats.first else { return [:] }
        let box = floats.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        guard box.width > 0.01, box.height > 0.01, box.width < 1 - tol || box.height < 1 - tol else { return [:] }
        for f in floats {
            let r = CGRect(x: (f.rect.minX - box.minX) / box.width, y: (f.rect.minY - box.minY) / box.height,
                           width: f.rect.width / box.width, height: f.rect.height / box.height)
            out[f.window] = settle(r)
        }
        return out
    }

    /// The floats right against one side of a vacated spot that together
    /// cover that whole side, grown across the spot. Nil if no side works.
    private func edgeGroupGrowth(into g: CGRect, floats: [(window: UInt32, rect: CGRect)],
                                 tol: CGFloat) -> [(UInt32, CGRect)]? {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < tol }
        func covers(_ spans: [(CGFloat, CGFloat)], _ lo: CGFloat, _ hi: CGFloat) -> Bool {
            var reach = lo
            for (a, b) in spans.sorted(by: { $0.0 < $1.0 }) {
                if a > reach + tol { return false }
                reach = max(reach, b)
            }
            return reach >= hi - tol
        }
        func inRows(_ f: CGRect) -> Bool { f.minY >= g.minY - tol && f.maxY <= g.maxY + tol }
        func inCols(_ f: CGRect) -> Bool { f.minX >= g.minX - tol && f.maxX <= g.maxX + tol }
        var options: [[(UInt32, CGRect)]] = []
        let left = floats.filter { near($0.rect.maxX, g.minX) && inRows($0.rect) }
        if !left.isEmpty, covers(left.map { ($0.rect.minY, $0.rect.maxY) }, g.minY, g.maxY) {
            options.append(left.map { ($0.window, CGRect(x: $0.rect.minX, y: $0.rect.minY,
                                                         width: g.maxX - $0.rect.minX, height: $0.rect.height)) })
        }
        let right = floats.filter { near($0.rect.minX, g.maxX) && inRows($0.rect) }
        if !right.isEmpty, covers(right.map { ($0.rect.minY, $0.rect.maxY) }, g.minY, g.maxY) {
            options.append(right.map { ($0.window, CGRect(x: g.minX, y: $0.rect.minY,
                                                          width: $0.rect.maxX - g.minX, height: $0.rect.height)) })
        }
        let below = floats.filter { near($0.rect.maxY, g.minY) && inCols($0.rect) }
        if !below.isEmpty, covers(below.map { ($0.rect.minX, $0.rect.maxX) }, g.minX, g.maxX) {
            options.append(below.map { ($0.window, CGRect(x: $0.rect.minX, y: $0.rect.minY,
                                                          width: $0.rect.width, height: g.maxY - $0.rect.minY)) })
        }
        let above = floats.filter { near($0.rect.minY, g.maxY) && inCols($0.rect) }
        if !above.isEmpty, covers(above.map { ($0.rect.minX, $0.rect.maxX) }, g.minX, g.maxX) {
            options.append(above.map { ($0.window, CGRect(x: $0.rect.minX, y: g.minY,
                                                          width: $0.rect.width, height: $0.rect.maxY - g.minY)) })
        }
        return options.min { $0.count < $1.count }
    }

    /// Where a pool's windows (all but `w`) would sit, in screen coordinates,
    /// with some floats changed and some extra floating areas to make room for.
    private func planned(_ placed: Placed, without w: UInt32, changes: [UInt32: CGRect?],
                         extra: [CGRect] = []) -> [(window: UInt32, rect: CGRect)] {
        let p = placed.panel
        let inner = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
        let others = shownWindows(p, of: placed.owner).filter {
            $0 != w && !onTop.contains($0) && !windows.parked.contains($0)
        }
        func rel(_ x: UInt32) -> CGRect? {
            if let c = changes[x] { return c }
            return p.floatRect(x)
        }
        let floats = others.compactMap { rel($0) }.map { absolute($0, in: inner) } + extra
        let filled = others.filter { rel($0) == nil }
        let plainFilled = filled.filter { p.floatRect($0) == nil }
        let fill = plainFilled.isEmpty ? inner
            : fillRect(for: p, in: inner, extra: floats, only: plainFilled)
        return others.map { x in (x, rel(x).map { absolute($0, in: inner) } ?? fill) }
    }

    /// Without pools on show: what dropping `w` here would do. Over an empty
    /// pool, it fills it. Near the edge of a window, it docks beside that
    /// window, which gives up the half on that side. In the middle of a
    /// window, or over open space in a pool, it floats where you let go.
    func dockTarget(at point: CGPoint, dragging w: UInt32, floating: Bool = false) -> DropTarget? {
        guard !isLocked(w) else { return nil }
        // Locked: nothing lands anywhere by dragging. Outside windows stay
        // outside until you punch one in (Hyper + P with the pointer on it).
        guard !placementsLocked else { return nil }
        if tileWindows, !floating { return tileTarget(at: point, dragging: w) }
        guard let hit = dropPanels().filter({ $0.rect.contains(point) }).max(by: { $0.depth < $1.depth })
        else { return nil }
        let r = hit.rect
        let inner = r.insetBy(dx: gap / 2, dy: gap / 2)
        func target(_ action: DropAction, _ highlight: CGRect, _ label: String, _ remaining: CGRect? = nil) -> DropTarget {
            DropTarget(panel: hit.panel, owner: hit.owner, action: action, panelRect: r, highlight: highlight,
                       label: label, remaining: remaining, panelLabel: hit.label, bars: [], activeBar: nil)
        }
        // The pool as it'll be once the dragged window has left its own spot.
        let changes = liveIn[w] == hit.panel.id ? closingChanges(w, in: hit.panel, owner: hit.owner, inner: inner) : [:]
        // Command held: float right where you let go, on top.
        if floating { return target(.float, r, "Float in pool \(hit.label)") }
        let spots = planned(hit, without: w, changes: changes)
        guard !spots.isEmpty else { return target(.fill, inner, "Pool \(hit.label)") }
        // The window under the pointer (a float on top of a filled one wins).
        let under = spots.filter { $0.rect.contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        guard let u = under else {
            // Open space in the pool: it takes the open space, beside the others.
            let open = fillRect(for: hit.panel, in: inner, extra: spots.map { $0.rect }, only: [w])
            return target(.fill, open, "Pool \(hit.label)")
        }
        let s = u.rect
        let fx = (point.x - s.minX) / max(s.width, 1), fy = (point.y - s.minY) / max(s.height, 1)
        // Docks on the side of the window you're nearest to (it never just
        // covers it: hold Command for that).
        let dx = min(fx, 1 - fx), dy = min(fy, 1 - fy)
        // Split the window's spot between the two. Apps that are known not to
        // shrink past a size get at least that (the other takes the rest);
        // if that can't work this way round, try the other way.
        let theirMin = windows.minSize(u.window) ?? .zero
        let myMin = windows.minSize(w) ?? .zero
        func split(sideways: Bool) -> (mine: CGRect, theirs: CGRect)? {
            let length = (sideways ? s.width : s.height) - gap
            let across = sideways ? s.height : s.width
            let floor: CGFloat = sideways ? 220 : 160
            let needMine = max(sideways ? myMin.width : myMin.height, floor)
            let needTheirs = max(sideways ? theirMin.width : theirMin.height, floor)
            guard needMine + needTheirs <= length,
                  across >= (sideways ? max(myMin.height, theirMin.height) : max(myMin.width, theirMin.width)) - 2
            else { return nil }
            var mineLen = length / 2
            if length - mineLen < needTheirs { mineLen = length - needTheirs }
            if mineLen < needMine { mineLen = needMine }
            let theirsLen = length - mineLen
            let first = sideways ? (fx < 0.5) : (fy < 0.5)   // mine goes left / at the bottom
            if sideways {
                let a = CGRect(x: s.minX, y: s.minY, width: first ? mineLen : theirsLen, height: s.height)
                let b = CGRect(x: a.maxX + gap, y: s.minY, width: s.width - a.width - gap, height: s.height)
                return first ? (a, b) : (b, a)
            } else {
                let a = CGRect(x: s.minX, y: s.minY, width: s.width, height: first ? mineLen : theirsLen)
                let b = CGRect(x: s.minX, y: a.maxY + gap, width: s.width, height: s.height - a.height - gap)
                return first ? (a, b) : (b, a)
            }
        }
        guard let pair = split(sideways: dx <= dy) ?? split(sideways: dx > dy) else {
            // Too small to share either way: float where you let go.
            return target(.float, r, "Float in pool \(hit.label)")
        }
        let (mine, theirs) = pair
        let action = DropAction.dock(rel: relative(mine, in: inner), partner: u.window,
                                     partnerRel: relative(theirs, in: inner))
        return target(action, mine, "Beside \(windows.appName(u.window))", theirs)
    }

    /// While a window is dragged away from its pool: where the windows it
    /// leaves behind go (the one docked beside it takes back the space).
    private func absenceMoves(of w: UInt32, unless target: DropTarget?) -> [(UInt32, CGRect)] {
        guard fillVacancies, let from = placedPool(of: w) else { return [] }
        // Over its own pool, the drop target already shows the pool without it.
        if let t = target, t.panel.id == from.panel.id { return [] }
        let inner = from.rect.insetBy(dx: gap / 2, dy: gap / 2)
        let changes = closingChanges(w, in: from.panel, owner: from.owner, inner: inner)
        guard !changes.isEmpty else { return [] }
        return planned(from, without: w, changes: changes).map { ($0.window, $0.rect) }
    }

    func drop(_ window: UInt32, on target: DropTarget) {
        if isLocked(window) || placementsLocked || (state.lockedBoards ?? []).contains(target.owner.id) {
            glideLayout()   // it glides back to its tile
            return
        }
        // An outside window placed on a board is part of it from now on.
        removeFloater(window)
        switch target.action {
        case .float, .desktop, .tab: break   // (tabs tell the coach themselves)
        default: Coach.shared.note(.docked)
        }
        onTop.remove(window)
        // Placing a window that's in Spotlight (a new one, say) ends Spotlight.
        if spotlit == window { spotlit = nil }
        switch target.action {
        case .tab:
            // Joins the tile it was dropped on, in front.
            checkpoint()
            let p = target.panel
            if !p.windows.contains(window) || p.tabs != true {
                removeLive(window)
                pruneVacated()
            }
            if target.owner.deepFind(panel: p.id) != nil {
                makeTab(window, in: p)
                for x in p.windows { lastApplied[x] = nil }
                state.lastPanelId = p.id
            } else {
                current.landingPanel().windows.append(window)
            }
            lastApplied[window] = nil
            glideLayout()
            windows.focus(window)
        case .peer(let before):
            // A peer in the small tile's strip, the same size as it.
            checkpoint()
            removeLive(window)
            pruneVacated()
            if target.owner.deepFind(panel: target.panel.id) != nil,
               let fresh = target.owner.addPeer(nextTo: target.panel, before: before) {
                fresh.windows = [window]
                state.lastPanelId = fresh.id
            } else {
                current.landingPanel().windows.append(window)
            }
            lastApplied[window] = nil
            glideLayout()
        case .tile(let axis, let before):
            // A tile of its own beside the window it was dropped on. The pool
            // it leaves goes first, exactly as the preview worked it out.
            checkpoint()
            removeLive(window)
            pruneVacated()
            if target.owner.deepFind(panel: target.panel.id) != nil {
                let fresh = target.owner.addPanel(nextTo: target.panel, axis: axis, before: before)
                fresh.windows = [window]
                state.lastPanelId = fresh.id
            } else {
                current.landingPanel().windows.append(window)
            }
            lastApplied[window] = nil
            glideLayout()
        case .edge(let axis, let before):
            // Along a whole side of the board, beside everything.
            checkpoint()
            removeLive(window)
            pruneVacated()
            let fresh = target.owner.addEdgePanel(axis: axis, before: before)
            fresh.windows = [window]
            state.lastPanelId = fresh.id
            lastApplied[window] = nil
            glideLayout()
        case .desktop:
            // Floats on the Desktop, right where you let go.
            checkpoint()
            let dropped = windows.frame(of: window)
            removeLive(window, reflow: false)
            pruneVacated()
            let p = target.panel
            if !p.windows.contains(window) { p.windows.append(window) }
            let rect = dropPanels().first { $0.panel.id == p.id }?.rect ?? target.panelRect
            let inner = rect.insetBy(dx: gap / 2, dy: gap / 2)
            p.setFloat(window, relative(dropped ?? inner, in: inner))
            lastApplied[window] = nil
            state.lastPanelId = p.id
            glideLayout()
        case .dock(let rel, let partner, let partnerRel):
            checkpoint()
            let p = target.panel
            removeLive(window)
            if p.windows.contains(partner) {
                p.setFloat(partner, partnerRel)
                lastApplied[partner] = nil
            }
            p.windows.append(window)
            p.setFloat(window, rel)
            lastApplied[window] = nil
            state.lastPanelId = p.id
            glideLayout()
        case .newPanel(let axis, let before):
            let fresh = target.owner.addPanel(nextTo: target.panel, axis: axis, before: before)
            put(window, in: fresh)
            Toast.show("\(windows.appName(window)) → new pool \(fresh.number)", seconds: 0.9)
        case .fill:
            // Dropped back onto its own pool (or its own tabs): it just settles back in.
            if target.panel.windows == [window] || (target.panel.tabs == true && target.panel.windows.contains(window)) {
                glideLayout()
                return
            }
            // Into empty breathing room: it becomes a tile of its own (not
            // a little Desktop to float in), and the room keeps the size it
            // has; nothing next to it takes its space back.
            if target.panel.scratch == true, target.panel.windows.isEmpty, target.panel.desktop == nil {
                target.panel.free = nil
                target.owner.parent(of: target.panel.id)?.split.seated = true
            }
            put(window, in: target.panel)
            if !(tileWindows && invisiblePools) {
                Toast.show("\(windows.appName(window)) → pool \(target.panelLabel)", seconds: 0.9)
            }
        case .float:
            // Keep it where you dropped it, as part of this panel.
            checkpoint()
            let inner = target.panelRect.insetBy(dx: gap / 2, dy: gap / 2)
            let dropped = windows.frame(of: window) ?? inner
            // Moved within its own pool: the others stay as they are.
            removeLive(window, reflow: liveIn[window] != target.panel.id)
            target.panel.windows.append(window)
            target.panel.setFloat(window, relative(dropped, in: inner))
            state.lastPanelId = target.panel.id
            glideLayout()
        }
    }

    /// Tiles you frosted by hand (Hyper + F on a live tile). They stay
    /// frosted, whatever their size, until you unfrost them (Hyper + F
    /// again, or a swipe up on the tile).
    private var handFrost = Set<UUID>()

    /// Hyper + F: frost or unfrost the tile under the pointer.
    /// On a live tile, frosts it: the app tucks away behind its frosted
    /// picture, so you can keep it in view, squeeze it small, or gather it
    /// with other frosted tiles. On a frosted tile, unfrosts it, and also
    /// forgets the frost Scuba remembered and the smallest sizes it learned
    /// for the apps inside (so a tile that got stuck comes back live). A spot
    /// that really is too small to use frosts again.
    func toggleFrostHere() {
        guard !onSurface, !busy else { return }
        Coach.shared.note(.frostToggled)
        let point = NSEvent.mouseLocation
        let placedAll = frames(current, in: viewport)
        if let t = shownTiles.first(where: { $0.rect.contains(point) }),
           let hit = placedAll.first(where: { $0.panel.id == t.panel }) {
            unfrost(hit)
            return
        }
        guard let hit = placedAll.filter({ $0.rect.contains(point) }).max(by: { $0.depth < $1.depth }) else {
            Toast.show("Point at a tile to frost or unfrost it", seconds: 1.2)
            return
        }
        let p = hit.panel
        guard p.free != true else {
            Toast.show("Desktop windows don't frost — dock it in a tile first", seconds: 1.4)
            return
        }
        guard !shownWindows(p, of: hit.owner).isEmpty else {
            Toast.show("Nothing here to frost", seconds: 1.0)
            return
        }
        checkpoint()   // Hyper + Z puts it back
        handFrost.insert(p.id)
        applyLayout()
        Toast.show("Frosted \(displayName(p)) — \(CapsKey.label) + F or swipe up to bring it back", seconds: 1.4)
    }

    private func unfrost(_ hit: Placed) {
        let p = hit.panel
        // Unfrosting into a spot too small for the app: the tiles around it
        // make room, down to their own smallest sizes, so it opens at a size
        // it can use (worked out before the sizes on record are forgotten).
        var growPlan: Inflate?
        if hit.owner === current, hit.depth == 0, inflating == nil,
           let main = shownWindows(p, of: hit.owner).first {
            let stub = CrowdTile(rect: .zero, icon: nil, name: "", extra: 0, panel: p.id, owner: current.id, window: main)
            let spot = hit.rect.insetBy(dx: gap / 2, dy: gap / 2)
            if tooSmall([main], for: spot) || windows.minSize(main) == nil && (spot.width < 480 || spot.height < 320) {
                growPlan = planInflate(stub)
            }
        }
        if growPlan != nil { checkpoint() }   // Hyper + Z puts the tiles back
        handFrost.remove(p.id)
        var list = Set(p.windows)
        list.formUnion(tabMembers(p, of: hit.owner))
        stickyFrost[p.id] = nil
        for w in list {
            windows.forgetMinimum(w)
            overflowAt[w] = nil
            overflowSeen[w] = nil
            frostChecked[w] = nil
            pictureFailed.remove(w)
        }
        if let growPlan {
            settleGrow(growPlan)
            glideLayout()
            Toast.show("Unfrosted \(displayName(p))  ·  the tiles around it made room", seconds: 1.2)
            return
        }
        applyLayout()
        let r = hit.rect
        if r.width < Self.usableWidth || r.height < Self.usableHeight {
            Toast.show("Unfrosted — but this spot is too small to use, so it frosts again. Widen it first.", seconds: 1.8)
        } else {
            Toast.show("Unfrosted \(displayName(p))", seconds: 1.0)
        }
    }

    /// Hyper + Shift + F: switch the focused window between floating and filling.
    func toggleFloat() {
        guard let w = windows.focusedWindowID() else {
            Toast.show("Put the window in a pool first")
            return
        }
        toggleFloat(w)
    }

    func toggleFloat(_ w: UInt32) {
        guard let c = chain(for: w), let p = c.last else {
            Toast.show("Put the window in a pool first")
            return
        }
        guard p.free != true else {
            Toast.show("Windows on the Desktop always float — drag it to a screen edge to dock it")
            return
        }
        checkpoint()
        onTop.remove(w)
        if p.floatRect(w) != nil {
            p.setFloat(w, nil)
            Toast.show("Fills the pool", seconds: 0.8)
        } else {
            p.setFloat(w, CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7))
            Toast.show("Floating in the pool", seconds: 0.8)
        }
        lastApplied[w] = nil
        glideLayout()
    }

    // MARK: The green button

    /// The green button on a window docks and floats it, instead of going
    /// full screen (Option + click keeps macOS's own).
    var greenButtonDocks: Bool {
        get { UserDefaults.standard.bool(forKey: "greenButtonDocks") }
        set { UserDefaults.standard.set(newValue, forKey: "greenButtonDocks") }
    }

    /// The side of the board a window's tile was nearest to when the green
    /// button floated it: the green button docks it back along that side.
    private var greenHome: [UInt32: (axis: Axis, before: Bool)] = [:]

    /// The green button, clicked on a window of the board you're on.
    /// - Docked: it floats on the board's Desktop (with no Desktop here, it
    ///   floats in its own tile instead).
    /// - On the Desktop: it docks again, along the side it came from (the
    ///   right, if it never was docked); the windows around make room.
    /// - Floating in a tile: it fills the tile.
    /// False when it isn't Scuba's to handle (macOS goes full screen).
    func greenButton(_ w: UInt32) -> Bool {
        guard greenButtonDocks, !busy, !onSurface, !gliding, spotlit != w,
              let placed = frames(current, in: viewport)
                .first(where: { $0.depth == 0 && $0.panel.desktop == nil && $0.panel.windows.contains(w) })
        else { return false }
        let p = placed.panel, board = placed.owner
        if p.free == true {
            checkpoint()
            let side = greenHome[w] ?? (axis: .h, before: false)
            greenHome[w] = nil
            p.windows.removeAll { $0 == w }
            p.setFloat(w, nil)
            let fresh = board.addEdgePanel(axis: side.axis, before: side.before)
            fresh.windows = [w]
            lastApplied[w] = nil
            onTop.remove(w)
            glideLayout()
            Toast.show("Docked — the windows around it made room", seconds: 1.0)
            return true
        }
        guard let desk = board.freePanel() else {
            toggleFloat(w)
            return true
        }
        checkpoint()
        // Which side of the board the tile was nearest to.
        let r = placed.rect, v = viewport
        let gaps: [(CGFloat, Axis, Bool)] = [(r.minX - v.minX, .h, true), (v.maxX - r.maxX, .h, false),
                                             (v.maxY - r.maxY, .v, true), (r.minY - v.minY, .v, false)]
        if let near = gaps.min(by: { $0.0 < $1.0 }) { greenHome[w] = (axis: near.1, before: near.2) }
        remove(window: w)
        desk.tucked = nil
        desk.windows.append(w)
        desk.setFloat(w, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        lastApplied[w] = nil
        glideLayout()
        Toast.show("Floating on the Desktop  ·  the green button docks it again", seconds: 1.3)
        return true
    }

    // MARK: Dividers

    /// A gap between two neighboring members of a split.
    struct Divider {
        let split: Split
        let index: Int          // between children index and index + 1
        let axis: Axis          // .h = a vertical line between side-by-side members
        let frame: CGRect       // the whole split's area (AppKit coordinates)
        let position: CGFloat   // x of the line for .h, y for .v
        /// The member on the other side of the gap (the next one shown: a
        /// folded-away member in between is skipped). -1: index + 1.
        var next: Int = -1
        /// The board the group is on.
        var owner: Desktop? = nil
    }

    /// Every divider on screen, including those inside nested desktops.
    func dividers() -> [Divider] { dividers(of: current, in: viewport) }

    /// A board's dividers laid out in any rectangle (the live map uses this).
    func dividers(of board: Desktop, in area: CGRect) -> [Divider] {
        var out: [Divider] = []
        func walk(_ node: Node, _ r: CGRect, _ owner: Desktop) {
            switch node {
            case .panel(let p):
                if let nested = p.desktop { walk(nested.root, r.insetBy(dx: gap / 2, dy: gap / 2), nested) }
            case .split(let s):
                // A folded-away member (breathing room, a tucked Desktop) gives
                // its space to the rest; the gaps between the ones you can see
                // still drag.
                let items = shownChildren(s, of: owner)
                var pos: CGFloat = 0
                for (k, item) in items.enumerated() {
                    let f = item.share
                    let cr: CGRect
                    if s.axis == .h {
                        cr = CGRect(x: r.minX + r.width * pos, y: r.minY, width: r.width * f, height: r.height)
                    } else {
                        cr = CGRect(x: r.minX, y: r.maxY - r.height * (pos + f), width: r.width, height: r.height * f)
                    }
                    walk(item.node, cr, owner)
                    pos += f
                    if k < items.count - 1 {
                        let at = s.axis == .h ? r.minX + r.width * pos : r.maxY - r.height * pos
                        out.append(Divider(split: s, index: item.index, axis: s.axis, frame: r, position: at,
                                           next: items[k + 1].index, owner: owner))
                    }
                }
            }
        }
        walk(board.root, area, board)
        return out
    }

    /// The divider closest to a point, if one is within `tolerance` points.
    func divider(near p: CGPoint, tolerance: CGFloat) -> Divider? {
        // Where the gap shows: a window that runs past its tile covers the
        // gap Scuba has on record, so the one you see is at its edge.
        func distance(_ d: Divider) -> CGFloat? {
            if d.axis == .h {
                guard p.y >= d.frame.minY, p.y <= d.frame.maxY else { return nil }
                return abs(p.x - shownPosition(d))
            } else {
                guard p.x >= d.frame.minX, p.x <= d.frame.maxX else { return nil }
                return abs(p.y - shownPosition(d))
            }
        }
        var best: (Divider, CGFloat)?
        for d in dividers() where gapMoves(d) {
            guard let dist = distance(d), dist <= tolerance else { continue }
            if best == nil || dist < best!.1 { best = (d, dist) }
        }
        return best?.0
    }

    /// Where a gap shows on screen. A window that won't shrink to its tile
    /// (Music, say) runs past the gap on record and covers it, and the
    /// frosted tile beside it gives way: the gap you see, where the pill goes
    /// and where you grab it, is at that window's edge. Grabbing it there
    /// brings the gap on record to your hand, so the tiles catch up at once.
    func shownPosition(_ d: Divider) -> CGFloat {
        let j = d.next >= 0 ? d.next : d.index + 1
        guard d.index < d.split.children.count, j < d.split.children.count else { return d.position }
        // The gap in your hand is where your hand is.
        if let g = draggingGap, g.split == d.split.id, g.index == d.index { return d.position }
        let before = Set(panelsIn(d.split.children[d.index]).map { $0.id })
        let after = Set(panelsIn(d.split.children[j]).map { $0.id })
        let half = gap / 2
        var at = d.position
        for (w, pid) in liveIn where w != spotlit && w != edgeWindow {
            let isBefore = before.contains(pid)
            guard isBefore || after.contains(pid), let f = settledFrames[w] else { continue }
            // Only a window that actually reaches across this gap.
            if d.axis == .h {
                guard f.maxY > d.frame.minY + half, f.minY < d.frame.maxY - half else { continue }
                if isBefore { at = max(at, f.maxX + half) } else { at = min(at, f.minX - half) }
            } else {
                guard f.maxX > d.frame.minX + half, f.minX < d.frame.maxX - half else { continue }
                // Stacked: the first member is on top (AppKit's y points up).
                if isBefore { at = min(at, f.minY - half) } else { at = max(at, f.maxY + half) }
            }
        }
        return d.axis == .h ? min(max(at, d.frame.minX), d.frame.maxX)
                            : min(max(at, d.frame.minY), d.frame.maxY)
    }

    /// The gap you're dragging (its pill follows your hand).
    var draggingGap: (split: UUID, index: Int)?

    /// Where each live window really is, read once things have settled after
    /// a layout, never while you drag: asking apps where their windows are
    /// on every frame of a drag made it stutter.
    private var settledFrames: [UInt32: CGRect] = [:]
    private var settleRead: Task<Void, Never>?

    /// After a layout: where windows were sent, at once; where they really
    /// ended up (an app that won't shrink stays bigger), a moment later.
    private func noteSettledFrames() {
        var sent: [UInt32: CGRect] = [:]
        for w in liveIn.keys { if let t = windows.target(of: w) { sent[w] = t } }
        settledFrames = sent
        settleRead?.cancel()
        settleRead = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled, self.draggingGap == nil, self.edgeWindow == nil,
                  !self.onSurface, !self.busy else { return }
            var real: [UInt32: CGRect] = [:]
            for w in self.liveIn.keys { if let f = self.windows.frame(of: w) { real[w] = f } }
            guard real != self.settledFrames else { return }
            self.settledFrames = real
            self.showBounds()
        }
    }

    /// A gap that can move: not on a board with its placements locked, and
    /// not beside a window locked in place.
    func gapMoves(_ d: Divider) -> Bool {
        if (state.lockedBoards ?? []).contains(d.owner?.id ?? current.id) { return false }
        let j = d.next >= 0 ? d.next : d.index + 1
        guard d.index < d.split.children.count, j < d.split.children.count else { return false }
        return !holdsLocked(d.split.children[d.index]) && !holdsLocked(d.split.children[j])
    }

    /// Moves a divider so it sits under the given point.
    func moveDivider(_ d: Divider, to p: CGPoint) {
        guard gapMoves(d) else { return }
        let s = d.split
        let i = d.index
        let j = d.next >= 0 ? d.next : i + 1
        guard i < j, j < s.ratios.count else { return }
        let t = d.axis == .h
            ? Double((p.x - d.frame.minX) / d.frame.width)
            : Double((d.frame.maxY - p.y) / d.frame.height)
        // Worked out in shares as shown: folded-away members take no space.
        let shown = shownChildren(s, of: d.owner)
        let total = shown.reduce(0.0) { $0 + s.ratios[$1.index] }
        guard total > 0 else { return }
        var before = 0.0
        for item in shown where item.index < i { before += s.ratios[item.index] / total }
        let after = before + (s.ratios[i] + s.ratios[j]) / total
        // Your hand decides: a side can go smaller than its app will (that
        // app frosts over until there's room for it again), just never to a
        // sliver.
        let length = Double(d.axis == .h ? d.frame.width : d.frame.height)
        guard length > 1 else { return }
        // Empty space (and the Desktop) can be pushed all the way closed;
        // tiles with windows keep at least a sliver.
        func floor(_ n: Node) -> Double {
            let m = Double(minLength(of: n, along: d.axis, apps: false))
            return m == 0 ? 0.002 : max(0.05, m / length)
        }
        let minBefore = floor(s.children[i])
        let minAfter = floor(s.children[j])
        guard before + minBefore <= after - minAfter else { return }
        let clamped = min(max(t, before + minBefore), after - minAfter)
        s.ratios[i] = (clamped - before) * total
        s.ratios[j] = (after - clamped) * total
        s.seated = true
    }

    /// After you let go of a gap or an edge: empty space you've pushed
    /// (nearly) closed goes, so nothing is held open as a sliver. Breathing
    /// room and empty tiles fold away; the Desktop tucks out of the layout,
    /// its floating windows with it, until Hyper + B brings it back.
    func settleEmpty() {
        guard !onSurface else { return }
        let d = current
        var tuckedDesk = false
        for placed in frames(d, in: viewport) where placed.depth == 0 {
            let p = placed.panel
            guard p.desktop == nil, p.tucked != true, p.free == true || p.windows.isEmpty,
                  let loc = d.parent(of: p.id) else { continue }
            let length = loc.split.axis == .h ? placed.rect.width : placed.rect.height
            guard length < 48 else { continue }
            if p.free == true {
                p.tucked = true
                tuckedDesk = true
            } else if p.scratch == true {
                d.removeRoom(p)
            } else {
                _ = d.pruneTile(p)
            }
        }
        if tuckedDesk { Toast.show("Desktop tucked away  ·  the menu bar brings it back", seconds: 1.4) }
    }

    /// How small part of a board can get along one direction: no pool
    /// narrower than 220 points (shorter than 160), nor smaller than the
    /// windows in it are known to go.
    private func minLength(of node: Node, along axis: Axis, apps: Bool = true) -> CGFloat {
        // Without the apps' own minimums: small enough to frost, still big
        // enough to see what's there and click it.
        let floor: CGFloat = apps ? (axis == .h ? 220 : 160) : (axis == .h ? 140 : 100)
        switch node {
        case .panel(let p):
            // Available space is available: nothing holds empty space (or
            // the Desktop) open against a window being dragged into it.
            if !apps, p.desktop == nil, p.free == true || p.windows.isEmpty { return 0 }
            if p.desktop != nil || !apps { return floor }
            let known = p.windows.compactMap { windows.minSize($0) }.map { axis == .h ? $0.width : $0.height }
            return max(floor, known.max() ?? 0)
        case .split(let sp):
            let parts = sp.children.map { minLength(of: $0, along: axis, apps: apps) }
            return sp.axis == axis ? parts.reduce(0, +) + gap * CGFloat(max(parts.count - 1, 0)) : (parts.max() ?? floor)
        }
    }

    // MARK: Zooming

    func zoomInto(panel number: Int) {
        guard let p = current.panel(number: number) else { Toast.show("There's no pool \(number) here"); return }
        zoomInto(p)
    }

    /// Jumps straight into one of the top-level panels, from any depth.
    func jumpToTopPanel(_ number: Int) {
        guard !busy else { return }
        guard let p = state.root.panel(number: number) else {
            Toast.show("There's no top-level pool \(number)")
            return
        }
        if onSurface {
            makeBoard(of: p)
            enterBoards(at: [p.id])
            return
        }
        if state.path.isEmpty {
            zoomInto(p)          // already at the top: a normal zoom-in
            return
        }
        if state.path == [p.id] { Toast.show(locationLabel()); return }
        makeBoard(of: p)
        navigate(to: [p.id])
    }

    func zoomInto(_ p: Panel) {
        guard !busy, let m = moveInto(p) else { return }
        perform(m)
    }

    func zoomOut() {
        guard !state.path.isEmpty else { surface(); return }
        navigate(to: Array(state.path.dropLast()))
    }

    func zoomToTop() {
        if onSurface { enterBoards(at: []) } else { navigate(to: []) }
    }

    func goHome() {
        // Home is on another Main: go across to it.
        if let hm = state.homeMain, hm != state.root.id, allMains.contains(where: { $0.id == hm }) {
            if onSurface {
                let all = allMains
                if let i = all.firstIndex(where: { $0.id == hm }) { setMains(all, current: i) }
                normalizePath()
                enterBoards(at: state.home ?? [])
            } else if !busy {
                let i = allMains.firstIndex(where: { $0.id == hm }) ?? 0
                playSideways(mainSwitch(to: hm, direction: i > mainPosition ? 1 : -1, landing: state.home ?? []))
            }
            return
        }
        if onSurface { enterBoards(at: state.home ?? []) } else { navigate(to: state.home ?? []) }
    }

    // MARK: Surface

    /// Dives from the Surface into your boards, back where you left off
    /// (or at `path`).
    func enterBoards(at path: [UUID]? = nil) {
        guard onSurface, !busy, let m = moveEnter(at: path) else { return }
        perform(m)
    }

    /// Hyper + Esc: come up for air. Boards tuck away, your desktop returns.
    func surface() {
        guard !onSurface, !busy, let m = moveSurface() else { return }
        perform(m)
    }

    // MARK: Moves

    /// One zoom step, worked out before it happens: where the deeper view
    /// sits inside the shallower one, and the change that makes it happen.
    /// A move can be played (keys, clicks) or steered (trackpad).
    struct Move {
        let zoomIn: Bool
        let target: CGRect      // AppKit screen coordinates
        let toKey: String       // where it ends up, for remembered pictures
        /// Say where you ended up once it lands.
        var announce = true
        let change: () -> Void
    }

    /// A name for a place, for the animator's remembered pictures.
    private func placeKey(_ path: [UUID]?, main: UUID? = nil) -> String {
        guard let path else { return "surface" }
        return "board:" + ([main ?? state.root.id] + path).map { $0.uuidString }.joined(separator: "/")
    }
    private var hereKey: String { placeKey(onSurface ? nil : state.path) }

    private var surfaceTarget: CGRect {
        let vf = screen.visibleFrame
        return vf.insetBy(dx: vf.width * 0.25, dy: vf.height * 0.25)
    }

    /// Diving into a panel of the board on screen.
    private func moveInto(_ p: Panel) -> Move? {
        guard !onSurface else { return nil }
        if p.free == true, p.scratch != true, !tileWindows {
            Toast.show("That's the Desktop: windows float there. Drag one to a screen edge to dock it", seconds: 1.4)
            return nil
        }
        // The only panel here (breathing room aside) already fills the screen;
        // another level would add nothing. The breathing room itself is a
        // fresh, empty place, so you can always dive into that.
        if isAsFarIn(p) {
            Toast.show("Already as far in as it goes")
            return nil
        }
        guard let target = rect(ofTopPanel: p.id) else { return nil }
        let newPath = state.path + [p.id]
        return Move(zoomIn: true, target: target, toKey: placeKey(newPath)) {
            // First time in: the panel becomes a board of its own.
            self.makeBoard(of: p)
            self.state.path = newPath
            self.addBreathingRoom(entering: target)
        }
    }

    // MARK: One tree, one camera

    /// Diving toward a point goes one level of the board's tree at a time:
    /// into the part of the board right under its top that holds the point.
    /// That's a single pool, or a whole group of tiles, which the camera
    /// frames as a lens without changing the board.
    private func moveStep(at point: CGPoint) -> Move? {
        let placed = frames(current, in: viewport).filter { $0.depth == 0 }
        // Every window its own tile: straight into the tile under your
        // fingers (a group of tiles is Cmd + Shift + drag a box). Breathing
        // room is yours to open (Hyper + B), not opened for you.
        // Breathing room counts as a tile here: it's a place of its own to dive
        // into, never a reason to take the tiles around it along.
        if tileWindows, let hit = placed.first(where: {
            $0.rect.contains(point) && ($0.panel.free != true || $0.panel.scratch == true)
        }) {
            return moveInto(hit.panel)
        }
        guard tileWindows, case .split(let top) = current.root else {
            return placed.first { $0.rect.contains(point) }.flatMap { moveInto($0.panel) }
        }
        for item in shownChildren(top, of: current) {
            let ids = Set(panelsIn(item.node).map { $0.id })
            let rects = placed.filter { ids.contains($0.panel.id) }.map { $0.rect }
            guard let first = rects.first else { continue }
            let box = rects.dropFirst().reduce(first) { $0.union($1) }
            guard box.contains(point) else { continue }
            switch item.node {
            case .panel(let p): return moveInto(p)
            case .split(let g): return moveIntoGroup(g, rect: box)
            }
        }
        return placed.first { $0.rect.contains(point) }.flatMap { moveInto($0.panel) }
    }

    // MARK: Framing: drag a box, double-click to focus

    /// Cmd + Shift + drag a box to frame part of the board.
    var frameDrag: Bool {
        get { UserDefaults.standard.bool(forKey: "frameDrag") }
        set { UserDefaults.standard.set(newValue, forKey: "frameDrag") }
    }

    /// What a box drawn over the board frames: the smallest part of the
    /// board that holds everything the box takes in (a tile, a group of
    /// tiles, the Desktop). Nil when it takes in nothing, or the whole board
    /// you're already looking at.
    /// What a box drawn over the board takes in: the tiles it covers a good
    /// part of (or that hold all of it), as one run of neighbours in their
    /// group. With tiles from more than one group, the run covers the
    /// smallest group holding them all, from the first to the last. Nil for
    /// nothing, or the whole board.
    private struct BoxRun {
        let split: Split?      // the group the run is in (nil: one tile on its own)
        let lo: Int, hi: Int   // which of its members
        let single: Panel?     // a lone tile
        let rect: CGRect
    }

    private func boxRun(for box: CGRect) -> BoxRun? {
        let placed = frames(current, in: viewport).filter { $0.depth == 0 }
        let hit = placed.filter { p in
            let i = p.rect.intersection(box)
            guard !i.isNull else { return false }
            return i.width * i.height >= p.rect.width * p.rect.height * 0.25 || p.rect.contains(box)
        }
        guard let one = hit.first else { return nil }
        if hit.count == 1 {
            if case .panel(let only) = current.root, only === one.panel { return nil }   // the whole board
            return BoxRun(split: nil, lo: 0, hi: 0, single: one.panel, rect: one.rect)
        }
        // Their lowest common group, and the run of its members they're in.
        let chains = hit.map { h in current.ancestors(of: h.panel.id) }
        guard let g = chains[0].map({ $0.split }).first(where: { g in
            chains.allSatisfy { c in c.contains { $0.split === g } }
        }) else { return nil }
        let indices = chains.compactMap { c in c.first { $0.split === g }?.index }
        guard let lo = indices.min(), let hi = indices.max() else { return nil }
        let whole = lo == 0 && hi == g.children.count - 1
        if whole, case .split(let top) = current.root, top === g { return nil }   // the whole board
        let inside = Set((lo...hi).flatMap { panelsIn(g.children[$0]) }.map { $0.id })
        let rects = placed.filter { inside.contains($0.panel.id) }.map { $0.rect }
        guard let r0 = rects.first else { return nil }
        return BoxRun(split: g, lo: lo, hi: hi, single: nil, rect: rects.dropFirst().reduce(r0) { $0.union($1) })
    }

    /// Where a box drawn over the board would frame (for its outline).
    func frameTarget(for box: CGRect) -> CGRect? { boxRun(for: box)?.rect }

    /// A box drawn over some windows (Cmd + Shift + drag): those windows
    /// become a room of their own, and you dive straight into it. The room
    /// stays (it doesn't fold back up when you leave); Hyper + Z undoes it.
    func frameZoom(to box: CGRect) {
        guard !busy, !onSurface, let run = boxRun(for: box) else { return }
        checkpoint()
        let board = current
        // The node that becomes the room: a lone tile, a whole group, or a
        // run of a group's members gathered into a group of their own.
        let node: Node
        if let p = run.single {
            node = .panel(p)
        } else if let g = run.split {
            if run.lo == 0 && run.hi == g.children.count - 1 {
                node = .split(g)
            } else {
                let members = Array(g.children[run.lo...run.hi])
                let shares = Array(g.ratios[run.lo...run.hi])
                let total = shares.reduce(0, +)
                let group = Split(axis: g.axis, children: members)
                group.ratios = total > 0 ? shares.map { $0 / total } : group.ratios
                g.children.replaceSubrange(run.lo...run.hi, with: [.split(group)])
                g.ratios.replaceSubrange(run.lo...run.hi, with: [total])
                node = .split(group)
            }
        } else { return }
        let room = Panel(number: panelsIn(node).map { $0.number }.min() ?? board.nextNumber())
        let newPath = state.path + [room.id]
        let count = panelsIn(node).reduce(0) { $0 + $1.windows.count }
        perform(Move(zoomIn: true, target: run.rect, toKey: placeKey(newPath)) {
            room.desktop = Desktop(root: node)
            board.replace(node.id, with: .panel(room))
            self.state.path = newPath
        }) {
            Toast.show("New room · \(count) window\(count == 1 ? "" : "s")  ·  \(CapsKey.label) + ↓ to come back up", seconds: 1.6)
        }
    }

    /// True when the board on screen is a lens on a single pool (a tile, or
    /// the Desktop) you zoomed in on.
    private var focusedOnOne: Bool {
        guard let last = state.path.last, let parent = desktopStack().dropLast().last,
              let holder = parent.panel(id: last), holder.lens == true,
              case .panel(_) = current.root else { return false }
        return true
    }

    /// Double-click a docked window's title bar: zoom in on it, so it has the
    /// screen; again, back to where you were. On the Desktop (or with tiles
    /// off), it goes into Spotlight as before. False if it's not for us.
    func focusDoubleClick(_ w: UInt32) -> Bool {
        guard !busy, !onSurface else { return false }
        guard tileWindows else {
            spotlight(w)
            return true
        }
        if focusedOnOne, current.panels().first?.windows.contains(w) == true {
            zoomOut()
            return true
        }
        guard let pid = liveIn[w], let p = current.panel(id: pid), p.free != true,
              current.panels().count > 1 else {
            spotlight(w)
            return true
        }
        zoomInto(p)
        return true
    }

    /// Double-click the Desktop's bare wallpaper: zoom in on the Desktop;
    /// again, back to where you were.
    func desktopDoubleClick(at point: CGPoint) -> Bool {
        guard tileWindows, !busy, !onSurface else { return false }
        if focusedOnOne, current.panels().first?.free == true {
            zoomOut()
            return true
        }
        guard current.panels().count > 1,
              let desk = frames(current, in: viewport).first(where: {
                  $0.depth == 0 && $0.panel.free == true && $0.rect.contains(point)
              }) else { return false }
        zoomInto(desk.panel)
        return true
    }

    /// The pools in part of a board's tree (not the boards inside them).
    private func panelsIn(_ node: Node) -> [Panel] {
        switch node {
        case .panel(let p): return [p]
        case .split(let s): return s.children.flatMap { panelsIn($0) }
        }
    }

    /// Zooming into a group of tiles: the group becomes, for now, a board of
    /// its own (a lens on that part of the board), and the camera frames it.
    private func moveIntoGroup(_ g: Split, rect: CGRect) -> Move? {
        guard !onSurface else { return nil }
        let board = current
        let lens = Panel(number: panelsIn(.split(g)).map { $0.number }.min() ?? board.nextNumber())
        lens.lens = true
        lens.lensRooms = panelsIn(.split(g)).filter { $0.scratch == true }.map { $0.id }
        let newPath = state.path + [lens.id]
        return Move(zoomIn: true, target: rect, toKey: placeKey(newPath)) {
            lens.desktop = Desktop(root: .split(g))
            board.replace(g.id, with: .panel(lens))
            self.state.path = newPath
        }
    }

    /// Lenses you've come back up out of fold back into the board above, so
    /// a tile or group is just part of that board again. One that's become a
    /// place of its own stays a board: it has a Desktop or breathing room, a
    /// name or wallpaper, hidden windows, or it's Home.
    private func foldLenses() {
        let onPath = Set(state.path)
        let home = Set(state.home ?? [])
        let hidden = Set(state.insideOnly ?? [])
        func fold(in d: Desktop) {
            for p in d.panels() {
                guard let nested = p.desktop else { continue }
                fold(in: nested)   // the innermost first
                guard p.lens == true, !onPath.contains(p.id), !home.contains(p.id),
                      nested.wallpaper == nil, nested.name == nil,
                      // (The board's own Desktop can be part of a group you zoomed into;
                      // breathing room made in there makes it a place.)
                      // (Rooms it was made around don't count, nor in lenses
                      // from older builds, which wrapped rooms by mistake.)
                      !nested.panels().contains(where: {
                          $0.scratch == true && p.lensRooms != nil && !(p.lensRooms ?? []).contains($0.id)
                      }),
                      Set(nested.allWindows()).isDisjoint(with: hidden) else { continue }
                if case .panel(let only) = nested.root, only.desktop == nil, only.free != true {
                    // A single tile: its windows come back to the pool itself.
                    p.windows = only.windows
                    p.floating = only.floating
                    p.landscape = only.landscape
                    p.tabs = only.tabs
                    p.front = only.front
                    p.desktop = nil
                    p.lens = nil
                } else {
                    // A group: its tiles go back in its place, keeping their
                    // numbers where those are free on this board.
                    let inner = Set(panelsIn(nested.root).map { $0.id })
                    d.replace(p.id, with: nested.root)
                    var used = Set(d.panels().filter { !inner.contains($0.id) }.map { $0.number })
                    for q in d.panels() where inner.contains(q.id) {
                        if q.number < 1 || used.contains(q.number) { q.number = 0 } else { used.insert(q.number) }
                    }
                    for q in d.panels() where q.number == 0 { q.number = d.nextNumber() }
                    if state.lastPanelId == p.id { state.lastPanelId = nil }
                    if selection?.panel == p.id { selection = nil }
                }
            }
        }
        for main in allMains { fold(in: main) }
    }

    /// A pool becomes a board of its own the first time you go into it,
    /// starting with one pool that holds its windows.
    /// - A breathing-room Desktop: the board inside starts as a Desktop, its
    ///   windows floating just as they were. Every level can have one.
    /// - A tile: the board is a lens on it, folded back into the board above
    ///   when you come back up (unless it becomes a place of its own).
    private func makeBoard(of p: Panel) {
        guard p.desktop == nil else { return }
        let nested = Desktop.single()
        let inner = nested.lowestNumbered()
        moveContents(from: p, to: inner)
        p.desktop = nested
        if p.free == true {
            inner.free = true
            inner.name = "Desktop"
            p.free = nil
            // The board's own Desktop, zoomed in on: folded back when you come up.
            if p.scratch != true { p.lens = true }
        } else if tileWindows, p.scratch != true {
            p.lens = true
        }
    }

    /// From the Surface into your boards.
    private func moveEnter(at path: [UUID]?) -> Move? {
        guard onSurface else { return nil }
        let wanted = path ?? state.path
        let dest = isValid(wanted) ? wanted : []
        return Move(zoomIn: true, target: surfaceTarget, toKey: placeKey(dest)) {
            self.steppedThrough = nil
            // Remember your normal desktop exactly as it is.
            self.surfaceFrames.removeAll()
            let onBoards = Set(self.everyWindow())
            // Only windows on this display, and not another display's.
            for id in self.windows.onScreenIDs() where !onBoards.contains(id) && self.windows.isStandard(id)
                && !self.belongsElsewhere(id) {
                if let f = self.windows.frame(of: id),
                   self.screen.frame.contains(CGPoint(x: f.midX, y: f.midY)) { self.surfaceFrames[id] = f }
            }
            self.onSurface = false
            self.state.path = dest
            if !dest.isEmpty { self.addBreathingRoom(entering: self.surfaceTarget) }
            // A board with a Desktop: your desktop's windows float on it,
            // right where they are, instead of stepping aside.
            self.adoptOntoDesktop()
        }
    }

    /// Your normal desktop's windows join the Desktop of the board you're
    /// going into, floating exactly where they are: nothing moves.
    private func adoptOntoDesktop() {
        guard !surfaceFrames.isEmpty, let desk = desktopPlaced() else { return }
        let inner = desk.rect.insetBy(dx: gap / 2, dy: gap / 2)
        for (w, f) in surfaceFrames where windows.exists(w) {
            if !desk.panel.windows.contains(w) { desk.panel.windows.append(w) }
            desk.panel.setFloat(w, relative(f, in: inner))
            lastApplied[w] = nil
        }
        surfaceFrames.removeAll()
    }

    /// Starting up on a board with a Desktop: straight in, with nothing
    /// moving (your windows float on the Desktop right where they are, and
    /// docked windows come back to their tiles).
    func startOnDesktop() {
        guard onSurface, !busy, AXIsProcessTrusted(), current.freePanel() != nil,
              let m = moveEnter(at: state.path) else { return }
        m.change()
        applyLayout()
    }

    /// Every window on the board you're on floats on the Desktop, right
    /// where it is now (the board gets a Desktop if it has none). Pools
    /// holding boards of their own stay, beside it. Hyper + Z puts it back.
    func floatAllOnDesktop() {
        guard !onSurface, !busy else { return }
        let d = current
        let v = viewport
        // Where each window is now, as laid out.
        var spots: [UInt32: CGRect] = [:]
        var order: [UInt32] = []
        for placed in frames(d, in: v) where placed.depth == 0 && placed.panel.desktop == nil {
            let target = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
            let fill = fillRect(for: placed.panel, in: target, only: placed.panel.windows)
            for w in placed.panel.windows where windows.exists(w) && !order.contains(w) {
                spots[w] = spot(for: w, in: placed.panel, target: target, fill: fill, stretch: nil)
                order.append(w)
            }
        }
        checkpoint()
        let desk: Panel
        if let existing = d.freePanel() {
            desk = existing
        } else {
            desk = Panel(number: 0)
            desk.free = true
            desk.name = "Desktop"
        }
        let boards = d.panels().filter { $0.desktop != nil }
        if boards.isEmpty {
            d.root = .panel(desk)
        } else {
            d.root = .split(Split(axis: .h, children: [Node.panel(desk)] + boards.map { Node.panel($0) }))
        }
        if desk.number == 0 { desk.number = d.nextNumber() }
        desk.windows = order
        desk.floating = nil
        desk.landscape = nil
        let inner = (frames(d, in: v).first { $0.panel === desk }?.rect ?? v).insetBy(dx: gap / 2, dy: gap / 2)
        for w in order {
            desk.setFloat(w, relative(spots[w] ?? inner, in: inner))
            lastApplied[w] = nil
            onTop.remove(w)
        }
        state.lastPanelId = desk.id
        selection = nil
        // Your normal desktop's windows join it too, right where they were.
        adoptOntoDesktop()
        glideLayout()
        Toast.show("Everything floats on the Desktop. Drag a window to a screen edge to dock it", seconds: 2)
    }

    /// Up to the Surface from anywhere.
    private func moveSurface() -> Move? {
        guard !onSurface else { return nil }
        return Move(zoomIn: false, target: surfaceTarget, toKey: placeKey(nil)) {
            if self.overviewOpen { BoardOverview.current?.close() }
            self.onSurface = true
        }
    }

    /// Between two boards where one is inside the other. Nil for a sideways
    /// trip (that's a flight: up to the shared board, then down).
    private func moveTo(_ newPath: [UUID]) -> Move? {
        guard !onSurface, newPath != state.path, isValid(newPath) else { return nil }
        let old = state.path
        let stack = desktopStack()
        if newPath.starts(with: old) {
            // Deeper: the panel leading there grows to fill the screen.
            guard let target = rect(ofTopPanel: newPath[old.count]) else { return nil }
            return Move(zoomIn: true, target: target, toKey: placeKey(newPath)) {
                self.state.path = newPath
                self.addBreathingRoom(entering: target)
            }
        }
        if old.starts(with: newPath) {
            // Shallower: the screen shrinks back into the panel we came from.
            let cameFrom = old[newPath.count]
            let parent = stack[newPath.count]
            // (A room panel folded away from up there has no spot: shrink to the middle.)
            let target = framesAsShown(parent)
                .first(where: { $0.depth == 0 && $0.panel.id == cameFrom })?.rect ?? surfaceTarget
            let leavingDepth = old.count
            return Move(zoomIn: false, target: target, toKey: placeKey(newPath)) {
                self.state.path = newPath
                self.foldAwayRoom()
                // Only fold up the board we were directly inside.
                if leavingDepth == newPath.count + 1, let owner = parent.panel(id: cameFrom) {
                    self.collapseIfTrivial(stack[leavingDepth], into: owner)
                }
            }
        }
        return nil
    }

    /// Plays a move as an animated zoom, then runs `next` (a flight's next leg).
    private func perform(_ m: Move, then next: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        quietReveal()
        windows.refresh()
        captureManualMoves()   // keep the arrangement you made before anything moves
        // (On the Overview, the picture taken now is of the Overview.)
        let from = overviewOpen ? overviewKey : hereKey
        Task { @MainActor in
            await animator.animate(on: screen, zoomIn: m.zoomIn, target: m.target, fromKey: from, toKey: m.toKey,
                                   change: { self.leaveSpotlight(); m.change() },
                                   layout: { self.applyLayout() })
            busy = false
            if let next {
                next()
            } else if m.announce {
                Toast.show(locationLabel() + (isHome && !onSurface ? "  ·  ⌂ Home" : ""), seconds: 0.7)
            }
        }
    }

    // MARK: Trackpad: the zoom follows your fingers

    private var steering: Move?
    /// A swipe up from Main while zooming out stops there: it gives a
    /// little and floats back.
    private var steeringStopped = false

    /// Starts a steered zoom. False when there's nowhere to go that way.
    /// - viaScroll: Hyper + scroll, which goes between your desktop and Main
    ///   (on through Main to the desktop, and back in to Main).
    /// - toDesktop: coming up goes straight to your desktop from any depth
    ///   (Hyper + a three-finger swipe up).
    func scrubBegin(zoomIn: Bool, at point: CGPoint, viaScroll: Bool = false, toDesktop: Bool = false) -> Bool {
        guard !busy, AXIsProcessTrusted() else { return false }
        var m: Move?
        let inOverview = overviewOpen
        if zoomIn {
            if onSurface {
                m = moveEnter(at: viaScroll ? [] : nil)
            } else if inOverview {
                m = moveFromOverview(BoardOverview.current?.item(at: point))
            } else if !viaScroll, let through = moveThrough(at: point) {
                m = through
            } else {
                m = moveStep(at: point)
            }
        } else if onSurface {
            // Stepped through to your desktop: swipe up to go back out the way you came.
            m = moveBackThrough()
        } else {
            if inOverview {
                // Already looking at everything: only Hyper goes on to your desktop.
                m = toDesktop || viaScroll ? moveSurface() : nil
                if m == nil { topHint() }
            } else if state.path.isEmpty, !toDesktop, !viaScroll, let o = moveOverview() {
                m = o
            } else {
                m = state.path.isEmpty || toDesktop ? moveSurface() : moveTo(Array(state.path.dropLast()))
            }
        }
        guard let m else { return false }
        steeringStopped = !zoomIn && !onSurface && state.path.isEmpty && stopAtMain && !viaScroll && !toDesktop
            && m.toKey != overviewKey && !inOverview
        busy = true
        quietReveal()
        windows.refresh()
        captureManualMoves()
        steering = m
        animator.beginScrub(on: screen, zoomIn: m.zoomIn, target: m.target,
                            fromKey: inOverview ? overviewKey : hereKey, toKey: m.toKey)
        return true
    }

    /// 0 = where you started, 1 = all the way there.
    func scrubUpdate(_ progress: CGFloat) {
        guard steering != nil else { return }
        if steeringStopped {
            // Gives a little, like pulling against a spring.
            animator.updateScrub(CGFloat(0.1 * (1 - Foundation.exp(-Double(max(progress, 0)) * 2.5))))
        } else {
            animator.updateScrub(progress)
        }
    }

    /// Let go: finish the zoom, or float back.
    func scrubEnd(commit: Bool) {
        guard let m = steering else { return }
        steering = nil
        let stopped = steeringStopped
        steeringStopped = false
        if stopped { stopHint() }
        Task { @MainActor in
            let moved = await animator.endScrub(commit: commit && !stopped,
                                                change: { self.leaveSpotlight(); m.change() },
                                                layout: { self.applyLayout() })
            busy = false
            // Floated back from the Overview's edge: the map laid out for it goes.
            if !moved, m.toKey == overviewKey, BoardOverview.current?.isOpen == false {
                BoardOverview.current?.close()
            }
            if moved, m.announce { Toast.show(locationLabel() + (isHome && !onSurface ? "  ·  ⌂ Home" : ""), seconds: 0.7) }
        }
    }

    // MARK: New windows join the board you're on

    var autoJoin: Bool {
        get { UserDefaults.standard.bool(forKey: "autoJoin") }
        set { UserDefaults.standard.set(newValue, forKey: "autoJoin") }
    }
    private var joinTimer: Timer?

    func startWatchingNewWindows() {
        joinTimer?.invalidate()
        joinTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Once a second while you're inside: tidy up after closed windows, then
    /// pick up new ones.
    private func tick() {
        guard !onSurface, !busy, AXIsProcessTrusted() else { return }
        if portholes, shownTiles.contains(where: { $0.porthole }), !gliding, edgeWindow == nil {
            fitPortholes(redraw: false)
        }
        // Apps (Safari, macOS itself) sometimes drag a tucked-away window
        // back into view, porthole windows included: tuck it away again.
        if !gliding, edgeWindow == nil {
            for w in windows.escaped(on: screen) { windows.repark(w, on: screen) }
        }
        // A cheap look at the window list first: when nothing has opened or
        // closed, skip asking every app for its windows (that's the costly
        // part). After a change, keep looking for a few seconds, since a new
        // window can take a moment to be ready to join.
        let seen = windows.onScreenIDs(on: screen)
        if seen != lastSeen {
            lastSeen = seen
            settling = 3
        } else if missingOnce.isEmpty {
            guard settling > 0 else { return }
            settling -= 1
        }
        windows.refresh()
        if noticeMinimized() { return }
        if noticeClosedWindows() { return }
        if settleNewSpotlight() { return }
        if autoJoin { adoptNewWindows() }
    }

    /// The on-screen windows at the last check, and how many more checks to
    /// make after the last change.
    private var lastSeen = Set<UInt32>()
    private var settling = 0

    /// Windows seen missing on the last check. A window has to be missing
    /// twice in a row, so an app that's briefly busy doesn't lose its spot.
    private var missingOnce = Set<UInt32>()

    // MARK: Minimized windows

    var minimizeReflow: Bool {
        get { UserDefaults.standard.bool(forKey: "minimizeReflow") }
        set {
            UserDefaults.standard.set(newValue, forKey: "minimizeReflow")
            if !newValue, !docked.isEmpty { docked.removeAll(); applyLayout() }
        }
    }

    /// Board windows you minimized into the Dock. They keep their place in
    /// their pool, but the pool lays out without them, so the windows beside
    /// them take the space. Bring one back and it returns to its spot.
    private var docked = Set<UInt32>()

    /// A window on the board was minimized, or one came back from the Dock:
    /// lay out again around it.
    private func noticeMinimized() -> Bool {
        guard minimizeReflow else { return false }
        // Live windows you just minimized (Scuba's own minimizing only ever
        // touches tucked-away windows, which aren't live).
        let went = liveIn.keys.filter { !docked.contains($0) && !windows.parked.contains($0) && windows.isMinimized($0) }
        // Windows back from the Dock, or closed while they were in it.
        let back = docked.filter { !windows.exists($0) || !windows.isMinimized($0) }
        guard !went.isEmpty || !back.isEmpty else { return false }
        docked.formUnion(went)
        docked.subtract(back)
        if let s = spotlit, docked.contains(s) { spotlit = nil }
        glideLayout()
        return true
    }

    /// A window on this board closed (or its app quit): drop it from its
    /// panel and let the rest re-fit, e.g. a filled window takes back the
    /// space a closed floating one was using.
    private func noticeClosedWindows() -> Bool {
        let here = frames(current, in: viewport).filter { $0.panel.desktop == nil }.flatMap { $0.panel.windows }
        let missing = Set(here.filter { !windows.exists($0) })
        let gone = missing.intersection(missingOnce)
        missingOnce = missing
        guard !gone.isEmpty else { return false }
        missingOnce.subtract(gone)
        if let s = spotlit, gone.contains(s) { spotlit = nil }
        for w in gone { remove(window: w) }
        if let marked = state.insideOnly {
            let kept = marked.filter { !gone.contains($0) }
            state.insideOnly = kept.isEmpty ? nil : kept
        }
        glideLayout()
        return true
    }

    /// Any new normal window that shows up while you're inside floats on the
    /// board you're on, in the panel it opened over.
    private func adoptNewWindows() {
        guard !onSurface, !busy, autoJoin, deploying == nil, AXIsProcessTrusted() else { return }
        let known = Set(everyWindow()).union(allFloaters)
        let fresh = windows.onScreenIDs().filter {
            !known.contains($0) && surfaceFrames[$0] == nil && !ignored.contains($0) && windows.isStandard($0)
                && isOnMyScreen($0) && !belongsElsewhere($0)
        }
        guard !fresh.isEmpty else { return }
        // Placements locked: new windows float on top of this board, outside
        // its layout, and stay with it.
        if placementsLocked {
            for w in fresh { addFloater(w, to: current.id) }
            saveState()
            return
        }
        checkpoint()
        let panels = dropPanels()
        let active = activePanel()
        let fallbackID = (active.desktop?.landingPanel() ?? active).id
        var names: [String] = []
        // A new window with nowhere empty to go opens in Spotlight, ready to
        // be dragged where you want it.
        var toSpotlight: UInt32?
        // Open water first: a new window goes to the nearest empty pool on the
        // board (the breathing room, say) and fills it, one window per pool.
        var open = openWater ? panels.filter { p in
            let t = p.rect.insetBy(dx: gap / 2, dy: gap / 2)
            return p.panel.windows.isEmpty && p.panel.free != true
                && (!crowdIcons || (t.width >= 340 && t.height >= 230))
        } : []
        // A board with a Desktop (its own, or breathing room): new windows
        // open on the nearest one, floating where the app put them.
        let desks = panels.filter { $0.panel.free == true }
        for w in fresh {
            guard let f = windows.frame(of: w) else { continue }
            let center = CGPoint(x: f.midX, y: f.midY)
            func away(_ r: CGRect) -> CGFloat {
                hypot(max(r.minX - center.x, 0, center.x - r.maxX), max(r.minY - center.y, 0, center.y - r.maxY))
            }
            if let desk = desks.min(by: { a, b in
                let da = away(a.rect), db = away(b.rect)
                return da != db ? da < db : a.depth > b.depth
            }) {
                landInHalf(w, of: desk, at: center)
                names.append(windows.appName(w))
                continue
            }
            if !open.isEmpty {
                func distance(_ r: CGRect) -> CGFloat {
                    let dx = max(r.minX - center.x, 0, center.x - r.maxX)
                    let dy = max(r.minY - center.y, 0, center.y - r.maxY)
                    return hypot(dx, dy)
                }
                var nearest = 0
                for (i, o) in open.enumerated() where distance(o.rect) < distance(open[nearest].rect) { nearest = i }
                let spot = open.remove(at: nearest)
                spot.panel.windows.append(w)
                state.lastPanelId = spot.panel.id
                names.append(windows.appName(w))
                if spot.depth >= 1, portholes { probing.insert(w) }
                continue
            }
            let under: Placed? = panels.filter { $0.rect.contains(center) }.max { $0.depth < $1.depth }
            let placed: Placed? = under ?? panels.first { $0.panel.id == fallbackID } ?? panels.first
            guard let target = placed else { continue }
            let inner = target.rect.insetBy(dx: gap / 2, dy: gap / 2)
            let taken = !shownWindows(target.panel, of: target.owner).isEmpty
            if taken {
                // The pool's already in use: float on top where it opened
                // (kept inside the pool), leaving the others as they are.
                let size = CGSize(width: min(f.width, inner.width), height: min(f.height, inner.height))
                let x = min(max(f.minX, inner.minX), inner.maxX - size.width)
                let y = min(max(f.minY, inner.minY), inner.maxY - size.height)
                if !target.panel.windows.contains(w) { target.panel.windows.append(w) }
                target.panel.setFloat(w, relative(CGRect(origin: CGPoint(x: x, y: y), size: size), in: inner))
                onTop.insert(w)
                lastApplied[w] = nil
                if spotlightNew, toSpotlight == nil {
                    toSpotlight = w
                } else if target.depth >= 1, portholes {
                    probing.insert(w)
                }
            } else if target.depth >= 1 {
                // On a nested board, it takes a proper spot instead of floating
                // wherever the app put it (over its neighbours): the whole pool,
                // or the half it opened over. Its size is checked out of sight
                // first, so one that won't shrink that far is a porthole from
                // the start.
                landInHalf(w, of: target, at: center)
                if portholes { probing.insert(w) }
            } else {
                target.panel.windows.append(w)
                target.panel.setFloat(w, relative(f, in: inner))
            }
            names.append(windows.appName(w))
        }
        if let s = toSpotlight {
            spotlit = s
            newInSpotlight = s
            newSpotlightAt = Date()
            if revealing {
                revealing = false
                numbers.hide()
            }
            glideLayout()
            windows.focus(s)
            Toast.show("Every pool is in use: drag \(windows.appName(s)) onto a pool to place it  ·  "
                       + "leave it and it goes to your desktop", seconds: 2.6)
        } else if !names.isEmpty {
            glideLayout()
            if desks.isEmpty { Toast.show("\(names.joined(separator: ", ")) joined \(locationLabel())", seconds: 0.9) }
        }
    }

    /// Puts a window in a pool: an empty pool takes it whole; in one that's
    /// in use it floats in the half where `point` is, and the windows there
    /// make room (the way a thrown window lands).
    private func landInHalf(_ w: UInt32, of target: Placed, at point: CGPoint) {
        let p = target.panel
        // The Desktop: it floats, where it is now if that's on the Desktop,
        // else in the middle of it.
        if p.free == true {
            if !p.windows.contains(w) { p.windows.append(w) }
            let inner = target.rect.insetBy(dx: gap / 2, dy: gap / 2)
            var f = windows.frame(of: w) ?? inner.insetBy(dx: inner.width * 0.15, dy: inner.height * 0.15)
            if !inner.intersects(f) {
                f = CGRect(x: inner.midX - f.width / 2, y: inner.midY - f.height / 2, width: f.width, height: f.height)
            }
            p.setFloat(w, relative(f, in: inner))
            lastApplied[w] = nil
            return
        }
        let occupied = !shownWindows(p, of: target.owner).filter { $0 != w }.isEmpty
        // Every window its own tile: the pool splits, and the window takes
        // the half nearest the point as a tile of its own.
        if tileWindows, occupied {
            p.windows.removeAll { $0 == w }
            p.setFloat(w, nil)
            let r = target.rect
            let axis = screenShapedAxis(for: r)
            let before = axis == .h ? point.x < r.midX : point.y > r.midY
            let fresh = target.owner.addPanel(nextTo: p, axis: axis, before: before)
            fresh.windows = [w]
            lastApplied[w] = nil
            return
        }
        if !p.windows.contains(w) { p.windows.append(w) }
        if occupied {
            let r = target.rect
            let half: CGRect = r.width >= r.height
                ? CGRect(x: point.x < r.midX ? 0 : 0.5, y: 0, width: 0.5, height: 1)
                : CGRect(x: 0, y: point.y < r.midY ? 0 : 0.5, width: 1, height: 0.5)
            p.setFloat(w, half)
        } else {
            p.setFloat(w, nil)
        }
        lastApplied[w] = nil
    }

    // MARK: Docked windows that won't shrink

    /// Two windows docked side by side (or stacked) in a pool on the board
    /// you're on, one of which won't shrink to its share: the line between
    /// them moves so it fits, taken from the other one. If the other can't
    /// spare that much, they stack the other way instead, if that fits.
    /// Returns true if anything changed.
    private func refitDocks(_ leaves: [(placed: Placed, target: CGRect)]) -> Bool {
        var changed = false
        let tol: CGFloat = 0.04
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < tol }
        for (placed, target) in leaves where placed.depth == 0 && target.width > 1 && target.height > 1
            && placed.panel.free != true {
            let p = placed.panel
            let shown = shownWindows(p, of: placed.owner).filter { !onTop.contains($0) && $0 != spotlit }
            for w in shown {
                guard let r = p.floatRect(w), let m = windows.minSize(w) else { continue }
                let spot = absolute(r, in: target)
                let needW = m.width - spot.width, needH = m.height - spot.height
                guard needW > 4 || needH > 4 else { continue }
                for n in shown where n != w {
                    guard let nr = p.floatRect(n) else { continue }
                    let nMin = windows.minSize(n) ?? .zero
                    let sideBySide = near(r.minY, nr.minY) && near(r.maxY, nr.maxY)
                        && (near(r.maxX, nr.minX) || near(nr.maxX, r.minX))
                    let stacked = near(r.minX, nr.minX) && near(r.maxX, nr.maxX)
                        && (near(r.maxY, nr.minY) || near(nr.maxY, r.minY))
                    var a = r, b = nr
                    if sideBySide, needW > 4 {
                        let spare = nr.width * target.width - max(nMin.width, 220)
                        if spare >= needW + 2 {
                            let d = (needW + 2) / target.width
                            if r.maxX <= nr.minX + tol { a.size.width += d; b.origin.x += d; b.size.width -= d }
                            else { a.origin.x -= d; a.size.width += d; b.size.width -= d }
                        } else {
                            // Not enough room side by side: stack them instead.
                            let both = r.union(nr), g = gap / target.height
                            guard both.width * target.width >= max(m.width, nMin.width) - 2,
                                  (both.height - g) / 2 * target.height >= max(m.height, nMin.height, 160) else { continue }
                            let hh = (both.height - g) / 2
                            a = CGRect(x: both.minX, y: both.minY + hh + g, width: both.width, height: hh)
                            b = CGRect(x: both.minX, y: both.minY, width: both.width, height: hh)
                        }
                    } else if stacked, needH > 4 {
                        let spare = nr.height * target.height - max(nMin.height, 160)
                        guard spare >= needH + 2 else { continue }
                        let d = (needH + 2) / target.height
                        if r.maxY <= nr.minY + tol { a.size.height += d; b.origin.y += d; b.size.height -= d }
                        else { a.origin.y -= d; a.size.height += d; b.size.height -= d }
                    } else {
                        continue
                    }
                    p.setFloat(w, a)
                    p.setFloat(n, b)
                    lastApplied[w] = nil
                    lastApplied[n] = nil
                    changed = true
                    break
                }
            }
        }
        return changed
    }

    // MARK: Checking a new window's size out of sight

    /// Windows just added to a nested board, whose size is being checked
    /// while they're tucked away: they show as portholes until it's known
    /// whether they fit their spot.
    private var probing = Set<UInt32>()

    /// New windows that opened into a pool already in use: they float on top
    /// where they opened, and the pool's other windows stay as they are
    /// (they don't make room). Dragging one, or Hyper + Shift + F, makes it an
    /// ordinary window of its pool again.
    private var onTop = Set<UInt32>()

    /// A new window that opens when every pool on the board is in use opens
    /// in Spotlight, to drag where you want it.
    var spotlightNew: Bool {
        get { UserDefaults.standard.bool(forKey: "spotlightNew") }
        set { UserDefaults.standard.set(newValue, forKey: "spotlightNew") }
    }

    /// Asks each tucked-away window to take its spot's size, and a moment
    /// later sees what it settled at: bigger than the spot, it stays a
    /// porthole; otherwise it goes live.
    private func runProbes(_ spots: [UInt32: CGRect]) {
        guard !spots.isEmpty else { return }
        for (w, spot) in spots { windows.resizeTucked(w, to: spot.size) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            for (w, spot) in spots {
                self.probing.remove(w)
                guard let f = self.windows.frame(of: w) else { continue }
                if f.width > spot.width + 8 || f.height > spot.height + 8 {
                    self.overflowAt[w] = f.size
                } else {
                    self.overflowAt[w] = nil
                }
            }
            guard !self.onSurface else { return }
            if self.busy {
                // Mid-zoom: the layout that ends it picks this up.
                return
            }
            self.glideLayout()
        }
    }

    // MARK: Portholes

    /// Windows on a nested board that won't shrink to their spot show as a
    /// frosted picture cropped at the pool's edge, instead of spilling over
    /// the pools beside them. Click one to dive straight to that window.
    var portholes: Bool {
        get { UserDefaults.standard.bool(forKey: "portholes") }
        set {
            UserDefaults.standard.set(newValue, forKey: "portholes")
            for c in Controller.all where !c.onSurface { c.applyLayout() }
        }
    }
    /// Portholes show the window live (shrunk to fit, kept up to date)
    /// instead of a frosted still picture.
    var portholesLive: Bool {
        get { UserDefaults.standard.bool(forKey: "livePortholes") }
        set {
            UserDefaults.standard.set(newValue, forKey: "livePortholes")
            for c in Controller.all where !c.onSurface { c.applyLayout() }
        }
    }
    /// Windows showing as portholes right now.
    private var portholed = Set<UInt32>()
    /// Copied windows that are live in one pool and show as portholes in
    /// their other pools.
    private var mirrored = Set<UInt32>()
    /// The pool each window is live in, as of the last layout.
    private var liveIn: [UInt32: UUID] = [:]
    /// Everything that needs a picture: portholes and copies.
    private var pictured: Set<UInt32> { portholed.union(mirrored) }
    /// Frosted pictures of porthole windows, and when each was taken.
    private var portholePictures: [UInt32: (image: CGImage, taken: Date)] = [:]
    /// Windows whose first picture is being taken (their app isn't hidden
    /// or minimized until then, since macOS won't show us those).
    private var awaitingPicture = Set<UInt32>()
    /// Windows whose picture couldn't be taken last time.
    private var pictureFailed = Set<UInt32>()
    /// The tiles on screen, redrawn when pictures arrive.
    private var shownTiles: [CrowdTile] = []
    private var portholeCapture: Task<Void, Never>?

    /// Where a window goes in its pool: the filled area, or its floating spot.
    private func spot(for w: UInt32, in p: Panel, target: CGRect, fill: CGRect, stretch: CGRect?) -> CGRect {
        guard var rel = p.floatRect(w) else { return fill }
        if let box = stretch {
            rel = CGRect(x: (rel.minX - box.minX) / box.width, y: (rel.minY - box.minY) / box.height,
                         width: rel.width / box.width, height: rel.height / box.height)
        }
        return absolute(rel, in: target)
    }

    /// True if the window, last time it spilled out of a spot, stayed
    /// bigger than this one.
    private func cramped(_ w: UInt32, in spot: CGRect) -> Bool {
        guard let size = overflowAt[w] else { return false }
        return size.width > spot.width + 8 || size.height > spot.height + 8
    }

    /// For each window that spilled out of its spot: the size it stayed at
    /// (about as small as it will go).
    private var overflowAt: [UInt32: CGSize] = [:]
    /// A spill seen once, waiting for a second look that agrees.
    private var overflowSeen: [UInt32: (size: CGSize, tries: Int)] = [:]
    /// Windows just laid out live, to check once they've settled at their
    /// new size: nested-board ones, plus any with a size on record (to
    /// learn if they can get smaller after all).
    private var overflowCheck: [UInt32: (spot: CGRect, nested: Bool)] = [:]
    private var overflowCheckDue = Date.distantPast
    private var overflowTimer: Timer?

    /// Some apps take a moment to resize, so where a window really ends up
    /// is checked a little after the layout. One that spills out of its
    /// spot becomes a porthole; one that fits now is live again next time.
    private func scheduleOverflowCheck(_ spots: [UInt32: (spot: CGRect, nested: Bool)]) {
        overflowTimer?.invalidate()
        overflowTimer = nil
        overflowCheck = spots
        guard portholes, !spots.isEmpty else { return }
        overflowCheckDue = Date().addingTimeInterval(0.3)
        overflowTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkOverflow() }
        }
    }

    private func checkOverflow() {
        overflowTimer = nil
        let spots = overflowCheck
        overflowCheck = [:]
        guard portholes, !onSurface else { return }
        var changed = false
        var again: [UInt32: (spot: CGRect, nested: Bool)] = [:]
        for (w, check) in spots {
            guard windows.exists(w), !windows.parked.contains(w), w != spotlit, w != edgeWindow,
                  let f = windows.frame(of: w) else { continue }
            let spot = check.spot
            if f.width > spot.width + 8 || f.height > spot.height + 8 {
                // Only once two looks in a row agree: an app still resizing
                // (Maps does it slowly) isn't mistaken for one that won't fit.
                if let prev = overflowSeen[w], abs(prev.size.width - f.width) < 2, abs(prev.size.height - f.height) < 2 {
                    overflowAt[w] = f.size
                    overflowSeen[w] = nil
                    if check.nested { changed = true }
                } else if (overflowSeen[w]?.tries ?? 0) < 4 {
                    overflowSeen[w] = (f.size, (overflowSeen[w]?.tries ?? 0) + 1)
                    again[w] = check
                } else {
                    overflowSeen[w] = nil   // never settles: leave it live
                }
            } else {
                overflowAt[w] = nil
                overflowSeen[w] = nil
            }
        }
        if changed {
            if gliding || edgeWindow != nil { scheduleOverflowCheck(spots) } else { glideLayout() }
        } else if !again.isEmpty {
            scheduleOverflowCheck(again)
        }
    }

    private var portholeFit: Task<Void, Never>?

    /// Portholes give way to live windows: a live window that can't shrink
    /// into its own pool (Maps beside a stack of two) stays whole, and any
    /// porthole it reaches over is cut back to the part it leaves free.
    /// - redraw: show the tiles even if nothing changed (after a layout).
    /// - around: where live windows are meant to be, used instead of where
    ///   they are right now (straight after a layout they may not be there yet).
    private func fitPortholes(redraw: Bool, around: [UInt32: CGRect]? = nil) {
        guard !onSurface, shownTiles.contains(where: { $0.porthole }) || redraw else { return }
        let frames: [CGRect]
        if let around {
            frames = Array(around.values)
        } else {
            let live = Set(state.root.allWindows()).filter {
                windows.exists($0) && !windows.parked.contains($0) && !portholed.contains($0)
            }
            frames = live.compactMap { windows.frame(of: $0) }
        }
        let covers = frames.map { $0.insetBy(dx: -gap / 2, dy: -gap / 2) }
        var changed = false
        shownTiles = shownTiles.map { tile in
            guard tile.porthole, !tile.full.isEmpty else { return tile }
            var r = tile.full
            for c in covers where c.intersects(r) { r = Controller.remainder(of: r, minus: c) }
            var t = tile
            if t.rect != r { changed = true }
            t.rect = r
            return t
        }
        if changed || redraw { showTiles() }
    }

    /// The biggest part of `r` left over once `cut` is taken out of it.
    private static func remainder(of r: CGRect, minus cut: CGRect) -> CGRect {
        guard r.intersects(cut) else { return r }
        // The strips of `r` beside the cut, measured before any rectangle is
        // made (CGRect quietly turns a negative size positive, which would
        // pass off a strip that isn't there as a real one).
        let left = cut.minX - r.minX, right = r.maxX - cut.maxX
        let below = cut.minY - r.minY, above = r.maxY - cut.maxY
        var parts: [CGRect] = []
        if left > 0 { parts.append(CGRect(x: r.minX, y: r.minY, width: left, height: r.height)) }
        if right > 0 { parts.append(CGRect(x: cut.maxX, y: r.minY, width: right, height: r.height)) }
        if below > 0 { parts.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: below)) }
        if above > 0 { parts.append(CGRect(x: r.minX, y: cut.maxY, width: r.width, height: above)) }
        return parts.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    }

    /// Shows the tiles, leaving out portholes squeezed too small to be useful.
    /// Live portholes get a live picture: the window shrunk to fit its
    /// porthole (the eight biggest; any others show their still picture).
    private func showTiles() {
        // Mid-swipe, the tiles stay as they are (a fresh picture can wait).
        if inflating != nil { return }
        let shown = shownTiles.filter { !$0.porthole || ($0.rect.width >= 40 && $0.rect.height >= 40) }
        var wanted: [CGWindowID: CGSize] = [:]
        let scale = screen.backingScaleFactor
        let liveOnes = shown.filter { $0.porthole && $0.live }
            .sorted { $0.full.width * $0.full.height > $1.full.width * $1.full.height }
        for t in liveOnes where wanted[t.window] == nil && wanted.count < 8 {
            guard let f = windows.frame(of: t.window), f.width > 1, f.height > 1 else { continue }
            let fit = min(1, min(t.full.width / f.width, t.full.height / f.height))
            wanted[t.window] = CGSize(width: (f.width * fit * scale).rounded(), height: (f.height * fit * scale).rounded())
        }
        live.keep(wanted)
        tiles.show(shown)
    }

    /// The window behind the porthole under a point (AppKit screen
    /// coordinates), for Hyper + click to spotlight it. Hidden windows seen
    /// from above aren't included.
    func portholeWindow(at p: CGPoint) -> UInt32? {
        shownTiles.last { $0.porthole && $0.badge != "eye.slash.fill" && $0.rect.contains(p) }?.window
    }

    private func portholeTile(_ w: UInt32, spot: CGRect, placed: Placed, target: CGRect) -> CrowdTile? {
        let r = spot.intersection(target)
        guard !r.isNull, r.width > 8, r.height > 8 else { return nil }
        var t = CrowdTile(rect: r, icon: windows.appIcon(w), name: windows.appName(w), extra: 0,
                          panel: placed.panel.id, owner: placed.owner.id, window: w)
        t.porthole = true
        t.full = r
        t.picture = portholePictures[w]?.image
        t.live = portholesLive && CGPreflightScreenCaptureAccess()
        // The window would hang down and right from its spot's top-left corner.
        t.anchor = CGPoint(x: spot.minX, y: spot.maxY)
        return t
    }

    /// Takes fresh pictures of porthole windows (new ones, or ones a few
    /// seconds old) and redraws the portholes when they arrive.
    private func refreshPortholePictures() {
        portholePictures = portholePictures.filter { windows.exists($0.key) }
        overflowAt = overflowAt.filter { windows.exists($0.key) }
        overflowSeen = overflowSeen.filter { windows.exists($0.key) }
        awaitingPicture.formIntersection(pictured)
        let now = Date()
        // macOS won't show us a hidden app's windows: keep their last picture.
        func appHidden(_ w: UInt32) -> Bool {
            guard let pid = windows.pid(of: w) else { return false }
            return NSRunningApplication(processIdentifier: pid)?.isHidden == true
        }
        let due = pictured.filter { w in
            !windows.isMinimized(w) && !appHidden(w)
                && (portholePictures[w].map { now.timeIntervalSince($0.taken) > 4 } ?? true)
        }
        // Windows showing as portholes without a picture keep their app in
        // view until one is taken, even while another capture is under way.
        awaitingPicture.formUnion(pictured.filter {
            portholePictures[$0] == nil && !pictureFailed.contains($0) && !windows.isMinimized($0)
        })
        guard !due.isEmpty, portholeCapture == nil else { return }
        let ids = Array(due)
        let scale = screen.backingScaleFactor
        portholeCapture = Task { @MainActor [weak self] in
            let got = await PortholeCamera.pictures(of: ids, scale: scale)
            guard let self, !Task.isCancelled else { return }
            self.portholeCapture = nil
            let taken = Date()
            for (id, image) in got { self.portholePictures[id] = (image, taken) }
            // Couldn't see it (say, no screen-recording permission): don't
            // keep its app in view waiting for a picture that won't come.
            self.pictureFailed.formUnion(ids.filter { got[$0] == nil })
            self.pictureFailed.subtract(got.keys)
            self.awaitingPicture.subtract(ids)
            if !got.isEmpty, !self.busy, !self.onSurface {
                self.shownTiles = self.shownTiles.map { tile in
                    var t = tile
                    if t.porthole || t.shrunk, let p = self.portholePictures[t.window] { t.picture = p.image }
                    return t
                }
                self.showTiles()
            }
            // New portholes that came along during this capture: one more go.
            if self.pictured.contains(where: { self.portholePictures[$0] == nil && !ids.contains($0)
                                                && !self.pictureFailed.contains($0) }) {
                self.refreshPortholePictures()
            }
            // Hiding an app here could bring another one forward: don't
            // follow that switch.
            self.quietUntil = Date().addingTimeInterval(1.0)
            self.updateAppVisibility()
        }
    }

    // MARK: Tucked-away windows leave Mission Control

    /// Windows tucked away for a few seconds get minimized (in their corner,
    /// out of sight), which keeps them out of Mission Control even while
    /// their app has other windows in view. Going to them brings them back.
    var tuckMinimize: Bool {
        get { UserDefaults.standard.bool(forKey: "tuckMinimize") }
        set {
            UserDefaults.standard.set(newValue, forKey: "tuckMinimize")
            for c in Controller.all {
                if newValue { c.updateAppVisibility() } else { c.restoreMinimized() }
            }
        }
    }
    /// When each of this display's tucked-away windows was tucked away.
    private var tuckedAt: [UInt32: Date] = [:]
    private var minimizeTimer: Timer?

    private func noteTucked() {
        let now = Date()
        let tucked = windows.parked
        for w in tucked where tuckedAt[w] == nil { tuckedAt[w] = now }
        tuckedAt = tuckedAt.filter { tucked.contains($0.key) }
        minimizeTimer?.invalidate()
        minimizeTimer = nil
        guard tuckMinimize, !tuckedAt.isEmpty else { return }
        minimizeTimer = Timer.scheduledTimer(withTimeInterval: 3.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.minimizeTucked() }
        }
    }

    private func minimizeTucked() {
        guard tuckMinimize, !busy, AXIsProcessTrusted() else { return }
        let cutoff = Date().addingTimeInterval(-3)
        for (w, at) in tuckedAt where at <= cutoff && windows.parked.contains(w) && !portholed.contains(w) {
            // A hidden app is already out of Mission Control.
            guard let pid = windows.pid(of: w), let app = NSRunningApplication(processIdentifier: pid),
                  !app.isHidden, !windows.isMinimized(w) else { continue }
            windows.minimize(w)
        }
    }

    /// The setting was turned off: bring minimized tucked-away windows back
    /// (they stay tucked away).
    private func restoreMinimized() {
        minimizeTimer?.invalidate()
        minimizeTimer = nil
        for w in windows.parked where windows.isMinimized(w) {
            windows.unminimize(w)
        }
    }

    // MARK: Keeping Mission Control clean

    /// Apps we hid because all their windows were on other boards.
    private var hiddenByUs = Set<pid_t>()
    /// Ignore app switches for a moment after we rearrange things ourselves.
    private var quietUntil = Date.distantPast

    /// Mission Control shows every window, even tucked-away ones. So an app
    /// whose windows are all tucked away gets hidden (like Cmd + H), which
    /// takes it out of Mission Control. Apps with a window in view stay shown.
    private func updateAppVisibility() {
        var byApp: [pid_t: [UInt32]] = [:]
        for id in windows.allIDs() {
            if let pid = windows.pid(of: id) { byApp[pid, default: []].append(id) }
        }
        // Tucked away on any display's boards.
        // A porthole waiting for its first picture counts as in view for now.
        // So does a window showing as a live porthole: macOS won't show us a
        // hidden app's windows.
        let waiting = Controller.all.reduce(awaitingPicture.union(live.windows)) {
            $0.union($1.awaitingPicture).union($1.live.windows)
        }
        let tucked = Controller.all.reduce(windows.parked) { $0.union($1.windows.parked) }.subtracting(waiting)
        defer { noteTucked() }
        for (pid, ids) in byApp {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if ids.allSatisfy({ tucked.contains($0) }) {
                if !app.isHidden {
                    app.hide()
                    hiddenByUs.insert(pid)
                }
            } else if app.isHidden, hiddenByUs.contains(pid) {
                app.unhide()
                hiddenByUs.remove(pid)
            }
        }
    }

    private var activationObserver: NSObjectProtocol?

    /// This display stops having boards (unplugged, or set to a live map or
    /// left alone): stop watching and take down everything drawn on it.
    func shutDown() {
        joinTimer?.invalidate()
        joinTimer = nil
        minimizeTimer?.invalidate()
        minimizeTimer = nil
        overflowTimer?.invalidate()
        overflowTimer = nil
        portholeFit?.cancel()
        portholeFit = nil
        portholeCapture?.cancel()
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        tiles.hide()
        tabStrips.hide()
        moreInside.hide()
        live.stopAll()
        lobby.hide()
        bounds.hide()
        shade.update(depth: -1, on: screen)
        backdrop.update(depth: -1, on: screen)
        numbers.hide()
        saveState()
    }

    /// Switching to an app that lives on another board (Cmd + Tab, the Dock)
    /// takes you to that board. Opening a new window of that app (Cmd + N,
    /// New Window in the Dock) keeps you where you are, and the new window
    /// joins this board.
    func startFollowingAppSwitches() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            Task { @MainActor in
                guard let self, let pid else { return }
                self.followToken += 1
                let token = self.followToken
                try? await Task.sleep(nanoseconds: 150_000_000)   // let it pick its focused window
                await self.followSwitch(to: pid, token: token)
            }
        }
    }

    /// Bumped on every app switch, so only the latest one is followed.
    private var followToken = 0

    private func followSwitch(to pid: pid_t, token: Int) async {
        let started = Date()
        while true {
            guard token == followToken, !busy, Date() >= quietUntil, AXIsProcessTrusted() else { return }
            windows.refresh()
            let appWindows = windows.allIDs().filter { windows.pid(of: $0) == pid }
            let onBoards = appWindows.filter { chain(for: $0) != nil }
            // Windows of this app on your other Mains.
            let elsewhere = appWindows.compactMap { w -> (window: UInt32, main: Desktop)? in
                guard let d = allMains.first(where: { $0 !== state.root && $0.allWindows().contains(w) }) else { return nil }
                return (w, d)
            }
            guard !onBoards.isEmpty || !elsewhere.isEmpty else { return }
            let tucked = Controller.all.reduce(windows.parked) { $0.union($1.windows.parked) }
            // A window of this app is in view (a new one, say): stay here, and
            // put back any tucked-away window the app dragged into view.
            let inView = windows.onScreenIDs()
            if appWindows.contains(where: { inView.contains($0) && !tucked.contains($0) && windows.isStandard($0) }) {
                stayForNewWindow(of: pid, token: token)
                return
            }
            // Every window of this app is on another board. A new window can
            // take a moment to show up, so wait briefly before going there,
            // unless the app has already focused one of its board windows.
            let elapsed = Date().timeIntervalSince(started)
            let focused = windows.focusedWindowID().flatMap { onBoards.contains($0) ? $0 : nil }
            if onBoards.isEmpty, elapsed >= 0.6, let far = elsewhere.first {
                // Only on another Main: go across to it, straight to the window's board.
                guard let c = search(far.main, far.window, []), let holder = c.last else { return }
                let boardPath = c.dropLast().map { $0.id }
                let i = allMains.firstIndex(where: { $0 === far.main }) ?? 0
                state.lastPanelId = holder.id
                playSideways(mainSwitch(to: far.main.id, direction: i > mainPosition ? 1 : -1, landing: Array(boardPath))) {
                    Toast.show(self.locationLabel(), seconds: 0.7)
                    self.windows.focus(far.window)
                }
                return
            }
            if !onBoards.isEmpty, (focused != nil && elapsed >= 0.3) || elapsed >= 0.6 {
                let w = focused ?? onBoards[0]
                guard let c = chain(for: w), let holder = c.last else { return }
                let boardPath = c.dropLast().map { $0.id }
                jump(to: Array(boardPath), panel: holder.id, window: w)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Staying on this board while an app opens a new window here: tuck its
    /// other windows back out of view (now, and once more in a moment, since
    /// some apps pull them in late) and let the new window join.
    private func stayForNewWindow(of pid: pid_t, token: Int) {
        tuckBack(pid)
        if autoJoin { adoptNewWindows() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, token == self.followToken, !self.busy else { return }
            self.windows.refresh()
            self.tuckBack(pid)
            if self.autoJoin { self.adoptNewWindows() }
        }
    }

    /// Tucks an app's windows back out of view if it pulled any in.
    private func tuckBack(_ pid: pid_t) {
        guard !busy else { return }
        for w in windows.escaped(on: screen, pid: pid) { windows.repark(w, on: screen) }
    }

    // MARK: Overview

    struct OverviewItem {
        enum Kind { case board, panel, window }
        let kind: Kind
        let rect: CGRect          // AppKit screen coordinates
        let depth: Int
        let label: String
        let icon: NSImage?
        let path: [UUID]          // the board to go to
        let panel: UUID?
        let window: UInt32?
        let isCurrent: Bool
        /// The Main it's on (nil: the one you're on).
        var main: UUID? = nil
    }

    /// Board paths for every desktop: desktop id → panel ids leading to it.
    private func boardPaths() -> [UUID: [UUID]] { boardPaths(of: state.root) }

    private func boardPaths(of top: Desktop) -> [UUID: [UUID]] {
        var out: [UUID: [UUID]] = [top.id: []]
        func walk(_ d: Desktop, _ path: [UUID]) {
            for p in d.panels() {
                guard let nested = p.desktop else { continue }
                out[nested.id] = path + [p.id]
                walk(nested, path + [p.id])
            }
        }
        walk(top, [])
        return out
    }

    /// Every Main side by side inside `area`, for the Overview: each Main's
    /// boards, pools and windows inside its own island. Also returns where
    /// the Main you're on sits.
    func overviewIslands(in area: CGRect) -> (items: [OverviewItem], current: CGRect) {
        let all = allMains
        let n = CGFloat(all.count)
        let shape = viewport.width / max(1, viewport.height)
        let spacing: CGFloat = all.count > 1 ? 40 : 0
        var w = (area.width - spacing * (n - 1)) / n
        var h = w / shape
        if h > area.height {
            h = area.height
            w = h * shape
        }
        var x = area.midX - (w * n + spacing * (n - 1)) / 2
        let y = area.midY - h / 2
        var items: [OverviewItem] = []
        var current = CGRect(x: area.midX - w / 2, y: y, width: w, height: h)
        for d in all {
            let r = CGRect(x: x, y: y, width: w, height: h)
            if d === state.root { current = r }
            items += islandItems(of: d, in: r)
            x += w + spacing
        }
        return (items, current)
    }

    /// One Main's boards, pools and windows, laid out inside `map`.
    private func islandItems(of d: Desktop, in map: CGRect) -> [OverviewItem] {
        let paths = boardPaths(of: d)
        let here: [UUID]? = onSurface || d !== state.root ? nil : state.path
        var items: [OverviewItem] = []
        items.append(OverviewItem(kind: .board, rect: map, depth: -1, label: mainName(d), icon: nil,
                                  path: [], panel: nil, window: nil, isCurrent: here == [], main: d.id))
        for placed in frames(d, in: map) {
            let ownerPath = paths[placed.owner.id] ?? []
            if let nested = placed.panel.desktop {
                let path = paths[nested.id] ?? ownerPath + [placed.panel.id]
                items.append(OverviewItem(kind: .board, rect: placed.rect, depth: placed.depth,
                                          label: placed.label, icon: nil, path: path,
                                          panel: nil, window: nil, isCurrent: here == path, main: d.id))
                continue
            }
            items.append(OverviewItem(kind: .panel, rect: placed.rect, depth: placed.depth,
                                      label: placed.label, icon: nil, path: ownerPath,
                                      panel: placed.panel.id, window: nil, isCurrent: false, main: d.id))
            let inner = placed.rect.insetBy(dx: 3, dy: 3)
            for w in placed.panel.windows {
                let r = placed.panel.floatRect(w).map { absolute($0, in: inner) } ?? inner
                items.append(OverviewItem(kind: .window, rect: r, depth: placed.depth + 1,
                                          label: windows.appName(w), icon: windows.appIcon(w),
                                          path: ownerPath, panel: placed.panel.id, window: w,
                                          isCurrent: false, main: d.id))
            }
        }
        return items
    }

    /// Everything on every board, laid out inside `map` for the Overview.
    /// - Parameter top: the board to start from (all your boards by default;
    ///   the live map starts one level above where you are).
    func overviewItems(in map: CGRect, from top: [UUID] = []) -> [OverviewItem] {
        let paths = boardPaths()
        var items: [OverviewItem] = []
        let here = onSurface ? nil : state.path
        let start = desktop(at: top) ?? state.root
        let startPath = desktop(at: top) == nil ? [] : top
        items.append(OverviewItem(kind: .board, rect: map, depth: -1, label: breadcrumb(startPath), icon: nil,
                                  path: startPath, panel: nil, window: nil, isCurrent: here == startPath))
        for placed in frames(start, in: map) {
            let ownerPath = paths[placed.owner.id] ?? []
            if let nested = placed.panel.desktop {
                let path = paths[nested.id] ?? ownerPath + [placed.panel.id]
                items.append(OverviewItem(kind: .board, rect: placed.rect, depth: placed.depth,
                                          label: placed.label, icon: nil, path: path,
                                          panel: nil, window: nil, isCurrent: here == path))
                continue
            }
            items.append(OverviewItem(kind: .panel, rect: placed.rect, depth: placed.depth,
                                      label: placed.label, icon: nil, path: ownerPath,
                                      panel: placed.panel.id, window: nil, isCurrent: false))
            let inner = placed.rect.insetBy(dx: 3, dy: 3)
            for w in placed.panel.windows {
                let r = placed.panel.floatRect(w).map { absolute($0, in: inner) } ?? inner
                items.append(OverviewItem(kind: .window, rect: r, depth: placed.depth + 1,
                                          label: windows.appName(w), icon: windows.appIcon(w),
                                          path: ownerPath, panel: placed.panel.id, window: w,
                                          isCurrent: false))
            }
        }
        return items
    }

    /// If a window sits on a board nested below the one you're on, the board
    /// to dive to and the panel holding it. Nil for windows on this board.
    func diveTarget(for window: UInt32) -> (path: [UUID], panel: UUID)? {
        guard !onSurface, !busy, let c = chain(for: window), let holder = c.last else { return nil }
        let path = c.dropLast().map { $0.id }
        guard path.count > state.path.count,
              Array(path.prefix(state.path.count)) == state.path else { return nil }
        return (path, holder.id)
    }

    /// Goes to a board (from anywhere, including the Surface) and focuses a
    /// panel or window there.
    func jump(to path: [UUID], panel: UUID?, window: UInt32?) {
        guard isValid(path) else { return }
        if let panel { state.lastPanelId = panel }
        // Once there: say where you are and focus the window.
        let arrive: () -> Void = { [weak self] in
            guard let self else { return }
            Toast.show(self.locationLabel() + (self.isHome && !self.onSurface ? "  ·  ⌂ Home" : ""), seconds: 0.7)
            if let w = window {
                // A tab behind another one: it comes to the front.
                if self.bringTabForward(w) { self.applyLayout() }
                self.windows.focus(w)
            }
        }
        if onSurface {
            guard !busy, let m = moveEnter(at: path) else { return }
            perform(m, then: arrive)
        } else if path != state.path {
            navigate(to: path, then: arrive)
        } else {
            arrive()
        }
    }

    // MARK: Saved pools

    /// A saved pool being opened: the windows still to come (by app, each
    /// with the pool it goes to), and the windows that were already there.
    private var deploying: (waiting: [String: [(panel: UUID, item: SavedWindow)]], before: Set<UInt32>)?

    /// Browsers whose tabs can be saved and reopened, by bundle id.
    private static let browsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    /// The pool to save: the pool of the board you're on under the pointer
    /// (from a shortcut), else the one you're in (from the menu). It may
    /// hold a whole board of pools.
    private func poolToSave(fromMenu: Bool) -> Placed? {
        let pools = frames(current, in: viewport).filter { $0.depth == 0 }
        if !fromMenu {
            let point = NSEvent.mouseLocation
            if let hit = pools.first(where: { $0.rect.contains(point) }) { return hit }
        }
        let active = activePanel().id
        return pools.first { $0.panel.id == active }
    }

    /// The empty pool to open a saved pool into: the one under the pointer
    /// (from a shortcut), else the one you're in (from the menu).
    private func poolToFill(fromMenu: Bool) -> Placed? {
        let leaves = frames(current, in: viewport).filter { $0.panel.desktop == nil }
        if !fromMenu {
            let point = NSEvent.mouseLocation
            if let hit = leaves.filter({ $0.rect.contains(point) }).max(by: { $0.depth < $1.depth }) { return hit }
        }
        let active = activePanel().id
        return leaves.first { $0.panel.id == active }
    }

    /// Writes down a pool's setup, and lists its windows.
    private func record(_ p: Panel) -> (leaf: SavedLeaf, windows: [UInt32]) {
        var items: [SavedWindow] = []
        var list: [UInt32] = []
        for w in p.windows where windows.exists(w) {
            guard let pid = windows.pid(of: w), let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            else { continue }
            let rect = p.floatRect(w).map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
            items.append(SavedWindow(bundleID: bid, appName: windows.appName(w), rect: rect,
                                     urls: savingTabs[w],
                                     hidden: isInsideOnly(w) ? true : nil))
            list.append(w)
        }
        var inner: SavedNode?
        if let d = p.desktop {
            let r = record(d.root)
            inner = r.node
            list += r.windows
        }
        let leaf = SavedLeaf(name: p.name, landscape: p.landscape, hidden: p.scratch == true ? true : nil,
                             items: items, inner: inner)
        return (leaf, list)
    }

    private func record(_ node: Node) -> (node: SavedNode, windows: [UInt32]) {
        switch node {
        case .panel(let p):
            let r = record(p)
            return (.pool(r.leaf), r.windows)
        case .split(let s):
            var children: [SavedNode] = []
            var list: [UInt32] = []
            for c in s.children {
                let r = record(c)
                children.append(r.node)
                list += r.windows
            }
            return (.split(axis: s.axis, ratios: s.ratios, landscape: s.landscape, children: children), list)
        }
    }

    /// Hyper + Shift + S: saves the pool under the pointer (on the board
    /// you're on) to open again later into any empty pool: the pools inside
    /// it, their sizes, which apps live in each, where their windows sit and
    /// what's hidden. Hyper + Shift + W also closes it: its windows close,
    /// and apps left with no windows anywhere quit.
    func savePool(close: Bool, fromMenu: Bool = false) {
        guard !onSurface, !busy, let placed = poolToSave(fromMenu: fromMenu) else { return }
        browserAccessRefused = nil
        browserNeedsAnswer = nil
        let p = placed.panel
        savingTabs = browserTabs(for: p.windows + (p.desktop?.allWindows() ?? []))
        let r = record(p)
        savingTabs = [:]
        guard !r.windows.isEmpty else {
            Toast.show("This pool is empty — nothing to save", seconds: 1.2)
            return
        }
        let suggested = appSummary(r.windows.map { windows.appName($0) }, joiner: " + ")
        let shape = p.desktop.map { "\($0.panels().count) pools, " } ?? ""
        var info = "Saves its layout (\(shape)\(r.windows.count) window\(r.windows.count == 1 ? "" : "s"))"
            + (close ? " and closes it." : ".") + " Open it again into any empty pool with \(CapsKey.label) + Shift + O."
        if let app = browserAccessRefused {
            info += "\n\n\(app)'s tabs won't be saved: allow Scuba to control \(app) in System Settings › "
                + "Privacy & Security › Automation."
        } else if let app = browserNeedsAnswer {
            info += "\n\n\(app)'s tabs won't be saved this time: macOS is asking whether Scuba may control \(app). "
                + "Choose Allow, then save again."
        }
        guard let name = askText("Save pool \(placed.label)", info: info, value: p.name ?? suggested,
                                 button: close ? "Save & Close" : "Save") else { return }
        var saved = state.savedPools ?? []
        saved.removeAll { $0.name == name }   // the same name replaces the old one
        saved.append(SavedPool(id: UUID(), name: name, saved: Date(), layout: .pool(r.leaf)))
        state.savedPools = saved
        saveState()
        let refused = browserAccessRefused ?? browserNeedsAnswer
        browserAccessRefused = nil
        browserNeedsAnswer = nil
        if let app = refused {
            Toast.show("Saved “\(name)” — without \(app)'s tabs", seconds: 2)
        } else if !close {
            Toast.show("Saved “\(name)”", seconds: 1)
        }
        guard close else { return }
        checkpoint()
        let list = r.windows
        let pids = Set(list.compactMap { windows.pid(of: $0) })
        if let h = held, list.contains(h.window) {
            held = nil
            chip.hide()
        }
        for w in list {
            windows.close(w)
            remove(window: w)
        }
        if let marked = state.insideOnly {
            let kept = marked.filter { !list.contains($0) }
            state.insideOnly = kept.isEmpty ? nil : kept
        }
        // The pool goes too (unless it's the board's only one, which is left empty).
        if current.panels().count > 1, p.free != true {
            _ = current.removePanel(p)
            if state.lastPanelId == p.id { state.lastPanelId = nil }
            if let home = state.home, home.contains(p.id) { state.home = nil }
        } else {
            p.desktop = nil
            p.floating = nil
        }
        quitIdleApps(pids)
        glideLayout()
        if refused == nil { Toast.show("Saved and closed “\(name)”", seconds: 1.2) }
    }

    /// Quits the apps that were left with no windows at all (a moment after
    /// their windows closed). Finder stays.
    private func quitIdleApps(_ pids: Set<pid_t>) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            self.windows.refresh()
            let me = ProcessInfo.processInfo.processIdentifier
            for pid in pids where pid != me {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.bundleIdentifier != "com.apple.finder" else { continue }
                let left = self.windows.allIDs().filter { self.windows.pid(of: $0) == pid && self.windows.isStandard($0) }
                if left.isEmpty { app.terminate() }
            }
        }
    }

    /// Set when macOS refused to let Scuba ask a browser for its tabs (it
    /// hasn't been allowed under Privacy & Security › Automation).
    private var browserAccessRefused: String?

    /// Runs a script for a browser. False if it failed; notes when macOS
    /// refused access.
    @discardableResult
    private func runScript(_ source: String, app: String, result: UnsafeMutablePointer<NSAppleEventDescriptor?>? = nil) -> Bool {
        var error: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 || code == -1744 { browserAccessRefused = app }
            return false
        }
        result?.pointee = out
        return true
    }

    /// Browsers Scuba has already asked macOS about this time round.
    private var askedToControl = Set<String>()

    /// Set when macOS hasn't asked you yet whether Scuba may control a
    /// browser (its "Scuba wants to control…" prompt is up now).
    private var browserNeedsAnswer: String?

    /// Whether Scuba may control a browser (to read or open its tabs), found
    /// out without ever holding Scuba up. If macOS hasn't asked you yet, it
    /// asks now, in the background, and this time Scuba goes on without that
    /// browser's tabs. (Waiting for the answer froze Scuba.)
    private func mayControl(_ bundleID: String, app: String) -> Bool {
        let check = PermissionCheck(bundleID: bundleID)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            check.run(ask: false)
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.6) == .success else { return false }
        switch check.status {
        case 0:
            return true
        case -1744:   // not asked yet
            browserNeedsAnswer = app
            if askedToControl.insert(bundleID).inserted {
                NSApp.activate()
                DispatchQueue.global(qos: .userInitiated).async {
                    PermissionCheck(bundleID: bundleID).run(ask: true)
                }
            }
            return false
        case -1743:   // turned down
            browserAccessRefused = app
            return false
        default:      // not running, or no answer
            return false
        }
    }

    /// The tabs of the browser windows being saved, by window.
    private var savingTabs: [UInt32: [String]] = [:]

    /// How far apart two frames are: their corners and sizes, added up.
    private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        Double(abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height))
    }

    /// The tabs of each browser window in a list. Each browser is asked once
    /// for all its windows (title, where it sits and its tabs), and each of
    /// ours is paired with a different one of them, by where it sits and its
    /// size first, then by title, so two windows on the same page don't both
    /// get one window's tabs. Two of ours in the same spot at the same size
    /// (tucked away in the same corner) are made a little different in size
    /// for a moment so they can be told apart.
    private func browserTabs(for list: [UInt32]) -> [UInt32: [String]] {
        var byBrowser: [String: [UInt32]] = [:]
        for w in list where windows.exists(w) {
            guard let pid = windows.pid(of: w), let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  Controller.browsers[bid] != nil else { continue }
            byBrowser[bid, default: []].append(w)
        }
        var out: [UInt32: [String]] = [:]
        for (bid, ours) in byBrowser {
            guard let app = Controller.browsers[bid], mayControl(bid, app: app) else { continue }
            // Where each of ours sits, measured down from the top of the main
            // screen (the way the browser reports it).
            var frames: [UInt32: CGRect] = [:]
            var restore: [(window: UInt32, size: CGSize)] = []
            for w in ours {
                guard let f = windows.scriptFrame(of: w) else { continue }
                var now = f
                var bump: CGFloat = 0
                while frames.values.contains(where: { Controller.distance($0, now) < 8 }), bump < 112 {
                    bump += 16
                    windows.nudgeSize(w, to: CGSize(width: f.width + bump, height: f.height))
                    now = windows.scriptFrame(of: w) ?? f
                }
                if bump > 0 { restore.append((window: w, size: f.size)) }
                frames[w] = now
            }
            let script = """
            set sep to "<<F>>"
            set out to ""
            set AppleScript's text item delimiters to linefeed
            with timeout of 4 seconds
                tell application "\(app)"
                    repeat with w in windows
                        try
                            set b to bounds of w
                            set found to URL of every tab of w
                            set u to found as text
                            set out to out & (name of w) & sep & ((item 1 of b) as text) & "," & ((item 2 of b) as text) & "," & ((item 3 of b) as text) & "," & ((item 4 of b) as text) & sep & u & "<<W>>"
                        end try
                    end repeat
                end tell
            end timeout
            return out
            """
            var result: NSAppleEventDescriptor?
            let ran = runScript(script, app: app, result: &result)
            for r in restore { windows.nudgeSize(r.window, to: r.size) }
            guard ran, let text = result?.stringValue else { continue }
            var theirs: [(title: String, rect: CGRect?, urls: [String])] = []
            for chunk in text.components(separatedBy: "<<W>>") where !chunk.isEmpty {
                let parts = chunk.components(separatedBy: "<<F>>")
                guard parts.count >= 3 else { continue }
                let n = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let rect = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]) : nil
                let urls = parts[2...].joined(separator: "<<F>>").components(separatedBy: "\n").filter { !$0.isEmpty }
                theirs.append((title: parts[0], rect: rect, urls: urls))
            }
            // Every likely pairing, best first; each window is used once.
            var pairs: [(score: Double, ours: UInt32, theirs: Int)] = []
            for w in ours {
                let title = windows.title(of: w) ?? ""
                for (j, t) in theirs.enumerated() where !t.urls.isEmpty {
                    var place = Double.infinity
                    if let f = frames[w], let r = t.rect { place = Controller.distance(f, r) }
                    let named: Double
                    if title.isEmpty || t.title.isEmpty {
                        named = 400
                    } else if title == t.title {
                        named = 0
                    } else if title.contains(t.title) || t.title.contains(title) {
                        named = 40
                    } else {
                        named = 400
                    }
                    // Its place or its title has to agree.
                    guard place <= 40 || named < 400 else { continue }
                    pairs.append((score: min(place, 1000) + named, ours: w, theirs: j))
                }
            }
            var usedOurs = Set<UInt32>()
            var usedTheirs = Set<Int>()
            for pair in pairs.sorted(by: { $0.score < $1.score }) {
                guard !usedOurs.contains(pair.ours), !usedTheirs.contains(pair.theirs) else { continue }
                usedOurs.insert(pair.ours)
                usedTheirs.insert(pair.theirs)
                out[pair.ours] = theirs[pair.theirs].urls
            }
        }
        return out
    }

    /// "Maps + Google Chrome ×2": each app once, with how many windows it
    /// has when that's more than one.
    private func appSummary(_ names: [String], joiner: String) -> String {
        var order: [String] = []
        var count: [String: Int] = [:]
        for n in names {
            if count[n] == nil { order.append(n) }
            count[n, default: 0] += 1
        }
        return order.prefix(4).map { n -> String in
            let k = count[n] ?? 1
            return k > 1 ? "\(n) ×\(k)" : n
        }.joined(separator: joiner)
    }

    /// Hyper + Shift + O: picks a saved pool to open into the empty pool
    /// under the pointer (from the menu: the pool you're in).
    func chooseSavedPool(fromMenu: Bool = false) {
        guard !onSurface, !busy else { return }
        guard let saved = state.savedPools, !saved.isEmpty else {
            Toast.show("No saved pools yet — \(CapsKey.label) + Shift + S saves the pool under the pointer", seconds: 1.6)
            return
        }
        guard let target = poolToFill(fromMenu: fromMenu) else { return }
        guard target.panel.free != true else {
            Toast.show("Saved pools open into a pool, not the Desktop — \(CapsKey.label) + B opens one", seconds: 1.4)
            return
        }
        guard shownWindows(target.panel, of: target.owner).isEmpty else {
            Toast.show("Point at an empty pool first — \(CapsKey.label) + B opens one", seconds: 1.4)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: "Open in pool \(target.label)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let id = target.panel.id
        for sp in saved.sorted(by: { $0.saved > $1.saved }) {
            let apps = appSummary(appNames(sp.layout), joiner: ", ")
            menu.addItem(ActionItem("\(sp.name)   ·   \(apps)") { [weak self] in self?.deploy(sp, into: id) })
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// From the menu: opens a saved pool into the pool you're in, if it's empty.
    func chooseSavedPoolFromMenu(_ sp: SavedPool) {
        guard !onSurface, !busy, let target = poolToFill(fromMenu: true) else { return }
        guard target.panel.free != true else {
            Toast.show("Saved pools open into a pool, not the Desktop — \(CapsKey.label) + B opens one", seconds: 1.4)
            return
        }
        guard shownWindows(target.panel, of: target.owner).isEmpty else {
            Toast.show("Go into an empty pool first — \(CapsKey.label) + B opens one", seconds: 1.4)
            return
        }
        deploy(sp, into: target.panel.id)
    }

    /// Forgets a saved pool.
    func deleteSavedPool(_ id: UUID) {
        state.savedPools?.removeAll { $0.id == id }
        if state.savedPools?.isEmpty == true { state.savedPools = nil }
        saveState()
    }

    /// The apps in a saved setup, in order.
    private func appNames(_ node: SavedNode) -> [String] {
        switch node {
        case .pool(let leaf): return leaf.items.map { $0.appName } + (leaf.inner.map(appNames) ?? [])
        case .split(_, _, _, let children): return children.flatMap(appNames)
        }
    }

    /// Builds the pools of a saved setup, and lists which window goes where.
    private func build(_ node: SavedNode, into list: inout [(panel: UUID, item: SavedWindow)]) -> Node {
        switch node {
        case .pool(let leaf):
            return .panel(build(leaf, into: &list))
        case .split(let axis, let ratios, let landscape, let children):
            let s = Split(axis: axis, children: children.map { build($0, into: &list) })
            if ratios.count == s.children.count { s.ratios = ratios }
            s.landscape = landscape
            return .split(s)
        }
    }

    private func build(_ leaf: SavedLeaf, into list: inout [(panel: UUID, item: SavedWindow)]) -> Panel {
        let p = Panel(number: 0)
        fill(p, with: leaf, into: &list)
        return p
    }

    /// Gives a pool a saved pool's name, shape, hidden mark and inner board,
    /// and lists the windows that go in it.
    private func fill(_ p: Panel, with leaf: SavedLeaf, into list: inout [(panel: UUID, item: SavedWindow)]) {
        if let name = leaf.name { p.name = name }
        p.landscape = leaf.landscape
        if leaf.hidden == true {
            p.scratch = true
            if !roomInsideOnly { roomInsideOnly = true }
        }
        for item in leaf.items { list.append((p.id, item)) }
        if let inner = leaf.inner {
            let d = Desktop(root: build(inner, into: &list))
            d.renumber()
            p.desktop = d
        }
    }

    /// Opens a saved pool into an empty pool: its pools are rebuilt, each app
    /// opens (or makes a new window) and its window takes the spot it had.
    /// Browsers get their tabs back. Opened into the only pool of a board
    /// (dive into a breathing room), the saved pools become that board's own.
    func deploy(_ sp: SavedPool, into id: UUID) {
        guard !busy, deploying == nil, !onSurface,
              let placed = frames(current, in: viewport).first(where: { $0.panel.id == id && $0.panel.desktop == nil })
        else { return }
        guard shownWindows(placed.panel, of: placed.owner).isEmpty else {
            Toast.show("That pool isn't empty any more", seconds: 1.2)
            return
        }
        checkpoint()
        windows.refresh()
        browserAccessRefused = nil
        browserNeedsAnswer = nil
        var list: [(panel: UUID, item: SavedWindow)] = []
        let p = placed.panel
        guard case .pool(let top) = sp.layout else { return }
        let onlyPool = placed.owner.panels().count == 1
        if onlyPool, let inner = top.inner {
            // The board's only pool: the saved pools become the board itself.
            for item in top.items { list.append((p.id, item)) }
            placed.owner.root = build(inner, into: &list)
            if !top.items.isEmpty {
                // (A pool with windows of its own beside its inner board can't
                // be both; its own windows join the first pool.)
                let first = placed.owner.firstPanel(in: placed.owner.root).id
                list = list.map { entry in entry.panel == p.id ? (panel: first, item: entry.item) : entry }
            }
            placed.owner.renumber()
            if state.lastPanelId == p.id { state.lastPanelId = nil }
        } else {
            var leaf = top
            leaf.name = p.name ?? top.name
            fill(p, with: leaf, into: &list)
        }
        var waiting: [String: [(panel: UUID, item: SavedWindow)]] = [:]
        for entry in list { waiting[entry.item.bundleID, default: []].append(entry) }
        deploying = (waiting, Set(windows.allIDs()))
        // Apps coming forward shouldn't send you off to their other boards.
        quietUntil = Date().addingTimeInterval(16)
        applyLayout()
        for (bid, entries) in waiting { openForDeploy(bid, items: entries.map { $0.item }) }
        watchDeploy(name: sp.name)
        Toast.show("Opening “\(sp.name)”…", seconds: 1)
    }

    /// Gets an app to show one new window per saved window.
    private func openForDeploy(_ bid: String, items: [SavedWindow]) {
        if let app = Controller.browsers[bid] {
            openBrowserWindows(bid, app: app, items: items)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        let hasWindows = running.map { r in windows.allIDs().contains { windows.pid(of: $0) == r.processIdentifier } } ?? false
        var extra = items.count
        if running == nil || !hasWindows {
            // Not running, or no windows: opening it gives it a window.
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
            extra -= 1
        }
        guard extra > 0 else { return }
        let more = extra
        let wait: UInt64 = running == nil ? 2_000_000_000 : 300_000_000
        // More windows of an app that's already open: ask it for new ones (Cmd + N).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard let self, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.processIdentifier
            else { return }
            for _ in 0..<more {
                self.pressNewWindow(pid)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    /// Sends Cmd + N to an app.
    private func pressNewWindow(_ pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let n: CGKeyCode = 45   // the N key
        let down = CGEvent(keyboardEventSource: source, virtualKey: n, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: n, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.postToPid(pid)
        up?.postToPid(pid)
    }

    /// Browser windows for a saved pool. A browser that isn't running is
    /// started first, and the window it opens with takes the first spot. If
    /// Scuba isn't allowed to script it, plain new windows (Cmd + N) still
    /// fill the rest of the spots, just without their tabs.
    private func openBrowserWindows(_ bid: String, app: String, items: [SavedWindow]) {
        let safari = bid == "com.apple.Safari"
        Task { @MainActor [weak self] in
            guard let self else { return }
            func pid() -> pid_t? { NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.processIdentifier }
            var reuse = false
            if pid() == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                for _ in 0..<24 {   // up to six seconds for its first window
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self.windows.refresh()
                    if let p = pid(), self.windows.allIDs().contains(where: { self.windows.pid(of: $0) == p && self.windows.isStandard($0) }) {
                        reuse = true
                        break
                    }
                }
            }
            let scriptable = self.mayControl(bid, app: app)
            for (i, item) in items.enumerated() {
                let first = reuse && i == 0
                var ok = false
                if scriptable { ok = self.openBrowserWindow(app, safari: safari, urls: item.urls ?? [], reuseFront: first) }
                if !ok, !first, let p = pid() { self.pressNewWindow(p) }
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    /// A browser window with these tabs: a new one, or the front one (the
    /// window a browser just opened with). False if it couldn't be scripted.
    private func openBrowserWindow(_ app: String, safari: Bool, urls: [String], reuseFront: Bool) -> Bool {
        if reuseFront && urls.isEmpty { return true }
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["with timeout of 4 seconds", "tell application \"\(app)\""]
        if safari {
            if reuseFront {
                if let first = urls.first { lines.append("set URL of front document to \(q(first))") }
            } else {
                lines.append(urls.first.map { "make new document with properties {URL:\(q($0))}" } ?? "make new document")
            }
            for u in urls.dropFirst() { lines.append("tell front window to make new tab at end of tabs with properties {URL:\(q(u))}") }
        } else {
            lines.append(reuseFront ? "set w to front window" : "set w to make new window")
            if let first = urls.first { lines.append("set URL of active tab of w to \(q(first))") }
            for u in urls.dropFirst() { lines.append("tell w to make new tab at end of tabs with properties {URL:\(q(u))}") }
        }
        lines.append("end tell")
        lines.append("end timeout")
        return runScript(lines.joined(separator: "\n"), app: app)
    }

    /// Watches for the new windows and puts each one in its spot, for up to
    /// about fifteen seconds.
    private func watchDeploy(name: String) {
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, var d = self.deploying else { return }
                self.windows.refresh()
                var placedAny = false
                // Oldest first, so windows land in the order they were asked for.
                for w in self.windows.allIDs().sorted() where !d.before.contains(w) && self.windows.isStandard(w) {
                    guard let pid = self.windows.pid(of: w),
                          let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                          var queue = d.waiting[bid], !queue.isEmpty else { continue }
                    let entry = queue.removeFirst()
                    d.waiting[bid] = queue.isEmpty ? nil : queue
                    d.before.insert(w)
                    guard let target = self.panelHere(entry.panel) else { continue }
                    self.remove(window: w)   // in case it joined somewhere on its own
                    target.windows.append(w)
                    target.setFloat(w, entry.item.rect.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) })
                    if entry.item.hidden == true {
                        var marked = self.state.insideOnly ?? []
                        if !marked.contains(w) { marked.append(w) }
                        self.state.insideOnly = marked
                    }
                    placedAny = true
                }
                self.deploying = d
                if placedAny, !self.busy { self.applyLayout() }
                if d.waiting.isEmpty { break }
            }
            guard let self else { return }
            let missing = self.appSummary(self.deploying?.waiting.values.flatMap { $0.map { $0.item.appName } } ?? [],
                                          joiner: ", ")
            self.deploying = nil
            self.quietUntil = Date().addingTimeInterval(0.5)
            if !self.busy { self.glideLayout() }
            if let app = self.browserAccessRefused {
                self.browserAccessRefused = nil
                Toast.show("“\(name)” is open — \(app)'s tabs need permission: allow Scuba to control \(app) in "
                           + "System Settings › Privacy & Security › Automation", seconds: 4)
            } else if let app = self.browserNeedsAnswer {
                self.browserNeedsAnswer = nil
                Toast.show("“\(name)” is open — without \(app)'s tabs: choose Allow when macOS asks, then open it again",
                           seconds: 3)
            } else {
                Toast.show(missing.isEmpty ? "“\(name)” is open"
                                           : "“\(name)” is open — no new window came from \(missing)",
                           seconds: 1.4)
            }
        }
    }

    private func askText(_ title: String, info: String, value: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? value : text
    }

    // MARK: Names

    /// Names a panel on the board you're on (empty = back to its number).
    func renamePanel(_ target: Panel? = nil) {
        let p = target ?? activePanel()
        askForName("Name pool \(p.number)", current: p.name) { name in
            self.checkpoint()
            p.name = name
            self.applyLayout()
            self.showNumbers()
        }
    }

    /// Names the board you're on (the panel you zoomed into to get here).
    func renameBoard() {
        guard let last = state.path.last,
              let owner = desktopStack().dropLast().last?.panel(id: last) else {
            guard state.otherMains != nil else {
                Toast.show("The main board is called Main — once you have more than one, you can name them")
                return
            }
            let main = state.root
            askForName("Name this Main", current: main.name) { name in
                self.checkpoint()
                main.name = name
                self.applyLayout()
                Toast.show(self.mainName(main), seconds: 0.8)
            }
            return
        }
        renamePanel(owner)
    }

    private func askForName(_ title: String, current: String?, _ done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Leave it empty to go back to the number."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = "e.g. Work, Music, Client X"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            done(text.isEmpty ? nil : text)
        }
    }

    // MARK: Saving

    private var saveWork: DispatchWorkItem?
    private static let saveQueue = DispatchQueue(label: "scuba.save", qos: .utility)

    /// Saves the layout a moment from now: a burst of changes (a drag, a
    /// glide) is written once, and the writing happens off the main thread.
    func saveState() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeState() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes anything still waiting, right now (when Scuba quits).
    func flushSave() {
        guard let work = saveWork else { return }
        work.cancel()
        writeState(wait: true)
    }

    private func writeState(wait: Bool = false) {
        saveWork = nil
        guard let data = state.encoded() else { return }
        let url = stateURL
        let write = { try? data.write(to: url, options: .atomic) }
        if wait { Self.saveQueue.sync { _ = write() } } else { Self.saveQueue.async { _ = write() } }
    }

    // MARK: Undo

    private var undoStack: [Data] = []

    /// Saves the layout so the next change can be undone.
    func checkpoint() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        undoStack.append(data)
        if undoStack.count > 30 { undoStack.removeFirst() }
    }

    /// Hyper + Z: puts the layout back the way it was before the last change.
    func undo(quiet: Bool = false) {
        guard !busy else { return }   // mid-zoom or mid-glide: nothing to do yet
        guard let data = undoStack.popLast(),
              let restored = try? JSONDecoder().decode(AppState.self, from: data) else {
            Toast.show("Nothing to undo")
            return
        }
        let here = state.path
        func emptyRoom(_ p: Panel) -> Bool { p.scratch == true && p.windows.isEmpty && p.desktop == nil }
        let hadRoom = current.panels().contains(where: emptyRoom)
        restored.root.sanitize()
        state = restored
        state.path = here
        normalizePath()
        // An empty breathing room saved along with an older layout doesn't
        // come back with it (it would split a pool in two): only what you
        // actually changed is undone.
        if !hadRoom {
            let d = current
            for p in d.panels() where emptyRoom(p) { d.removeRoom(p) }
        }
        lastApplied.removeAll()
        selection = nil
        glideLayout()
        if !quiet { Toast.show("Undone", seconds: 0.7) }
    }

    func setHome() {
        state.home = state.path.isEmpty ? nil : state.path
        state.homeMain = state.otherMains == nil ? nil : state.root.id
        saveState()
        Toast.show("⌂ Home is now: \(locationLabel())")
    }

    /// Desktops that hold only one plain panel aren't worth keeping once you
    /// leave them; fold them back into their panel.
    private func collapseIfTrivial(_ leaving: Desktop, into owner: Panel) {
        let ps = leaving.panels()
        guard ps.count == 1, ps[0].desktop == nil else { return }
        owner.desktop = nil
        moveContents(from: ps[0], to: owner)
    }

    /// Goes to another board. Inside or outside the one you're on, it's one
    /// zoom; anywhere else it's a flight: up to the board both share, then
    /// down to the new one.
    func navigate(to newPath: [UUID], then next: (() -> Void)? = nil) {
        guard !busy, !onSurface, newPath != state.path, isValid(newPath) else { next?(); return }
        if let m = moveTo(newPath) {
            perform(m, then: next)
            return
        }
        // Straight up or down but no zoom worked out: just go there.
        if newPath.starts(with: state.path) || state.path.starts(with: newPath) {
            state.path = newPath
            applyLayout()
            next?()
            return
        }
        // The board both places share: the path up to where they differ.
        let common = zip(state.path, newPath).prefix(while: { $0.0 == $0.1 }).count
        let shared = Array(newPath.prefix(common))
        navigate(to: shared) { [weak self] in
            self?.navigate(to: newPath, then: next)
        }
    }

    // MARK: Quitting

    /// Puts every window somewhere visible so nothing is left tucked away.
    func restoreAll() {
        joinTimer?.invalidate()
        joinTimer = nil
        minimizeTimer?.invalidate()
        minimizeTimer = nil
        portholeCapture?.cancel()
        // Bring minimized windows back first, and give them a moment to land
        // before they're moved.
        windows.refresh()
        let minimized = windows.parked.filter { windows.isMinimized($0) }
        for w in minimized { windows.unminimize(w) }
        if !minimized.isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.45)) }
        for pid in hiddenByUs { NSRunningApplication(processIdentifier: pid)?.unhide() }
        hiddenByUs.removeAll()
        windows.refresh()
        for (w, f) in surfaceFrames where windows.exists(w) { windows.setFrame(w, f) }
        windows.unparkAll(on: screen)
    }
}

/// Asks macOS whether Scuba may send a browser Apple events, off the main
/// thread: when macOS has to ask you, the answer takes as long as you do.
private final class PermissionCheck: @unchecked Sendable {
    let bundleID: String
    var status: OSStatus = 1

    init(bundleID: String) { self.bundleID = bundleID }

    func run(ask: Bool) {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }
}
