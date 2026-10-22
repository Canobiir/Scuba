import AppKit
import SwiftUI

/// A small coach for your first swim. One card in the bottom corner, one
/// step at a time, and each step ticks itself off when you actually do the
/// thing: no Next button, no slideshow. A soft glow sits on whatever the step
/// is about. Two steps wait for their moment instead of a turn: the bubble
/// (the first time one appears) and frosting (the first time a window frosts
/// by itself). "Later" hides it until you next dive in; "Skip tour" ends it.
@MainActor
final class Coach {
    static let shared = Coach()

    enum Step: String { case dive, nest, tab, room, deeper, bubble, frost, menu }

    enum Event {
        case dived
        case docked
        case tabbed
        /// Breathing room opened (`deeper`: inside a breathing room), and where it is.
        case roomOpened(CGRect?, deeper: Bool)
        case bubbleSeen(CGRect)
        case frostSeen(CGRect)
        case frostToggled
        case menuOpened
    }

    /// The steps that take their turn, in order.
    private let ordered: [Step] = [.dive, .nest, .tab, .room, .deeper, .menu]
    private let total = 8

    /// Set by the app: whether you're inside your boards, the screen to use,
    /// and where the ⊞ sits in the menu bar.
    var isInside: () -> Bool = { false }
    var screen: () -> NSScreen? = { NSScreen.main }
    var menuBarRect: () -> CGRect? = { nil }

    private let card = CoachCard()
    private let glow = CoachGlow()
    /// Bubble and frosting, seen and waiting for their turn (they jump the queue).
    private var waiting: [Step] = []
    private var roomRect: CGRect?
    private var bubbleRect: CGRect?
    private var frostRect: CGRect?
    private var later = false
    private var showing: Step?
    private var celebrating = false

    private var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "coach.done") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "coach.done") }
    }
    private var off: Bool {
        get { UserDefaults.standard.bool(forKey: "coach.off") }
        set { UserDefaults.standard.set(newValue, forKey: "coach.off") }
    }
    private func isDone(_ s: Step) -> Bool { done.contains(s.rawValue) }

    /// Shows the coach if there's still something to learn.
    func start() { refresh() }

    /// From the menu: the whole tour again.
    func restart() {
        done = []
        off = false
        later = false
        waiting = []
        refresh()
    }

    func note(_ e: Event) {
        guard !off else { return }
        switch e {
        case .dived:
            later = false
            complete(.dive)
        case .docked:
            complete(.nest)
        case .tabbed:
            complete(.tab)
        case .roomOpened(let r, let deeper):
            roomRect = r
            if deeper && isDone(.room) { complete(.deeper) } else { complete(.room) }
        case .bubbleSeen(let r):
            bubbleRect = r
            if !isDone(.bubble), !waiting.contains(.bubble) { waiting.append(.bubble) }
        case .frostSeen(let r):
            frostRect = r
            if !isDone(.frost), !waiting.contains(.frost) { waiting.append(.frost) }
        case .frostToggled:
            complete(.frost)
        case .menuOpened:
            // Only once it's the menu's turn (opening it early isn't the lesson).
            if showing == .menu { complete(.menu) }
        }
        refresh()
    }

    private func complete(_ s: Step) {
        guard !isDone(s) else { return }
        done.insert(s.rawValue)
        waiting.removeAll { $0 == s }
        // The step on the card: a moment of ✓ before the next one.
        guard showing == s, !celebrating else { return }
        celebrating = true
        glow.hide()
        card.show(caption: progress, title: "✓  Nice.", detail: "", buttons: false,
                  on: screen(), handlers: handlers)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.celebrating = false
            self?.refresh()
        }
    }

    private var progress: String { "Getting started  ·  \(min(done.count + 1, total)) of \(total)" }

    private var handlers: CoachCard.Handlers {
        CoachCard.Handlers(
            gotIt: { [weak self] in
                guard let self, let s = self.showing else { return }
                self.complete(s)
                self.refresh()
            },
            later: { [weak self] in
                self?.later = true
                self?.refresh()
            },
            skip: { [weak self] in
                self?.off = true
                self?.refresh()
                Toast.show("Tour skipped  ·  ⊞ menu › Show me around brings it back", seconds: 1.6)
            })
    }

    /// Shows the step that's up, or nothing.
    func refresh() {
        guard !celebrating else { return }
        let next = waiting.first { !isDone($0) } ?? ordered.first { !isDone($0) }
        guard !off, AXIsProcessTrusted(), let next else {
            if next == nil, !off, showing != nil { off = true }   // all done
            hideAll()
            return
        }
        // Already inside: diving in is done.
        if next == .dive, isInside() {
            done.insert(Step.dive.rawValue)
            refresh()
            return
        }
        // Later: until you next dive in. Every step but the first happens inside.
        if later || (next != .dive && !isInside()) {
            hideAll()
            return
        }
        let (title, detail) = Self.text(next)
        let gotIt = next == .bubble || next == .frost || next == .menu
        // Only redrawn when the step changes (layouts tell the coach things all the time).
        if showing != next || !card.isVisible {
            card.show(caption: progress, title: title, detail: detail, buttons: true, gotIt: gotIt,
                      on: screen(), handlers: handlers)
        }
        showing = next
        switch next {
        case .deeper: if let r = roomRect { glow.show(r, radius: 14) } else { glow.hide() }
        case .bubble: if let r = bubbleRect { glow.show(r, radius: r.height / 2 + 6) } else { glow.hide() }
        case .frost: if let r = frostRect { glow.show(r, radius: 14) } else { glow.hide() }
        case .menu: if let r = menuBarRect() { glow.show(r, radius: 8, aboveMenuBar: true) } else { glow.hide() }
        default: glow.hide()
        }
    }

    private func hideAll() {
        showing = nil
        card.hide()
        glow.hide()
    }

    private static func text(_ s: Step) -> (String, String) {
        switch s {
        case .dive:
            return ("Dive in", "Press \(CapsKey.label) + ↑\(CapsKey.usingCaps ? "" : " (Control + Option + Command + ↑)"), or pinch out on empty desktop. Your windows line up on Main.")
        case .nest:
            return ("Nest a window", "Drag a window by its title bar to the edge of another window, or of the screen. The windows around it make room. (\(CapsKey.label) + ← / → snaps one too.)")
        case .tab:
            return ("Tab two windows", "Drop a window on the middle of another and pause a moment. They share a strip of tabs.")
        case .room:
            return ("Make breathing room", "Press \(CapsKey.label) + B. An empty corner opens near the pointer: a little space of its own, ready to dive into.")
        case .deeper:
            return ("Go deeper", "Swipe down with three fingers on that breathing room to dive into it, then press \(CapsKey.label) + B again: a room inside a room.")
        case .bubble:
            return ("There's more in here", "That small dark bubble means a tile holds windows you can't see from here. Click it, or dive in, to find them.")
        case .frost:
            return ("Why that window frosted", "Some apps won't shrink as far as you'd like, so when a spot is too tight Scuba frosts the window instead of letting it spill over. You have the last word: \(CapsKey.label) + F unfrosts it and the tiles around it make room. \(CapsKey.label) + F on any window frosts it by hand when it's fighting you.")
        case .menu:
            return ("Everything else lives up here", "The ⊞ in the menu bar has the rest, and the Quick guide whenever you want a refresher. That's the basics. Enjoy the swim.")
        }
    }
}

// MARK: - The card

@MainActor
final class CoachCard {
    struct Handlers {
        let gotIt: () -> Void
        let later: () -> Void
        let skip: () -> Void
    }

    private var window: NSPanel?
    var isVisible: Bool { window != nil }

    func show(caption: String, title: String, detail: String, buttons: Bool, gotIt: Bool = false,
              on screen: NSScreen?, handlers: Handlers) {
        guard let screen else { return }
        let view = CoachView(caption: caption, title: title, detail: detail, buttons: buttons, gotIt: gotIt,
                             handlers: handlers)
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        let vf = screen.visibleFrame
        let frame = CGRect(x: vf.maxX - size.width - 18, y: vf.minY + 18, width: size.width, height: size.height)
        let w: NSPanel
        let fresh = window == nil
        if let existing = window {
            w = existing
        } else {
            w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isReleasedWhenClosed = false
            w.level = .statusBar
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window = w
        }
        w.contentView = host
        w.setFrame(frame, display: true)
        if fresh {
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fade * 2
                w.animator().alphaValue = 1
            }
        } else {
            w.orderFrontRegardless()
        }
    }

    func hide() {
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fade * 2
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }
}

/// Buttons answer the first click, without the app having to come forward.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CoachView: View {
    let caption: String
    let title: String
    let detail: String
    let buttons: Bool
    let gotIt: Bool
    let handlers: CoachCard.Handlers

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if buttons {
                HStack(spacing: 14) {
                    Button("Skip tour") { handlers.skip() }
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    Button("Later") { handlers.later() }
                        .foregroundStyle(Color.white.opacity(0.6))
                    if gotIt {
                        Button("Got it") { handlers.gotIt() }
                            .foregroundStyle(Color.white)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.08).opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - The glow

/// A soft ring around the thing a step is about: it pulses a few times, then
/// stays faint. Clicks go straight through it.
@MainActor
final class CoachGlow {
    private var window: NSPanel?
    private var shown: CGRect?

    func show(_ r: CGRect, radius: CGFloat, aboveMenuBar: Bool = false) {
        if let shown, shown == r, window != nil { return }
        hide()
        shown = r
        let frame = r.insetBy(dx: -10, dy: -10)
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = aboveMenuBar ? .popUpMenu : .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = NSView(frame: CGRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        let ring = CAShapeLayer()
        let box = v.bounds.insetBy(dx: 6, dy: 6)
        let rad = min(radius, min(box.width, box.height) / 2)
        ring.path = CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
        ring.lineWidth = 2
        ring.shadowColor = NSColor.white.cgColor
        ring.shadowRadius = 6
        ring.shadowOpacity = 0.8
        ring.shadowOffset = .zero
        ring.opacity = 0.35
        v.layer?.addSublayer(ring)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 1
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = 3
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(pulse, forKey: "pulse")
        w.contentView = v
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        shown = nil
    }
}
