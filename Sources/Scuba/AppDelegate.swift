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
    /// The pill inside it: ‹ › · desktop, everything · the Scuba menu.
    private var pill: MenuBarPill?
    private let statusMenu = NSMenu()
    /// Quitting from Terminal (pkill) still gives Caps Lock back.
    private var signalSources: [DispatchSourceSignal] = []

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
                    if AXIsProcessTrusted() {
                        c.applyLayout()
                        // A board with a Desktop: straight in, nothing moves.
                        c.startOnDesktop()
                    }
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
        if let c, !c.onSurface { Coach.shared.note(.dived) } else { Coach.shared.refresh() }
        for map in maps.values { map.refresh() }
    }
    private var dragDock: DragDock!
    private var dividerDrag: DividerDrag!
    private var frameDrag: FrameDrag!
    private var reveal: HyperReveal!
    private var scrollZoom: ScrollZoom!
    private var overview: BoardOverview!
    private var doubleClickDive: DoubleClickDive!
    private var pinchZoom: PinchZoom!
    private var spotlightClick: SpotlightClick!
    private var swipes: ThreeFingerSwipes!
    private let setup = SetupWindow()

    // MARK: Commands by link

    /// scuba:// links run Scuba's commands, from Raycast, Alfred, Shortcuts or
    /// a script: `open scuba://back`, `open scuba://view/3`, and so on.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleLink(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    private var launched = false
    private var pendingLinks: [URL] = []

    @objc private func handleLink(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        if launched { run(url) } else { pendingLinks.append(url) }
    }

    static let linkCommands: [(name: String, does: String)] = [
        ("dive", "dive in toward the pointer"), ("up", "come back up a level"), ("desktop", "back to your desktop"),
        ("home", "go Home"), ("back", "back to where you were"), ("forward", "forward again"),
        ("overview", "the overview of all boards"), ("view/1–9", "go to a saved view"),
        ("save-view/1–9", "save where you're looking"), ("frost", "frost / unfrost the tile under the pointer"),
        ("float", "float / fill the window you're using"), ("room", "open / fold away breathing room"),
        ("undo", "undo the last layout change"), ("float-all", "float every window on the Desktop"),
    ]

    private func run(_ url: URL) {
        guard url.scheme?.lowercased() == "scuba", requireAccessibility() else { return }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        guard let command = parts.first?.lowercased() else { return }
        let number = parts.count > 1 ? Int(parts[1]) : nil
        let c = controller
        let inside = !c.onSurface
        switch command {
        case "dive": c.zoomInStep()
        case "up": if inside { c.zoomOutStep() }
        case "desktop", "surface": if inside { c.surface() }
        case "home": c.goHome()
        case "back": if inside { c.goBack() }
        case "forward": if inside { c.goForward() }
        case "overview": overview.toggle()
        case "view": if let n = number, (1...9).contains(n) { c.goToView(n) }
        case "save-view": if let n = number, (1...9).contains(n) { c.saveView(n) }
        case "frost": c.toggleFrostHere()
        case "float": if inside { c.toggleFloat() }
        case "room": if inside { c.toggleBreathingRoom() }
        case "undo": c.undo()
        case "float-all": c.floatAllOnDesktop()
        default:
            Toast.show("Scuba doesn't know scuba://\(command)", seconds: 1.4)
        }
    }

    // MARK: Reporting a problem

    /// Copies a short report about this Mac and Scuba (versions, displays,
    /// permissions, settings changed from how they come; nothing personal)
    /// and opens a new issue on Scuba's GitHub page to paste it into.
    private func reportProblem() {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let version = "\(short) (\(build))"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let defaults = UserDefaults.standard
        let keys = ["pictureResize", "stageDrag", "greenButtonDocks", "arrowsHistory", "appColours", "pinchFollows",
                    "wallpaperBlur", "tileWindows", "crowdIcons", "autoRotate", "growToFit", "edgeGaps", "gapDrag",
                    "threeFinger", "portholes", "glideMotion", "menuArrows", "gapHandles"]
        let settings: [String] = keys.map { key in
            let value = defaults.object(forKey: key).map { String(describing: $0) } ?? "default"
            return key + ": " + value
        }
        let report = """
        Scuba \(version) · macOS \(os)
        Displays: \(NSScreen.screens.count) · Accessibility: \(AXIsProcessTrusted() ? "on" : "off") · Screen Recording: \(CGPreflightScreenCaptureAccess() ? "on" : "off")
        Apps left alone: \(WindowManager.leftAlone.count)
        \(settings.joined(separator: "\n"))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        if let url = URL(string: "https://github.com/Canobiir/Scuba/issues/new") {
            NSWorkspace.shared.open(url)
        }
        Toast.show("Details are on your clipboard — paste them under: what happened, what you expected, and what you were doing just before",
                   seconds: 4)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.fromFractalWindows()   // boards and settings from before the rename
        Migration.cleanGaps()            // gaps without lines, with a handle to grab
        Migration.mainToDesktop()        // zooming out from Main goes to your desktop
        // An app that hangs shouldn't freeze Scuba with it: give up on any
        // one accessibility request after a second (macOS waits about six).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        // Frosted tiles show the blurred window, not its icon's colour (once,
        // for builds that had the colour on by default).
        if !UserDefaults.standard.bool(forKey: "plainFrostOnce") {
            UserDefaults.standard.set(false, forKey: "appColours")
            UserDefaults.standard.set(true, forKey: "plainFrostOnce")
        }
        UserDefaults.standard.register(defaults: ["autoJoin": true, "depthShade": true, "makeRoom": true, "autoRotate": true, "crowdIcons": true, "parallax": true, "breathingRoom": false, "threeFinger": true, "showLobby": true, "roomInsideOnly": true, "growToFit": true, "roomQuarter": true, "glideMotion": true, "edgeGaps": true, "gapDrag": true, "invisiblePools": true, "tileWindows": true, "stageDrag": true, "windowOutlines": false, "gapHandles": true, "menuArrows": true, "frameDrag": true, "fillVacancy": true, "minimizeReflow": true,"openWater": true, "throwing": true, "portholes": true, "livePortholes": false, "tuckMinimize": false, "stopAtMain": false, "overviewZoom": false, "spotlightNew": true, "stepThrough": true, "foldPreview": true, "pictureResize": true, "greenButtonDocks": true, "arrowsHistory": true, "appColours": false, "pinchFollows": true, "wallpaperBlur": false])
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
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        if let button = statusItem.button {
            button.title = ""
            button.setAccessibilityLabel("Scuba")
            let p = MenuBarPill(frame: button.bounds)
            p.autoresizingMask = [.width, .height]
            p.onClick = { [weak self] id in self?.pillClicked(id) }
            p.onMenu = { [weak self] in self?.openStatusMenu() }
            button.addSubview(p)
            pill = p
        }
        updateTitle()

        registerHotKeys()
        // The coach for your first swim: once Scuba's settled in.
        Coach.shared.isInside = { [weak self] in self.map { !$0.controller.onSurface } ?? false }
        Coach.shared.screen = { [weak self] in self?.controller.screen }
        Coach.shared.menuBarRect = { [weak self] in
            guard let button = self?.statusItem.button, let w = button.window else { return nil }
            return w.convertToScreen(button.convert(button.bounds, to: nil))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Coach.shared.start() }
        dragDock = DragDock(controller: active)
        dragDock.start()
        dividerDrag = DividerDrag(controller: active)
        dividerDrag.start()
        frameDrag = FrameDrag(controller: active)
        frameDrag.start()
        reveal = HyperReveal(controller: active)
        reveal.start()
        scrollZoom = ScrollZoom(controller: active)
        scrollZoom.start()
        doubleClickDive = DoubleClickDive(controller: active)
        doubleClickDive.start()
        pinchZoom = PinchZoom(controller: active)
        pinchZoom.start()
        // Hyper + click is for borders now (DividerDrag); Spotlight is a
        // three-finger tap or a title-bar double-click.
        spotlightClick = SpotlightClick(controller: active)
        swipes = ThreeFingerSwipes(controller: active)
        swipes.start()
        launched = true
        for url in pendingLinks { run(url) }
        pendingLinks.removeAll()
        // Caps Lock as your Scuba key (pilot): hold it for Hyper, tap it for caps.
        UserDefaults.standard.register(defaults: [CapsKey.defaultsKey: true])
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            s.setEventHandler(handler: AppDelegate.exitGivingCapsLockBack)
            s.resume()
            signalSources.append(s)
        }
        if AXIsProcessTrusted() {
            if UserDefaults.standard.bool(forKey: CapsKey.defaultsKey) { CapsKey.shared.setEnabled(true) }
            Toast.show(controller.onSurface ? "Scuba is running — \(CapsKey.label) + ↑ to dive in" : "Scuba is running", seconds: 2)
            // Restarted partway through Setup: pick up where you left off.
            if SetupModel.reopenAfterRestart { setup.show() }
        } else {
            setup.show()
        }
    }

    /// Off the main thread on purpose, so it works even if Scuba is stuck.
    nonisolated static func exitGivingCapsLockBack() {
        CapsKey.shared.restoreForExit()
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        CapsKey.shared.setEnabled(false)
        for c in controllers.values {
            c.flushSave()
            c.restoreAll()
        }
    }

    private func pillClicked(_ id: String) {
        guard requireAccessibility() else { return }
        let c = controller
        switch id {
        case "back": stepBack()
        case "forward": stepForward()
        // Your normal desktop, or back into your boards from there.
        case "desktop": if c.onSurface { c.zoomInStep() } else { c.surface() }
        case "everything": overview.toggle()
        default: break
        }
        // The move updates the pill when it lands; this catches the rest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.updateTitle() }
    }

    /// The full menu, dropped from the pill like any menu bar item's.
    private func openStatusMenu() {
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Without a menu attached, clicks reach the pill's own buttons.
        if menu === statusMenu {
            DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
        }
    }

    @objc private func stepBack() {
        guard requireAccessibility(), !controller.onSurface else { return }
        if arrowsHistory { controller.goBack() } else { controller.stepSideways(-1) }
    }

    @objc private func stepForward() {
        guard requireAccessibility(), !controller.onSurface else { return }
        if arrowsHistory { controller.goForward() } else { controller.stepSideways(1) }
    }

    /// The ‹ › arrows (and Cmd + Option + ← →) go back and forward through
    /// where you've been, like a browser; otherwise they step to the
    /// neighbouring board.
    private var arrowsHistory: Bool {
        get { UserDefaults.standard.bool(forKey: "arrowsHistory") }
        set { UserDefaults.standard.set(newValue, forKey: "arrowsHistory") }
    }

    /// The ‹ › arrows show while you're inside your boards (on your normal
    /// desktop there's nowhere to step to), unless they're turned off.
    private var menuArrows: Bool {
        get { UserDefaults.standard.bool(forKey: "menuArrows") }
        set { UserDefaults.standard.set(newValue, forKey: "menuArrows"); updateTitle() }
    }

    /// Menu bar: the pill of buttons, kept up to date with whichever screen
    /// moved last. Where you are shows when you hover it, and at the top of
    /// the menu, rather than as text in the menu bar.
    private func updateTitle(_ moved: Controller? = nil) {
        guard let pill, let c = moved ?? mainController else { return }
        let inside = !c.onSurface
        var segs: [MenuBarPill.Segment] = []
        if menuArrows {
            // On your desktop there's nowhere to step, so they rest dimmed.
            let back = inside && (!arrowsHistory || c.canGoBack)
            let forward = inside && (!arrowsHistory || c.canGoForward)
            segs.append(.init(id: "back", symbol: "chevron.left", tip: "Back  (Cmd + Option + ←)",
                              enabled: back, width: 20))
            segs.append(.init(id: "forward", symbol: "chevron.right", tip: "Forward  (Cmd + Option + →)",
                              enabled: forward, width: 20))
        }
        segs.append(.init(id: "desktop", symbol: "menubar.dock.rectangle",
                          tip: inside ? "Your desktop  (\(CapsKey.label) + Esc)" : "Back into your boards  (\(CapsKey.label) + ↑)",
                          on: !inside))
        segs.append(.init(id: "everything", symbol: "square.grid.2x2", tip: "Everything"))
        let here = inside ? c.breadcrumb() : "Your desktop"
        segs.append(.init(id: "menu", symbol: "water.waves", tip: "Scuba · \(here)"))
        pill.segments = segs
        statusItem.length = MenuBarPill.width(for: segs)
        statusItem.button?.toolTip = nil
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
                    Toast.show("You're on your desktop — \(CapsKey.label) + ↑ to dive in", seconds: 1.2)
                    return
                }
                // Using a shortcut means this Hyper hold isn't for a look at the panels.
                self.controller.quietReveal()
                action(self.controller)
            }
        }

        // Just a few keys, on purpose. Everything else is in the menu bar.

        // Snapping, the way Windows 11 does it: Hyper + ← / → take a half;
        // then Hyper + ↑ / ↓ make it a quarter. On a window you haven't
        // snapped, ↑ dives in (from the Surface too) and ↓ comes back up.
        bind(kVK_UpArrow, H, true) { $0.snapFocused(.up) }
        bind(kVK_DownArrow, H, false) { $0.snapFocused(.down) }
        bind(kVK_LeftArrow, H, false) { $0.snapFocused(.left) }
        bind(kVK_RightArrow, H, false) { $0.snapFocused(.right) }
        bind(kVK_Escape, H, false) { $0.surface() }

        // Breathing room, and tiling one into the board.
        bind(kVK_ANSI_B, H, false) { $0.toggleBreathingRoom() }
        bind(kVK_ANSI_Y, H, false) { $0.toggleRoomTile() }

        // Hidden from the layer above: the window under the pointer, or its whole pool.
        bind(kVK_ANSI_H, H, false) { $0.hideWindowHere() }
        bind(kVK_ANSI_H, HS, false) { $0.hidePoolHere() }

        // Cut, copy and paste a window (its tabs come along).
        bind(kVK_ANSI_X, H, false) { $0.cutFocused() }
        bind(kVK_ANSI_C, H, false) { $0.copyFocused() }
        bind(kVK_ANSI_V, H, false) { $0.paste() }

        // Views: Hyper + Shift + a number saves what's on screen; Hyper + that number comes back.
        for (i, key) in HotKeys.digits.enumerated() {
            let n = i + 1
            bind(key, H, true) { $0.goToView(n) }
            bind(key, HS, false) { $0.saveView(n) }
        }

        // Locks: this board's placements, or the window under the pointer.
        bind(kVK_ANSI_P, H, false) { $0.togglePlacementLock() }
        bind(kVK_ANSI_L, H, false) { $0.toggleWindowLock() }

        bind(kVK_ANSI_F, H, false) { $0.toggleFrostHere() }
        bind(kVK_ANSI_Z, H, false) { $0.undo() }

        // Not Hyper: Control + Option + arrows push the window you're using
        // a level at a time (Shift: move a gap); Cmd + Option + ← / → are the
        // menu bar's ‹ › arrows.
        let CO = HotKeys.ctrlOption
        let COS = HotKeys.ctrlOptionShift
        bind(kVK_LeftArrow, CO, false) { $0.pushFocused(.left) }
        bind(kVK_RightArrow, CO, false) { $0.pushFocused(.right) }
        bind(kVK_UpArrow, CO, false) { $0.pushFocused(.up) }
        bind(kVK_DownArrow, CO, false) { $0.pushFocused(.down) }
        bind(kVK_LeftArrow, COS, false) { $0.nudgeGap(.left) }
        bind(kVK_RightArrow, COS, false) { $0.nudgeGap(.right) }
        bind(kVK_UpArrow, COS, false) { $0.nudgeGap(.up) }
        bind(kVK_DownArrow, COS, false) { $0.nudgeGap(.down) }
        bind(kVK_LeftArrow, HotKeys.cmdOption, false) { [weak self] c in
            if self?.arrowsHistory == true { c.goBack() } else { c.stepSideways(-1) }
        }
        bind(kVK_RightArrow, HotKeys.cmdOption, false) { [weak self] c in
            if self?.arrowsHistory == true { c.goForward() } else { c.stepSideways(1) }
        }

        HotKeys.register(kVK_ANSI_Slash, H) { Toast.show(AppDelegate.helpText, seconds: 7) }
    }

    static var helpText: String { """
    Scuba   \(CapsKey.usingCaps ? "(hold Caps Lock for these — a tap is still Caps Lock)" : "(Hyper = Ctrl + Option + Cmd)")

    \(CapsKey.label) + ← / →           snap the window you're using to that half
    \(CapsKey.label) + ↑ / ↓           snapped: top / bottom quarter (the other way: the half again)
                            not snapped: dive in / come back up
    \(CapsKey.label) + Esc             back to your desktop
    \(CapsKey.label) + B               open / fold away breathing room
    \(CapsKey.label) + Y               tile the breathing room under the pointer into the board (again: room again)
    \(CapsKey.label) + H               hide the window under the pointer from the layer above (Shift: its whole pool)
    \(CapsKey.label) + X / C / V       cut / copy / paste a window, tabs and all
    \(CapsKey.label) + Shift + 1–9     save the view on screen   ·   \(CapsKey.label) + 1–9: back to it
    \(CapsKey.label) + P               lock this board's placements (nothing docks, snaps or resizes;
                            windows opened meanwhile float on top and stay with the board;
                            \(CapsKey.label) + P on one of those punches it into the tile under it)
    \(CapsKey.label) + L               lock the window under the pointer in place
    \(CapsKey.label) + F               frost / unfrost the tile under the pointer
    \(CapsKey.label) + Z               undo

    Three fingers: down / up dive in / come back up · sideways: next board · click: Spotlight
    Pinch out / in on empty space: dive in / come back up
    Drag a gap's pill to resize, or hold \(CapsKey.label) and grab any border · drop a window on another's middle to tab it
    Cmd + Shift + drag a box: make those windows a room of their own
    Everything else is in the menu bar.
    """ }

    // MARK: Menu

    /// "Breathing room" submenu: on/off, which side, how wide.
    private func roomMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Breathing room", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Open breathing room here  (\(CapsKey.label) + B)", enabled: !c.onSurface) {
            c.toggleBreathingRoom()
        })
        sub.addItem(ActionItem("Open it every time you dive in", checked: c.breathingRoom) {
            c.breathingRoom.toggle()
        })
        sub.addItem(ActionItem("Show the lobby in it", checked: c.showLobby) {
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
        sub.addItem(ActionItem("Hide / show the window under the pointer  (\(CapsKey.label) + H)", enabled: !c.onSurface) {
            c.hideWindowHere()
        })
        sub.addItem(ActionItem("Hide / show the pool under the pointer  (\(CapsKey.label) + Shift + H)", enabled: !c.onSurface) {
            c.hidePoolHere()
        })
        sub.addItem(ActionItem("Lock placements on this board  (\(CapsKey.label) + P)", checked: c.placementsLocked) {
            c.togglePlacementLock()
        })
        sub.addItem(ActionItem("Lock / unlock the window under the pointer  (\(CapsKey.label) + L)", enabled: !c.onSurface) {
            c.toggleWindowLock()
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
        sub.addItem(ActionItem("Cmd + Shift + drag a box over windows to make them a room", checked: c.frameDrag) {
            c.frameDrag.toggle()
        })
        sub.addItem(ActionItem("Fine outlines around docked windows", checked: c.bounds.windowOutlines) {
            c.bounds.windowOutlines.toggle()
            c.showBounds()
        })
        sub.addItem(ActionItem("‹ › arrows in the menu bar", checked: menuArrows) { self.menuArrows.toggle() })
        sub.addItem(ActionItem("‹ › go back and forward through where you've been (off: neighbouring boards)",
                               checked: arrowsHistory) { self.arrowsHistory.toggle() })
        sub.addItem(ActionItem("A handle in each gap to drag", checked: c.bounds.gapHandles) {
            c.bounds.gapHandles.toggle()
            c.showBounds()
        })
        sub.addItem(ActionItem("Drags glide smoothly, after a moment's pause (needs Screen Recording)", checked: c.smoothDrags) {
            c.smoothDrags.toggle()
        })
        sub.addItem(leftAloneMenu(c))
        sub.addItem(ActionItem("The green button docks and floats windows (Option + click: full screen)",
                               checked: c.greenButtonDocks) {
            c.greenButtonDocks.toggle()
        })
        sub.addItem(ActionItem("Resizing moves pictures; apps resize once when you let go (needs Screen Recording)",
                               checked: c.pictureResize) {
            c.pictureResize.toggle()
        })
        sub.addItem(ActionItem("Every docked window gets a space of its own", checked: c.tileWindows) {
            c.tileWindows.toggle()
        })
        sub.addItem(ActionItem("Pools stay invisible while dragging (hold Shift to see them)", checked: c.invisiblePools) {
            c.invisiblePools.toggle()
        })
        sub.addItem(ActionItem("Windows grow into the space a window leaves", checked: c.fillVacancies) {
            c.fillVacancies.toggle()
        })
        sub.addItem(ActionItem("Drag a gap between pools to resize them (no keys)", checked: c.gapDrag) {
            c.gapDrag.toggle()
        })
        sub.addItem(ActionItem("Minimized windows give their space to their neighbours", checked: c.minimizeReflow) {
            c.minimizeReflow.toggle()
        })
        sub.addItem(ActionItem("New windows go to empty pools first", checked: c.openWater) {
            c.openWater.toggle()
        })
        sub.addItem(ActionItem("Throw a window to send it across", checked: c.throwing) {
            c.throwing.toggle()
        })
        sub.addItem(ActionItem("Zooming out stops at Main (\(CapsKey.label) + Esc still goes to your desktop)",
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

    /// Apps left alone: they float freely and are never arranged.
    private func leftAloneMenu(_ c: Controller) -> NSMenuItem {
        let item = NSMenuItem(title: "Apps left alone", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let alone = WindowManager.leftAlone
        if let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier, !alone.contains(bid) {
            sub.addItem(ActionItem("Leave \(app.localizedName ?? bid) alone") { c.leaveAlone(app) })
            sub.addItem(.separator())
        }
        if alone.isEmpty {
            let none = NSMenuItem(title: "None yet — their windows would float freely, never arranged", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for bid in alone.sorted() {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bid
            sub.addItem(ActionItem(name, checked: true) { c.stopLeavingAlone(bid) })
        }
        item.submenu = sub
        return item
    }

    /// Saved views: go to one, or save where you're looking on a number.
    private func savedViewsMenu(_ c: Controller, trusted: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Saved views", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let saved = c.savedViewList()
        for v in saved {
            sub.addItem(ActionItem("\(v.label)  (Ctrl + Option + \(v.number))", enabled: trusted) { c.goToView(v.number) })
        }
        if !saved.isEmpty { sub.addItem(.separator()) }
        let taken = Set(saved.map { $0.number })
        let save = NSMenuItem(title: "Save this view on…", action: nil, keyEquivalent: "")
        let numbers = NSMenu()
        for n in 1...9 {
            let label = taken.contains(n) ? "\(n)  (replaces the one there)" : "\(n)"
            numbers.addItem(ActionItem(label, enabled: trusted) { c.saveView(n) })
        }
        save.submenu = numbers
        sub.addItem(save)
        item.submenu = sub
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Coach.shared.note(.menuOpened)
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
        menu.addItem(ActionItem("Quick guide…") { self.setup.showGettingStarted() })
        menu.addItem(ActionItem("Show me around") { Coach.shared.restart() })
        menu.addItem(.separator())

        // On the Surface (your normal desktop) the menu stays minimal.
        if c.onSurface {
            menu.addItem(ActionItem("Dive in  (\(CapsKey.label) + ↑)", enabled: trusted) { c.zoomInStep() })
            menu.addItem(ActionItem("Go Home", enabled: trusted) { c.goHome() })
            menu.addItem(ActionItem("Overview of all boards", enabled: trusted) { self.overview.open() })
            menu.addItem(ActionItem("Send the front window to a pool…", enabled: trusted) {
                c.chooseDestinationPool()
            })
            menu.addItem(.separator())
            menu.addItem(ActionItem(trusted ? "Setup & Permissions…" : "⚠︎ Setup & Permissions…") {
                self.setup.show()
            })
            menu.addItem(ActionItem("Keyboard shortcuts") { Toast.show(AppDelegate.helpText, seconds: 7) })
            menu.addItem(ActionItem("Report a problem…") { self.reportProblem() })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Quit Scuba") { NSApp.terminate(nil) })
            return
        }

        menu.addItem(ActionItem("Back to desktop  (\(CapsKey.label) + Esc)", enabled: trusted) { c.surface() })
        menu.addItem(ActionItem("Overview of all boards", enabled: trusted) { self.overview.open() })
        menu.addItem(ActionItem("Undo  (\(CapsKey.label) + Z)", enabled: trusted) { c.undo() })
        menu.addItem(ActionItem("Float every window on the Desktop", enabled: trusted) { c.floatAllOnDesktop() })
        if !c.isHome { menu.addItem(ActionItem("Go Home", enabled: trusted) { c.goHome() }) }
        menu.addItem(ActionItem("Back  (Cmd + Option + ←)", enabled: trusted && c.canGoBack) { c.goBack() })
        menu.addItem(ActionItem("Forward  (Cmd + Option + →)", enabled: trusted && c.canGoForward) { c.goForward() })
        menu.addItem(savedViewsMenu(c, trusted: trusted))
        menu.addItem(.separator())
        if let h = c.held {
            let name = c.windows.appName(h.window)
            menu.addItem(ActionItem("Paste \(name) here  (\(CapsKey.label) + V)", enabled: trusted) { c.paste() })
            menu.addItem(ActionItem(h.kind == .cut ? "Put \(name) back" : "Stop holding \(name)", enabled: trusted) {
                c.putBack()
            })
        } else {
            menu.addItem(ActionItem("Cut focused window  (\(CapsKey.label) + X)", enabled: trusted) { c.cutFocused() })
            menu.addItem(ActionItem("Copy focused window  (\(CapsKey.label) + C)", enabled: trusted) { c.copyFocused() })
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
        menu.addItem(ActionItem("Report a problem…") { self.reportProblem() })
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
        sub.addItem(ActionItem(c.spotlit == nil ? "Spotlight focused window"
                                                 : "End Spotlight", enabled: trusted) {
            c.toggleSpotlightFocused()
        })
        sub.addItem(ActionItem(c.spotlit == nil ? "Send focused window to your desktop"
                                                 : "Send the Spotlight window to your desktop", enabled: trusted) {
            c.sendToDesktop()
        })
        sub.addItem(.separator())
        sub.addItem(pools("Add pool to the right of") { p in c.addPanel(.h, nextTo: p) })
        sub.addItem(pools("Add pool below") { p in c.addPanel(.v, nextTo: p) })
        sub.addItem(pools("Flip side by side ⇄ stacked", enabled: many) { p in c.flip(p) })
        sub.addItem(pools("Delete pool", enabled: many) { p in c.deletePanel(p) })
        sub.addItem(ActionItem("Delete empty pools", enabled: trusted) {
            c.deleteEmptyPools()
        })
        sub.addItem(ActionItem("Tidy up & renumber pools", enabled: trusted) { c.tidyUp() })
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
        sub.addItem(ActionItem("Set this board as Home", checked: c.isHome) { c.setHome() })
        item.submenu = sub
        return item
    }

    /// "Saved pools" submenu: save the pool you're in, open one, forget one.
    private func savedMenu(_ c: Controller, trusted: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Saved pools (BETA)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem("Save the pool you're in, with everything inside it…", enabled: trusted) {
            c.savePool(close: false, fromMenu: true)
        })
        sub.addItem(ActionItem("Save & close it…", enabled: trusted) {
            c.savePool(close: true, fromMenu: true)
        })
        let saved = (c.state.savedPools ?? []).sorted { $0.saved > $1.saved }
        if !saved.isEmpty {
            sub.addItem(.separator())
            let head = NSMenuItem(title: "Open in the pool you're in", action: nil, keyEquivalent: "")
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
        sub.addItem(ActionItem("Hold Caps Lock for Hyper (pilot) — a tap is still Caps Lock",
                               checked: CapsKey.shared.enabled) {
            let on = !CapsKey.shared.enabled
            UserDefaults.standard.set(on, forKey: CapsKey.defaultsKey)
            CapsKey.shared.setEnabled(on)
            if on && !CapsKey.shared.enabled {
                Toast.show("Caps Lock needs Scuba's Accessibility access", seconds: 2)
            }
        })
        sub.addItem(.separator())
        sub.addItem(ActionItem("Reset: one Main, all Desktop") { c.resetLayout() })
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
        sub.addItem(ActionItem("Blur the wallpaper behind your boards", checked: c.shade.blur) {
            c.shade.blur.toggle()
            c.applyLayout()
        })
        sub.addItem(ActionItem("Frosted tiles take a little of each app's colour", checked: AppColour.enabled) {
            AppColour.enabled.toggle()
            c.applyLayout()
        })
        sub.addItem(ActionItem("Pinching follows your fingers (off: one step per pinch)", checked: self.pinchZoom.follows) {
            self.pinchZoom.follows.toggle()
        })
        item.submenu = sub
        return item
    }
}
