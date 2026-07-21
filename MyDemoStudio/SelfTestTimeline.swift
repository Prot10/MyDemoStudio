import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Headless end-to-end validation of the multi-clip timeline, run with
/// `MDS_SELFTEST=timeline`.
///
/// It builds a project entirely out of synthesized media with known colors, applies the
/// full edit vocabulary (trim, split, speed, Ken Burns, text, fades, audio), exports it,
/// and then *reads pixels and samples back out of the exported file*. Nothing here trusts
/// the code under test to report its own success.
enum SelfTestTimeline {

    // Deliberately saturated, far-apart colors so a probe can't be ambiguous.
    private static let redVideo = (r: 0.90, g: 0.05, b: 0.05)
    private static let greenImage = (r: 0.05, g: 0.85, b: 0.10)

    static func run() async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        log("timeline checks starting")
        var ok = true

        ok = documentMath() && ok
        ok = await renderPipeline() && ok

        log(ok ? "PASS all timeline checks" : "FAIL timeline checks")
        return ok
    }

    // MARK: 1. Pure document logic — deterministic, no rendering

    private static func documentMath() -> Bool {
        var ok = true
        var doc = EditDocument.makeDefault(name: "math", canvas: .fullHD)
        let mainID = doc.tracks[0].id

        let clip = TimelineClip(source: .recording(id: "x"), start: 0, sourceIn: 0, sourceOut: 10)
        doc.add(clip, toTrack: mainID)
        guard let placed = doc.tracks[0].clips.first else { log("FAIL clip not added"); return false }

        // Speed warps the timeline length but not the source window.
        doc.setSpeed(clipID: placed.id, speed: 2.0)
        let sped = doc.clip(id: placed.id)!
        ok = expect(abs(sped.duration - 5.0) < 0.001, "speed 2x on a 10s window → 5s timeline (got \(fmt(sped.duration)))") && ok
        ok = expect(abs(sped.sourceTime(at: 1.0) - 2.0) < 0.001,
                    "t=1s at 2x maps to source 2s (got \(fmt(sped.sourceTime(at: 1.0))))") && ok

        // Splitting at a timeline instant cuts the *source* at the warped position.
        guard let rightID = doc.split(clipID: placed.id, at: 2.0) else { log("FAIL split returned nil"); return false }
        let left = doc.clip(id: placed.id)!
        let right = doc.clip(id: rightID)!
        ok = expect(abs(left.sourceOut - 4.0) < 0.001, "split at t=2s cuts source at 4s (got \(fmt(left.sourceOut)))") && ok
        ok = expect(abs(left.duration - 2.0) < 0.001, "left half is 2s (got \(fmt(left.duration)))") && ok
        ok = expect(abs(right.start - 2.0) < 0.001, "right half starts at 2s") && ok
        ok = expect(abs(right.end - 5.0) < 0.001, "right half ends at 5s (got \(fmt(right.end)))") && ok
        ok = expect(abs(doc.duration - 5.0) < 0.001, "total stays 5s after split") && ok

        // Ripple delete closes the hole it leaves behind.
        doc.rippleDelete(clipID: placed.id)
        ok = expect(abs(doc.duration - 3.0) < 0.001, "ripple delete closes the gap (got \(fmt(doc.duration)))") && ok
        ok = expect(abs(doc.clip(id: rightID)!.start) < 0.001, "remaining clip slides to 0") && ok

        // Fades produce the expected envelope.
        doc.trim(clipID: rightID, sourceIn: nil, sourceOut: 10)
        var faded = doc.clip(id: rightID)!
        faded.fadeIn = 1.0
        ok = expect(abs(faded.fadeLevel(at: faded.start + 0.5) - 0.5) < 0.02, "fade-in is halfway at 0.5s") && ok
        ok = expect(faded.fadeLevel(at: faded.start) < 0.01, "fade-in starts at black") && ok

        // Look overrides resolve against the project defaults.
        var override = LookOverride()
        override.zoomScale = 1.75
        let resolved = override.applied(to: doc.defaultLook)
        ok = expect(abs(resolved.zoomScale - 1.75) < 0.001, "override applies zoomScale") && ok
        ok = expect(resolved.paddingFraction == doc.defaultLook.paddingFraction, "override inherits padding") && ok

        return ok
    }

    // MARK: 2. Full render — synthesize media, export, read the pixels back

    private static func renderPipeline() async -> Bool {
        var ok = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MDSTimelineTest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let project: EditProject
        var doc: EditDocument
        do {
            project = try EditProject.create(named: "selftest", canvas: Canvas(width: 640, height: 360, aspect: .wide, fps: 30), in: root)
            doc = try project.read()
        } catch {
            log("FAIL create project: \(error)"); return false
        }

        // --- Synthesize the media ---
        let videoURL = root.appendingPathComponent("red.mov")
        let imageURL = root.appendingPathComponent("green.png")
        let audioURL = root.appendingPathComponent("tone.wav")
        do {
            try await writeSolidVideo(to: videoURL, color: redVideo, seconds: 4, fps: 30, width: 320, height: 180)
            try writeSolidPNG(to: imageURL, color: greenImage, width: 320, height: 180)
            try writeTone(to: audioURL, seconds: 4, frequency: 440)
        } catch {
            log("FAIL synthesize media: \(error)"); return false
        }

        let videoSource: MediaSource, imageSource: MediaSource, audioSource: MediaSource
        do {
            videoSource = try project.importMedia(from: videoURL)
            imageSource = try project.importMedia(from: imageURL)
            audioSource = try project.importMedia(from: audioURL)
        } catch {
            log("FAIL import media: \(error)"); return false
        }

        // --- Build the edit: 4s of video at 2x → 2s, then a 2s image with Ken Burns,
        //     a text card over the image, and a tone underneath. Total 4s. ---
        let mainTrack = doc.tracks[0].id
        let overlayTrack = doc.tracks[1].id
        let musicTrack = doc.tracks[3].id

        var videoClip = TimelineClip(source: videoSource, start: 0, sourceIn: 0, sourceOut: 4, name: "red")
        videoClip.speed = 2.0
        videoClip.fadeIn = 0.5
        doc.add(videoClip, toTrack: mainTrack, at: 0)

        var imageClip = TimelineClip(source: imageSource, start: 2, sourceIn: 0, sourceOut: 2, name: "green")
        imageClip.kenBurns = KenBurns()
        doc.add(imageClip, toTrack: mainTrack, at: 2)

        var textClip = TimelineClip(source: .text, start: 2.5, sourceIn: 0, sourceOut: 1.0, name: "title")
        textClip.text = TextOverlay(string: "HELLO", fontSize: 0.16, x: 0.5, y: 0.86)
        doc.add(textClip, toTrack: overlayTrack, at: 2.5)

        let toneClip = TimelineClip(source: audioSource, start: 0, sourceIn: 0, sourceOut: 4, name: "tone")
        doc.add(toneClip, toTrack: musicTrack, at: 0)

        // Zero padding on the main clips so the canvas centre is unambiguously content.
        var flat = LookOverride()
        flat.paddingFraction = 0
        flat.cornerRadiusFraction = 0
        flat.shadowOpacity = 0
        for i in doc.tracks[0].clips.indices { doc.tracks[0].clips[i].look = flat }

        do { try project.write(doc) } catch { log("FAIL write document: \(error)"); return false }

        ok = expect(abs(doc.duration - 4.0) < 0.01, "timeline duration is 4s (got \(fmt(doc.duration)))") && ok

        // --- Export ---
        let outputURL = root.appendingPathComponent("out.mov")
        do {
            try await VideoExporter.exportTimeline(project: project, document: doc, to: outputURL) { _ in }
        } catch {
            log("FAIL export: \(error)"); return false
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            log("FAIL export produced no file"); return false
        }

        // --- Probe the exported file ---
        let asset = AVURLAsset(url: outputURL)
        let exportedDuration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        ok = expect(abs(exportedDuration - 4.0) < 0.3, "exported duration ≈ 4s (got \(fmt(exportedDuration)))") && ok

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video))?.count ?? 0
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
        ok = expect(videoTracks == 1, "exported video track present (got \(videoTracks))") && ok
        ok = expect(audioTracks == 1, "exported audio track present (got \(audioTracks))") && ok

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // t=1.0s → inside the sped-up red video clip.
        if let frame = await self.frame(generator, at: 1.0) {
            let c = frame.average(x: frame.width / 2 - 16, y: frame.height / 2 - 16, w: 32, h: 32)
            ok = expect(c.r > 0.5 && c.g < 0.35 && c.b < 0.35,
                        "t=1.0s centre is the red video clip (r=\(fmt(c.r)) g=\(fmt(c.g)) b=\(fmt(c.b)))") && ok
        } else { log("FAIL no frame at 1.0s"); ok = false }

        // t=0.05s → still inside the 0.5s fade-in, so much darker than mid-clip.
        if let dark = await self.frame(generator, at: 0.05), let bright = await self.frame(generator, at: 1.0) {
            let d = dark.average(x: dark.width / 2 - 16, y: dark.height / 2 - 16, w: 32, h: 32)
            let b = bright.average(x: bright.width / 2 - 16, y: bright.height / 2 - 16, w: 32, h: 32)
            ok = expect(d.r < b.r * 0.55, "fade-in darkens the first frames (\(fmt(d.r)) vs \(fmt(b.r)))") && ok
        } else { log("FAIL no fade frames"); ok = false }

        // t=3.0s → the still-image clip, which has no video track at all. This is the
        // check that the filler timebase track is doing its job.
        if let frame = await self.frame(generator, at: 3.0) {
            let c = frame.average(x: frame.width / 2 - 16, y: frame.height / 2 - 16, w: 32, h: 32)
            ok = expect(c.g > 0.45 && c.r < 0.4,
                        "t=3.0s centre is the green image clip (r=\(fmt(c.r)) g=\(fmt(c.g)) b=\(fmt(c.b)))") && ok
            // The text card sits in the lower band and is the only near-white thing there.
            let band = frame.average(x: 0, y: Int(Double(frame.height) * 0.78), w: frame.width, h: max(frame.height / 8, 1))
            ok = expect(band.r > c.r + 0.04, "text card brightens the lower band (\(fmt(band.r)) vs \(fmt(c.r)))") && ok
        } else { log("FAIL no frame at 3.0s"); ok = false }

        // Audio actually carries signal, rather than just existing as an empty track.
        let rms = await audioRMS(url: outputURL)
        ok = expect(rms > 0.01, "exported audio has signal (rms=\(String(format: "%.4f", rms)))") && ok

        // Ken Burns must actually move the picture — compare the start and end of the
        // image clip; a static render would be pixel-identical.
        if let a = await self.frame(generator, at: 2.05), let b = await self.frame(generator, at: 3.9) {
            let left = a.average(x: 0, y: a.height / 2 - 8, w: 24, h: 16)
            let leftLater = b.average(x: 0, y: b.height / 2 - 8, w: 24, h: 16)
            let moved = abs(left.r - leftLater.r) + abs(left.g - leftLater.g) + abs(left.b - leftLater.b) > 0.02
            ok = expect(moved, "Ken Burns changes the framing across the image clip") && ok
        }

        log("render pipeline checks done (project at \(project.packageURL.path))")
        return ok
    }

    // MARK: Media synthesis

    private static func writeSolidVideo(to url: URL, color: (r: Double, g: Double, b: Double),
                                        seconds: Double, fps: Int, width: Int, height: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pixelBuffer else { throw VideoExporter.ExportError.writerFailed("test video buffer") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * bytesPerRow + x * 4          // BGRA
                    ptr[i] = UInt8(color.b * 255)
                    ptr[i + 1] = UInt8(color.g * 255)
                    ptr[i + 2] = UInt8(color.r * 255)
                    ptr[i + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw VideoExporter.ExportError.writerFailed(writer.error?.localizedDescription ?? "test video")
        }
    }

    /// A flat color with a bright marker stripe down the left edge — the stripe is what
    /// makes a Ken Burns move detectable, since a truly solid image looks identical at
    /// every zoom level.
    private static func writeSolidPNG(to url: URL, color: (r: Double, g: Double, b: Double), width: Int, height: Int) throws {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let stripe = max(width / 12, 2)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                let marker = x < stripe
                pixels[i] = UInt8((marker ? 1.0 : color.r) * 255)
                pixels[i + 1] = UInt8((marker ? 0.05 : color.g) * 255)
                pixels[i + 2] = UInt8((marker ? 1.0 : color.b) * 255)
                pixels[i + 3] = 255
            }
        }
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VideoExporter.ExportError.writerFailed("test png")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func writeTone(to url: URL, seconds: Double, frequency: Double) throws {
        let count = Int(seconds * AudioMixer.sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = Float(sin(2 * .pi * frequency * Double(i) / AudioMixer.sampleRate)) * 0.5
        }
        let temp = try AudioMixer.writeWAV(samples)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }

    // MARK: Probing

    @concurrent
    private static func frame(_ generator: AVAssetImageGenerator, at seconds: Double) async -> RGBAImage? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return RGBAImage(cg)
    }

    private static func audioRMS(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading() else { return 0 }

        var sum = 0.0, n = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for v in data { sum += Double(v * v); n += 1 }
        }
        return n > 0 ? (sum / n).squareRoot() : 0
    }

    // MARK: Reporting

    private static func expect(_ condition: Bool, _ description: String) -> Bool {
        log((condition ? "ok   " : "FAIL ") + description)
        return condition
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.3f", d) }

    private static func log(_ message: String) { print("SELFTEST: \(message)") }
}
