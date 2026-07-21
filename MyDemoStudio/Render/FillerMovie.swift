import Foundation
import AVFoundation
import CoreVideo

/// Generates the tiny black movie that acts as the project's **timebase track**.
///
/// A composition only produces video frames where some video track has content. Still
/// images, text cards and gaps have no track of their own, so without a filler the
/// compositor would simply never be asked to render those instants. Looping this clip
/// across the whole timeline guarantees every instant gets a frame; its pixels are never
/// sampled, so it stays deliberately tiny.
enum FillerMovie {

    static let width = 128
    static let height = 72
    /// Long enough that even a 10-minute project only needs a few dozen inserts.
    static let duration: Double = 10

    /// Writes the filler if it isn't already there. Cheap and idempotent.
    static func ensure(at url: URL, fps: Int) async throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await write(to: url, fps: max(fps, 1))
    }

    private static func write(to url: URL, fps: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw VideoExporter.ExportError.writerFailed("filler: cannot add input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoExporter.ExportError.writerFailed(writer.error?.localizedDescription ?? "filler")
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pixelBuffer else {
            throw VideoExporter.ExportError.writerFailed("filler: no pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let frameCount = Int(duration * Double(fps))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw VideoExporter.ExportError.writerFailed(writer.error?.localizedDescription ?? "filler")
        }
    }
}
