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
                detail: "Optional. Only used for the smooth zoom animation; without it, zooming snaps.",
                granted: model.screenRecording,
                grant: { model.grantScreenRecording() },
                fix: { model.fixScreenRecording() })

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

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: model) { [weak self] in
                self?.window?.close()
            })
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
