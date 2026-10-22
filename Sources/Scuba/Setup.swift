import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Tracks permissions and setup options, and fixes them.
@MainActor
final class SetupModel: ObservableObject {
    @Published var accessibility = AXIsProcessTrusted()
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var message: String?
    /// macOS features that move or hide windows behind Scuba's back.
    @Published var conflicts: [Conflict] = []

    enum Page { case welcome, permissions, start }
    @Published var page: Page = UserDefaults.standard.bool(forKey: "welcome.seen") ? .permissions : .welcome

    struct Conflict: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    private var timer: Timer?
    private var restarting = false

    var bundleID: String { Bundle.main.bundleIdentifier ?? "com.michaelmartinez.scuba" }
    var inApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let had = accessibility
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        checkConflicts()
        if accessibility && screenRecording { SetupModel.reopenAfterRestart = false }
        if !had && accessibility && !restarting {
            // macOS only fully applies the permission to a fresh launch.
            message = "Accessibility is on. Restarting…"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.relaunch()
            }
        }
    }

    // MARK: What gets in the way

    /// Edge tiling, clicking the wallpaper to reveal the desktop, and Stage
    /// Manager all move or hide windows behind Scuba's back.
    func checkConflicts() {
        let wm = UserDefaults(suiteName: "com.apple.WindowManager")
        func on(_ key: String, _ standard: Bool) -> Bool { (wm?.object(forKey: key) as? Bool) ?? standard }
        var found: [Conflict] = []
        if on("GloballyEnabled", false) {
            found.append(Conflict(id: "stage", title: "Stage Manager",
                                  detail: "Hides windows into a strip at the side. Turn it off in Desktop & Dock."))
        }
        if #available(macOS 15, *), on("EnableTilingByEdgeDrag", true) || on("EnableTopTilingByEdgeDrag", true) {
            found.append(Conflict(id: "tiling", title: "Tiling by dragging to the edge",
                                  detail: "Fills a window to half the screen when you drag it to an edge, fighting Scuba's own docking. Turn off \"Drag windows to screen edges to tile\" and \"Drag windows to menu bar to fill screen\" in Desktop & Dock."))
        }
        if on("EnableStandardClickToShowDesktop", true) {
            found.append(Conflict(id: "wallpaper", title: "Click wallpaper to reveal desktop",
                                  detail: "Sweeps every window aside when you click the wallpaper. Set it to \"Only in Stage Manager\" in Desktop & Dock."))
        }
        if found.map(\.id) != conflicts.map(\.id) { conflicts = found }
    }

    func openDesktopSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Accessibility

    func grantAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
        message = "Switch on Scuba in the list. The app restarts by itself once it's on."
    }

    /// Clears old entries left behind by previous builds, then asks again.
    func fixAccessibility() {
        run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
        message = "Cleared old entries."
        grantAccessibility()
    }

    // MARK: Screen Recording

    func grantScreenRecording() {
        // macOS may offer "Quit & Reopen" once it's on; come back to Setup after.
        SetupModel.reopenAfterRestart = true
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
        message = "Switch on Scuba, then press Restart. This is only needed for the smooth zoom."
    }

    func fixScreenRecording() {
        run("/usr/bin/tccutil", ["reset", "ScreenCapture", bundleID])
        grantScreenRecording()
    }

    // MARK: Options

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Copies the app into /Applications and relaunches from there.
    func moveToApplications() {
        let source = Bundle.main.bundleURL
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
        } catch {
            message = "Couldn't copy to Applications: \(error.localizedDescription)"
            return
        }
        // The copy is a "new" app as far as permissions go.
        run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
        relaunch(at: dest)
    }

    /// Bring Setup back after a restart, so the next permission can be done
    /// without reopening the app by hand.
    static var reopenAfterRestart: Bool {
        get { UserDefaults.standard.bool(forKey: "setup.reopen") }
        set { UserDefaults.standard.set(newValue, forKey: "setup.reopen") }
    }

    /// Quits and reopens the app (from a new location if given).
    func relaunch(at url: URL? = nil) {
        restarting = true
        // Come back to this window if anything's still left to switch on.
        SetupModel.reopenAfterRestart = !(AXIsProcessTrusted() && CGPreflightScreenCaptureAccess())
        let path = (url ?? Bundle.main.bundleURL).path
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        // Wait until this copy has really quit (putting windows back can take
        // a moment); opening it sooner just wakes the copy that's closing.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done; " +
                     "sleep 0.3; /usr/bin/open \"\(escaped)\""
        run("/bin/sh", ["-c", script], wait: false)
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func run(_ tool: String, _ args: [String], wait: Bool = true) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        do {
            try p.run()
            if wait { p.waitUntilExit() }
        } catch {
            NSLog("Scuba: couldn't run \(tool): \(error.localizedDescription)")
        }
    }
}

// MARK: - Window

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var close: () -> Void

    var body: some View {
        switch model.page {
        case .welcome:
            // The welcome page shows first, until you've been through it once.
            WelcomeView {
                UserDefaults.standard.set(true, forKey: "welcome.seen")
                model.page = .permissions
            }
        case .start:
            GettingStartedView(back: { model.page = .permissions }, done: close)
        case .permissions:
            permissions
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("⊞").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scuba").font(.title2.bold())
                    Text("Setup & permissions").foregroundStyle(.secondary)
                }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "Required. Lets Scuba see, move and resize your windows.",
                granted: model.accessibility,
                grant: { model.grantAccessibility() },
                fix: { model.fixAccessibility() })

            PermissionRow(
                title: "Screen Recording",
                detail: "Optional. Lets Scuba show a frosted picture of a window that doesn't fit, and play smooth zooms and drags. Without it, those snap instead.",
                granted: model.screenRecording,
                grant: { model.grantScreenRecording() },
                fix: { model.fixScreenRecording() })

            if !model.conflicts.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Turn off what gets in the way").font(.headline)
                        Spacer()
                        Button("Open Desktop & Dock") { model.openDesktopSettings() }
                    }
                    ForEach(model.conflicts) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.callout.bold())
                                Text(c.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            Divider()

            Toggle("Open Scuba at login", isOn: $model.launchAtLogin)
                .onChange(of: model.launchAtLogin) { _, wanted in
                    if wanted != (SMAppService.mainApp.status == .enabled) {
                        model.setLaunchAtLogin(wanted)
                    }
                }

            if !model.inApplications {
                HStack {
                    Text("Running from \(Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Move to Applications") { model.moveToApplications() }
                }
            }

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Restart App") { model.relaunch() }
                Button("Welcome") { model.page = .welcome }
                    .help("What Scuba is going for, and why it asks for these permissions")
                Button("Getting Started") { model.page = .start }
                    .help("The first moves, one at a time")
                Spacer()
                Button("Done") {
                    SetupModel.reopenAfterRestart = false
                    close()
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// The first page you see: what Scuba is going for, and why it's about to
/// ask for permissions.
private struct WelcomeView: View {
    var next: () -> Void

    private struct Idea: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    private let ideas: [Idea] = [
        Idea(title: "Your hand has the final word",
             detail: "Sizes you set stay set. An app that can't shrink that far frosts over, and comes back when there's room."),
        Idea(title: "No dead space",
             detail: "Empty space never stops a window from growing. Space too small to use becomes a way into a full-size view."),
        Idea(title: "Make rooms as you go",
             detail: "Box a few windows with Cmd + Shift + drag and they become a room of their own, and you step right in."),
        Idea(title: "Tabs here, rooms a level down",
             detail: "Drop a window on the middle of another to tab them. Rooms hold windows one level down."),
        Idea(title: "Quiet until touched",
             detail: "No colours or lines in the way. Handles, close buttons and hints appear when you point or drag."),
        Idea(title: "Every gesture has a button",
             detail: "Swipes and pinches all have a click or a shortcut too, like the ‹ › arrows in the menu bar."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("⊞").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Scuba").font(.title2.bold())
                    Text("Here's what we're going for").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(ideas) { idea in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(idea.title).font(.headline)
                        Text(idea.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Why Scuba asks for permission").font(.headline)
                Text("macOS only lets an app move and resize other apps' windows with Accessibility turned on, so Scuba needs it to do anything at all. Screen Recording is optional: it lets Scuba take pictures of your windows for frosted previews and smooth animations. Those pictures stay in memory on your Mac. They're never saved, and Scuba never connects to the internet to send anything anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .bottom) {
                Text("Inspired by the work done by Dan Fessler.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Get Started") { next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// The first moves, one at a time.
private struct GettingStartedView: View {
    var back: () -> Void
    var done: () -> Void

    private struct Step: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let steps: [Step] = [
        Step(symbol: "arrow.down.right.and.arrow.up.left", title: "Dive in and out",
             detail: "\(CapsKey.label) + ↑, or pinch out on bare desktop, takes you into Scuba. Three fingers up (or \(CapsKey.label) + ↓) comes back up a level; \(CapsKey.label) + Esc goes straight to your desktop."),
        Step(symbol: "rectangle.split.2x2", title: "Snap",
             detail: "\(CapsKey.label) + ← / → snaps the window you're using to that half. Then \(CapsKey.label) + ↑ / ↓ makes it the top or bottom quarter. Or drag a window by its title bar to an edge."),
        Step(symbol: "arrow.left.and.right", title: "Resize",
             detail: "Drag the pill in the gap between two windows, or hold \(CapsKey.label) and grab any border (even under a window). A window too small to use frosts over and comes back when there's room; \(CapsKey.label) + F frosts or unfrosts one by hand."),
        Step(symbol: "rectangle.stack", title: "Tab",
             detail: "Drop a window on the middle of another and pause a moment. They share a strip of tabs."),
        Step(symbol: "square.dashed", title: "Breathing room",
             detail: "\(CapsKey.label) + B opens a little space of its own to dive into. \(CapsKey.label) + Y tiles it into the board beside its neighbour instead (again: back to its own space)."),
        Step(symbol: "eye.slash", title: "Keep things tucked inside",
             detail: "Three fingers down on a tile steps into it. \(CapsKey.label) + H hides the window under the pointer from the layer above (Shift: its whole pool), so it's only there when you zoom in. Cmd + Shift + drag a box around windows to make them a room."),
        Step(symbol: "doc.on.doc", title: "Move windows anywhere",
             detail: "\(CapsKey.label) + X cuts the window you're using (C copies it), tabs and all. Go anywhere and \(CapsKey.label) + V puts it down under the pointer."),
        Step(symbol: "bookmark", title: "Save a view",
             detail: "\(CapsKey.label) + Shift + a number saves what's on screen. \(CapsKey.label) + that number comes straight back. ‹ › in the menu bar go back and forward through where you've been."),
        Step(symbol: "lock", title: "Lock",
             detail: "\(CapsKey.label) + P locks this board's placements: nothing docks, snaps or resizes. Windows you open while it's locked float on top and stay with this board; point at one and press \(CapsKey.label) + P to punch it into the tile under it as a tab. \(CapsKey.label) + L locks the window under the pointer in place."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("⊞").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick guide").font(.title2.bold())
                    Text(CapsKey.usingCaps ? "Hold Caps Lock for these — a tap is still Caps Lock" : "Hyper is Control + Option + Command").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 18))
                            .frame(width: 26)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(i + 1). \(step.title)").font(.headline)
                            Text(step.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("Everything else is in Scuba's menu. Commands can also be run from Raycast, Alfred or Shortcuts with scuba:// links (scuba://back, scuba://view/3).")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { back() }
                Spacer()
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grant: @MainActor () -> Void
    let fix: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(granted ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("On").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Turn On…") { grant() }
                    Button("Fix") { fix() }
                        .help("Already switched on but not working? This clears old entries and asks again.")
                }
            }
        }
    }
}

@MainActor
final class SetupWindow {
    let model = SetupModel()
    private var window: NSWindow?

    /// The Getting Started page.
    func showGettingStarted() {
        model.page = .start
        show(keepPage: true)
    }

    func show(keepPage: Bool = false) {
        if !keepPage, model.page == .start { model.page = .permissions }
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: model) { [weak self] in
                self?.window?.close()
            })
            host.sizingOptions = [.preferredContentSize]   // the window fits each page
            let w = NSWindow(contentViewController: host)
            w.title = "Scuba"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        model.message = nil
        model.refresh()
        model.startWatching()
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
