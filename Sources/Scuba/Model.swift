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
        } else if case .panel(let p) = root, p.desktop == nil, p.windows.count >= 2 {
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
            // One pool with one window (or none): the room takes the other
            // half of the board on its own, so Hyper + B adds exactly one pool.
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

    // MARK: Edits

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

    init() {
        root = Desktop.twoUp()
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
