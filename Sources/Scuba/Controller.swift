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
    let shade = DepthShade()
    let tiles = CrowdTiles()
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

    let gap: CGFloat = 8

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
        // Always start at Home (the top level unless you've set another),
        // on the Main it's on.
        if let hm = state.homeMain, hm != state.root.id {
            let all = allMains
            if let i = all.firstIndex(where: { $0.id == hm }) { setMains(all, current: i) }
        }
        normalizePath()
        state.path = state.home ?? []
        tiles.onOpen = { [weak self] t in self?.openTile(t) }
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
        state.save(to: stateURL)
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
        if let t = shownTiles.first(where: { $0.badge == "lock.fill" && $0.rect.contains(point) }),
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
        if let t = shownTiles.first(where: { $0.badge == "lock.fill" && $0.rect.contains(point) }),
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
        t.badge = "lock.fill"
        t.jumpOnly = true
        return t
    }

    /// True for a window marked to only show on its own board (Hyper + P).
    func isInsideOnly(_ w: UInt32) -> Bool { state.insideOnly?.contains(w) == true }

    /// A panel's windows as they show from where you are: inside-only
    /// windows are left out unless their board is the one on screen.
    private func shownWindows(_ p: Panel, of owner: Desktop) -> [UInt32] {
        var list = p.windows
        // A cut window is on its way somewhere else: its pool carries on without it.
        if let h = held, h.kind == .cut { list.removeAll { $0 == h.window } }
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
        case .panel(let p): return isHiddenRoom(p, of: owner)
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
            // Only clearly wide or clearly tall spaces count; near-square ones leave it alone.
            let shape = shapeOf(r)
            if let shape {
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
        guard let shape = shapeOf(r)
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

    private func remove(window w: UInt32) {
        for main in allMains {
            forEachPanel(main) { p in
                p.windows.removeAll { $0 == w }
                p.setFloat(w, nil)
            }
        }
        lastApplied[w] = nil
        onTop.remove(w)
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
        windows.refresh()
        for main in allMains {
            forEachPanel(main) { p in p.windows.removeAll { !self.windows.exists($0) } }
        }
        foldAwayRoom()
        if let h = held, !windows.exists(h.window) {
            held = nil
            chip.hide()
        }
        if onSurface {
            layoutSurface()
            finishLayout()
            return
        }
        captureManualMoves()
        if autoRotate { adapt(current.root, viewport, current) }

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
        for placed in placedAll where placed.panel.desktop == nil {
            let target = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
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
                            t.badge = "lock.fill"
                            t.live = false
                            crowd.append(t)
                        }
                        nowPortholed.insert(w)
                    }
                }
                continue
            }
            // Too small to be useful: show the main app's icon instead (its
            // windows are tucked away until you dive in).
            if let tile = crowdTile(for: placed, in: target) {
                crowd.append(tile)
                continue
            }
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
                            t.badge = "lock.fill"
                            t.jumpOnly = true
                            crowd.append(t)
                        }
                    } else {
                        if var t = portholeTile(w, spot: sp, placed: placed, target: target) {
                            t.badge = "lock.fill"
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
                guard var rel = placed.panel.floatRect(w) else {
                    windows.setFrame(w, fill)
                    lastApplied[w] = Applied(frame: windows.frame(of: w) ?? fill, panelRect: target,
                                             panel: placed.panel.id, filled: true)
                    continue
                }
                if let box = stretch {
                    rel = CGRect(x: (rel.minX - box.minX) / box.width, y: (rel.minY - box.minY) / box.height,
                                 width: rel.width / box.width, height: rel.height / box.height)
                }
                let f = absolute(rel, in: target)
                windows.setFrame(w, f)
                // A stretched spot is only how it looks from here: don't save it as the window's own.
                lastApplied[w] = stretch != nil ? nil
                    : Applied(frame: windows.frame(of: w) ?? f, panelRect: target, panel: placed.panel.id, filled: false)
            }
        }
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
        for w in everyWindow() where !visible.contains(w) {
            windows.park(w, on: screen)
            lastApplied[w] = nil   // tucked away, not a manual move
        }
        // Your normal desktop windows step aside while you're inside.
        for w in surfaceFrames.keys where windows.exists(w) {
            windows.park(w, on: screen)
        }
        runProbes(probeSpots)
        // An app that won't shrink to its panel: widen the panel to fit it,
        // then lay out once more.
        if growToFit, !refitting, refitPanels(leaves) {
            refitting = true
            applyLayout()
            refitting = false
            return
        }
        shownTiles = crowd
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
        live.stopAll()
        shownTiles = []
        portholed = []
        mirrored = []
        for w in everyWindow() {
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
        let members = (only ?? panel.windows).filter { $0 != excluding && !onTop.contains($0) }
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
        state.save(to: stateURL)
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
        guard glideMotion, !busy, !gliding, !onSurface, edgeWindow == nil, glider.hasPermission, AXIsProcessTrusted() else {
            applyLayout()
            return
        }
        windows.refresh()
        // Every board window in view now (some may be on their way out of view).
        var seen: [UInt32: CGRect] = [:]
        for w in Set(state.root.allWindows()) where windows.exists(w) && !windows.parked.contains(w) {
            if let f = windows.frame(of: w), screen.frame.intersects(f) { seen[w] = f }
        }
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
                for w in before.keys where self.windows.exists(w) && !self.windows.parked.contains(w) {
                    guard let f = self.windows.frame(of: w), self.screen.frame.intersects(f) else { continue }
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
        guard bounds.enabled, !onSurface else {
            bounds.hide()
            return
        }
        bounds.show(frames(current, in: viewport).filter { $0.depth == 0 }.map { $0.rect }, on: screen)
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
        for placed in frames(current, in: viewport) where placed.panel.desktop == nil {
            let target = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
            let shown = shownWindows(placed.panel, of: placed.owner)
            let fill = fillRect(for: placed.panel, in: target, only: shown)
            for w in shown where w != edgeWindow && w != spotlit && !windows.parked.contains(w) && !portholed.contains(w)
                && liveIn[w] == placed.panel.id {
                if let rel = placed.panel.floatRect(w) {
                    windows.setFrame(w, absolute(rel, in: target))
                } else {
                    windows.setFrame(w, fill)
                }
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
    }
    private struct EdgeSession {
        let window: UInt32
        let start: CGRect      // the window's frame before the drag
        let pool: CGRect       // its pool, before the drag
        let depth: Int
        var grips: [EdgeGrip]
    }
    private var edgeSession: EdgeSession?
    /// The window being resized by hand: layouts leave it alone until you let go.
    private var edgeWindow: UInt32?
    private var edgeLastLayout = Date.distantPast

    /// While you drag a filled window's edge, the gap on that side follows
    /// it: the neighbours give way as you drag and the window stays filled.
    /// Edges along the outside of the board don't count. Returns true when
    /// the resize was taken up this way (so it isn't turned into a float).
    @discardableResult
    func edgeResize(_ w: UInt32, final: Bool) -> Bool {
        defer {
            if final {
                edgeSession = nil
                edgeWindow = nil
            }
        }
        guard edgeGaps, !onSurface, !busy, spotlit != w, let now = windows.frame(of: w) else { return false }
        if edgeSession?.window != w {
            guard let last = lastApplied[w], last.filled,
                  let placed = frames(current, in: viewport)
                    .first(where: { $0.panel.id == last.panel && $0.panel.desktop == nil })
            else { return false }
            edgeSession = EdgeSession(window: w, start: last.frame, pool: placed.rect, depth: placed.depth, grips: [])
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
        if wide, !have(.right), abs(now.maxX - was.maxX) > moved, abs(was.maxX - (p.maxX - half)) < near,
           let d = gapAt(.h, p.maxX) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .right, offset: d.position - was.maxX))
        }
        if wide, !have(.left), abs(now.minX - was.minX) > moved, abs(was.minX - (p.minX + half)) < near,
           let d = gapAt(.h, p.minX) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .left, offset: d.position - was.minX))
        }
        if tall, !have(.top), abs(now.maxY - was.maxY) > moved, abs(was.maxY - (p.maxY - half)) < near,
           let d = gapAt(.v, p.maxY) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .top, offset: d.position - was.maxY))
        }
        if tall, !have(.bottom), abs(now.minY - was.minY) > moved, abs(was.minY - (p.minY + half)) < near,
           let d = gapAt(.v, p.minY) {
            session.grips.append(EdgeGrip(split: d.split, index: d.index, edge: .bottom, offset: d.position - was.minY))
        }
        edgeSession = session
        guard !session.grips.isEmpty else { return false }
        if !hadGrips {
            checkpoint()   // Hyper + Z puts the gaps back
            edgeWindow = w
        }

        let fresh = dividers()
        for g in session.grips {
            let axis: Axis = (g.edge == .left || g.edge == .right) ? .h : .v
            guard let d = fresh.first(where: { $0.split === g.split && $0.index == g.index }), d.axis == axis
            else { continue }
            switch g.edge {
            case .right: moveDivider(d, to: CGPoint(x: now.maxX + g.offset, y: now.midY))
            case .left: moveDivider(d, to: CGPoint(x: now.minX + g.offset, y: now.midY))
            case .top: moveDivider(d, to: CGPoint(x: now.midX, y: now.maxY + g.offset))
            case .bottom: moveDivider(d, to: CGPoint(x: now.midX, y: now.minY + g.offset))
            }
        }
        if final {
            // Let go: the window settles into its pool, still filling it.
            edgeWindow = nil
            touched.remove(w)
            lastApplied[w] = nil
            applyLayout()
        } else if Date().timeIntervalSince(edgeLastLayout) > 1.0 / 40 {
            edgeLastLayout = Date()
            liveLayout()
        }
        return true
    }

    /// A new press of the mouse: any edge drag that never saw its release is over.
    func clearEdgeResize() {
        guard edgeSession != nil || edgeWindow != nil else { return }
        edgeSession = nil
        edgeWindow = nil
        applyLayout()
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
        let occupied = !to.panel.windows.isEmpty
        to.panel.windows.append(w)
        if occupied {
            let r = to.rect
            let half: CGRect = r.width >= r.height
                ? CGRect(x: landing.x < r.midX ? 0 : 0.5, y: 0, width: 0.5, height: 1)
                : CGRect(x: 0, y: landing.y < r.midY ? 0 : 0.5, width: 1, height: 0.5)
            to.panel.setFloat(w, half)
        }
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
    /// along its row or column just enough to hold the window, taking the
    /// space evenly from its neighbours (never more than 80% of the row).
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
            let wantW = need.width > target.width + 4, wantH = need.height > target.height + 4
            guard wantW || wantH, let loc = current.parent(of: p.id) else { continue }
            let s = loc.split
            guard (s.axis == .h && wantW) || (s.axis == .v && wantH) else { continue }
            let span = s.axis == .h ? placed.rect.width : placed.rect.height
            let share = s.ratios[loc.index]
            guard share > 0.001 else { continue }
            let rowLength = span / CGFloat(share)
            let needed = Double(((s.axis == .h ? need.width : need.height) + gap + 2) / rowLength)
            let newShare = min(needed, 0.8)
            let others = 1 - share
            guard newShare > share + 0.005, others > 0.01 else { continue }
            let left = 1 - newShare
            s.ratios = s.ratios.enumerated().map { $0.offset == loc.index ? newShare : $0.element * left / others }
            changed = true
        }
        return changed
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
        guard !onSurface, !busy else { return }
        let d = current
        let rooms = d.panels().filter { $0.scratch == true && $0.windows.isEmpty && $0.desktop == nil }
        if rooms.isEmpty {
            checkpoint()   // Hyper + Z folds it away again
            placeRoom(on: d, entering: lastRoomTarget ?? screen.frame)
        } else {
            // Folding it away isn't saved for undo: Hyper + B opens it again.
            for p in rooms { d.removeRoom(p) }
        }
        glideLayout()
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
        if roomQuarter {
            // Turn the board to suit the screen it's about to fill first, so the
            // corner is worked out from the arrangement you'll actually see.
            if autoRotate { adapt(d.root, viewport, d) }
            d.addQuadrantRoom(right: onRight, bottom: bottom)
        } else {
            _ = d.addRoom(onRight: onRight, share: roomShare)
        }
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
            if target.desktop == nil {
                let nested = Desktop.single()
                self.moveContents(from: target, to: nested.lowestNumbered())
                target.desktop = nested
            }
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
        guard crowdIcons, !list.isEmpty,
              target.width < 340 || target.height < 230,
              spotlit.map({ !list.contains($0) }) ?? true else { return nil }
        // The main app: a filled window if there is one, else the biggest float.
        let main = list.first { p.floatRect($0) == nil }
            ?? list.max { a, b in
                let ra = p.floatRect(a) ?? .zero, rb = p.floatRect(b) ?? .zero
                return ra.width * ra.height < rb.width * rb.height
            }
        guard let w = main else { return nil }
        return CrowdTile(rect: target, icon: windows.appIcon(w), name: windows.appName(w),
                         extra: list.count - 1, panel: p.id, owner: placed.owner.id, window: w)
    }

    /// Clicking an app-icon tile dives straight into that panel.
    func openTile(_ t: CrowdTile) {
        guard !busy, !onSurface, let ownerPath = boardPaths()[t.owner] else { return }
        if t.porthole || t.jumpOnly {
            jump(to: ownerPath, panel: t.panel, window: t.window)
            return
        }
        var found: Panel?
        forEachPanel(state.root) { if $0.id == t.panel { found = $0 } }
        guard let p = found else { return }
        if p.desktop == nil {
            let nested = Desktop.single()
            moveContents(from: p, to: nested.lowestNumbered())
            p.desktop = nested
        }
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
    func previewDrop(_ dragged: UInt32, target: DropTarget?) {
        guard !onSurface else { return }
        var moves: [(UInt32, CGRect)] = []
        var key = "none"
        if let t = target {
            let p = t.panel
            let inner = t.panelRect.insetBy(dx: gap / 2, dy: gap / 2)
            let others = p.windows.filter { $0 != dragged && !windows.parked.contains($0) }
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
                        key = "\(p.id)-f-\(Int(fill.minX / 24))-\(Int(fill.minY / 24))-\(Int(fill.width / 24))-\(Int(fill.height / 24))"
                    }
                }
            case .newPanel:
                if let keep = t.remaining?.insetBy(dx: gap / 2, dy: gap / 2) {
                    for w in others {
                        if let rel = p.floatRect(w) { moves.append((w, absolute(rel, in: keep))) }
                        else { moves.append((w, fillRect(for: p, in: keep, excluding: dragged))) }
                    }
                    key = "\(p.id)-n-\(t.label)-\(keep.minX)-\(keep.minY)"
                }
            case .fill:
                key = "\(p.id)-fill"
            }
        }
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
        Toast.show("Sent \(windows.appName(w)) to your desktop  ·  Hyper + Esc to see it", seconds: 1.6)
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
        Toast.show("\(name) went to your desktop  ·  Hyper + Esc to see it", seconds: 1.4)
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
        state.save(to: stateURL)
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
        showBounds()
        state.save(to: stateURL)
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
                apps = names.isEmpty ? "empty · Hyper + scroll here to dive in" : names.joined(separator: ", ")
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
        checkpoint()
        removeLive(w)   // also clears floating: a placed window fills its panel
        let target = p.desktop?.landingPanel() ?? p
        target.windows.append(w)
        state.lastPanelId = p.id
        glideLayout()
    }

    func releaseFocused() {
        guard let w = windows.focusedWindowID() else { Toast.show("No focused window"); return }
        checkpoint()
        if held?.window == w { held = nil; chip.hide() }
        remove(window: w)
        ignored.insert(w)
        state.save(to: stateURL)
        Toast.show("Released \(windows.appName(w))")
    }

    // MARK: Cut, copy and paste

    enum HoldKind { case cut, copy }
    /// The window you cut or copied, waiting to be put down (one at a time).
    private(set) var held: (window: UInt32, kind: HoldKind, from: UUID)?
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
        // One at a time: whatever you were holding goes back first.
        let wasCut = held?.kind == .cut
        held = (w, kind, from)
        if spotlit == w { spotlit = nil }
        let name = windows.appName(w)
        chip.onClick = { [weak self] in self?.putBack() }
        chip.show(icon: windows.appIcon(w), title: kind == .cut ? "Cut: \(name)" : "Copied: \(name)",
                  hint: kind == .cut ? "Hyper + V puts it down · click to put it back"
                                     : "Hyper + V pastes a copy · click to cancel",
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
            Toast.show("Nothing to paste — Hyper + X cuts a window, Hyper + C copies one", seconds: 1.4)
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
        checkpoint()
        held = nil
        chip.hide()
        if h.kind == .cut { removeMembership(w, from: h.from) }
        landInHalf(w, of: target, at: point)
        if target.depth >= 1, portholes { probing.insert(w) }
        state.lastPanelId = target.panel.id
        glideLayout()
        windows.focus(w)
        Toast.show(h.kind == .cut ? "\(name) → pool \(target.label)" : "\(name) is in pool \(target.label) too", seconds: 1)
    }

    /// Takes a window out of one pool (on any Main).
    private func removeMembership(_ w: UInt32, from id: UUID) {
        var removed = false
        for main in allMains {
            forEachPanel(main) { p in
                guard p.id == id, p.windows.contains(w) else { return }
                p.windows.removeAll { $0 == w }
                p.setFloat(w, nil)
                removed = true
            }
        }
        if !removed { remove(window: w) }
        lastApplied[w] = nil
    }

    /// Takes a window out of the pool it's live in before it goes somewhere
    /// else. A window with copies keeps its other pools.
    private func removeLive(_ w: UInt32) {
        if held?.window == w {
            held = nil
            chip.hide()
        }
        var holders = 0
        for main in allMains { forEachPanel(main) { if $0.windows.contains(w) { holders += 1 } } }
        if holders > 1, let id = liveIn[w] ?? chain(for: w)?.last?.id {
            removeMembership(w, from: id)
        } else {
            remove(window: w)
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
        func unused(_ p: Panel) -> Bool { p.windows.isEmpty && (p.desktop?.allWindows().isEmpty ?? true) }
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
        Toast.show("That's everything · Hyper + Esc for your desktop", seconds: 1.1)
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
        Toast.show("\(mainName(state.root)) is the top · Hyper + Esc for your desktop", seconds: 1.1)
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
        zoomInto(activePanel())
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
        for w in windows.parked where windows.isMinimized(w) { windows.unminimize(w) }
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
        state.save(to: stateURL)
        if !onSurface { applyLayout() }
        Toast.show("Fresh start: one Main, two empty pools", seconds: 1.4)
    }

    func resetLayout() {
        windows.unparkAll(on: screen)
        state = AppState()
        state.save(to: stateURL)
        Toast.show("Reset to two pools")
    }

    // MARK: Drag and drop

    enum DropAction {
        case fill                          // snap to fill the panel
        case newPanel(Axis, before: Bool)  // split off a new panel on that side
        case float                         // stay where dropped, inside the panel
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
        case .fill, .float:
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

    func drop(_ window: UInt32, on target: DropTarget) {
        onTop.remove(window)
        // Placing a window that's in Spotlight (a new one, say) ends Spotlight.
        if spotlit == window { spotlit = nil }
        switch target.action {
        case .newPanel(let axis, let before):
            let fresh = target.owner.addPanel(nextTo: target.panel, axis: axis, before: before)
            put(window, in: fresh)
            Toast.show("\(windows.appName(window)) → new pool \(fresh.number)", seconds: 0.9)
        case .fill:
            put(window, in: target.panel)
            Toast.show("\(windows.appName(window)) → pool \(target.panelLabel)", seconds: 0.9)
        case .float:
            // Keep it where you dropped it, as part of this panel.
            checkpoint()
            let inner = target.panelRect.insetBy(dx: gap / 2, dy: gap / 2)
            let dropped = windows.frame(of: window) ?? inner
            removeLive(window)
            target.panel.windows.append(window)
            target.panel.setFloat(window, relative(dropped, in: inner))
            state.lastPanelId = target.panel.id
            glideLayout()
        }
    }

    /// Hyper + F: switch the focused window between floating and filling.
    func toggleFloat() {
        guard let w = windows.focusedWindowID(), let c = chain(for: w), let p = c.last else {
            Toast.show("Put the window in a pool first")
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

    // MARK: Dividers

    /// A gap between two neighboring members of a split.
    struct Divider {
        let split: Split
        let index: Int          // between children index and index + 1
        let axis: Axis          // .h = a vertical line between side-by-side members
        let frame: CGRect       // the whole split's area (AppKit coordinates)
        let position: CGFloat   // x of the line for .h, y for .v
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
                let items = shownChildren(s, of: owner)
                // A split with a folded-away room panel has no draggable gaps.
                let draggable = items.count == s.children.count
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
                    if draggable, k < items.count - 1 {
                        let at = s.axis == .h ? r.minX + r.width * pos : r.maxY - r.height * pos
                        out.append(Divider(split: s, index: item.index, axis: s.axis, frame: r, position: at))
                    }
                }
            }
        }
        walk(board.root, area, board)
        return out
    }

    /// The divider closest to a point, if one is within `tolerance` points.
    func divider(near p: CGPoint, tolerance: CGFloat) -> Divider? {
        func distance(_ d: Divider) -> CGFloat? {
            if d.axis == .h {
                guard p.y >= d.frame.minY, p.y <= d.frame.maxY else { return nil }
                return abs(p.x - d.position)
            } else {
                guard p.x >= d.frame.minX, p.x <= d.frame.maxX else { return nil }
                return abs(p.y - d.position)
            }
        }
        var best: (Divider, CGFloat)?
        for d in dividers() {
            guard let dist = distance(d), dist <= tolerance else { continue }
            if best == nil || dist < best!.1 { best = (d, dist) }
        }
        return best?.0
    }

    /// Moves a divider so it sits under the given point.
    func moveDivider(_ d: Divider, to p: CGPoint) {
        let s = d.split
        let i = d.index
        guard i + 1 < s.ratios.count else { return }
        let t = d.axis == .h
            ? Double((p.x - d.frame.minX) / d.frame.width)
            : Double((d.frame.maxY - p.y) / d.frame.height)
        var before = 0.0
        for k in 0..<i { before += s.ratios[k] }
        let after = before + s.ratios[i] + s.ratios[i + 1]
        let minShare = 0.05
        let clamped = min(max(t, before + minShare), after - minShare)
        s.ratios[i] = clamped - before
        s.ratios[i + 1] = after - clamped
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
            if p.desktop == nil {
                let nested = Desktop.single()
                moveContents(from: p, to: nested.lowestNumbered())
                p.desktop = nested
            }
            enterBoards(at: [p.id])
            return
        }
        if state.path.isEmpty {
            zoomInto(p)          // already at the top: a normal zoom-in
            return
        }
        if state.path == [p.id] { Toast.show(locationLabel()); return }
        if p.desktop == nil {
            let nested = Desktop.single()
            moveContents(from: p, to: nested.lowestNumbered())
            p.desktop = nested
        }
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
        // The only panel here (breathing room aside) already fills the screen;
        // another level would add nothing. The breathing room itself is a
        // fresh, empty place, so you can always dive into that.
        if isAsFarIn(p) {
            Toast.show("Already as far in as it goes — add a pool with Hyper + N")
            return nil
        }
        guard let target = rect(ofTopPanel: p.id) else { return nil }
        let newPath = state.path + [p.id]
        return Move(zoomIn: true, target: target, toKey: placeKey(newPath)) {
            if p.desktop == nil {
                // First time in: the panel becomes a board of its own, starting
                // with one panel that holds the panel's windows.
                let nested = Desktop.single()
                self.moveContents(from: p, to: nested.lowestNumbered())
                p.desktop = nested
            }
            self.state.path = newPath
            self.addBreathingRoom(entering: target)
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
        }
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
            } else if let hit = frames(current, in: viewport)
                        .first(where: { $0.depth == 0 && $0.rect.contains(point) }) {
                m = moveInto(hit.panel)
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
        let known = Set(everyWindow())
        let fresh = windows.onScreenIDs().filter {
            !known.contains($0) && surfaceFrames[$0] == nil && !ignored.contains($0) && windows.isStandard($0)
                && isOnMyScreen($0) && !belongsElsewhere($0)
        }
        guard !fresh.isEmpty else { return }
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
            return p.panel.windows.isEmpty && (!crowdIcons || (t.width >= 340 && t.height >= 230))
        } : []
        for w in fresh {
            guard let f = windows.frame(of: w) else { continue }
            let center = CGPoint(x: f.midX, y: f.midY)
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
            Toast.show("\(names.joined(separator: ", ")) joined \(locationLabel())", seconds: 0.9)
        }
    }

    /// Puts a window in a pool: an empty pool takes it whole; in one that's
    /// in use it floats in the half where `point` is, and the windows there
    /// make room (the way a thrown window lands).
    private func landInHalf(_ w: UInt32, of target: Placed, at point: CGPoint) {
        let p = target.panel
        let occupied = !shownWindows(p, of: target.owner).filter { $0 != w }.isEmpty
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

    // MARK: Checking a new window's size out of sight

    /// Windows just added to a nested board, whose size is being checked
    /// while they're tucked away: they show as portholes until it's known
    /// whether they fit their spot.
    private var probing = Set<UInt32>()

    /// New windows that opened into a pool already in use: they float on top
    /// where they opened, and the pool's other windows stay as they are
    /// (they don't make room). Dragging one, or Hyper + F, makes it an
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
        shownTiles.last { $0.porthole && $0.badge != "lock.fill" && $0.rect.contains(p) }?.window
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
                    if t.porthole, let p = self.portholePictures[t.window] { t.picture = p.image }
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
        live.stopAll()
        lobby.hide()
        bounds.hide()
        shade.update(depth: -1, on: screen)
        backdrop.update(depth: -1, on: screen)
        numbers.hide()
        state.save(to: stateURL)
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
            if let w = window { self.windows.focus(w) }
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
            + (close ? " and closes it." : ".") + " Open it again into any empty pool with Hyper + Shift + O."
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
        state.save(to: stateURL)
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
        if current.panels().count > 1 {
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
            Toast.show("No saved pools yet — Hyper + Shift + S saves the pool under the pointer", seconds: 1.6)
            return
        }
        guard let target = poolToFill(fromMenu: fromMenu) else { return }
        guard shownWindows(target.panel, of: target.owner).isEmpty else {
            Toast.show("Point at an empty pool first — Hyper + B opens one", seconds: 1.4)
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
        guard shownWindows(target.panel, of: target.owner).isEmpty else {
            Toast.show("Go into an empty pool first — Hyper + B opens one", seconds: 1.4)
            return
        }
        deploy(sp, into: target.panel.id)
    }

    /// Forgets a saved pool.
    func deleteSavedPool(_ id: UUID) {
        state.savedPools?.removeAll { $0.id == id }
        if state.savedPools?.isEmpty == true { state.savedPools = nil }
        state.save(to: stateURL)
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

    // MARK: Undo

    private var undoStack: [Data] = []

    /// Saves the layout so the next change can be undone.
    func checkpoint() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        undoStack.append(data)
        if undoStack.count > 30 { undoStack.removeFirst() }
    }

    /// Hyper + Z: puts the layout back the way it was before the last change.
    func undo() {
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
        Toast.show("Undone", seconds: 0.7)
    }

    func setHome() {
        state.home = state.path.isEmpty ? nil : state.path
        state.homeMain = state.otherMains == nil ? nil : state.root.id
        state.save(to: stateURL)
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
