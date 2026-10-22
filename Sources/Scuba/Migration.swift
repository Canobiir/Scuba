import Foundation

/// Scuba used to be called Fractal Windows. The first time Scuba runs on a
/// Mac that had it, it brings the boards and settings over, so nothing is
/// lost in the rename. On any other Mac it does nothing.
enum Migration {
    private static let oldBundleID = "com.michaelmartinez.fractalwindows"
    private static let doneKey = "migratedFromFractalWindows"

    static func fromFractalWindows() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        // Boards: copy the old files across, never over newer ones.
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("FractalWindows", isDirectory: true)
        let new = AppState.folder
        if let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for file in files {
                let dest = new.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: file, to: dest) }
            }
        }

        // Settings: anything not already set under the new name.
        guard let id = Bundle.main.bundleIdentifier, id != oldBundleID,
              let previous = defaults.persistentDomain(forName: oldBundleID) else { return }
        let mine = defaults.persistentDomain(forName: id) ?? [:]
        let skip: Set<String> = ["setup.reopen", doneKey]
        for (key, value) in previous where mine[key] == nil && !skip.contains(key) {
            defaults.set(value, forKey: key)
        }
    }

    /// Clean gaps (this build): the outlines around windows and pools go,
    /// once, in favour of a handle in each gap. Either can be turned back on.
    static func cleanGaps() {
        let defaults = UserDefaults.standard
        let key = "migratedCleanGaps"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        defaults.set(false, forKey: "windowOutlines")
        defaults.set(false, forKey: "poolBounds")
    }

    /// Zooming out from Main goes to your desktop (this build): no stop at
    /// Main and no Overview on the way. The Overview is still Hyper + O.
    static func mainToDesktop() {
        let defaults = UserDefaults.standard
        let key = "migratedMainToDesktop"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        defaults.set(false, forKey: "stopAtMain")
        defaults.set(false, forKey: "overviewZoom")
    }
}
