import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// Renders a project's master movie through `DemoCompositor` and writes the polished
/// result to disk. Uses a reader→writer pipeline so the same custom compositor path is
/// exercised here as in the live preview.
enum VideoExporter {

    enum ExportError: Error {
        case noVideoTrack
        case readerFailed(String)
        case writerFailed(String)
    }

    @concurrent
    static func export(
        project: DemoProject,
        settings: RenderSettings,
        format: ExportFormat = .mp4,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let eventTrack = try project.readEventTrack()

        // Assemble master (+ optional camera) tracks; build the video composition.
        let built = try await CompositionBuilder.buildAsset(
            masterURL: project.masterURL,
            cameraURL: project.hasCamera ? project.cameraURL : nil
        )
        let composition = CompositionBuilder.videoComposition(settings: settings, eventTrack: eventTrack, built: built, captions: project.readCaptions())

        // Build the final audio: voiceover mixed with click/keystroke SFX.
        let mixedAudioURL = try? await AudioMixer.buildMixedAudio(
            masterURL: project.masterURL, eventTrack: eventTrack,
            settings: settings, duration: CMTimeGetSeconds(built.duration)
        )
        let hasAudio = mixedAudioURL != nil
        let videoOnlyURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("._videoonly_\(UUID().uuidString).mov")

        try await renderVideoOnly(
            asset: built.asset, composition: composition,
            width: settings.outputWidth, height: settings.outputHeight, duration: built.duration,
            format: format, to: videoOnlyURL, progress: { p in progress(p * (hasAudio ? 0.9 : 1.0)) }
        )

        // Mux the mixed audio track in (passthrough) if present.
        if let mixedAudioURL {
            try await mux(videoOnly: videoOnlyURL, audioURL: mixedAudioURL, format: format, to: outputURL)
            try? FileManager.default.removeItem(at: videoOnlyURL)
            try? FileManager.default.removeItem(at: mixedAudioURL)
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: videoOnlyURL, to: outputURL)
        }
        progress(1.0)
    }

    /// Renders a multi-clip project. Same two-stage shape as `export`: composite the
    /// picture, mix the audio, then mux — so both editors share one export path.
    @concurrent
    static func exportTimeline(
        project: EditProject,
        document: EditDocument,
        size: (width: Int, height: Int)? = nil,
        format: ExportFormat = .mp4,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = try await TimelineCompositionBuilder.build(project: project, document: document)
        let width = size?.width ?? document.canvas.width
        let height = size?.height ?? document.canvas.height
        if size != nil {
            built.videoComposition.renderSize = CGSize(width: width, height: height)
        }

        let mixedAudioURL = try? await TimelineAudioMixer.build(project: project, document: document)
        let hasAudio = mixedAudioURL != nil
        let videoOnlyURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("._videoonly_\(UUID().uuidString).\(format.fileExtension)")

        try await renderVideoOnly(
            asset: built.asset, composition: built.videoComposition,
            width: width, height: height, duration: built.duration,
            format: format, to: videoOnlyURL, progress: { p in progress(p * (hasAudio ? 0.9 : 1.0)) }
        )

        if let mixedAudioURL {
            try await mux(videoOnly: videoOnlyURL, audioURL: mixedAudioURL, format: format, to: outputURL)
            try? FileManager.default.removeItem(at: videoOnlyURL)
            try? FileManager.default.removeItem(at: mixedAudioURL)
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: videoOnlyURL, to: outputURL)
        }
        progress(1.0)
    }

    /// Renders a multi-clip project to an animated GIF.
    @concurrent
    static func exportTimelineGIF(
        project: EditProject,
        document: EditDocument,
        frameRate: Int,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = try await TimelineCompositionBuilder.build(project: project, document: document)
        try await writeGIF(asset: built.asset, composition: built.videoComposition,
                           duration: built.duration, frameRate: frameRate,
                           width: document.canvas.width, height: document.canvas.height,
                           to: outputURL, progress: progress)
    }

    /// Renders the composited timeline to a video-only file.
    private static func renderVideoOnly(
        asset: AVAsset,
        composition: AVMutableVideoComposition,
        width: Int,
        height: Int,
        duration: CMTime,
        format: ExportFormat,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.videoComposition = composition
        guard reader.canAdd(readerOutput) else { throw ExportError.readerFailed("cannot add output") }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: format.fileType)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw ExportError.writerFailed("cannot add input") }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        while reader.status == .reading {
            guard writerInput.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            guard let sample = readerOutput.copyNextSampleBuffer() else { break }
            writerInput.append(sample)
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            progress(min(1.0, max(0.0, t / totalSeconds)))
        }
        writerInput.markAsFinished()
        await writer.finishWriting()

        if reader.status == .failed { throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        if writer.status == .failed { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown") }
    }

    /// Combines the video-only render with the master's audio track (passthrough).
    private static func mux(videoOnly: URL, audioURL: URL, format: ExportFormat, to outputURL: URL) async throws {
        let composition = AVMutableComposition()
        // Keep both assets alive for the whole function — a track whose asset deallocates
        // becomes invalid and insertTimeRange fails with -12780.
        let videoAsset = AVURLAsset(url: videoOnly)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.writerFailed("mux: no video")
        }
        let videoDuration = try await videoAsset.load(.duration)
        try videoComp.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)

        if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration))
            try audioComp.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.writerFailed("mux: no export session")
        }
        try await session.export(to: outputURL, as: format.fileType)
    }

    /// Renders the project to an animated GIF by sampling the composited timeline with
    /// an image generator (which drives the same `DemoCompositor`).
    @concurrent
    static func exportGIF(
        project: DemoProject,
        settings: RenderSettings,
        frameRate: Int,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let eventTrack = try project.readEventTrack()
        let built = try await CompositionBuilder.buildAsset(
            masterURL: project.masterURL,
            cameraURL: project.hasCamera ? project.cameraURL : nil
        )
        let duration = built.duration
        let composition = CompositionBuilder.videoComposition(settings: settings, eventTrack: eventTrack, built: built, captions: project.readCaptions())
        try await writeGIF(asset: built.asset, composition: composition, duration: duration,
                           frameRate: frameRate, width: settings.outputWidth, height: settings.outputHeight,
                           to: outputURL, progress: progress)
    }

    /// Samples a composited timeline with an image generator (which drives the same
    /// `DemoCompositor`) and encodes the frames as an animated GIF.
    @concurrent
    private static func writeGIF(
        asset: AVAsset,
        composition: AVMutableVideoComposition,
        duration: CMTime,
        frameRate: Int,
        width: Int,
        height: Int,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: width, height: height)

        let totalSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let frameCount = max(1, Int(totalSeconds * Double(frameRate)))
        let delay = 1.0 / Double(frameRate)

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else {
            throw ExportError.writerFailed("could not create GIF destination")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
        ] as CFDictionary

        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) * delay, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
            progress(Double(i) / Double(frameCount))
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writerFailed("GIF finalize failed")
        }
        progress(1.0)
    }
}
