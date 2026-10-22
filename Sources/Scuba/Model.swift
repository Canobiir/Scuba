import Foundation
import CoreGraphics

// MARK: - Layout model
//
// A Desktop is a tiling of Panels. Splits arrange panels side by side ("h")
// or stacked ("v"). A Panel holds windows, OR a nested Desktop of its own.
// Zooming into a panel shows its nested desktop full screen; zooming out
// shows it shrunk back inside the panel.
//
// Every panel has a number that is stable within its desktop: it is given the
// lowest free number when created and keeps it no matter what else is added,
// deleted or zoomed.

enum Axis: String, Codable {
    case h  // side by side
    case v  // stacked, first child on top

    var flipped: Axis { self == .h ? .v : .h }
}

final class Panel: Codable {
    var id: UUID
    var number: Int
    var windows: [UInt32]
    var desktop: Desktop?
    /// Optional name, e.g. "Work". Shown instead of the number where it fits.
    var name: String?
    /// Breathing room: an empty panel added when you dive into a board. It
    /// folds away when you leave, unless you've put something in it.
    var scratch: Bool?
    /// Windows that float inside the panel instead of filling it:
    /// window id → [x, y, width, height] as fractions of the panel (y from the bottom).
    var floating: [String: [Double]]?
    /// The shape (wide or tall) the floating arrangement was last shown in.
    var landscape: Bool?
    /// On a quarter-screen breathing room: how the board made way for it.
    var roomFit: RoomFit?
    /// The Desktop: the part of a board where windows float freely, like a
    /// normal Mac, between the windows docked around it. Never tiled, never
    /// zoomed into, never deleted.
    var free: Bool?
    /// A lens: a pool made only so you could zoom into part of a board (a
    /// tile, or a group of tiles). When you come back up it folds back into
    /// the board above, unless it's become a place of its own.
    var lens: Bool?
    /// Breathing rooms that were already on the board when this lens was
    /// made around them. They don't make the lens a place of its own: it
    /// still folds back when you come up. (Nil for lenses from older builds.)
    var lensRooms: [UUID]?
    /// The Desktop, pushed all the way closed by the windows around it on
    /// Main: out of the layout (its floating windows tucked away) until
    /// Hyper + B brings it back.
    var tucked: Bool?
    /// Tabs: the pool's windows share it, one at a time, with a strip of tabs
    /// along the top to switch between them.
    var tabs: Bool?
    /// The tab in front (the one showing).
    var front: UInt32?

    /// Turns the floating arrangement a quarter turn, so windows stacked top
    /// and bottom in a tall panel sit left and right in a wide one (top goes
    /// left), and back again.
    func rotateFloats(toLandscape: Bool) {
        guard let map = floating else { return }
        var out: [String: [Double]] = [:]
        for (k, f) in map where f.count == 4 {
            let (x, y, w, h) = (f[0], f[1], f[2], f[3])
            out[k] = toLandscape ? [1 - y - h, x, h, w] : [y, 1 - x - w, h, w]
        }
        floating = out
    }

    func floatRect(_ w: UInt32) -> CGRect? {
        guard let f = floating?[String(w)], f.count == 4 else { return nil }
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }

    func setFloat(_ w: UInt32, _ rel: CGRect?) {
        var map = floating ?? [:]
        if let r = rel {
            // Keep it sensible: at least 10% of the panel and fully inside it.
            let width = min(max(Double(r.width), 0.1), 1)
            let height = min(max(Double(r.height), 0.1), 1)
            let x = min(max(Double(r.minX), 0), 1 - width)
            let y = min(max(Double(r.minY), 0), 1 - height)
            map[String(w)] = [x, y, width, height]
        } else {
            map.removeValue(forKey: String(w))
        }
        floating = map.isEmpty ? nil : map
    }

    init(number: Int) {
        self.id = UUID()
        self.number = number
        self.windows = []
        self.desktop = nil
    }
}

/// How a quarter-screen breathing room was fitted into a board, so folding it
/// away puts the board back the way it was.
struct RoomFit: Codable {
    /// The split whose shares changed, how many members it had, which member
    /// moved over beside the room, and that member's share before.
    var split: UUID?
    var count: Int?
    var edge: Int?
    var share: Double?
    /// A board that was one pool, split in two for the room: the pool, the
    /// partner made from it, and the pool's windows, floats and shape before.
    var pool: UUID?
    var partner: UUID?
    var windows: [UInt32]?
    var floating: [String: [Double]]?
    var landscape: Bool?
}

final class Split: Codable {
    var id: UUID
    var axis: Axis
    var children: [Node]
    var ratios: [Double]
    /// The shape (wide or tall) this split was last shown in. When it's shown
    /// in the other shape, side by side and stacked swap (see Controller.adapt).
    var landscape: Bool?
    /// You've sized these by hand (dragged a gap or an edge): your sizes
    /// stand, and an app that won't fit frosts over instead of its tile
    /// growing to make room.
    var seated: Bool?

    init(axis: Axis, children: [Node]) {
        self.id = UUID()
        self.axis = axis
        self.children = children
        let share = 1.0 / Double(max(children.count, 1))
        self.ratios = Array(repeating: share, count: children.count)
    }
}

enum Node: Codable {
    case panel(Panel)
    case split(Split)

    var id: UUID {
        switch self {
        case .panel(let p): return p.id
        case .split(let s): return s.id
        }
    }
}

final class Desktop: Codable {
    var id: UUID
    var root: Node
    /// This board's own wallpaper (a file path); boards inside it share it
    /// unless they have their own. Nil: your Mac's wallpaper.
    var wallpaper: String?
    /// A top-level board's name ("Main", "Main 2"…). Nil: "Main".
    var name: String?

    init(root: Node) {
        self.id = UUID()
        self.root = root
    }

    /// Opens an empty panel along one side of the whole board (breathing room),
    /// taking `share` of the width from what's there.
    func addRoom(onRight: Bool, share: Double) -> Panel {
        let fresh = Panel(number: nextNumber())
        fresh.scratch = true
        if case .split(let s) = root, s.axis == .h {
            s.ratios = s.ratios.map { $0 * (1 - share) }
            if onRight {
                s.children.append(.panel(fresh))
                s.ratios.append(share)
            } else {
                s.children.insert(.panel(fresh), at: 0)
                s.ratios.insert(share, at: 0)
            }
        } else {
            let s = Split(axis: .h, children: onRight ? [root, .panel(fresh)] : [.panel(fresh), root])
            s.ratios = onRight ? [1 - share, share] : [share, 1 - share]
            root = .split(s)
        }
        return fresh
    }

    /// Opens a quarter of the board as breathing room, in one corner. A
    /// quarter has the screen's own shape, so it reads as a little desktop of
    /// its own, ready to dive into. What's on the board makes way: the member
    /// nearest that corner moves into the quarter beside the room, and the
    /// rest share the other half. A board that's a single pool splits its
    /// windows the same way; with one window (or none), the room takes the
    /// other half of the board on its own.
    @discardableResult
    func addQuadrantRoom(right: Bool, bottom: Bool) -> Panel {
        let room = Panel(number: 0)
        room.scratch = true
        var fit = RoomFit()
        var fresh: [Panel] = []   // new panels, numbered at the end

        // The room and its neighbour, sharing a column (or a row) half and half.
        func pairUp(_ other: Node, axis: Axis) -> Node {
            let roomLast = axis == .v ? bottom : right
            let pair = Split(axis: axis, children: roomLast ? [other, .panel(room)] : [.panel(room), other])
            pair.ratios = [0.5, 0.5]
            return .split(pair)
        }

        if case .split(let s) = root, s.children.count >= 2 {
            // Side by side: the end member shares a column with the room.
            // Stacked: the top or bottom member shares a row with it.
            let towardEnd = s.axis == .h ? right : bottom
            let edge = towardEnd ? s.children.count - 1 : 0
            fit.split = s.id
            fit.count = s.children.count
            fit.edge = edge
            fit.share = s.ratios[edge]
            let rest = 1 - s.ratios[edge]
            let others = Double(s.children.count - 1)
            s.ratios = s.ratios.enumerated().map { i, r in
                i == edge ? 0.5 : (rest > 0.001 ? r / rest * 0.5 : 0.5 / others)
            }
            s.children[edge] = pairUp(s.children[edge], axis: s.axis.flipped)
        } else if case .panel(let p) = root, p.desktop == nil, p.free != true, p.windows.count >= 2, p.tabs != true {
            // (Tabs stay together: a tabbed pool keeps its half whole, below.)
            // One pool for the whole board, holding two or more windows: its
            // windows on the room's side move into a partner pool above (or
            // below) the room; the rest keep the half.
            let moving = Desktop.windowsToward(right: right, in: p)
            let staying = p.windows.filter { !moving.contains($0) }
            let q = Panel(number: 0)
            fit.pool = p.id
            fit.partner = q.id
            fit.windows = p.windows
            fit.floating = p.floating
            fit.landscape = p.landscape
            let saved = p.floating
            p.windows = staying
            q.windows = moving
            Desktop.regroup(staying, floats: saved, into: p)
            Desktop.regroup(moving, floats: saved, into: q)
            q.landscape = p.landscape
            let beside = q
            fresh.append(beside)
            let column = pairUp(.panel(beside), axis: .v)
            let outer = Split(axis: .h, children: right ? [root, column] : [column, root])
            outer.ratios = [0.5, 0.5]
            root = .split(outer)
        } else {
            // One pool with one window (or none), or tabs: the room takes the
            // other half of the board on its own, so Hyper + B adds exactly one pool.
            let outer = Split(axis: .h, children: right ? [root, .panel(room)] : [.panel(room), root])
            outer.ratios = [0.5, 0.5]
            root = .split(outer)
        }
        fresh.append(room)
        for p in fresh { p.number = nextNumber() }
        room.roomFit = fit
        return room
    }

    /// The windows of a pool on one side, by where their middles sit: never
    /// none of them and never all of them.
    static func windowsToward(right: Bool, in p: Panel) -> [UInt32] {
        let mids = p.windows.map { w -> (window: UInt32, x: Double) in
            let r = p.floatRect(w) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            return (w, Double(r.midX))
        }
        var moving = mids.filter { right ? $0.x > 0.5 : $0.x < 0.5 }.map { $0.window }
        if moving.isEmpty {
            // Nothing clearly on that side: the window nearest it goes (the
            // last one, when they all sit in the middle).
            var best = mids[0]
            for m in mids.dropFirst() where right ? m.x >= best.x : m.x <= best.x { best = m }
            moving = [best.window]
        } else if moving.count == mids.count {
            // Everything's on that side: the one farthest from it stays.
            var far = mids[0]
            for m in mids.dropFirst() where right ? m.x < far.x : m.x > far.x { far = m }
            moving.removeAll { $0 == far.window }
        }
        return moving
    }

    /// Windows moved into a pool keep their arrangement, spread over the
    /// pool: floats are placed relative to the box they take up together.
    /// A window on its own fills the pool.
    static func regroup(_ ws: [UInt32], floats: [String: [Double]]?, into q: Panel) {
        q.floating = nil
        guard ws.count > 1 else { return }
        func rect(_ w: UInt32) -> CGRect? {
            guard let f = floats?[String(w)], f.count == 4 else { return nil }
            return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        let rects = ws.compactMap(rect)
        guard let first = rects.first else { return }   // they all fill
        guard rects.count == ws.count else {
            // Some fill the pool: the floats keep their spots in it.
            for w in ws { if let r = rect(w) { q.setFloat(w, r) } }
            return
        }
        let box = rects.dropFirst().reduce(first) { $0.union($1) }
        guard box.width > 0.01, box.height > 0.01 else { return }
        for w in ws {
            guard let r = rect(w) else { continue }   // a filling window keeps filling
            q.setFloat(w, CGRect(x: (r.minX - box.minX) / box.width, y: (r.minY - box.minY) / box.height,
                                 width: r.width / box.width, height: r.height / box.height))
        }
    }

    /// Folds a breathing-room panel away and gives its share back to every
    /// other panel in proportion. A quarter-screen room also undoes how the
    /// board made way for it, so the board is exactly as it was.
    func removeRoom(_ room: Panel) {
        guard let loc = parent(of: room.id) else { return }
        detach(loc)
        guard let fit = room.roomFit else { return }
        room.roomFit = nil

        // A pool split in two for the room takes its windows back, arranged as before.
        if let pid = fit.pool, let qid = fit.partner, let p = panel(id: pid), let q = panel(id: qid),
           p.desktop == nil, q.desktop == nil, let ql = parent(of: q.id) {
            let before = fit.windows ?? []
            let now = p.windows + q.windows
            p.windows = before.filter { now.contains($0) } + now.filter { !before.contains($0) }
            var floats: [String: [Double]] = [:]
            for w in p.windows {
                if let f = fit.floating?[String(w)] { floats[String(w)] = f }
            }
            p.floating = floats.isEmpty ? nil : floats
            p.landscape = fit.landscape
            q.windows = []
            q.floating = nil
            detach(ql)
        }

        // The member that moved over beside the room gets its old share back;
        // the rest keep their proportions to each other.
        if let sid = fit.split, let edge = fit.edge, let old = fit.share, let s = split(id: sid),
           s.children.count == fit.count, edge < s.children.count, s.children.count >= 2 {
            let rest = 1 - s.ratios[edge]
            let others = Double(s.children.count - 1)
            s.ratios = s.ratios.enumerated().map { i, r in
                i == edge ? old : (rest > 0.001 ? r / rest * (1 - old) : (1 - old) / others)
            }
        }
    }

    /// Takes a member out of its split; the others share its space in
    /// proportion, and a split left with one member is replaced by it.
    private func detach(_ loc: (split: Split, index: Int)) {
        let s = loc.split
        let share = s.ratios[loc.index]
        s.children.remove(at: loc.index)
        s.ratios.remove(at: loc.index)
        if share < 1, !s.ratios.isEmpty { s.ratios = s.ratios.map { $0 / (1 - share) } }
        if s.children.count == 1 { replace(s.id, with: s.children[0]) }
    }

    /// Takes a node (a pool or a group) out of the board: its group closes
    /// up, and a group left with one member becomes that member. Nil when
    /// it's the whole board (nothing to take it out of).
    @discardableResult
    func pluck(_ id: UUID) -> Node? {
        guard let loc = parent(of: id) else { return nil }
        let n = loc.split.children[loc.index]
        detach(loc)
        return n
    }

    /// The node with this id on the board (not inside nested boards).
    func node(_ id: UUID) -> Node? {
        if root.id == id { return root }
        return parent(of: id).map { $0.split.children[$0.index] }
    }

    /// Puts a node along a whole side of the board (left or right), taking
    /// `share` of its width; what's there keeps its proportions in the rest.
    func dockAlongSide(_ n: Node, right: Bool, share: Double = 0.5) {
        if case .split(let s) = root, s.axis == .h {
            s.ratios = s.ratios.map { $0 * (1 - share) }
            if right {
                s.children.append(n)
                s.ratios.append(share)
            } else {
                s.children.insert(n, at: 0)
                s.ratios.insert(share, at: 0)
            }
        } else {
            let s = Split(axis: .h, children: right ? [root, n] : [n, root])
            s.ratios = right ? [1 - share, share] : [share, 1 - share]
            root = .split(s)
        }
    }

    /// Puts a node beside another (side by side, or stacked), sharing its
    /// slot half and half: in its group if that runs the same way, or as a
    /// new pair in its place. `after`: right of it, or below it.
    func pair(_ n: Node, with id: UUID, axis: Axis, after: Bool) {
        if let loc = parent(of: id), loc.split.axis == axis {
            let g = loc.split, i = loc.index
            let share = g.ratios[i] / 2
            g.ratios[i] = share
            let at = after ? i + 1 : i
            g.children.insert(n, at: at)
            g.ratios.insert(share, at: at)
            return
        }
        guard let here = node(id) else { return }
        let pair = Split(axis: axis, children: after ? [here, n] : [n, here])
        pair.ratios = [0.5, 0.5]
        replace(id, with: .split(pair))
    }

    /// The split with this id, anywhere on the board (not inside nested boards).
    func split(id: UUID) -> Split? {
        func search(_ node: Node) -> Split? {
            guard case .split(let s) = node else { return nil }
            if s.id == id { return s }
            for c in s.children { if let found = search(c) { return found } }
            return nil
        }
        return search(root)
    }

    /// A desktop with a single panel numbered 1.
    static func single() -> Desktop {
        Desktop(root: .panel(Panel(number: 1)))
    }

    /// The default desktop: two panels, left and right.
    static func twoUp() -> Desktop {
        Desktop(root: .split(Split(axis: .h, children: [.panel(Panel(number: 1)), .panel(Panel(number: 2))])))
    }

    // MARK: Queries

    /// Panels in reading order.
    func panels() -> [Panel] {
        var out: [Panel] = []
        collect(root, &out)
        return out
    }

    private func collect(_ node: Node, _ out: inout [Panel]) {
        switch node {
        case .panel(let p): out.append(p)
        case .split(let s): for c in s.children { collect(c, &out) }
        }
    }

    func panel(number: Int) -> Panel? {
        panels().first { $0.number == number }
    }

    func panel(id: UUID) -> Panel? {
        panels().first { $0.id == id }
    }

    func lowestNumbered() -> Panel {
        panels().min { $0.number < $1.number }!
    }

    func nextNumber() -> Int {
        let used = Set(panels().map { $0.number })
        var n = 1
        while used.contains(n) { n += 1 }
        return n
    }

    /// The split that directly contains the node with this id, and its index.
    func parent(of id: UUID) -> (split: Split, index: Int)? {
        find(root, id)
    }

    private func find(_ node: Node, _ id: UUID) -> (split: Split, index: Int)? {
        guard case .split(let s) = node else { return nil }
        for (i, c) in s.children.enumerated() {
            if c.id == id { return (s, i) }
            if let found = find(c, id) { return found }
        }
        return nil
    }

    /// Splits containing this node, innermost first.
    func ancestors(of id: UUID) -> [(split: Split, index: Int)] {
        var out: [(split: Split, index: Int)] = []
        var current = id
        while let p = parent(of: current) {
            out.append(p)
            current = p.split.id
        }
        return out
    }

    func replace(_ id: UUID, with new: Node) {
        if root.id == id {
            root = new
        } else if let p = parent(of: id) {
            p.split.children[p.index] = new
        }
    }

    /// Every window in this desktop, including nested desktops.
    func allWindows() -> [UInt32] {
        panels().flatMap { p in p.windows + (p.desktop?.allWindows() ?? []) }
    }

    /// The panel a window should land in when it's sent to this desktop:
    /// the lowest-numbered panel, descending into nested desktops.
    func landingPanel() -> Panel {
        let p = lowestNumbered()
        if let d = p.desktop { return d.landingPanel() }
        return p
    }

    func firstPanel(in node: Node) -> Panel {
        switch node {
        case .panel(let p): return p
        case .split(let s): return firstPanel(in: s.children[0])
        }
    }

    /// The Desktop on this board (where windows float freely), if it has one.
    /// Breathing room is a little Desktop too, but this is the board's own.
    func freePanel() -> Panel? { panels().first { $0.free == true && $0.scratch != true } }

    /// A panel anywhere on this board or the boards inside it, and the board
    /// it's directly on.
    func deepFind(panel id: UUID) -> (panel: Panel, owner: Desktop)? {
        for p in panels() {
            if p.id == id { return (p, self) }
            if let found = p.desktop?.deepFind(panel: id) { return found }
        }
        return nil
    }

    /// The panel holding a window, anywhere on this board or the boards
    /// inside it, and the board it's directly on.
    func deepFind(window w: UInt32) -> (panel: Panel, owner: Desktop)? {
        for p in panels() {
            if p.windows.contains(w) { return (p, self) }
            if let found = p.desktop?.deepFind(window: w) { return found }
        }
        return nil
    }

    // MARK: Edits

    /// Docks a new panel along one whole side of the board, beside
    /// everything: the left or right edge (`.h`), or the top or bottom
    /// (`.v`). `before` is the left or top side. It takes an even share.
    @discardableResult
    func addEdgePanel(axis: Axis, before: Bool) -> Panel {
        let fresh = Panel(number: nextNumber())
        if case .split(let s) = root, s.axis == axis {
            let share = 1.0 / Double(s.children.count + 1)
            s.ratios = s.ratios.map { $0 * (1 - share) }
            if before {
                s.children.insert(.panel(fresh), at: 0)
                s.ratios.insert(share, at: 0)
            } else {
                s.children.append(.panel(fresh))
                s.ratios.append(share)
            }
        } else {
            let s = Split(axis: axis, children: before ? [.panel(fresh), root] : [root, .panel(fresh)])
            root = .split(s)
        }
        return fresh
    }

    /// Keyboard docking: moves a panel one step toward a side, climbing the
    /// board's tree one level per step.
    /// - Beside a neighbour that way in its own group, it swaps places with it.
    /// - At the end of its group (or in a group that runs the other way), it
    ///   leaves the group and docks beside it on that side, in the group
    ///   above; at the top, along that whole edge of the board.
    /// False when it's already against that edge of the board.
    func push(_ target: Panel, toward dir: Direction) -> Bool {
        let axis: Axis = (dir == .left || dir == .right) ? .h : .v
        let before = dir == .left || dir == .up
        var node = target.id
        while let loc = parent(of: node) {
            let a = loc.split, k = loc.index
            if a.axis == axis {
                let j = before ? k - 1 : k + 1
                if j >= 0, j < a.children.count {
                    if node == target.id {
                        // A neighbour right there: swap places (each keeps its size).
                        a.children.swapAt(k, j)
                        a.ratios.swapAt(k, j)
                    } else {
                        // Out of its group, into this one, beside the group.
                        detachPanel(target)
                        dock(.panel(target), besideSlot: (a, k), axis: axis, before: before)
                    }
                    return true
                }
                node = a.id   // already at that end: one level up
                continue
            }
            // A group that runs the other way: dock beside the whole of it,
            // so the panel spans it.
            let slot = parent(of: a.id)
            detachPanel(target)
            dock(.panel(target), besideSlot: slot, axis: axis, before: before)
            return true
        }
        return false
    }

    /// Takes a panel out of its group (the group closes up; a group left
    /// with one member becomes that member).
    private func detachPanel(_ p: Panel) {
        guard let loc = parent(of: p.id) else { return }
        detach(loc)
    }

    /// Puts a node beside whatever is in a slot of a group (or beside the
    /// whole board, with no slot), on one side: in that group if it runs the
    /// same way, taking half the slot's share, or as a new pair otherwise.
    private func dock(_ n: Node, besideSlot slot: (split: Split, index: Int)?, axis: Axis, before: Bool) {
        if let slot, slot.split.axis == axis {
            let g = slot.split, i = slot.index
            let share = g.ratios[i] / 2
            g.ratios[i] = share
            let at = before ? i : i + 1
            g.children.insert(n, at: at)
            g.ratios.insert(share, at: at)
            return
        }
        let here = slot.map { $0.split.children[$0.index] } ?? root
        let pair = Split(axis: axis, children: before ? [n, here] : [here, n])
        if let slot { slot.split.children[slot.index] = .split(pair) } else { root = .split(pair) }
    }

    /// Takes a panel off the board: the panels beside it share its space in
    /// proportion. Never the last panel.
    func dissolve(_ target: Panel) {
        guard let loc = parent(of: target.id) else { return }
        detach(loc)
    }

    /// A pool a window has just left, if nothing is left in it: it goes, and
    /// the windows around it take its space. Breathing room, the Desktop,
    /// pools holding a board, and a board's last pool stay. True if it went.
    @discardableResult
    func pruneTile(_ p: Panel) -> Bool {
        guard p.windows.isEmpty, p.desktop == nil, p.scratch != true, p.free != true,
              panels().count > 1, parent(of: p.id) != nil else { return false }
        dissolve(p)
        return true
    }

    /// Turns pools that hold windows docked side by side (or stacked) into a
    /// pool per window, split the same way, so each window is a tile of its
    /// own. Pools whose windows overlap, or that mix filled and floating
    /// windows, stay as they are. Boards inside pools too.
    func tileize() {
        for p in panels() {
            if let d = p.desktop { d.tileize(); continue }
            guard p.windows.count >= 2, p.scratch != true, p.free != true else { continue }
            let rects = p.windows.compactMap { w in p.floatRect(w).map { (w, $0) } }
            let first = p.windows[0]
            guard rects.count == p.windows.count,
                  let node = Desktop.guillotine(rects, in: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                keep: p, first: first)
            else { continue }
            p.windows = [first]
            p.floating = nil
            p.landscape = nil
            replace(p.id, with: node)
            for q in panels() where q.number == 0 { q.number = nextNumber() }
        }
    }

    /// Cuts a set of window rectangles (fractions of a pool) into a split
    /// tree, one panel per window, if straight cuts can separate them all.
    /// The first window keeps the pool `keep` (its number, name and id).
    private static func guillotine(_ items: [(UInt32, CGRect)], in box: CGRect, keep: Panel,
                                   first: UInt32) -> Node? {
        if items.count == 1 {
            let w = items[0].0
            // Nothing is changed until the whole cut works out: the kept pool
            // only gets its one window afterwards.
            if w == first { return .panel(keep) }
            let p = Panel(number: 0)
            p.windows = [w]
            return .panel(p)
        }
        let tol: CGFloat = 0.03
        // Side by side: a line that every window is wholly left or right of.
        for (_, r) in items.sorted(by: { $0.1.maxX < $1.1.maxX }) {
            let cut = r.maxX
            let left = items.filter { $0.1.maxX <= cut + tol }
            let right = items.filter { $0.1.maxX > cut + tol }
            guard !left.isEmpty, !right.isEmpty, right.allSatisfy({ $0.1.minX >= cut - tol }) else { continue }
            let at = (cut + (right.map { $0.1.minX }.min() ?? cut)) / 2
            let share = Double(min(max((at - box.minX) / max(box.width, 0.0001), 0.05), 0.95))
            let lb = CGRect(x: box.minX, y: box.minY, width: at - box.minX, height: box.height)
            let rb = CGRect(x: at, y: box.minY, width: box.maxX - at, height: box.height)
            guard let a = guillotine(left, in: lb, keep: keep, first: first),
                  let b = guillotine(right, in: rb, keep: keep, first: first)
            else { return nil }
            let s = Split(axis: .h, children: [a, b])
            s.ratios = [share, 1 - share]
            return .split(s)
        }
        // Stacked: a line every window is wholly above or below (y from the
        // bottom; the first child is the top one).
        for (_, r) in items.sorted(by: { $0.1.maxY < $1.1.maxY }) {
            let cut = r.maxY
            let below = items.filter { $0.1.maxY <= cut + tol }
            let above = items.filter { $0.1.maxY > cut + tol }
            guard !below.isEmpty, !above.isEmpty, above.allSatisfy({ $0.1.minY >= cut - tol }) else { continue }
            let at = (cut + (above.map { $0.1.minY }.min() ?? cut)) / 2
            let topShare = Double(min(max((box.maxY - at) / max(box.height, 0.0001), 0.05), 0.95))
            let bb = CGRect(x: box.minX, y: box.minY, width: box.width, height: at - box.minY)
            let tb = CGRect(x: box.minX, y: at, width: box.width, height: box.maxY - at)
            guard let top = guillotine(above, in: tb, keep: keep, first: first),
                  let bottom = guillotine(below, in: bb, keep: keep, first: first)
            else { return nil }
            let s = Split(axis: .v, children: [top, bottom])
            s.ratios = [topShare, 1 - topShare]
            return .split(s)
        }
        return nil
    }

    /// Adds a new panel next to the target: right of / below it, or
    /// left of / above it when `before` is true.
    @discardableResult
    func addPanel(nextTo target: Panel, axis: Axis, before: Bool = false) -> Panel {
        let fresh = Panel(number: nextNumber())
        if let p = parent(of: target.id), p.split.axis == axis {
            // Same direction as the surrounding group: share the target's space.
            let s = p.split
            let i = p.index
            let share = s.ratios[i]
            s.ratios[i] = share / 2
            let at = before ? i : i + 1
            s.children.insert(.panel(fresh), at: at)
            s.ratios.insert(share / 2, at: at)
        } else {
            // Otherwise the target becomes a pair: old panel and the new one.
            let pair = Split(axis: axis, children: before ? [.panel(fresh), .panel(target)]
                                                          : [.panel(target), .panel(fresh)])
            replace(target.id, with: .split(pair))
        }
        return fresh
    }

    /// Adds a new panel as a peer of the target in its row (or column): the
    /// same size as the target, the whole row making room for it, instead
    /// of halving the target. Nil if the target isn't in a group.
    @discardableResult
    func addPeer(nextTo target: Panel, before: Bool) -> Panel? {
        guard let p = parent(of: target.id) else { return nil }
        let s = p.split
        let share = s.ratios[p.index]
        let fresh = Panel(number: nextNumber())
        s.ratios = s.ratios.map { $0 / (1 + share) }
        let at = before ? p.index : p.index + 1
        s.children.insert(.panel(fresh), at: at)
        s.ratios.insert(share / (1 + share), at: at)
        return fresh
    }

    /// Removes a panel; its neighbor takes over the space. Returns the
    /// neighbor panel that should inherit its windows, or nil if this was
    /// the only panel.
    func removePanel(_ target: Panel) -> Panel? {
        guard let p = parent(of: target.id) else { return nil }
        let s = p.split
        let share = s.ratios[p.index]
        s.children.remove(at: p.index)
        s.ratios.remove(at: p.index)
        let neighbor = max(0, p.index - 1)
        s.ratios[neighbor] += share
        let heir = firstPanel(in: s.children[neighbor])
        if s.children.count == 1 {
            replace(s.id, with: s.children[0])
        }
        return heir
    }

    /// Switches the group holding this panel between side by side and stacked.
    func flip(_ target: Panel) -> Axis? {
        guard let p = parent(of: target.id) else { return nil }
        p.split.axis = p.split.axis.flipped
        return p.split.axis
    }

    enum Direction { case left, right, up, down }

    /// Grows a panel toward a direction by moving the nearest divider there.
    func grow(_ target: Panel, toward dir: Direction, by step: Double = 0.05) -> Bool {
        let axis: Axis = (dir == .left || dir == .right) ? .h : .v
        let forward = (dir == .right || dir == .down)
        let minShare = 0.08
        for a in ancestors(of: target.id) where a.split.axis == axis {
            let s = a.split
            let i = a.index
            if forward, i < s.children.count - 1 {
                let take = min(step, s.ratios[i + 1] - minShare)
                guard take > 0 else { return false }
                s.ratios[i] += take
                s.ratios[i + 1] -= take
                return true
            }
            if !forward, i > 0 {
                let take = min(step, s.ratios[i - 1] - minShare)
                guard take > 0 else { return false }
                s.ratios[i] += take
                s.ratios[i - 1] -= take
                return true
            }
        }
        return false
    }

    /// Shrinks a panel from a direction (the opposite edge moves inward).
    func shrink(_ target: Panel, from dir: Direction, by step: Double = 0.05) -> Bool {
        let axis: Axis = (dir == .left || dir == .right) ? .h : .v
        let forward = (dir == .right || dir == .down)
        let minShare = 0.08
        for a in ancestors(of: target.id) where a.split.axis == axis {
            let s = a.split
            let i = a.index
            if forward, i < s.children.count - 1 {
                let give = min(step, s.ratios[i] - minShare)
                guard give > 0 else { return false }
                s.ratios[i] -= give
                s.ratios[i + 1] += give
                return true
            }
            if !forward, i > 0 {
                let give = min(step, s.ratios[i] - minShare)
                guard give > 0 else { return false }
                s.ratios[i] -= give
                s.ratios[i - 1] += give
                return true
            }
        }
        return false
    }

    /// Renumbers panels 1, 2, 3… in reading order.
    func renumber() {
        for (i, p) in panels().enumerated() { p.number = i + 1 }
    }

    /// Repairs anything inconsistent after loading from disk.
    func sanitize() {
        sanitize(root)
        for p in panels() { p.desktop?.sanitize() }
    }

    private func sanitize(_ node: Node) {
        guard case .split(let s) = node else { return }
        let n = s.children.count
        let total = s.ratios.reduce(0, +)
        if s.ratios.count != n || total <= 0 || s.ratios.contains(where: { $0 <= 0 }) {
            s.ratios = Array(repeating: 1.0 / Double(max(n, 1)), count: n)
        } else {
            s.ratios = s.ratios.map { $0 / total }
        }
        for c in s.children { sanitize(c) }
    }
}

// MARK: - Saved pools

/// A pool saved to open again later (Hyper + Shift + S): its whole setup, the
/// pools inside it (if it holds a board), their sizes, which apps live in
/// each and where their windows sat, and what's hidden from above.
struct SavedPool: Codable {
    var id: UUID
    var name: String
    var saved: Date
    var layout: SavedNode
}

/// One part of a saved setup: a pool, or a group of pools side by side or
/// stacked.
indirect enum SavedNode: Codable {
    case pool(SavedLeaf)
    case split(axis: Axis, ratios: [Double], landscape: Bool?, children: [SavedNode])
}

struct SavedLeaf: Codable {
    var name: String?
    /// The shape (wide or tall) it was in, so its arrangement turns to suit
    /// where it's opened.
    var landscape: Bool?
    /// Hidden from the board above (a filled breathing room, or Hyper + Shift + P).
    var hidden: Bool?
    var items: [SavedWindow]
    /// A board of its own inside this pool.
    var inner: SavedNode?
}

struct SavedWindow: Codable {
    var bundleID: String
    var appName: String
    /// Where it floated in its pool: [x, y, width, height] as fractions of
    /// the pool (y from the bottom). Nil: it filled the pool.
    var rect: [Double]?
    /// A browser window's tabs.
    var urls: [String]?
    /// Hidden from the board above (Hyper + P).
    var hidden: Bool?
}

// MARK: - Saved state

final class AppState: Codable {
    var root: Desktop
    /// Panel ids leading from the top desktop to the one on screen.
    var path: [UUID]
    var home: [UUID]?
    var lastPanelId: UUID?
    /// Windows that only show on their own board (Hyper + P).
    var insideOnly: [UInt32]?
    /// Your other Mains, beside this one (swipe sideways from Main). `root`
    /// is the one you're on; `mainIndex` is where it sits among them all.
    var otherMains: [Desktop]?
    var mainIndex: Int?
    /// The Main that Home is on (nil: whichever Main you're on).
    var homeMain: UUID?
    /// Pools you saved to open again later.
    var savedPools: [SavedPool]?
    /// Boards whose placements are locked (Hyper + P): nothing docks,
    /// snaps, resizes or joins there until you unlock.
    var lockedBoards: [UUID]?
    /// Windows locked in place (Hyper + L): they stay in their tile, at its size.
    var lockedWindows: [UInt32]?
    /// Outside windows: opened while a board's placements were locked, they
    /// float on top of that board (board id → windows) and go where it goes.
    var floaters: [String: [UInt32]]?

    init() {
        // A fresh start: the whole screen is the Desktop, where windows float
        // as on a normal Mac. Nothing moves until you dock a window.
        let desk = Panel(number: 1)
        desk.free = true
        desk.name = "Desktop"
        root = Desktop(root: .panel(desk))
        path = []
        home = nil
        lastPanelId = nil
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Scuba", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The main display's boards (the file earlier versions used).
    static var fileURL: URL { folder.appendingPathComponent("state.json") }

    /// Another display's boards, named after that display so they come back
    /// when it's plugged in again.
    static func displayFileURL(_ key: String) -> URL {
        folder.appendingPathComponent("state-\(key).json")
    }

    static func load(from url: URL = AppState.fileURL) -> AppState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            return AppState()
        }
        state.root.sanitize()
        for d in state.otherMains ?? [] { d.sanitize() }
        return state
    }

    func save(to url: URL = AppState.fileURL) {
        if let data = encoded() { try? data.write(to: url, options: .atomic) }
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try? encoder.encode(self)
    }
}
