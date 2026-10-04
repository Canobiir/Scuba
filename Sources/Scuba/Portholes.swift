import AppKit
import CoreImage
import CoreMedia
import IOSurface
import ScreenCaptureKit

/// Takes the frosted pictures shown in portholes: a window on a nested board
/// that won't shrink to fit its spot is tucked away, and a frosted picture of
/// it, cropped at the pool's edge, shows in its place.
enum PortholeCamera {
    /// Frosted pictures of these windows, by window number. Windows macOS
    /// won't let us see (a hidden app's, a minimized one) are left out.
    static func pictures(of ids: [CGWindowID], scale: CGFloat) async -> [CGWindowID: CGImage] {
        guard !ids.isEmpty, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [:] }
        var out: [CGWindowID: CGImage] = [:]
        for id in ids {
            guard let w = content.windows.first(where: { $0.windowID == id }) else { continue }
            let c = SCStreamConfiguration()
            c.width = max(1, Int(w.frame.width * scale))
            c.height = max(1, Int(w.frame.height * scale))
            c.showsCursor = false
            c.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: w)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
            else { continue }
            out[id] = frost(image) ?? image
        }
        return out
    }

    /// A soft blur, like frosted glass.
    private static func frost(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: input.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: input.extent)
    }
}

/// A live picture of one window for its portholes: the whole window, shrunk
/// to fit, kept up to date as it changes (eight times a second at most, and
/// only when something in it moves).
final class LiveFeed: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let window: CGWindowID
    /// The size it's captured at, in pixels.
    let pixels: CGSize
    fileprivate let queue = DispatchQueue(label: "Scuba.LiveFeed")
    // The rest is only touched on the main thread.
    private var capture: SCStream?
    private(set) var running = false
    private(set) var starting = false
    private(set) var attempts = 0
    private var stopped = false
    /// The latest picture, and the porthole layers showing it.
    private var latest: IOSurface?
    private let layers = NSHashTable<CALayer>.weakObjects()

    init(window: CGWindowID, pixels: CGSize) {
        self.window = window
        self.pixels = pixels
        super.init()
    }

    static func configuration(_ size: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(2, Int(size.width))
        c.height = max(2, Int(size.height))
        c.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        c.queueDepth = 4
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.backgroundColor = CGColor.clear
        return c
    }

    private static func open(_ id: CGWindowID, config: SCStreamConfiguration, feed: LiveFeed) async -> SCStream? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let w = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: config, delegate: feed)
        do {
            try s.addStreamOutput(feed, type: .screen, sampleHandlerQueue: feed.queue)
            try await s.startCapture()
        } catch {
            return nil
        }
        return s
    }

    /// Starts capturing (main thread). A window macOS won't show us yet (its
    /// app is hidden, say) just doesn't start; it can be tried again.
    func start() {
        guard !starting, !running, !stopped else { return }
        starting = true
        attempts += 1
        let id = window
        let config = LiveFeed.configuration(pixels)
        Task.detached { [self] in
            let s = await LiveFeed.open(id, config: config, feed: self)
            DispatchQueue.main.async { self.started(s) }
        }
    }

    private func started(_ s: SCStream?) {
        starting = false
        guard let s else { return }
        if stopped {
            Task.detached { [self] in
                try? await s.stopCapture()
                _ = self
            }
        } else {
            capture = s
            running = true
        }
    }

    /// Stops for good (main thread).
    func stop() {
        stopped = true
        running = false
        guard let s = capture else { return }
        capture = nil
        Task.detached { [self] in
            try? await s.stopCapture()
            _ = self
        }
    }

    /// Shows the live picture in a porthole's layer (main thread).
    func attach(_ layer: CALayer) {
        layers.add(layer)
        if let latest { layer.contents = latest }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[SCStreamFrameInfo.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer,
              let ref = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        let surface = unsafeBitCast(ref, to: IOSurface.self)
        DispatchQueue.main.async { self.show(surface) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.running = false
            self.capture = nil
        }
    }

    private func show(_ surface: IOSurface) {
        guard !stopped else { return }
        latest = surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.allObjects { layer.contents = surface }
        CATransaction.commit()
    }
}

/// The live feeds for one display's portholes.
@MainActor
final class LivePortholes {
    private var feeds: [CGWindowID: LiveFeed] = [:]
    private var retryTimer: Timer?

    /// Windows with a live feed (running or starting).
    var windows: Set<CGWindowID> { Set(feeds.keys) }

    /// Keeps live feeds going for exactly these windows, each captured at
    /// about this many pixels.
    func keep(_ wanted: [CGWindowID: CGSize]) {
        for (id, feed) in feeds where wanted[id] == nil {
            feed.stop()
            feeds[id] = nil
        }
        for (id, size) in wanted {
            if let f = feeds[id] {
                // A much bigger or smaller porthole: capture at the new size.
                let dw = abs(f.pixels.width - size.width) / max(1, size.width)
                let dh = abs(f.pixels.height - size.height) / max(1, size.height)
                guard dw > 0.3 || dh > 0.3 else { continue }
                f.stop()
            }
            let f = LiveFeed(window: id, pixels: size)
            feeds[id] = f
            f.start()
        }
        if feeds.values.contains(where: { !$0.running }) { scheduleRetry() }
    }

    func attach(_ layer: CALayer, to id: CGWindowID) {
        feeds[id]?.attach(layer)
    }

    func stopAll() {
        retryTimer?.invalidate()
        retryTimer = nil
        keep([:])
    }

    /// Feeds that couldn't start (their app was hidden a moment ago, say)
    /// get a few more tries.
    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.retry() }
        }
    }

    private func retry() {
        retryTimer = nil
        var again = false
        for f in feeds.values where !f.running {
            if f.starting {
                again = true
            } else if f.attempts < 4 {
                f.start()
                again = true
            }
        }
        if again { scheduleRetry() }
    }
}
