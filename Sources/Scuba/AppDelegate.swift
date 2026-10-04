import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.isEnabled = enabled
        self.state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    // MARK: Displays

    /// Each display set to "own boards" has its own Controller (its own
    /// Main, Home and nested boards); a display set to "live map" shows a map
    /// of where you are on the main screen; "left alone" gets neither.
    private var controllers: [CGDirectDisplayID: Controller] = [:]
    private var maps: [CGDirectDisplayID: LiveMap] = [:]
    private var screenObserver: NSObjectProtocol?

    enum DisplayMode: String { case boards, map, off }

    /// The main display's boards (the one with the menu bar).
    private var mainController: Controller? {
        NSScreen.screens.first.flatMap { controllers[Controller.displayID(of: $0)] } ?? controllers.values.first
    }

    /// The boards of the screen under the pointer: every shortcut, gesture
    /// and menu acts there. Falls back to the main display's.
    private var controller: Controller {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let c = controllers[Controller.displayID(of: s)] { return c }
        return mainController!
    }

    /// A display's lasting name (its ID number can change when it's re-plugged).
    private func displayKey(_ id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String? else { return String(id) }
        return text
    }

    private func displayMode(_ id: CGDirectDisplayID) -> DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: "display.\(displayKey(id))") ?? "") ?? .boards
    }

    private func setDisplayMode(_ mode: DisplayMode, for id: CGDirectDisplayID) {
        UserDefaults.standard.set(mode.rawValue, forKey: "display.\(displayKey(id))")
        setupDisplays()
    }

    /// Matches controllers and live maps to the displays connected right now.
    private func setupDisplays() {
        // Mid-change macOS can briefly list no displays: wait for the next update.
        guard !NSScreen.screens.isEmpty else { return }
        var seen = Set<CGDirectDisplayID>()
        for (i, screen) in NSScreen.screens.enumerated() {
            let id = Controller.displayID(of: screen)
            seen.insert(id)
            switch i == 0 ? .boards : displayMode(id) {
            case .boards:
                maps[id]?.hide()
                maps[id] = nil
                if controllers[id] == nil {
                    // Every display saves to its own file. The first time, the main
                    // display takes over the boards earlier versions saved.
                    let url = AppState.displayFileURL(displayKey(id))
                    let fm = FileManager.default
                    if i == 0, !UserDefaults.standard.bool(forKey: "movedMainState"),
                       !fm.fileExists(atPath: url.path), fm.fileExists(atPath: AppState.fileURL.path) {
                        try? fm.copyItem(at: AppState.fileURL, to: url)
                    }
                    if i == 0 { UserDefaults.standard.set(true, forKey: "movedMainState") }
                    let c = Controller(displayID: id, stateURL: url)
                    c.onLocationChange = { [weak self, weak c] in self?.locationChanged(c) }
                    c.startWatchingNewWindows()
                    c.startFollowingAppSwitches()
                    controllers[id] = c
                    Controller.all = Array(controllers.values)
                    if AXIsProcessTrusted() { c.applyLayout() }
                }
            case .map:
                retire(id)
                if maps[id] == nil {
                    maps[id] = LiveMap(displayID: id, source: { [weak self] in self?.mainController })
                }
                maps[id]?.refresh()
            case .off:
                retire(id)
                maps[id]?.hide()
                maps[id] = nil
            }
        }
        // Displays that were unplugged: their windows come back to a screen you can see.
        for id in Array(controllers.keys) where !seen.contains(id) { retire(id) }
        for id in Array(maps.keys) where !seen.contains(id) {
            maps[id]?.hide()
            maps[id] = nil
        }
        Controller.all = Array(controllers.values)
    }

    private func retire(_ id: CGDirectDisplayID) {
        guard let c = controllers[id] else { return }
        c.restoreAll()
        c.shutDown()
        controllers[id] = nil
        Controller.all = Array(controllers.values)
    }

    private func locationChanged(_ c: Controller?) {
        updateTitle(c)
        for map in maps.values { map.refresh() }
    }
    private var dragDock: DragDock!
    private var dividerDrag: DividerDrag!
    private var reveal: HyperReveal!
    private var scrollZoom: ScrollZoom!
    private var overview: BoardOverview!
    private var doubleClickDive: DoubleClickDive!
    private var pinchZoom: PinchZoom!
    private var spotlightClick: SpotlightClick!
    private var swipes: ThreeFingerSwipes!
    private let setup = SetupWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.fromFractalWindows()   // boards and settings from before the rename
        // An app that hangs shouldn't freeze Scuba with it: give up on any
        // one accessibility request after a second (macOS waits about six).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        UserDefaults.standard.register(defaults: ["autoJoin": true, "depthShade": true, "makeRoom": true, "autoRotate": true, "crowdIcons": true, "parallax": true, "breathingRoom": false, "threeFinger": true, "showLobby": true, "roomInsideOnly": true, "growToFit": true, "roomQuarter": true, "glideMotion": true, "edgeGaps": true, "openWater": true, "throwing": true, "portholes": true, "livePortholes": false, "tuckMinimize": false, "stopAtMain": true, "overviewZoom": true, "spotlightNew": true, "stepThrough": true, "foldPreview": true])
        // Breathing room became something you open (Hyper + B) rather than
        // something every dive adds: switch the old automatic room off, once.
        if !UserDefaults.standard.bool(forKey: "roomOnDemand") {
            UserDefaults.standard.set(true, forKey: "roomOnDemand")
            UserDefaults.standard.set(false, forKey: "breathingRoom")
        }
        // Hyper + B opens the room in the corner nearest the pointer: switch
        // to that once (the menu still has the other choices).
        if !UserDefaults.standard.bool(forKey: "roomTowardPointer") {
            UserDefaults.standard.set(true, forKey: "roomTowardPointer")
            UserDefaults.standard.set("pointer", forKey: "roomSide")
        }
        setupDisplays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)   // let the displays settle
                self?.setupDisplays()
            }
        }
        let active: () -> Controller = { [unowned self] in self.controller }
        overview = BoardOverview(controller: active)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⊞"
        statusItem.button?.toolTip = "Scuba"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        registerHotKeys()
        dragDock = DragDock(controller: active)
        dragDock.start()
        dividerDrag = DividerDrag(controller: active)
        dividerDrag.start()
        reveal = HyperReveal(controller: active)
        reveal.start()
        scrollZoom = ScrollZoom(controller: active)
        scrollZoom.start()
        doubleClickDive = DoubleClickDive(controller: active)
        doubleClickDive.start()
        pinchZoom = PinchZoom(controller: active)
        pinchZoom.start()
        spotlightClick = SpotlightClick(controller: active)
        spotlightClick.start()
        swipes = ThreeFingerSwipes(controller: active)
        swipes.start()
        if AXIsProcessTrusted() {
            Toast.show("Scuba is running — Hyper + ↑ to dive in", seconds: 2)
            // Restarted partway through Setup: pick up where you left off.
            if SetupModel.reopenAfterRestart { setup.show() }
        } else {
            setup.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for c in controllers.values { c.restoreAll() }
    }

    /// Menu bar: just ⊞ on the Surface, the breadcrumb once you're inside
    /// (for whichever screen moved last).
    private func updateTitle(_ moved: Controller? = nil) {
        guard let button = statusItem?.button, let controller = moved ?? mainController else { return }
        if controller.onSurface {
            button.title = "⊞"
        } else {
            var crumb = controller.breadcrumb()
            if crumb.count > 36 { crumb = "…" + crumb.suffix(35) }
            button.title = "⊞ " + crumb
        }
    }

    // MARK: Permissions

    private func requireAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        setup.show()
        return false
    }

    // MARK: Hot keys  (Hyper = Ctrl + Option + Cmd)

    private func registerHotKeys() {
        let H = HotKeys.hyper
        let HS = HotKeys.hyperShift
        // Most shortcuts only work inside your boards; on the Surface (your
        // normal desktop) Scuba stays out of the way.
        let bind: (Int, UInt32, Bool, @escaping (Controller) -> Void) -> Void = { [weak self] key, mods, onSurfaceToo, action in
            HotKeys.register(key, mods) {
                guard let self, self.requireAccessibility() else { return }
                if self.controller.onSurface && !onSurfaceToo {
                    Toast.show("You're on your desktop — Hyper + ↑ to dive in", seconds: 1.2)
                    return
                }
                // Using a shortcut means this Hyper hold isn't for a look at the panels.
                self.controller.quietReveal()
                action(self.controller)
            }
        }

        for (i, key) in HotKeys.digits.enumerated() {
            let n = i + 1
            bind(key, H, false) { $0.placeFocused(inPanel: n) }
            bind(key, HS, false) { $0.zoomInto(panel: n) }
        }
        let letters = [kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K]
        for (i, key) in letters.enumerated() {
            let n = i + 1
            bind(key, H, false) { $0.placeFocused(inPanel: n) }
            bind(key, HS, true) { $0.jumpToTopPanel(n) }
        }

        // Depth: up dives in (from the Surface too), down comes back up.
        bind(kVK_UpArrow, H, true) { $0.zoomInStep() }
        bind(kVK_DownArrow, H, false) { $0.zoomOutStep() }
        bind(kVK_ANSI_Minus, H, false) { $0.zoomOutStep() }
        bind(kVK_Escape, H, false) { $0.surface() }
        bind(kVK_ANSI_0, H, true) { $0.zoomToTop() }
        bind(kVK_ANSI_H, H, true) { $0.goHome() }
        bind(kVK_ANSI_H, HS, false) { $0.setHome() }

        // Left/right move between panels.
        bind(kVK_LeftArrow, H, false) { $0.focusNeighbor(-1) }
        bind(kVK_RightArrow, H, false) { $0.focusNeighbor(1) }
        // Shift + arrows: grow the current panel toward that side.
        bind(kVK_LeftArrow, HS, false) { $0.grow(.left) }
        bind(kVK_RightArrow, HS, false) { $0.grow(.right) }
        bind(kVK_UpArrow, HS, false) { $0.grow(.up) }
        bind(kVK_DownArrow, HS, false) { $0.grow(.down) }

        bind(kVK_ANSI_N, H, false) { $0.addPanel(.h) }
        bind(kVK_ANSI_N, HS, false) { $0.addPanel(.v) }
        bind(kVK_Delete, H, false) { $0.deletePanel() }
        bind(kVK_ANSI_T, H, false) { $0.flip() }
        bind(kVK_ANSI_F, H, false) { $0.toggleFloat() }
        // Cut, copy and paste windows, one at a time.
        bind(kVK_ANSI_X, H, false) { $0.cutFocused() }
        bind(kVK_ANSI_C, H, false) { $0.copyFocused() }
        bind(kVK_ANSI_V, H, false) { $0.paste() }
        bind(kVK_ANSI_X, HS, false) { $0.releaseFocused() }
        bind(kVK_Delete, HS, false) { $0.deleteEmptyPools() }
        // Saved pools: save, save & close, open one into an empty pool.
        bind(kVK_ANSI_S, HS, false) { $0.savePool(close: false) }
        bind(kVK_ANSI_W, HS, false) { $0.savePool(close: true) }
        bind(kVK_ANSI_O, HS, false) { $0.chooseSavedPool() }
        bind(kVK_ANSI_G, H, false) { $0.showNumbers() }
        bind(kVK_ANSI_G, HS, false) { $0.tidyUp() }
        bind(kVK_ANSI_R, H, false) { $0.renamePanel() }
        bind(kVK_ANSI_R, HS, false) { $0.renameBoard() }
        bind(kVK_ANSI_Z, H, false) { $0.undo() }
        bind(kVK_Return, H, false) { $0.toggleSpotlightFocused() }
        bind(kVK_ANSI_D, H, true) { $0.sendToDesktop() }   // on your desktop: send a window to a pool
        // Step sideways to the previous / next board on this level.
        bind(kVK_ANSI_L, H, false) { $0.toggleLobby() }
        bind(kVK_ANSI_B, H, false) { $0.toggleBreathingRoom() }
        bind(kVK_ANSI_L, HS, false) { $0.hidePoolHere() }   // same as Hyper + Shift + P
        // Hide (or show again) what's under the pointer: a window, or a whole pool.
        bind(kVK_ANSI_P, H, false) { $0.hideWindowHere() }
        bind(kVK_ANSI_P, HS, false) { $0.hidePoolHere() }
        bind(kVK_ANSI_LeftBracket, H, false) { $0.stepSideways(-1) }
        bind(kVK_ANSI_RightBracket, H, false) { $0.stepSideways(1) }
        bind(kVK_ANSI_O, H, true) { [weak self] _ in self?.overview.toggle() }
        bind(kVK_F3, H, true) { [weak self] _ in self?.overview.toggle() }

        HotKeys.register(kVK_ANSI_Slash, H) { Toast.show(AppDelegate.helpText, seconds: 7) }
    }

    static let helpText = """
    Scuba   (Hyper = Ctrl + Option + Cmd)

    Hyper + ↑  or  Hyper + scroll up    dive in (from your desktop, or into a pool)
    Hyper + ↓  or  Hyper + scroll down  come back up (scroll goes on past Main to your desktop) · Hyper + Esc: straight there
    Hold Hyper                          see the board's pools and names
    Hyper + O  or  Hyper + F3           overview of all boards (or zoom out past Main) — click to go there
    Hyper + [  /  ]  or  Hyper + swipe sideways   step to the previous / next board on this level
    Hyper + B                           open / fold away breathing room (corner nearest the pointer)
    Hyper + L                           show / hide the lobby in the breathing room
    Hyper + P                           hide the window under the pointer when you zoom out · again shows it
    Hyper + Shift + P                   hide the whole pool under the pointer when you zoom out · again shows it
    Hyper + X  /  C  /  V               cut / copy / paste a window (one at a time) · Hyper + X again puts it back
    Hyper + Shift + S  /  W  /  O       (BETA) save the pool under the pointer / save & close it / open a saved pool here
    Three fingers: swipe down / up      dive in / come back up (follows your fingers; out past Main: the Overview) · with Hyper: up goes straight to your desktop · down on a gap between windows: step through to your desktop (swipe up there to come back)
    Three fingers: swipe left / right   next / previous board on this level · from Main: another Main
    Three-finger click on a window      Spotlight it (again to put it back) · also Hyper + click, Hyper + Return, or double-click its title bar
    Hyper + D                           send the Spotlight window (or the one you're using) to your desktop · on your desktop: send a window to a pool
    Double-click a nested window's title bar   dive to its board
    Pinch out / in on empty space      dive in / come back up (Hyper + pinch: anywhere)
    Hyper + R  /  Shift + R             name this pool / this board
    Hyper + Z                           undo the last layout change

    Hyper + 1–9 / U I J K       put window in that pool
    Hyper + ←   /   Hyper + →   previous / next pool
    Hyper + Shift + 1–9         zoom into that pool
    Hyper + Shift + U I J K     jump into top-level pool 1–4
    Hyper + –    /   Hyper + 0  zoom out / to top
    Hyper + H                   go Home   (Shift: set Home here)
    Hyper + N    /   Shift + N  add pool right / below
    Hyper + Delete              delete pool  (Shift: delete every empty pool here)
    Hyper + T                   flip side by side ⇄ stacked
    Hyper + F                   float / fill the focused window
    Hyper + Shift + arrows      grow pool toward that side
    Hyper + drag a gap          resize pools with the mouse
    Hyper + G                   show pool numbers
    Hyper + Shift + G           tidy up and renumber pools
    Hyper + Shift + X           release window (it stops joining boards)

    Drag a window: it floats where you drop it inside a pool.
    Drop on the middle "Fill" bar to snap, or an edge bar for a new pool.
    Hold Option when letting go to leave it alone.
    """

    // MARK: Menu

    /// "Breathing room" submenu: on/off, which side, how wide.
    private func roomMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Breathing room", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Open breathing room here  (Hyper + B)", enabled: !c.onSurface) {
            c.toggleBreathingRoom()
        })
        sub.addItem(ActionItem("Open it every time you dive in", checked: c.breathingRoom) {
            c.breathingRoom.toggle()
        })
        sub.addItem(ActionItem("Show the lobby in it  (Hyper + L)", checked: c.showLobby) {
            c.showLobby.toggle()
        })
        sub.addItem(ActionItem("Hidden and empty pools fold away from above", checked: c.roomInsideOnly) {
            c.roomInsideOnly.toggle()
        })
        sub.addItem(.separator())
        let on = true
        sub.addItem(ActionItem("In the corner nearest the pointer", enabled: on, checked: c.roomSide == .pointer) {
            c.roomSide = .pointer
        })
        sub.addItem(ActionItem("Toward the middle of the screen", enabled: on, checked: c.roomSide == .middle) {
            c.roomSide = .middle
        })
        sub.addItem(ActionItem("Always on the left", enabled: on, checked: c.roomSide == .left) {
            c.roomSide = .left
        })
        sub.addItem(ActionItem("Always on the right", enabled: on, checked: c.roomSide == .right) {
            c.roomSide = .right
        })
        sub.addItem(.separator())
        let quarter = c.roomQuarter
        sub.addItem(ActionItem("A quarter of the screen, bottom corner", enabled: on,
                               checked: quarter && !c.roomAtTop) {
            c.setRoomShape(quarter: true, top: false)
        })
        sub.addItem(ActionItem("A quarter of the screen, top corner", enabled: on,
                               checked: quarter && c.roomAtTop) {
            c.setRoomShape(quarter: true, top: true)
        })
        for (title, share) in [("A narrow strip", 0.15), ("A medium strip", 0.22), ("A wide strip", 0.3)] {
            sub.addItem(ActionItem(title, enabled: on, checked: !quarter && abs(c.roomShare - share) < 0.01) {
                c.setRoomShape(quarter: false, share: share)
            })
        }
        item.submenu = sub
        return item
    }


    /// "Hiding" submenu: hide windows and pools from the view above,
    /// how they look from there, and the preview.
    private func privateMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Hiding windows & pools", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Hide / show the window under the pointer  (Hyper + P)", enabled: !c.onSurface) {
            c.hideWindowHere()
        })
        sub.addItem(ActionItem("Hide / show the pool under the pointer  (Hyper + Shift + P)", enabled: !c.onSurface) {
            c.hidePoolHere()
        })
        let title = NSMenuItem(title: "Seen from above, hidden things…", action: nil, keyEquivalent: "")
        title.isEnabled = false
        sub.addItem(.separator())
        sub.addItem(title)
        sub.addItem(ActionItem("Fold away completely", checked: c.privateLook == .hidden) { c.privateLook = .hidden })
        sub.addItem(ActionItem("Show as frosted portholes", checked: c.privateLook == .frosted) { c.privateLook = .frosted })
        sub.addItem(ActionItem("Show as app icons with a badge", checked: c.privateLook == .icon) { c.privateLook = .icon })
        sub.addItem(.separator())
        sub.addItem(ActionItem("Preview the board before and after", checked: c.previewsFold) {
            c.previewsFold.toggle()
        })
        item.submenu = sub
        return item
    }

    /// "Motion & feel" submenu: the quiet behaviours, each one switchable.
    private func feelMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Motion & feel", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Windows glide into place", checked: c.glideMotion) {
            c.glideMotion.toggle()
        })
        sub.addItem(ActionItem("Dragging a window's edge moves the gap", checked: c.edgeGaps) {
            c.edgeGaps.toggle()
        })
        sub.addItem(ActionItem("New windows go to empty pools first", checked: c.openWater) {
            c.openWater.toggle()
        })
        sub.addItem(ActionItem("Throw a window to send it across", checked: c.throwing) {
            c.throwing.toggle()
        })
        sub.addItem(ActionItem("Zooming out stops at Main (Hyper + Esc still goes to your desktop)",
                               checked: c.stopAtMain) {
            c.stopAtMain.toggle()
        })
        sub.addItem(ActionItem("Zooming out past Main shows all your boards", checked: c.overviewZoom) {
            c.overviewZoom.toggle()
        })
        sub.addItem(ActionItem("Swipe down on the gaps between windows to step through to your desktop",
                               checked: c.stepThrough) {
            c.stepThrough.toggle()
        })
        sub.addItem(ActionItem("Three-finger swipes (dive, rise, step sideways)", checked: swipes.enabled) {
            self.swipes.enabled.toggle()
            if self.swipes.enabled {
                Toast.show("Set macOS's own three-finger swipes to four fingers in System Settings › Trackpad › More Gestures", seconds: 4)
            }
        })
        item.submenu = sub
        return item
    }

    /// "Displays" submenu: what each extra screen does.
    private func displaysMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (i, screen) in NSScreen.screens.enumerated() {
            let id = Controller.displayID(of: screen)
            let name = NSMenuItem(title: screen.localizedName + (i == 0 ? "  (main)" : ""), action: nil, keyEquivalent: "")
            name.isEnabled = false
            sub.addItem(name)
            if i == 0 {
                sub.addItem(ActionItem("Own boards", enabled: false, checked: true) {})
            } else {
                let mode = displayMode(id)
                sub.addItem(ActionItem("Own boards", checked: mode == .boards) {
                    self.setDisplayMode(.boards, for: id)
                })
                sub.addItem(ActionItem("Live map of where you are", checked: mode == .map) {
                    self.setDisplayMode(.map, for: id)
                })
                sub.addItem(ActionItem("Left alone", checked: mode == .off) {
                    self.setDisplayMode(.off, for: id)
                })
            }
            if i < NSScreen.screens.count - 1 { sub.addItem(.separator()) }
        }
        item.submenu = sub
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = controller
        let trusted = AXIsProcessTrusted()

        // With more than one display, the menu acts on the screen you opened it on.
        let several = NSScreen.screens.count > 1
        let screenName = several ? "  ·  " + c.screen.localizedName : ""
        let header = NSMenuItem(title: "Scuba · \(c.locationLabel())\(c.isHome && !c.onSurface ? "  ⌂" : "")\(screenName)",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // On the Surface (your normal desktop) the menu stays minimal.
        if c.onSurface {
            menu.addItem(ActionItem("Dive in  (Hyper + ↑)", enabled: trusted) { c.zoomInStep() })
            menu.addItem(ActionItem("Go Home", enabled: trusted) { c.goHome() })
            menu.addItem(ActionItem("Overview of all boards  (Hyper + O)", enabled: trusted) { self.overview.open() })
            menu.addItem(ActionItem("Send the front window to a pool…  (Hyper + D)", enabled: trusted) {
                c.chooseDestinationPool()
            })
            menu.addItem(.separator())
            menu.addItem(ActionItem(trusted ? "Setup & Permissions…" : "⚠︎ Setup & Permissions…") {
                self.setup.show()
            })
            menu.addItem(ActionItem("Keyboard shortcuts") { Toast.show(AppDelegate.helpText, seconds: 7) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Quit Scuba") { NSApp.terminate(nil) })
            return
        }

        menu.addItem(ActionItem("Back to desktop  (Hyper + Esc)", enabled: trusted) { c.surface() })
        menu.addItem(ActionItem("Overview of all boards  (Hyper + O)", enabled: trusted) { self.overview.open() })
        menu.addItem(ActionItem("Undo  (Hyper + Z)", enabled: trusted) { c.undo() })
        if !c.isHome { menu.addItem(ActionItem("Go Home  (Hyper + H)", enabled: trusted) { c.goHome() }) }
        menu.addItem(.separator())
        if let h = c.held {
            let name = c.windows.appName(h.window)
            menu.addItem(ActionItem("Paste \(name) here  (Hyper + V)", enabled: trusted) { c.paste() })
            menu.addItem(ActionItem(h.kind == .cut ? "Put \(name) back" : "Stop holding \(name)", enabled: trusted) {
                c.putBack()
            })
        } else {
            menu.addItem(ActionItem("Cut focused window  (Hyper + X)", enabled: trusted) { c.cutFocused() })
            menu.addItem(ActionItem("Copy focused window  (Hyper + C)", enabled: trusted) { c.copyFocused() })
        }
        menu.addItem(.separator())
        menu.addItem(boardMenu(c, trusted: trusted))
        menu.addItem(savedMenu(c, trusted: trusted))
        menu.addItem(settingsMenu(c, trusted: trusted))
        menu.addItem(.separator())
        menu.addItem(ActionItem("Keyboard shortcuts") { Toast.show(AppDelegate.helpText, seconds: 7) })
        menu.addItem(ActionItem(trusted ? "Setup & Permissions…" : "⚠︎ Setup & Permissions…") {
            self.setup.show()
        })
        menu.addItem(ActionItem("Quit Scuba") { NSApp.terminate(nil) })
    }

    /// "This board" submenu: everything about the board you're on and its pools.
    private func boardMenu(_ c: Controller, trusted: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "This board", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let panels = c.current.panels().sorted { $0.number < $1.number }
        func panelTitle(_ p: Panel) -> String {
            let label = p.name.map { "\($0) (\(p.number))" } ?? "Pool \(p.number)"
            if p.desktop != nil { return label + " — board (\(p.desktop!.panels().count) pools)" }
            let names = p.windows.map { c.windows.appName($0) }
            return label + " — " + (names.isEmpty ? "empty" : names.joined(separator: ", "))
        }
        func pools(_ title: String, enabled: Bool = true, _ action: @escaping (Panel) -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let list = NSMenu()
            list.autoenablesItems = false
            for p in panels { list.addItem(ActionItem(panelTitle(p)) { action(p) }) }
            item.submenu = list
            item.isEnabled = enabled && trusted
            return item
        }
        let many = panels.count > 1
        sub.addItem(pools("Put focused window in") { p in
            if let w = c.windows.focusedWindowID() { c.put(w, in: p) }
        })
        sub.addItem(pools("Zoom into") { p in c.zoomInto(p) })
        sub.addItem(ActionItem(c.spotlit == nil ? "Spotlight focused window  (Hyper + Return)"
                                                 : "End Spotlight  (Hyper + Return)", enabled: trusted) {
            c.toggleSpotlightFocused()
        })
        sub.addItem(ActionItem(c.spotlit == nil ? "Send focused window to your desktop  (Hyper + D)"
                                                 : "Send the Spotlight window to your desktop  (Hyper + D)", enabled: trusted) {
            c.sendToDesktop()
        })
        sub.addItem(.separator())
        sub.addItem(pools("Add pool to the right of") { p in c.addPanel(.h, nextTo: p) })
        sub.addItem(pools("Add pool below") { p in c.addPanel(.v, nextTo: p) })
        sub.addItem(pools("Flip side by side ⇄ stacked", enabled: many) { p in c.flip(p) })
        sub.addItem(pools("Delete pool", enabled: many) { p in c.deletePanel(p) })
        sub.addItem(ActionItem("Delete empty pools  (Hyper + Shift + Delete)", enabled: trusted) {
            c.deleteEmptyPools()
        })
        sub.addItem(ActionItem("Tidy up & renumber pools  (Hyper + Shift + G)", enabled: trusted) { c.tidyUp() })
        sub.addItem(.separator())
        sub.addItem(pools("Name pool") { p in c.renamePanel(p) })
        sub.addItem(ActionItem(c.state.path.isEmpty ? "Name this Main…" : "Name this board…",
                               enabled: trusted && (!c.state.path.isEmpty || c.state.otherMains != nil)) {
            c.renameBoard()
        })
        sub.addItem(ActionItem("Wallpaper for this board…") { c.chooseWallpaper() })
        if c.current.wallpaper != nil {
            sub.addItem(ActionItem("Use the wallpaper from above here") { c.clearWallpaper() })
        }
        sub.addItem(ActionItem("Set this board as Home  (Hyper + Shift + H)", checked: c.isHome) { c.setHome() })
        item.submenu = sub
        return item
    }

    /// "Saved pools" submenu: save the pool you're in, open one, forget one.
    private func savedMenu(_ c: Controller, trusted: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Saved pools (BETA)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Save the pool you're in, with everything inside it…  (Hyper + Shift + S)", enabled: trusted) {
            c.savePool(close: false, fromMenu: true)
        })
        sub.addItem(ActionItem("Save & close it…  (Hyper + Shift + W)", enabled: trusted) {
            c.savePool(close: true, fromMenu: true)
        })
        let saved = (c.state.savedPools ?? []).sorted { $0.saved > $1.saved }
        if !saved.isEmpty {
            sub.addItem(.separator())
            let head = NSMenuItem(title: "Open in the pool you're in (Hyper + Shift + O)", action: nil, keyEquivalent: "")
            head.isEnabled = false
            sub.addItem(head)
            for sp in saved {
                sub.addItem(ActionItem("   " + sp.name, enabled: trusted) { c.chooseSavedPoolFromMenu(sp) })
            }
            sub.addItem(.separator())
            let forget = NSMenuItem(title: "Forget a saved pool", action: nil, keyEquivalent: "")
            let list = NSMenu()
            list.autoenablesItems = false
            for sp in saved { list.addItem(ActionItem(sp.name) { c.deleteSavedPool(sp.id) }) }
            forget.submenu = list
            sub.addItem(forget)
        }
        item.submenu = sub
        return item
    }

    /// "Settings" submenu: every on/off option, grouped.
    private func settingsMenu(_ c: Controller, trusted: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(feelMenu(c))
        sub.addItem(roomMenu(c))
        sub.addItem(privateMenu(c))
        sub.addItem(windowsMenu(c))
        sub.addItem(lookMenu(c))
        if NSScreen.screens.count > 1 { sub.addItem(displaysMenu()) }
        sub.addItem(.separator())
        sub.addItem(ActionItem("Reset to two pools") { c.resetLayout() })
        sub.addItem(ActionItem("Close all board windows & start over (for testing)…", enabled: trusted) {
            c.hardReset()
        })
        item.submenu = sub
        return item
    }

    /// "Windows & pools" settings: how windows join and fit their pools.
    private func windowsMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Windows & pools", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("New windows join the board you're on", checked: c.autoJoin) { c.autoJoin.toggle() })
        sub.addItem(ActionItem("When every pool is in use, new windows open in Spotlight", checked: c.spotlightNew) {
            c.spotlightNew.toggle()
        })
        sub.addItem(ActionItem("Show cramped pools as app icons", checked: c.crowdIcons) { c.crowdIcons.toggle() })
        sub.addItem(portholeMenu(c))
        sub.addItem(ActionItem("Stacks turn side by side on wide screens", checked: c.autoRotate) { c.autoRotate.toggle() })
        sub.addItem(ActionItem("Pools grow to fit apps that won't shrink", checked: c.growToFit) { c.growToFit.toggle() })
        sub.addItem(ActionItem("Filled windows make room for floating ones", checked: c.makeRoom) { c.makeRoom.toggle() })
        sub.addItem(ActionItem("Keep tucked-away windows out of Mission Control", checked: c.tuckMinimize) {
            c.tuckMinimize.toggle()
        })
        item.submenu = sub
        return item
    }

    /// What a window too big for its pool on a nested board shows as.
    private func portholeMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Windows too big for a nested pool", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Frosted portholes: a still picture, cropped at the pool's edge",
                               checked: c.portholes && !c.portholesLive) {
            c.portholesLive = false
            c.portholes = true
        })
        sub.addItem(ActionItem("Live portholes (BETA): the whole window, shrunk to fit and kept up to date",
                               checked: c.portholes && c.portholesLive) {
            c.portholesLive = true
            c.portholes = true
        })
        sub.addItem(ActionItem("No portholes: windows spill over the pools beside them", checked: !c.portholes) {
            c.portholes = false
        })
        item.submenu = sub
        return item
    }

    /// "Look" settings: what you see around your boards.
    private func lookMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Look", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Show pool boundaries", checked: c.bounds.enabled) {
            c.bounds.enabled.toggle()
            for each in Controller.all { each.showBounds() }
        })
        sub.addItem(ActionItem("Wallpaper zooms as you dive", checked: c.backdrop.enabled) {
            c.backdrop.enabled.toggle()
            c.applyLayout()
        })
        sub.addItem(ActionItem("Darken the background as you dive", checked: c.shade.enabled) {
            c.shade.enabled.toggle()
            c.applyLayout()
        })
        item.submenu = sub
        return item
    }
}
