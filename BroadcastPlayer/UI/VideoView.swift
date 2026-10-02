import AppKit
import Metal
import QuartzCore
import SwiftUI

struct VideoView: NSViewRepresentable {
    let renderer: MetalRenderer

    func makeNSView(context: Context) -> PlaybackMetalView {
        PlaybackMetalView(renderer: renderer)
    }

    func updateNSView(_ view: PlaybackMetalView, context: Context) {}

    static func dismantleNSView(_ view: PlaybackMetalView, coordinator: ()) {
        view.stopDisplayLink()
    }
}

final class PlaybackMetalView: NSView, CAMetalDisplayLinkDelegate {
    private let renderer: MetalRenderer
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?
    private var observers: [NSObjectProtocol] = []

    init(renderer: MetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        guard let window else { return }
        updateDrawableSize()
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 1
        displayLink = link
        updateDisplayPolicy()
        link.add(to: .main, forMode: .common)
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDisplayPolicy() }
            })
        }
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        updateDisplayPolicy()
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func updateDrawableSize() {
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        renderer.drawableSizeDidChange()
    }

    private func updateDisplayPolicy() {
        guard let window, let displayLink else { return }
        let rate = Float(min(60, window.screen?.maximumFramesPerSecond ?? 60))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        displayLink.isPaused = !window.occlusionState.contains(.visible)
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // A resize can occur after the display link acquires this drawable.
        let size = CGSize(width: update.drawable.texture.width, height: update.drawable.texture.height)
        renderer.draw(drawable: update.drawable, drawableSize: size) { [metalLayer] colorSpace in
                if metalLayer.colorspace != colorSpace { metalLayer.colorspace = colorSpace }
            }
    }
}
