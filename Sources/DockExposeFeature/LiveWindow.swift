import AppKit
import SwiftUI

/// The card under the pointer plays live, and so does its window when it is shown in place: a
/// video that plays in the window plays there too. Every other card keeps the picture it had
/// when the preview opened, so a card costs nothing until the pointer is on it.
///
/// Frames come from the same window-server capture as the still pictures, one after the other
/// on their queue. A capture waits for the window server's next frame (about 16.7 ms at any
/// size), so frames come evenly at 60 a second; two at the same time are no faster. Only the
/// window shown in place gets full resolution. A frame that shows the same as the last one is
/// not sent on. Measured with a window that animates: about 20 % CPU in `replayd` and 20–30 %
/// more in the window server; 30 frames a second saved only about 5 % there.
///
/// ScreenCaptureKit streams were tried and removed: while one runs, macOS shows its screen
/// recording icon in the menu bar and puts a purple badge over the streamed window's own
/// buttons, and a stream for every card made the window server drop frames.
@MainActor
final class LiveWindow {
    /// At most 60 frames a second: the most that video shows.
    nonisolated static let shortestGap: TimeInterval = 1.0 / 60 - 0.001
    /// Time to cross the gap between cards without the live card stopping.
    static let leaveGrace: TimeInterval = 0.15

    /// Each full-resolution frame, for the window shown in place.
    var frame: (CGWindowID, CGImage) -> Void = { _, _ in }

    /// The window shown in place, if any. Only it needs full resolution: the card shows a
    /// frame about 5 times smaller, and a quarter of the pixels is less for the window
    /// server to draw. A capture takes the same time at either resolution.
    var shownInPlace: CGWindowID? {
        didSet { updateResolution() }
    }

    /// The card the pointer is on.
    var hovered: CGWindowID? {
        didSet {
            guard hovered != oldValue else { return }
            if hovered != nil { return retarget() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveGrace) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hovered == nil else { return }
                    self.retarget()
                }
            }
        }
    }

    private let model: DockPreviewModel
    private let thumbnails: WindowThumbnails
    private var isRunning = false
    private var target: CGWindowID?
    /// Goes up at each change of target, so a capture for an old one is dropped.
    private var generation = 0
    private var feed: LiveFeed?
    private var lastFrame: CGImage?
    private let loop = CaptureLoop()

    init(model: DockPreviewModel, thumbnails: WindowThumbnails) {
        self.model = model
        self.thumbnails = thumbnails
    }

    /// Runs while the preview shows. Call again when its windows change.
    func run() {
        isRunning = true
        retarget()
    }

    func stop() {
        isRunning = false
        hovered = nil
        retarget()
    }

    private func retarget() {
        let id = Self.choose(hovered: hovered, windows: isRunning ? model.windows : [])
        guard id != target else { return }
        finish()
        guard let id else { return }
        target = id
        updateResolution()
        capture(id, generation: generation)
    }

    private func updateResolution() {
        loop.full = target != nil && shownInPlace == target
    }

    /// The window to play: the one under the pointer, if it is on this desktop. A window
    /// elsewhere shows its last picture.
    nonisolated static func choose(hovered: CGWindowID?, windows: [DockWindow]) -> CGWindowID? {
        guard let hovered, windows.contains(where: { $0.id == hovered && $0.place == .here }) else { return nil }
        return hovered
    }

    /// The card keeps the last frame as its still picture, and the next preview opens with it.
    private func finish() {
        guard let id = target else { return }
        target = nil
        generation += 1
        loop.start(generation)
        let frame = lastFrame
        let feed = feed
        lastFrame = nil
        self.feed = nil
        guard let frame else { return }
        let visit = model.visit
        WindowThumbnails.captureQueue.async { [weak self] in
            let still = ImageHolder(image: WindowThumbnails.scaled(frame, toFit: WindowThumbnails.maximumPixels))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let image = still.image {
                        self.thumbnails.remember(image, for: id)
                        if self.model.visit == visit { self.model.pictures[id] = image }
                    }
                    // Only now, so the card never shows an older picture in between; and also
                    // when another preview opened meanwhile, so no old frame stays behind.
                    if let feed, self.model.live[id] === feed { self.model.live[id] = nil }
                }
            }
        }
    }

    /// Captures one frame after the other on the capture queue, with no stop on the main
    /// thread in between. A capture waits for the window server's next frame, so the frames
    /// come at the screen's own rate, evenly: through the main thread, some missed a frame.
    private func capture(_ id: CGWindowID, generation: Int) {
        let loop = loop
        loop.start(generation)
        let deliver: @Sendable () -> Void = {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let (image, full) = loop.take(generation), let self, self.generation == generation else { return }
                    self.show(image, of: id, full: full)
                }
            }
        }
        @Sendable func step() {
            guard loop.isCurrent(generation) else { return }
            let start = DispatchTime.now()
            let full = loop.full
            if let image = WindowSpacePrivateApis.captureWindow(id, bestResolution: full),
               !loop.isUnchanged(image), loop.offer(image, full: full) {
                deliver()
            }
            // On a Mac where a capture does not wait for a frame, at most 60 a second.
            WindowThumbnails.captureQueue.asyncAfter(deadline: start + Self.shortestGap) { step() }
        }
        WindowThumbnails.captureQueue.async { step() }
    }

    /// The live window's latest frame, so its window shows in place without a capture of its own.
    func latestFrame(of id: CGWindowID) -> CGImage? {
        target == id ? lastFrame : nil
    }

    private func show(_ image: CGImage, of id: CGWindowID, full: Bool) {
        lastFrame = image
        let feed = feed ?? LiveFeed(aspectRatio: CGFloat(image.width) / CGFloat(max(image.height, 1)))
        self.feed = feed
        feed.show(image)
        if model.live[id] !== feed { model.live[id] = feed }
        if full { frame(id, image) }
    }
}

/// What the capture loop shares with the main thread: which round is current, the
/// resolution, and the newest frame not yet shown. The main thread takes only the newest,
/// so frames never pile up behind it.
private final class CaptureLoop: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var isFull = false
    private var waiting: (image: CGImage, full: Bool)?
    /// The last frame offered, and a count that moves the rows compared. Used on the capture
    /// queue only.
    private var last: (image: CGImage, pixels: CFData)?
    private var round = 0

    var full: Bool {
        get { lock.withLock { isFull } }
        set { lock.withLock { isFull = newValue } }
    }

    func start(_ generation: Int) {
        lock.withLock {
            self.generation = generation
            waiting = nil
        }
        WindowThumbnails.captureQueue.async { self.last = nil }
    }

    /// Rows compared in each frame: one in this many.
    static let rowStride = 8

    /// Whether the frame shows the same as the last one offered. A frame that is the same is
    /// not sent on: drawing it again costs the window server as much as a new one. Comparing
    /// every row of a full-resolution frame takes 2 ms, so each frame compares one row in 8,
    /// starting one row further on each time. A video changes many rows and is found at once;
    /// a change in one thin row, such as a text cursor, is found within 8 frames.
    func isUnchanged(_ image: CGImage) -> Bool {
        guard let pixels = image.dataProvider?.data else { return false }
        defer { round += 1 }
        guard let last, last.image.width == image.width, last.image.height == image.height,
              last.image.bytesPerRow == image.bytesPerRow, CFDataGetLength(last.pixels) == CFDataGetLength(pixels),
              let old = CFDataGetBytePtr(last.pixels), let new = CFDataGetBytePtr(pixels)
        else {
            self.last = (image, pixels)
            return false
        }
        let rowBytes = image.bytesPerRow
        var row = round % Self.rowStride
        while row < image.height {
            if memcmp(old + row * rowBytes, new + row * rowBytes, rowBytes) != 0 {
                self.last = (image, pixels)
                return false
            }
            row += Self.rowStride
        }
        return true
    }

    func isCurrent(_ generation: Int) -> Bool { lock.withLock { self.generation == generation } }

    /// Keeps the frame. True when the main thread must be asked to take it.
    func offer(_ image: CGImage, full: Bool) -> Bool {
        lock.withLock {
            let asked = waiting != nil
            waiting = (image, full)
            return !asked
        }
    }

    func take(_ generation: Int) -> (CGImage, Bool)? {
        lock.withLock {
            defer { waiting = nil }
            guard self.generation == generation, let waiting else { return nil }
            return (waiting.image, waiting.full)
        }
    }
}

/// The latest frame of one window, and the view that draws it.
@MainActor
final class LiveFeed {
    /// Width over height of the frames.
    let aspectRatio: CGFloat
    private var image: CGImage?
    private weak var view: LiveFeedView?

    init(aspectRatio: CGFloat) {
        self.aspectRatio = aspectRatio
    }

    func show(_ image: CGImage) {
        self.image = image
        view?.show(image)
    }

    func attach(_ view: LiveFeedView) {
        guard self.view !== view else { return }
        self.view = view
        view.show(image)
    }
}

/// Draws a feed's frames as its layer's contents, scaled by Core Animation, so a frame
/// costs no drawing. Clicks and hovers go to the card under it.
final class LiveFeedView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
        // A card shows a full-resolution frame about 6 times smaller. Mipmaps keep small
        // text from shimmering, where plain linear scaling skips pixels.
        layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

struct LivePicture: NSViewRepresentable {
    let feed: LiveFeed

    func makeNSView(context: Context) -> LiveFeedView {
        let view = LiveFeedView()
        feed.attach(view)
        return view
    }

    func updateNSView(_ view: LiveFeedView, context: Context) {
        feed.attach(view)
    }
}

/// Carries a picture between the capture queue and the main thread.
struct ImageHolder: @unchecked Sendable {
    let image: CGImage?
}
