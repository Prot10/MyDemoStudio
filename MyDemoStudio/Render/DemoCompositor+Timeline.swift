import Foundation
import AVFoundation
import Metal
import MetalKit
import CoreVideo
import CoreMedia
import CoreGraphics
import CoreText
import AppKit
import simd

/// The multi-clip half of the compositor: renders one `TimelineInstruction` per frame.
///
/// The single-clip path (`DemoCompositor.render(source:…)`) is untouched — this adds the
/// timeline cases on top: still-image clips, Ken Burns, text-only segments, empty gaps,
/// per-clip fades, and overlay clips that only exist for part of the video.
extension DemoCompositor {

    func renderTimeline(request: AVAsynchronousVideoCompositionRequest,
                        instruction: TimelineInstruction,
                        into output: CVPixelBuffer,
                        time: Double) {
        guard let outputTexture = makeTexture(from: output) else { return }
        let s = instruction.settings
        let outW = Double(s.outputWidth), outH = Double(s.outputHeight)

        // --- Main content: a video frame, a still image, or nothing at all. ---
        var mainTexture: MTLTexture?
        var content = CGRect(x: 0, y: 0, width: outW, height: outH)
        var focusU = 0.5, focusV = 0.5, zoomScale = 1.0
        var cursorVec = SIMD4<Float>(0, 0, 0, 0)
        var cursorMode: Float = 0
        var cursorTexture: MTLTexture?
        var captionTexture: MTLTexture?
        var captionVec = SIMD4<Float>(0, 0, 0, 0)
        var fade = 1.0

        if let main = instruction.main {
            if let trackID = main.trackID, let pixelBuffer = request.sourceFrame(byTrackID: trackID) {
                mainTexture = makeTexture(from: pixelBuffer)
            } else if let imageURL = main.imageURL {
                mainTexture = imageTexture(at: imageURL)
            }

            if mainTexture != nil {
                let sourceW = Double(main.sourceWidth), sourceH = Double(main.sourceHeight)
                content = RenderLayout.contentRect(settings: s, masterWidth: main.sourceWidth, masterHeight: main.sourceHeight)
                let local = main.sourceTime(at: time)
                fade = main.fadeLevel(at: time)

                // Auto-zoom (recordings) and Ken Burns (stills) feed the same look-at
                // uniform: a source-uv focus that lands at the centre of the frame.
                if let zoomAt = main.zoomAt {
                    let zoom = zoomAt(local)
                    zoomScale = max(zoom.scale, 1.0)
                    focusU = zoom.focus.x / sourceW
                    focusV = zoom.focus.y / sourceH
                } else if let ken = main.kenBurns {
                    let p = smoothstep(main.progress(at: time))
                    zoomScale = max(ken.startScale + (ken.endScale - ken.startScale) * p, 1.0)
                    focusU = ken.startX + (ken.endX - ken.startX) * p
                    focusV = ken.startY + (ken.endY - ken.startY) * p
                }
                // Keep the 1/z window inside the source.
                let halfU = 0.5 / zoomScale
                focusU = min(max(focusU, halfU), 1 - halfU)
                focusV = min(max(focusV, halfU), 1 - halfU)

                if let smoother = main.smoother, let cursorPixel = smoother.position(at: local) {
                    let built = cursorUniform(settings: s, smoother: smoother, at: local,
                                              cursorPixel: cursorPixel, content: content,
                                              sourceW: sourceW, sourceH: sourceH,
                                              focusU: focusU, focusV: focusV, zoomScale: zoomScale)
                    cursorVec = built.vector
                    cursorMode = built.mode
                    cursorTexture = built.texture
                }

                if s.captionsEnabled, let segment = main.captions?.active(at: local), !segment.text.isEmpty {
                    let fontSize = CGFloat(max(outH * 0.036, 14))
                    if let cap = makeCaptionTexture(text: segment.text, maxWidth: Int(outW * 0.82), fontSize: fontSize) {
                        captionTexture = cap.texture
                        let cw = Double(cap.width), ch = Double(cap.height)
                        captionVec = SIMD4<Float>(Float((outW - cw) / 2), Float(outH - outH * 0.07 - ch), Float(cw), Float(ch))
                    }
                }
            }
        }

        // --- Video overlay (webcam bubble / picture-in-picture) ---
        // One overlay is drawn per frame; when several are active the topmost track wins.
        var cameraVec = SIMD4<Float>(0, 0, 0, 0)
        var cameraParams = SIMD4<Float>(1.777, 1, 0, 0)
        var cameraTexture: MTLTexture?
        for overlay in instruction.overlays {
            guard let pixelBuffer = request.sourceFrame(byTrackID: overlay.trackID),
                  let texture = makeTexture(from: pixelBuffer) else { continue }
            let minSide = min(outW, outH)
            let radius = max(overlay.transform.scale, 0.02) * minSide / 2
            let opacity = overlay.transform.opacity * overlay.fadeLevel(at: time)
            cameraVec = SIMD4<Float>(
                Float(overlay.transform.centerX * outW),
                Float(overlay.transform.centerY * outH),
                Float(radius), Float(opacity)
            )
            let w = Double(CVPixelBufferGetWidth(pixelBuffer)), h = Double(CVPixelBufferGetHeight(pixelBuffer))
            cameraParams = SIMD4<Float>(Float(h > 0 ? w / h : 1.777), overlay.transform.circular ? 1 : 0, 0, 0)
            cameraTexture = texture
            break
        }

        // --- Text layer --- one canvas-sized premultiplied texture for all active cards.
        // They share a single alpha, so overlapping cards with different fades fade
        // together; in practice cards don't overlap.
        var overlayTexture: MTLTexture?
        var overlayAlpha: Float = 0
        let visibleTexts = instruction.texts.filter { $0.fadeLevel(at: time) > 0.004 && !$0.text.string.isEmpty }
        if !visibleTexts.isEmpty {
            overlayTexture = textLayer(for: visibleTexts, width: s.outputWidth, height: s.outputHeight)
            overlayAlpha = overlayTexture == nil ? 0 : Float(visibleTexts[0].fadeLevel(at: time))
        }

        let bg = s.background
        let uniforms = GPUUniforms(
            outputSize_corner: SIMD4<Float>(Float(s.outputWidth), Float(s.outputHeight), Float(s.cornerRadiusPixels), 0),
            contentRect: SIMD4<Float>(Float(content.minX), Float(content.minY), Float(content.width), Float(content.height)),
            zoom: SIMD4<Float>(Float(focusU), Float(focusV), Float(max(zoomScale, 0.0001)), 0),
            bgColor1: SIMD4<Float>(Float(bg.color1.r), Float(bg.color1.g), Float(bg.color1.b), Float(bg.color1.a)),
            bgColor2: SIMD4<Float>(Float(bg.color2.r), Float(bg.color2.g), Float(bg.color2.b), Float(bg.color2.a)),
            bgParams: SIMD4<Float>(Float(bg.angleDegrees * .pi / 180.0), Float(bg.kind.rawValue), cursorMode, Float(bg.wallpaperIndex)),
            shadow: SIMD4<Float>(Float(s.shadowRadiusPixels), Float(s.shadowOpacity), 0, Float(bg.blur)),
            cursor: cursorVec,
            cursorColor: SIMD4<Float>(1, 1, 1, 1),
            camera: cameraVec,
            cameraParams: cameraParams,
            caption: captionVec,
            extra: SIMD4<Float>(Float(fade), overlayAlpha, mainTexture == nil ? 0 : 1, 0)
        )

        // Every slot must be bound; with no main content the output texture stands in.
        let source = mainTexture ?? outputTexture
        draw(uniforms: uniforms, source: source, cursor: cursorTexture, camera: cameraTexture,
             caption: captionTexture, overlay: overlayTexture, into: outputTexture)
    }

    private func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Places the cursor sprite through the same look-at transform as the picture, so it
    /// stays glued to the pixel it points at while the camera zooms.
    private func cursorUniform(settings s: RenderSettings, smoother: CursorSmoother, at local: Double,
                               cursorPixel: CGPoint, content: CGRect, sourceW: Double, sourceH: Double,
                               focusU: Double, focusV: Double, zoomScale: Double)
    -> (vector: SIMD4<Float>, mode: Float, texture: MTLTexture?) {
        let contentNormX = 0.5 + (cursorPixel.x / sourceW - focusU) * zoomScale
        let contentNormY = 0.5 + (cursorPixel.y / sourceH - focusV) * zoomScale
        let zoomed = CGPoint(x: content.minX + content.width * contentNormX,
                             y: content.minY + content.height * contentNormY)
        let sizeScale = Float(s.cursorScale) * Float(s.minSide / 1080.0)

        let sprite: CursorSprite?
        switch s.cursorStyle {
        case .arrow:       sprite = arrowSprite
        case .hand:        sprite = handSprite
        case .handOnClick: sprite = smoother.isPressed(at: local) ? handSprite : arrowSprite
        }

        if s.showDebugCursorDot || sprite == nil {
            let radius = Float(9) * sizeScale
            return (SIMD4<Float>(Float(zoomed.x), Float(zoomed.y), max(radius, 4), 1), 1, nil)
        }
        guard let sprite else { return (SIMD4<Float>(0, 0, 0, 0), 0, nil) }
        let height = Float(26) * sizeScale
        let width = height * sprite.aspect
        let originX = Float(zoomed.x) - sprite.hotspot.x * width
        let originY = Float(zoomed.y) - sprite.hotspot.y * height
        return (SIMD4<Float>(originX, originY, width, height), 2, sprite.texture)
    }

    /// Loads (and caches) a still image as a texture for image clips.
    private func imageTexture(at url: URL) -> MTLTexture? {
        if let cached = imageCache[url.path] { return cached }
        guard let device else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft
        ]
        guard let texture = try? loader.newTexture(URL: url, options: options) else { return nil }
        imageCache[url.path] = texture
        return texture
    }

    /// Rasterizes every active text card into one canvas-sized premultiplied layer.
    /// Cached by content (not by fade), so playback doesn't re-rasterize each frame.
    private func textLayer(for texts: [TextSegment], width: Int, height: Int) -> MTLTexture? {
        let key = texts.map(\.cacheKey).joined(separator: "␟") + "|\(width)x\(height)"
        if let cached = overlayCache[key] { return cached }
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textMatrix = .identity

        for segment in texts {
            let overlay = segment.text
            let fontSize = max(CGFloat(overlay.fontSize) * CGFloat(height), 10)
            let fontName = overlay.bold ? "HelveticaNeue-Bold" : "HelveticaNeue"
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(red: overlay.color.r, green: overlay.color.g,
                                          blue: overlay.color.b, alpha: overlay.color.a),
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: overlay.string, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let maxWidth = CGFloat(width) * 0.86
            var fitRange = CFRange()
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: maxWidth, height: .greatestFiniteMagnitude), &fitRange)
            let tw = min(ceil(suggested.width), maxWidth)
            let th = ceil(suggested.height)
            // The layer's position is given in top-left-origin canvas coordinates (matching
            // the CoreVideo textures), but Core Graphics draws bottom-up — so y flips here.
            let originX = CGFloat(overlay.x) * CGFloat(width) - tw / 2
            let originY = CGFloat(1 - overlay.y) * CGFloat(height) - th / 2

            if overlay.pill {
                let pad = th * 0.45
                let rect = CGRect(x: originX - pad, y: originY - pad * 0.55,
                                  width: tw + pad * 2, height: th + pad * 1.1)
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height * 0.32,
                                   cornerHeight: rect.height * 0.32, transform: nil))
                ctx.fillPath()
            }

            let path = CGPath(rect: CGRect(x: originX, y: originY, width: tw, height: th), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device?.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: &pixels, bytesPerRow: bytesPerRow)

        // Canvas-sized layers are ~8 MB each; keep the cache small.
        if overlayCache.count > 8 { overlayCache.removeAll() }
        overlayCache[key] = texture
        return texture
    }
}
