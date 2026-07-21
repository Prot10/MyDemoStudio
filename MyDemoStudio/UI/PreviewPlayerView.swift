import SwiftUI
import AVFoundation
import AppKit

/// Hosts an `AVPlayerLayer` so the editor preview shows the composited (polished)
/// frames — the same `DemoCompositor` output as export.
struct PreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
    }
}

/// A layer-*hosting* view whose backing layer is the `AVPlayerLayer`.
///
/// Letting AppKit own and size the player layer avoids having to keep a sublayer's frame
/// in sync by hand (a sublayer left at 0×0 shows nothing but the parent's background).
///
/// Nothing here force-casts or force-unwraps. `updateNSView` runs during layout —
/// including on every frame of a split-view divider drag — so a wrong assumption about
/// the backing layer's type or lifetime would take the whole app down mid-drag.
final class PlayerLayerView: NSView {

    /// Held separately so the player survives being set before AppKit has created the
    /// backing layer, and can be re-applied if that layer is ever recreated.
    private var pendingPlayer: AVPlayer?

    var player: AVPlayer? {
        get { playerLayer?.player ?? pendingPlayer }
        set {
            pendingPlayer = newValue
            applyPlayer()
        }
    }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        applyPlayer()
    }

    required init?(coder: NSCoder) { return nil }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPlayer()
    }

    /// Attaches the player once a backing layer of the expected type exists.
    private func applyPlayer() {
        guard let playerLayer, playerLayer.player !== pendingPlayer else { return }
        playerLayer.player = pendingPlayer
    }
}
