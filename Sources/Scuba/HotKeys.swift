import Carbon.HIToolbox
import Foundation

/// Global keyboard shortcuts through the Carbon hot key API, which works
/// system-wide without extra permissions.
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var nextId: UInt32 = 1
    private static var installed = false

    static let hyper = UInt32(cmdKey | optionKey | controlKey)
    static let hyperShift = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// Key codes for the number row 1-9.
    static let digits: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKey)
            if status == noErr {
                let id = hotKey.id
                DispatchQueue.main.async { HotKeys.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func register(_ keyCode: Int, _ modifiers: UInt32, _ handler: @escaping () -> Void) {
        install()
        let id = nextId
        nextId += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4652_4354), id: id)  // 'FRCT'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            handlers[id] = handler
            refs.append(ref)
        } else {
            NSLog("Scuba: couldn't register hot key \(keyCode) (status \(status))")
        }
    }
}
