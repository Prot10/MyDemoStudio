import Foundation
import AVFoundation
import CoreMedia

/// The assembled composition that `DemoCompositor` renders: the master screen track,
/// plus an optional webcam track, with the geometry the compositor needs.
struct BuiltAsset {
    let asset: AVMutableComposition
    let masterTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let duration: CMTime
    let fps: Int
    let masterWidth: Int
    let masterHeight: Int
}

/// Builds the composition + video composition that drive `DemoCompositor`. Shared by
/// the live editor preview and the exporter so preview matches export. Split in two so
/// the editor can rebuild only the (cheap) video composition on each settings change
/// while keeping the (expensive) multi-track asset.
enum CompositionBuilder {

    /// Assembles the master (and optional camera) tracks into one composition.
    static func buildAsset(masterURL: URL, cameraURL: URL?) async throws -> BuiltAsset {
        let masterAsset = AVURLAsset(url: masterURL)
        guard let masterVideo = try await masterAsset.loadTracks(withMediaType: .video).first else {
            throw VideoExporter.ExportError.noVideoTrack
        }
        let duration = try await masterAsset.load(.duration)
        let nominal = (try? await masterVideo.load(.nominalFrameRate)) ?? 60
        let fps = nominal > 1 ? Int(nominal.rounded()) : 60
        let size = (try? await masterVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoExporter.ExportError.writerFailed("compose master")
        }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: masterVideo, at: .zero)

        var cameraTrackID: CMPersistentTrackID?
        if let cameraURL, FileManager.default.fileExists(atPath: cameraURL.path) {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if let cameraVideo = try? await cameraAsset.loadTracks(withMediaType: .video).first,
               let compCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let cameraDuration = (try? await cameraAsset.load(.duration)) ?? duration
                let range = CMTimeRange(start: .zero, duration: min(duration, cameraDuration))
                try? compCamera.insertTimeRange(range, of: cameraVideo, at: .zero)
                cameraTrackID = compCamera.trackID
            }
        }

        return BuiltAsset(
            asset: composition,
            masterTrackID: compVideo.trackID,
            cameraTrackID: cameraTrackID,
            duration: duration,
            fps: fps,
            masterWidth: Int(size.width),
            masterHeight: Int(size.height)
        )
    }

    /// Rebuilds the video composition (custom compositor + instruction) for the given
    /// settings. Cheap — safe to call on every edit.
    static func videoComposition(settings: RenderSettings, eventTrack: EventTrack, built: BuiltAsset, captions: CaptionTrack? = nil) -> AVMutableVideoComposition {
        let smoother = CursorSmoother(track: eventTrack, smoothing: settings.cursorSmoothing)
        let planner = ZoomPlanner(track: eventTrack, settings: settings)
        let zoomAt: (@Sendable (Double) -> ZoomState)? = planner.isEmpty ? nil : { @Sendable t in planner.zoom(at: t) }

        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = DemoCompositor.self
        composition.renderSize = CGSize(width: settings.outputWidth, height: settings.outputHeight)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(built.fps, 1)))
        composition.instructions = [
            DemoInstruction(
                timeRange: CMTimeRange(start: .zero, duration: built.duration),
                masterTrackID: built.masterTrackID,
                cameraTrackID: built.cameraTrackID,
                settings: settings,
                masterWidth: eventTrack.pixelWidth,
                masterHeight: eventTrack.pixelHeight,
                smoother: smoother,
                zoomAt: zoomAt,
                captionTrack: captions
            )
        ]
        return composition
    }
}
