import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit
import IOKit.hidsystem

/// Caps Lock as your Scuba key (pilot).
///  - Hold it: it's Hyper (Ctrl + Option + Cmd) for as long as it's down, so
///    every Hyper shortcut works, Hyper + click grabs borders, and holding it
///    on its own shows the pools.
///  - Tap it: plain Caps Lock, light and all.
///
/// macOS is told to send the Caps Lock key as F18 (hidutil; undone when Scuba
/// quits), so the system never toggles caps or lights the key by itself:
/// Scuba decides what each press means. A hold never turns the light on.
/// The keyboard watcher runs on a thread of its own, so a busy Scuba can't
/// make typing lag.
final class CapsKey: @unchecked Sendable {
    static let shared = CapsKey()
    static let defaultsKey = "capsLockHyper"

    /// Caps Lock and F18 as keyboard usages (page 7), the way hidutil names keys.
    private static let capsUsage: UInt64 = 0x7_0000_0039
    private static let f18Usage: UInt64 = 0x7_0000_006D
    private static let f18KeyCode = Int64(kVK_F18)
    /// Stamped on the modifier presses Scuba posts, so the watcher lets them by.
    private static let marker: Int64 = 0x5343_5542  // 'SCUB'
    private static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    /// Let go sooner than this without using it and it was a tap: Caps Lock.
    /// The same wait as before holding Hyper shows the pools.
    private static let tapWindow: TimeInterval = 0.35

    /// What on-screen text calls the Scuba key: "Caps Lock" while the
    /// Caps Lock setting is on, "Hyper" (Ctrl + Option + Cmd) otherwise.
    static var label: String { usingCaps ? "Caps Lock" : "Hyper" }
    static var usingCaps: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private(set) var enabled = false
    fileprivate var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// Whatever key mappings were in place before Scuba's, put back on quit.
    private var savedMappings: [(src: UInt64, dst: UInt64)] = []

    // Only touched on the watcher's thread.
    private var held = false
    private var used = false
    private var pressedAt = Date.distantPast

    // MARK: On / off

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        if on {
            // Without the watcher, a remapped Caps Lock would do nothing at all,
            // so the key is only taken over once the watcher is running.
            guard AXIsProcessTrusted(), startWatching() else {
                NSLog("Scuba: couldn't watch the keyboard for Caps Lock (needs Accessibility)")
                return
            }
            remap(true)
            enabled = true
        } else {
            enabled = false
            remap(false)
            stopWatching()
        }
    }

    /// Quitting from Terminal (pkill): give Caps Lock back, nothing else.
    func restoreForExit() {
        guard enabled else { return }
        setMappings(savedMappings)
    }

    // MARK: The watcher

    private func startWatching() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask.max,
                                          callback: capsTapCallback,
                                          userInfo: refcon) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Scuba Caps Lock"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    private func stopWatching() {
        if held {
            held = false
            postModifiers(down: false, extra: [])
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
    }

    /// Returns false to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        // Scuba's own Ctrl / Option / Cmd presses go straight through.
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return true }

        if (type == .keyDown || type == .keyUp),
           event.getIntegerValueField(.keyboardEventKeycode) == Self.f18KeyCode {
            let others = event.flags.intersection([.maskShift, .maskAlphaShift])
            if type == .keyDown {
                // Holding the key repeats it; only the first press counts.
                guard !held, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
                held = true
                used = false
                pressedAt = Date()
                postModifiers(down: true, extra: others)
            } else if held {
                held = false
                postModifiers(down: false, extra: others)
                if !used, Date().timeIntervalSince(pressedAt) < Self.tapWindow { toggleCapsLock() }
            }
            return false
        }

        guard held else { return true }
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            used = true
        default:
            break
        }
        // While it's held, everything else arrives with Hyper down.
        event.flags.formUnion(Self.hyperFlags)
        return true
    }

    /// Ctrl, Option and Cmd going down (or up) one after another, the way a
    /// real Hyper press arrives, so everything that watches for Hyper sees it.
    private func postModifiers(down: Bool, extra: CGEventFlags) {
        let keys: [(CGKeyCode, CGEventFlags)] = [
            (CGKeyCode(kVK_Control), .maskControl),
            (CGKeyCode(kVK_Option), .maskAlternate),
            (CGKeyCode(kVK_Command), .maskCommand),
        ]
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = extra
        if down {
            for (key, flag) in keys {
                flags.insert(flag)
                post(key, down: true, flags: flags, source)
            }
        } else {
            flags.formUnion(Self.hyperFlags)
            for (key, flag) in keys.reversed() {
                flags.remove(flag)
                post(key, down: false, flags: flags, source)
            }
        }
    }

    private func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, _ source: CGEventSource?) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.post(tap: .cghidEventTap)
    }

    /// A tap: flip Caps Lock (and its light) the way the key normally would.
    private func toggleCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        // 1 = kIOHIDParamConnectType
        guard IOServiceOpen(service, mach_task_self_, 1, &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var on = false
        // 1 = kIOHIDCapsLockState
        IOHIDGetModifierLockState(connect, 1, &on)
        IOHIDSetModifierLockState(connect, 1, !on)
    }

    // MARK: Key mapping (hidutil)

    private func remap(_ on: Bool) {
        if on {
            // Leave any mappings you already had alone (minus a stale one of
            // Scuba's from a crash), and put them back exactly on quit.
            savedMappings = currentMappings().filter { !($0.src == Self.capsUsage && $0.dst == Self.f18Usage) }
            let active = savedMappings.filter { $0.src != Self.capsUsage } + [(src: Self.capsUsage, dst: Self.f18Usage)]
            setMappings(active)
        } else {
            setMappings(savedMappings)
        }
    }

    private func currentMappings() -> [(src: UInt64, dst: UInt64)] {
        guard let out = hidutil(["property", "--get", "UserKeyMapping"]) else { return [] }
        var pairs: [(src: UInt64, dst: UInt64)] = []
        for block in out.components(separatedBy: "{").dropFirst() {
            func value(_ key: String) -> UInt64? {
                guard let r = block.range(of: key) else { return nil }
                let rest = block[r.upperBound...].drop { $0 == " " || $0 == "=" || $0 == ":" || $0 == "\"" }
                let token = String(rest.prefix { $0.isLetter || $0.isNumber })
                if token.lowercased().hasPrefix("0x") { return UInt64(token.dropFirst(2), radix: 16) }
                return UInt64(token)
            }
            if let s = value("HIDKeyboardModifierMappingSrc"), let d = value("HIDKeyboardModifierMappingDst") {
                pairs.append((src: s, dst: d))
            }
        }
        return pairs
    }

    private func setMappings(_ pairs: [(src: UInt64, dst: UInt64)]) {
        let items = pairs.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
        _ = hidutil(["property", "--set", "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"])
    }

    @discardableResult
    private func hidutil(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

private func capsTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<CapsKey>.fromOpaque(refcon).takeUnretainedValue()
    return keys.handle(type, event) ? Unmanaged.passUnretained(event) : nil
}
