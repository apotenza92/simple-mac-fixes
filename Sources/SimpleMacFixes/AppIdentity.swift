import AppKit

/// Public names follow the signed bundle.
enum AppIdentity {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Simple Mac Fixes"
    }

    static let developmentBundleIdentifier = "com.apotenza.SimpleMacFixes.dev"
    static let releaseBundleIdentifiers = ["com.apotenza.SimpleMacFixes", "com.apotenza.SimpleMacFixes.beta"]

    static var isDevelopmentBuild: Bool {
        Bundle.main.bundleIdentifier == developmentBundleIdentifier
    }

    /// The app icon's switch, reduced to an outline track and a solid knob.
    /// macOS supplies template tinting.
    static let menuImage = makeMenuImage(pointSize: 18)

    static func makeMenuImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: pointSize / 18)
            transform.concat()
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let track = NSBezierPath(roundedRect: NSRect(x: 1.65, y: 4.65, width: 14.7, height: 8.7),
                                     xRadius: 4.35, yRadius: 4.35)
            track.lineWidth = 1.3
            track.stroke()
            NSBezierPath(ovalIn: NSRect(x: 9.2, y: 6.2, width: 5.6, height: 5.6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
