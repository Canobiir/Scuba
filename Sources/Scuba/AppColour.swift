import AppKit

/// Each app's own colour, taken from its icon: frosted tiles and pictures
/// on the move take a little of it instead of plain grey, so you can tell
/// them apart at a glance.
@MainActor
enum AppColour {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appColours") }
        set { UserDefaults.standard.set(newValue, forKey: "appColours") }
    }

    /// How much of the colour goes into the frost (0–1).
    static let amount: CGFloat = 0.28

    /// Each icon is kept with its colour, so its identity can't be reused by
    /// another icon while it's in here.
    private static var cache: [ObjectIdentifier: (icon: NSImage, colour: NSColor?)] = [:]

    /// The icon's colour: the average of its colourful pixels (white, black
    /// and grey parts left out), a little deepened. Nil for a grey icon.
    static func of(_ icon: NSImage?) -> NSColor? {
        guard enabled, let icon else { return nil }
        let key = ObjectIdentifier(icon)
        if let c = cache[key] { return c.colour }   // (nil: a grey icon)
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let made: NSColor? = pixels.withUnsafeMutableBytes { buffer -> NSColor? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, weight: CGFloat = 0
            for i in stride(from: 0, to: side * side * 4, by: 4) {
                let a = CGFloat(buffer[i + 3]) / 255
                guard a > 0.5 else { continue }
                let pr = CGFloat(buffer[i]) / 255 / a, pg = CGFloat(buffer[i + 1]) / 255 / a, pb = CGFloat(buffer[i + 2]) / 255 / a
                let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
                let saturation = hi > 0 ? (hi - lo) / hi : 0
                guard saturation > 0.25, hi > 0.15 else { continue }
                let w = saturation * a
                r += pr * w; g += pg * w; b += pb * w; weight += w
            }
            guard weight > 2 else { return nil }
            let c = NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
            // Deepened a touch, so it reads as a tint under white text.
            return c.blended(withFraction: 0.2, of: .black)
        }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = (icon, made)
        return made
    }
}
