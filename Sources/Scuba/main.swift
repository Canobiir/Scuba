import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()   // kept alive for the life of the app
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
