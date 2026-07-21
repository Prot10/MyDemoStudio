import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import ImageIO

/// A fully assembled multi-clip timeline, ready for the player or the exporter.
struct BuiltTimeline {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let duration: CMTime
    let fps: Int
}

/// Turns an `EditDocument` into an `AVMutableComposition` plus the per-segment
/// instructions that drive `DemoCompositor`.
///
/// Sibling of `CompositionBuilder`, which still handles the single-recording editor.
/// Shared by the live preview and the exporter so preview matches export exactly.
enum TimelineCompositionBuilder {

    enum BuildError: Error, LocalizedError {
        case empty
        case missingMedia(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The timeline is empty."
            case .missingMedia(let name): return "Missing media: \(name)"
            }
        }
    }

    /// Everything we need to know about one distinct media source, loaded once and reused
    /// by every clip that references it.
    private struct ResolvedSource {
        var assetTrack: AVAssetTrack?
        var asset: AVURLAsset?
        var width: Int
        var height: Int
        var imageURL: URL?
        var eventTrack: EventTrack?
        var captions: CaptionTrack?
    }

    static func build(project: EditProject, document: EditDocument) async throws -> BuiltTimeline {
        let total = document.duration
        guard total > 0.01 else { throw BuildError.empty }

        let fps = max(document.canvas.fps, 1)
        let composition = AVMutableComposition()

        // 1. Timebase track: filled in at step 4, once the real clips have revealed the
        //    composition's true length.
        try await FillerMovie.ensure(at: project.fillerURL, fps: fps)
        let fillerAsset = AVURLAsset(url: project.fillerURL)
        guard let fillerTrack = try await fillerAsset.loadTracks(withMediaType: .video).first,
              let fillerComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.missingMedia("filler")
        }
        let fillerDuration = try await fillerAsset.load(.duration)

        // 2. Load every distinct source once.
        var resolved: [MediaSource: ResolvedSource] = [:]
        for track in document.tracks where !track.hidden && track.kind != .audio {
            for clip in track.clips where resolved[clip.source] == nil {
                resolved[clip.source] = try await resolve(clip.source, project: project, canvas: document.canvas)
            }
        }

        // 3. One composition video track per document track; insert each clip, then scale
        //    it for speed. Clips are processed in timeline order and nothing exists after
        //    the insertion point yet, so the scale only ever affects the clip itself.
        var clipTrackID: [UUID: CMPersistentTrackID] = [:]
        for track in document.tracks where !track.hidden && track.kind != .audio {
            let videoClips = track.clips.filter { $0.source.hasVideoTrack }.sorted { $0.start < $1.start }
            guard !videoClips.isEmpty else { continue }
            guard let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            for clip in videoClips {
                guard let source = resolved[clip.source], let assetTrack = source.assetTrack else { continue }
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: clip.sourceIn, preferredTimescale: 600),
                    duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
                )
                let at = CMTime(seconds: clip.start, preferredTimescale: 600)
                do {
                    try compTrack.insertTimeRange(sourceRange, of: assetTrack, at: at)
                } catch {
                    continue
                }
                if abs(clip.speed - 1.0) > 0.001 {
                    let inserted = CMTimeRange(start: at, duration: sourceRange.duration)
                    compTrack.scaleTimeRange(inserted, toDuration: CMTime(seconds: clip.duration, preferredTimescale: 600))
                }
                clipTrackID[clip.id] = compTrack.trackID
            }
        }

        // 4. Now fill the timebase across the composition's *actual* length. `scaleTimeRange`
        //    (how speed is implemented) rounds to the source's media timescale, so a sped-up
        //    clip can land a few milliseconds past the document's nominal duration.
        let contentDuration = composition.duration
        let timelineDuration = max(contentDuration, CMTime(seconds: total, preferredTimescale: 600))
        var cursor = CMTime.zero
        while cursor < timelineDuration {
            let chunk = min(fillerDuration, timelineDuration - cursor)
            try fillerComp.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: fillerTrack, at: cursor)
            cursor = cursor + chunk
        }

        // 5. Cut the composition into instructions at every clip boundary.
        //
        // AVPlayer requires the instructions to tile the asset *exactly*: leave even a few
        // milliseconds uncovered at the tail and it silently renders black without ever
        // calling the compositor (AVAssetReader, used by the exporter, is lenient about
        // this — which is why a gap here breaks the preview but not the export).
        let assetDuration = composition.duration
        let assetSeconds = CMTimeGetSeconds(assetDuration)
        // Merge boundaries less than a frame apart. A sub-frame instruction is not just
        // wasteful — AVPlayer refuses to play a composition containing one, and falls back
        // to rendering black without ever invoking the compositor.
        let grain = 1.0 / Double(fps)
        var boundaries: [Double] = [0]
        for value in document.segmentBoundaries.sorted()
        where value >= (boundaries.last ?? 0) + grain && value <= assetSeconds - grain {
            boundaries.append(value)
        }

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for i in 0..<boundaries.count {
            let t0 = boundaries[i]
            let t1 = i + 1 < boundaries.count ? boundaries[i + 1] : assetSeconds
            guard t1 - t0 > 0.0005 else { continue }
            let mid = (t0 + t1) / 2

            var main: MainSegment?
            var overlays: [OverlaySegment] = []
            var texts: [TextSegment] = []
            var settings = document.defaultLook
            settings.outputWidth = document.canvas.width
            settings.outputHeight = document.canvas.height
            settings.aspect = document.canvas.aspect

            for track in document.tracks where !track.hidden && track.kind != .audio {
                guard let clip = track.clip(at: mid) else { continue }

                if let text = clip.text {
                    texts.append(TextSegment(text: text, clipStart: clip.start, clipDuration: clip.duration,
                                             fadeIn: clip.fadeIn, fadeOut: clip.fadeOut))
                    continue
                }

                if track.kind == .main, main == nil {
                    let source = resolved[clip.source]
                    var resolvedSettings = clip.look?.applied(to: settings) ?? settings
                    resolvedSettings.outputWidth = document.canvas.width
                    resolvedSettings.outputHeight = document.canvas.height
                    settings = resolvedSettings

                    var zoomAt: (@Sendable (Double) -> ZoomState)?
                    var smoother: CursorSmoother?
                    if let eventTrack = source?.eventTrack {
                        smoother = CursorSmoother(track: eventTrack, smoothing: resolvedSettings.cursorSmoothing)
                        let planner = ZoomPlanner(track: eventTrack, settings: resolvedSettings)
                        if !planner.isEmpty {
                            zoomAt = { @Sendable t in planner.zoom(at: t) }
                        }
                    }
                    main = MainSegment(
                        trackID: clipTrackID[clip.id],
                        imageURL: source?.imageURL,
                        sourceWidth: source?.width ?? document.canvas.width,
                        sourceHeight: source?.height ?? document.canvas.height,
                        clipStart: clip.start, clipDuration: clip.duration,
                        sourceIn: clip.sourceIn, speed: clip.speed,
                        fadeIn: clip.fadeIn, fadeOut: clip.fadeOut,
                        zoomAt: zoomAt, smoother: smoother,
                        kenBurns: clip.kenBurns,
                        captions: resolvedSettings.captionsEnabled ? source?.captions : nil
                    )
                } else if let trackID = clipTrackID[clip.id] {
                    overlays.append(OverlaySegment(trackID: trackID, transform: clip.transform,
                                                   clipStart: clip.start, clipDuration: clip.duration,
                                                   fadeIn: clip.fadeIn, fadeOut: clip.fadeOut))
                }
            }

            // The final instruction ends on the asset's exact duration, not a rounded
            // copy of it, so the tiling has no tail gap.
            let start = CMTime(seconds: t0, preferredTimescale: 600)
            let end = i + 1 < boundaries.count ? CMTime(seconds: t1, preferredTimescale: 600) : assetDuration
            instructions.append(TimelineInstruction(
                timeRange: CMTimeRange(start: start, end: end),
                settings: settings,
                fillerTrackID: fillerComp.trackID,
                main: main, overlays: overlays, texts: texts
            ))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = DemoCompositor.self
        videoComposition.renderSize = CGSize(width: document.canvas.width, height: document.canvas.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.instructions = instructions

        return BuiltTimeline(asset: composition, videoComposition: videoComposition,
                             duration: composition.duration, fps: fps)
    }

    private static func resolve(_ source: MediaSource, project: EditProject, canvas: Canvas) async throws -> ResolvedSource {
        switch source {
        case .text:
            return ResolvedSource(assetTrack: nil, asset: nil, width: canvas.width, height: canvas.height,
                                  imageURL: nil, eventTrack: nil, captions: nil)

        case .file(_, let kind) where kind == .image:
            guard let url = project.url(for: source) else { throw BuildError.missingMedia("\(source)") }
            let size = imageSize(at: url) ?? CGSize(width: canvas.width, height: canvas.height)
            return ResolvedSource(assetTrack: nil, asset: nil, width: Int(size.width), height: Int(size.height),
                                  imageURL: url, eventTrack: nil, captions: nil)

        default:
            guard let url = project.url(for: source) else { throw BuildError.missingMedia("\(source)") }
            let asset = AVURLAsset(url: url)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let natural = (try? await track?.load(.naturalSize)) ?? CGSize(width: canvas.width, height: canvas.height)
            let recording = project.recordingPackage(for: source)
            let eventTrack = try? recording?.readEventTrack()
            return ResolvedSource(
                assetTrack: track, asset: asset,
                width: eventTrack?.pixelWidth ?? Int(natural.width),
                height: eventTrack?.pixelHeight ?? Int(natural.height),
                imageURL: nil, eventTrack: eventTrack, captions: recording?.readCaptions()
            )
        }
    }

    private static func imageSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
}
