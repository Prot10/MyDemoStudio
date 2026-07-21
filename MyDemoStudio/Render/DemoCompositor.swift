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

/// The zoom applied at a given instant: a focus point in master-pixel space and a
/// scale (1 = no zoom). Produced by `ZoomPlanner` in M3; nil means identity.
struct ZoomState: Sendable {
    var focus: CGPoint
    var scale: Double
    static let identity = ZoomState(focus: .zero, scale: 1)
}

/// Uniform buffer shared with `Shaders.metal`. Field order and float4 packing must
/// match `GPUUniforms` there exactly.
struct GPUUniforms {
    var outputSize_corner: SIMD4<Float>
    var contentRect: SIMD4<Float>
    var zoom: SIMD4<Float>
    var bgColor1: SIMD4<Float>
    var bgColor2: SIMD4<Float>
    var bgParams: SIMD4<Float>
    var shadow: SIMD4<Float>
    var cursor: SIMD4<Float>
    var cursorColor: SIMD4<Float>
    var camera: SIMD4<Float>       // x,y (output px), z=radius, w=opacity (0 = no overlay)
    var cameraParams: SIMD4<Float> // x=aspect(w/h), y=circular(1)/rounded-rect(0), z,w unused
    var caption: SIMD4<Float>      // x,y (top-left px), z=w, w=h of the text texture
    var extra: SIMD4<Float>        // x=fade, y=overlay-layer alpha, z=main content enabled, w unused
}

/// Per-composition data handed to the compositor via the video-composition instruction.
/// (AVFoundation instantiates the compositor itself with `init()`, so all inputs must
/// arrive through the instruction.)
final class DemoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let masterTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let settings: RenderSettings
    let masterWidth: Int
    let masterHeight: Int
    let smoother: CursorSmoother
    let zoomAt: (@Sendable (Double) -> ZoomState)?
    let captionTrack: CaptionTrack?

    init(timeRange: CMTimeRange,
         masterTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID? = nil,
         settings: RenderSettings,
         masterWidth: Int,
         masterHeight: Int,
         smoother: CursorSmoother,
         zoomAt: (@Sendable (Double) -> ZoomState)? = nil,
         captionTrack: CaptionTrack? = nil) {
        self.timeRange = timeRange
        self.masterTrackID = masterTrackID
        self.cameraTrackID = cameraTrackID
        self.settings = settings
        self.masterWidth = masterWidth
        self.masterHeight = masterHeight
        self.smoother = smoother
        self.zoomAt = zoomAt
        self.captionTrack = captionTrack
        var ids = [NSNumber(value: masterTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
    }
}

/// Where the recording sits inside the output frame, at zoom 1.
enum RenderLayout {
    static func contentRect(settings: RenderSettings, masterWidth: Int, masterHeight: Int) -> CGRect {
        let outW = Double(settings.outputWidth)
        let outH = Double(settings.outputHeight)
        let pad = settings.paddingPixels
        let availW = max(1, outW - 2 * pad)
        let availH = max(1, outH - 2 * pad)
        let scale = min(availW / Double(masterWidth), availH / Double(masterHeight))
        let w = Double(masterWidth) * scale
        let h = Double(masterHeight) * scale
        return CGRect(x: (outW - w) / 2, y: (outH - h) / 2, width: w, height: h)
    }
}

/// Custom video compositor: renders each master frame into the polished output with a
/// single Metal pass (background, rounded-corner screen, soft shadow, cursor, zoom).
final class DemoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    let device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    struct CursorSprite {
        let texture: MTLTexture
        let aspect: Float                 // width / height
        let hotspot: SIMD2<Float>         // fraction (0…1) of the sprite where the click lands
    }
    let arrowSprite: CursorSprite?
    let handSprite: CursorSprite?
    private let renderQueue = DispatchQueue(label: "com.andrea.mydemostudio.render")
    /// Rasterized caption textures, keyed by text (accessed only on renderQueue).
    private var captionCache: [String: (texture: MTLTexture, width: Int, height: Int)] = [:]
    /// Still-image textures for image clips, keyed by file path (renderQueue only).
    var imageCache: [String: MTLTexture] = [:]
    /// Canvas-sized text-overlay layers, keyed by the active text set (renderQueue only).
    var overlayCache: [String: MTLTexture] = [:]

    /// False when Metal could not be set up; every frame request then fails cleanly.
    var isUsable: Bool { device != nil && pipeline != nil && commandQueue != nil && textureCache != nil }

    /// AVFoundation instantiates the compositor itself, so `init()` cannot fail. Rather
    /// than trap — which would take the whole app down over a GPU hiccup — an unusable
    /// compositor is left inert and finishes every request with an error, which
    /// AVFoundation surfaces as a failed render instead of a crash.
    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()

        if let device,
           let queue = device.makeCommandQueue(),
           let library = device.makeDefaultLibrary(),
           let vfn = library.makeFunction(name: "demo_vertex"),
           let ffn = library.makeFunction(name: "demo_fragment") {
            self.commandQueue = queue
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try? device.makeRenderPipelineState(descriptor: desc)
            if self.pipeline == nil {
                NSLog("MyDemoStudio: Metal pipeline creation failed; rendering disabled")
            }
        } else {
            self.pipeline = nil
            NSLog("MyDemoStudio: Metal setup failed; rendering disabled")
        }

        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }

        self.arrowSprite = device.flatMap { Self.loadCursorSprite(NSCursor.arrow, device: $0) }
        self.handSprite = device.flatMap { Self.loadCursorSprite(NSCursor.pointingHand, device: $0) }

        super.init()
    }

    /// Loads a system cursor as a premultiplied texture, keeping its hotspot fraction so
    /// the sprite is positioned so the click point lands where the cursor actually is.
    private static func loadCursorSprite(_ cursor: NSCursor, device: MTLDevice) -> CursorSprite? {
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft
        ]
        guard let texture = try? loader.newTexture(cgImage: cg, options: options) else { return nil }
        let size = image.size
        let hotspot = SIMD2<Float>(
            size.width > 0 ? Float(cursor.hotSpot.x / size.width) : 0,
            size.height > 0 ? Float(cursor.hotSpot.y / size.height) : 0
        )
        return CursorSprite(texture: texture, aspect: Float(texture.width) / Float(texture.height), hotspot: hotspot)
    }

    // MARK: AVVideoCompositing

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self, self.isUsable, let outputPB = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "MyDemoStudio", code: -1))
                return
            }
            let time = CMTimeGetSeconds(request.compositionTime)

            // Two instruction shapes share one compositor: the single-recording editor
            // (`DemoInstruction`) and the multi-clip timeline (`TimelineInstruction`).
            if let instruction = request.videoCompositionInstruction as? DemoInstruction {
                guard let sourcePB = request.sourceFrame(byTrackID: instruction.masterTrackID) else {
                    request.finish(with: NSError(domain: "MyDemoStudio", code: -1))
                    return
                }
                let cameraPB = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
                self.render(source: sourcePB, camera: cameraPB, into: outputPB, time: time, instruction: instruction)
            } else if let instruction = request.videoCompositionInstruction as? TimelineInstruction {
                self.renderTimeline(request: request, instruction: instruction, into: outputPB, time: time)
            } else {
                request.finish(with: NSError(domain: "MyDemoStudio", code: -1))
                return
            }
            request.finish(withComposedVideoFrame: outputPB)
        }
    }

    // MARK: Rendering

    private func render(source: CVPixelBuffer, camera: CVPixelBuffer?, into output: CVPixelBuffer, time: Double, instruction: DemoInstruction) {
        guard let sourceTexture = makeTexture(from: source),
              let outputTexture = makeTexture(from: output) else { return }

        let built = makeUniforms(time: time, instruction: instruction)
        var uniforms = built.uniforms
        let cursorTexture = built.cursorTexture

        // Fill in the live camera frame + aspect, or disable the bubble if absent.
        let cameraTexture = camera.flatMap { makeTexture(from: $0) }
        if let camera, cameraTexture != nil {
            let w = Double(CVPixelBufferGetWidth(camera))
            let h = Double(CVPixelBufferGetHeight(camera))
            uniforms.cameraParams.x = Float(h > 0 ? w / h : 1.777)
        } else {
            uniforms.camera.w = 0
        }

        // Active caption: rasterize + place near the bottom-center.
        var captionTexture: MTLTexture?
        let s = instruction.settings
        if s.captionsEnabled, let segment = instruction.captionTrack?.active(at: time),
           !segment.text.isEmpty {
            let outW = Double(s.outputWidth), outH = Double(s.outputHeight)
            let fontSize = CGFloat(max(outH * 0.036, 14))
            let maxWidth = Int(outW * 0.82)
            if let cap = makeCaptionTexture(text: segment.text, maxWidth: maxWidth, fontSize: fontSize) {
                captionTexture = cap.texture
                let cw = Double(cap.width), ch = Double(cap.height)
                let cx = (outW - cw) / 2
                let cy = outH - outH * 0.07 - ch
                uniforms.caption = SIMD4<Float>(Float(cx), Float(cy), Float(cw), Float(ch))
            }
        }

        draw(uniforms: uniforms, source: sourceTexture, cursor: cursorTexture,
             camera: cameraTexture, caption: captionTexture, overlay: nil, into: outputTexture)
    }

    /// Encodes the single fullscreen pass. Every texture slot must be bound even when
    /// unused, so absent textures fall back to the source texture.
    func draw(uniforms: GPUUniforms, source: MTLTexture, cursor: MTLTexture?,
                      camera: MTLTexture?, caption: MTLTexture?, overlay: MTLTexture?,
                      into output: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let pipeline, let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(cursor ?? source, index: 1)
        encoder.setFragmentTexture(camera ?? source, index: 2)
        encoder.setFragmentTexture(caption ?? source, index: 3)
        encoder.setFragmentTexture(overlay ?? source, index: 4)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func makeUniforms(time: Double, instruction: DemoInstruction) -> (uniforms: GPUUniforms, cursorTexture: MTLTexture?) {
        let s = instruction.settings
        let masterW = Double(instruction.masterWidth)
        let masterH = Double(instruction.masterHeight)
        let content = RenderLayout.contentRect(settings: s, masterWidth: instruction.masterWidth, masterHeight: instruction.masterHeight)

        // Camera looks at the cursor: focus is a master-uv point that maps to the CENTER
        // of the screen. Clamp it so the 1/z window stays inside the recording.
        let zoom = instruction.zoomAt?(time) ?? ZoomState(focus: CGPoint(x: masterW / 2, y: masterH / 2), scale: 1)
        let zVal = max(zoom.scale, 1.0)
        let halfU = 0.5 / zVal
        let focusU = min(max(zoom.focus.x / masterW, halfU), 1 - halfU)
        let focusV = min(max(zoom.focus.y / masterH, halfU), 1 - halfU)
        let z = Float(max(zoom.scale, 0.0001))

        // Zoom-blur (off by default): proportional to how fast the zoom scale changes.
        var zoomBlur: Float = 0
        if s.motionBlur {
            let dt = 1.0 / 30.0
            let zoomPrev = instruction.zoomAt?(time - dt) ?? zoom
            let zoomVelocity = abs(zoom.scale - zoomPrev.scale) / dt
            zoomBlur = Float(min(zoomVelocity * 0.02, 0.04))
        }

        // Cursor: master px → output px (unzoomed placement), then expand about focus.
        var cursorVec = SIMD4<Float>(0, 0, 0, 0)
        var cursorMode: Float = 0
        var cursorTexture: MTLTexture?
        if let cursorPixel = instruction.smoother.position(at: time) {
            // Cursor position through the same look-at transform (content-normalized).
            let contentNormX = 0.5 + (cursorPixel.x / masterW - focusU) * Double(z)
            let contentNormY = 0.5 + (cursorPixel.y / masterH - focusV) * Double(z)
            let zoomed = CGPoint(
                x: content.minX + content.width * contentNormX,
                y: content.minY + content.height * contentNormY
            )
            let sizeScale = Float(s.cursorScale) * Float(s.minSide / 1080.0)

            let sprite: CursorSprite?
            switch s.cursorStyle {
            case .arrow:       sprite = arrowSprite
            case .hand:        sprite = handSprite
            case .handOnClick: sprite = instruction.smoother.isPressed(at: time) ? handSprite : arrowSprite
            }

            if s.showDebugCursorDot || sprite == nil {
                let radius = Float(9) * sizeScale
                cursorVec = SIMD4<Float>(Float(zoomed.x), Float(zoomed.y), max(radius, 4), 1)
                cursorMode = 1
            } else if let sprite {
                let height = Float(26) * sizeScale
                let width = height * sprite.aspect
                // Position so the hotspot (actual click point) lands at the cursor position.
                let originX = Float(zoomed.x) - sprite.hotspot.x * width
                let originY = Float(zoomed.y) - sprite.hotspot.y * height
                cursorVec = SIMD4<Float>(originX, originY, width, height)
                cursorMode = 2
                cursorTexture = sprite.texture
            }
        }

        // Webcam bubble geometry (aspect is filled in during render from the frame).
        var cameraVec = SIMD4<Float>(0, 0, 0, 0)
        if s.webcamEnabled, instruction.cameraTrackID != nil {
            let outW = Double(s.outputWidth), outH = Double(s.outputHeight)
            let radius = s.webcamSize * min(outW, outH) / 2.0
            let margin = radius * 0.35 + 0.025 * min(outW, outH)
            let cx: Double, cy: Double
            switch s.webcamCorner {
            case .bottomLeading:  cx = margin + radius;         cy = outH - margin - radius
            case .bottomTrailing: cx = outW - margin - radius;  cy = outH - margin - radius
            case .topLeading:     cx = margin + radius;         cy = margin + radius
            case .topTrailing:    cx = outW - margin - radius;  cy = margin + radius
            }
            cameraVec = SIMD4<Float>(Float(cx), Float(cy), Float(radius), 1)
        }

        let bg = s.background
        let uniforms = GPUUniforms(
            outputSize_corner: SIMD4<Float>(Float(s.outputWidth), Float(s.outputHeight), Float(s.cornerRadiusPixels), 0),
            contentRect: SIMD4<Float>(Float(content.minX), Float(content.minY), Float(content.width), Float(content.height)),
            zoom: SIMD4<Float>(Float(focusU), Float(focusV), z, 0),
            bgColor1: SIMD4<Float>(Float(bg.color1.r), Float(bg.color1.g), Float(bg.color1.b), Float(bg.color1.a)),
            bgColor2: SIMD4<Float>(Float(bg.color2.r), Float(bg.color2.g), Float(bg.color2.b), Float(bg.color2.a)),
            bgParams: SIMD4<Float>(Float(bg.angleDegrees * .pi / 180.0), Float(bg.kind.rawValue), cursorMode, Float(bg.wallpaperIndex)),
            shadow: SIMD4<Float>(Float(s.shadowRadiusPixels), Float(s.shadowOpacity), zoomBlur, Float(bg.blur)),
            cursor: cursorVec,
            cursorColor: SIMD4<Float>(1, 1, 1, 1),
            camera: cameraVec,
            cameraParams: SIMD4<Float>(1.777, 1, 0, 0),
            caption: SIMD4<Float>(0, 0, 0, 0),
            extra: SIMD4<Float>(1, 0, 1, 0)
        )
        return (uniforms, cursorTexture)
    }

    private func masterToOutput(_ p: CGPoint, content: CGRect, masterW: Double, masterH: Double) -> CGPoint {
        CGPoint(
            x: content.minX + (p.x / masterW) * content.width,
            y: content.minY + (p.y / masterH) * content.height
        )
    }

    /// Rasterizes caption text (white, wrapped) to a texture, cached by string.
    func makeCaptionTexture(text: String, maxWidth: Int, fontSize: CGFloat) -> (texture: MTLTexture, width: Int, height: Int)? {
        if let cached = captionCache[text] { return cached }

        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: CGFloat(maxWidth), height: .greatestFiniteMagnitude)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, &fitRange)
        let width = max(1, Int(ceil(suggested.width)))
        let height = max(1, Int(ceil(suggested.height)))

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Core Text draws in CG's bottom-up space; the resulting bitmap rows already
        // map to a top-left-origin texture, so no extra flip is needed here.
        ctx.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device?.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: &pixels, bytesPerRow: bytesPerRow)

        let result = (texture, width, height)
        captionCache[text] = result
        return result
    }

    func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return texture
    }
}
