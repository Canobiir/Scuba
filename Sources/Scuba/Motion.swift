import QuartzCore

/// Every speed Scuba moves at, in one place.
///
/// The rule: every rearrangement moves at one speed, every fade at one speed,
/// and the camera has its own. Change a number here and everything of that
/// kind changes with it, so the app always feels like one thing.
enum Motion {
    /// Every rearrangement of windows: drop, throw, add / delete / flip a
    /// pool, close, minimize, tidy up, undo, a gap dragged and let go.
    static let layout: CFTimeInterval = 0.22

    /// App-icon tiles, portholes and toasts fading in or out.
    static let fade: CFTimeInterval = 0.14

    /// The picture over a glide or a zoom fading away to show the real
    /// windows underneath, and new pictures fading in mid-zoom.
    static let reveal: CFTimeInterval = 0.10

    /// One level of zoom. Diving is quick; coming back up is a little gentler.
    static let diveIn: CFTimeInterval = 0.30
    static let diveOut: CFTimeInterval = 0.36

    /// Trips that aren't one level: a flight up and back down, or a step
    /// sideways to the next board.
    static let travel: CFTimeInterval = 0.42

    /// A gesture let go before it got far enough, floating back.
    static let settle: CFTimeInterval = 0.16
}
