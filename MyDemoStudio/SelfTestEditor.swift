import Foundation
import AVFoundation
import AppKit

/// Headless validation of the editor's glue layer, run with `MDS_SELFTEST=editor`.
///
/// The render pipeline is covered by `SelfTestTimeline`; this covers what sits *between*
/// the UI and the pipeline — loading a project, building a live preview (video + mixed
/// audio), editing through the model, undo, autosave, and picking up an external edit
/// made by the MCP server.
@MainActor
enum SelfTestEditor {

    static func run() async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        log("editor checks starting")
        var ok = true

        // Build a throwaway project seeded from a real library recording, so this test
        // exercises the same path the app uses on the user's own clips.
        guard let clip = ClipLibrary.all().first(where: { $0.duration > 6 }) else {
            log("SKIP no library recording long enough to test with")
            return true
        }
        log("using clip '\(clip.name)' (\(fmt(clip.duration))s)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MDSEditorTest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Point at a real project instead of a synthesized one, for reproducing a problem
        // seen in the app: MDS_SELFTEST_PROJECT=<name>.
        if let name = ProcessInfo.processInfo.environment["MDS_SELFTEST_PROJECT"],
           let existing = ProjectLibrary.all().first(where: { $0.name == name || $0.id == name }) {
            log("opening existing project '\(existing.name)'")
            guard let model = TimelineEditorModel(project: existing) else {
                log("FAIL model would not initialise"); return false
            }
            var waited = 0.0
            while !model.isReady, model.buildError == nil, waited < 30 {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 0.2
            }
            var ok = expect(model.buildError == nil, "preview built (\(model.buildError ?? "none"))")
            ok = await expectValidComposition(model) && ok
            // Sample away from t=0: a clip with a fade-in is legitimately black there.
            for probe in [1.5, 5.0, 12.0] {
                model.seek(to: probe)
                try? await Task.sleep(for: .milliseconds(400))
                ok = await expectFirstFrame(model, label: "t=\(probe)s") && ok
            }
            log(ok ? "PASS existing-project checks" : "FAIL existing-project checks")
            return ok
        }

        let project: EditProject
        do {
            project = try EditProject.create(named: "editor", canvas: .fullHD, in: root)
            try project.update { document in
                guard let track = document.tracks.first(where: { $0.kind == .main }) else { return }
                var placed = clip.makeTimelineClip()
                placed.sourceOut = min(clip.duration, 6)
                document.add(placed, toTrack: track.id, at: 0)
                // A second clip and a text card, so the video composition is cut into
                // several instructions — a single-instruction project would not exercise
                // the same playback path the real editor uses.
                var second = clip.makeTimelineClip()
                second.sourceIn = 8
                second.sourceOut = min(clip.duration, 14)
                document.add(second, toTrack: track.id, at: 6)
                if let overlay = document.tracks.first(where: { $0.kind == .overlay }) {
                    var text = TimelineClip(source: .text, start: 2, sourceIn: 0, sourceOut: 2, name: "Card")
                    text.text = TextOverlay(string: "Hello")
                    document.add(text, toTrack: overlay.id, at: 2)
                }
                // Screen recordings are often video-only (mic off), so lean on the click
                // and keystroke effects to guarantee the mix has something in it.
                document.defaultLook.sfxEnabled = true
            }
        } catch {
            log("FAIL project setup: \(error)"); return false
        }

        guard let model = TimelineEditorModel(project: project) else {
            log("FAIL model would not initialise"); return false
        }

        // The preview builds asynchronously; give it a bounded window to become ready.
        var waited = 0.0
        while !model.isReady, model.buildError == nil, waited < 30 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        ok = expect(model.buildError == nil, "preview built without error (\(model.buildError ?? "none"))") && ok
        ok = expect(model.isReady, "preview ready after \(fmt(waited))s") && ok
        ok = expect(abs(model.duration - 12) < 0.2, "model duration is 12s (got \(fmt(model.duration)))") && ok

        // The preview item must carry both the composited video and the mixed audio,
        // otherwise the editor would play silently while the export has sound.
        if let asset = (model.player.currentItem?.asset as? AVMutableComposition) {
            let video = asset.tracks(withMediaType: .video).count
            let audio = asset.tracks(withMediaType: .audio).count
            ok = expect(video >= 1, "preview composition has video tracks (\(video))") && ok
            ok = expect(audio >= 1, "preview composition has mixed audio (\(audio))") && ok
            ok = expect(model.player.currentItem?.videoComposition != nil, "preview uses the custom compositor") && ok
        } else {
            ok = expect(false, "preview player has a composition"); ok = false
        }

        // AVPlayer validates a video composition far more strictly than AVAssetReader
        // does: instructions must tile the whole timeline with no gaps or overlaps, or
        // playback silently shows black even though export renders fine.
        ok = await expectValidComposition(model) && ok

        // The composition must decode at t=0, so a freshly opened project has something
        // to show before you press play.
        ok = await expectFirstFrame(model) && ok

        // Editing through the model: split, then speed, then undo.
        guard let first = model.document.tracks.first(where: { $0.kind == .main })?.clips.first else {
            log("FAIL no clip on the main track"); return false
        }
        model.selectedClipID = first.id
        model.seek(to: 3.0)
        model.splitAtPlayhead()
        let mainClips = model.document.tracks.first(where: { $0.kind == .main })?.clips.count ?? 0
        ok = expect(mainClips == 3, "split produced a third clip (got \(mainClips))") && ok

        // Speeding a clip up shortens that clip but deliberately does *not* ripple: the
        // clips after it stay where they are, leaving a gap to close explicitly.
        model.edit("speed") { $0.setSpeed(clipID: first.id, speed: 2.0) }
        let spedUp = model.document.clip(id: first.id)?.duration ?? 0
        ok = expect(abs(spedUp - 1.5) < 0.05, "2× halves the 3s clip to 1.5s (got \(fmt(spedUp)))") && ok
        ok = expect(abs(model.duration - 12.0) < 0.2,
                    "the later clips stay put, so the total is still 12s (got \(fmt(model.duration)))") && ok

        // Autosave: the change must already be on disk, since that's what the MCP server
        // and the next launch will read.
        let onDisk = try? project.read()
        ok = expect(onDisk == model.document, "document autosaved to disk after the edit") && ok

        model.undo()
        let undone = model.document.clip(id: first.id)?.duration ?? 0
        ok = expect(abs(undone - 3.0) < 0.05, "undo restores the clip to 3s (got \(fmt(undone)))") && ok
        model.redo()
        let redone = model.document.clip(id: first.id)?.duration ?? 0
        ok = expect(abs(redone - 1.5) < 0.05, "redo reapplies 2× (got \(fmt(redone)))") && ok

        // Closing the gap is what actually shortens the timeline.
        if let mainTrackID = model.document.tracks.first(where: { $0.kind == .main })?.id {
            model.edit("compact") { $0.compact(trackID: mainTrackID) }
            ok = expect(abs(model.duration - 10.5) < 0.1,
                        "closing gaps gives 1.5s + 3s + 6s = 10.5s (got \(fmt(model.duration)))") && ok
        }

        // An external edit (what the MCP server does) must be picked up by the open editor.
        try? project.update { document in
            guard let track = document.tracks.first(where: { $0.kind == .overlay }) else { return }
            var text = TimelineClip(source: .text, start: 0, sourceIn: 0, sourceOut: 2, name: "External")
            text.text = TextOverlay(string: "From MCP")
            document.add(text, toTrack: track.id, at: 0)
        }
        var externalSeen = false
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(150))
            if model.document.tracks.contains(where: { $0.kind == .overlay && !$0.clips.isEmpty }) {
                externalSeen = true
                break
            }
        }
        ok = expect(externalSeen, "editor picked up an external (MCP-style) document edit") && ok

        log(ok ? "PASS all editor checks" : "FAIL editor checks")
        return ok
    }

    /// Asks AVFoundation itself whether the preview's video composition is well formed.
    private static func expectValidComposition(_ model: TimelineEditorModel) async -> Bool {
        guard let item = model.player.currentItem,
              let composition = item.videoComposition,
              let asset = item.asset as? AVComposition else {
            return expect(false, "preview has a video composition to validate")
        }
        let duration = (try? await asset.load(.duration)) ?? .zero
        let delegate = ValidationRecorder()
        let valid = (try? await composition.isValid(for: asset,
                                                    timeRange: CMTimeRange(start: .zero, duration: .positiveInfinity),
                                                    validationDelegate: delegate)) ?? false
        var ok = expect(valid, "video composition is valid for playback"
                        + (delegate.problems.isEmpty ? "" : " — \(delegate.problems.joined(separator: "; "))"))

        // Instructions must reach the very end of the composition, or the tail plays black.
        let covered = composition.instructions.last.map { CMTimeGetSeconds($0.timeRange.end) } ?? 0
        let assetSeconds = CMTimeGetSeconds(duration)
        ok = expect(abs(covered - assetSeconds) < 0.05,
                    "instructions cover the whole asset (\(fmt(covered))s of \(fmt(assetSeconds))s)") && ok
        return ok
    }

    /// Captures why AVFoundation considers a composition invalid.
    private final class ValidationRecorder: NSObject, AVVideoCompositionValidationHandling {
        var problems: [String] = []

        private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

        func videoComposition(_ videoComposition: AVVideoComposition,
                              shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
            problems.append("invalid value for \(key)")
            return true
        }

        func videoComposition(_ videoComposition: AVVideoComposition,
                              shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
            problems.append("empty range at \(fmt(CMTimeGetSeconds(timeRange.start)))s for \(fmt(CMTimeGetSeconds(timeRange.duration)))s")
            return true
        }

        func videoComposition(_ videoComposition: AVVideoComposition,
                              shouldContinueValidatingAfterFindingInvalidTimeRangeIn instruction: any AVVideoCompositionInstructionProtocol) -> Bool {
            problems.append("invalid time range \(fmt(CMTimeGetSeconds(instruction.timeRange.start)))s+\(fmt(CMTimeGetSeconds(instruction.timeRange.duration)))s")
            return true
        }

        func videoComposition(_ videoComposition: AVVideoComposition,
                              shouldContinueValidatingAfterFindingInvalidTrackIDIn instruction: any AVVideoCompositionInstructionProtocol,
                              layerInstruction: AVVideoCompositionLayerInstruction,
                              asset: AVAsset) -> Bool {
            problems.append("invalid track id in an instruction")
            return true
        }
    }

    /// Pulls a real pixel buffer out of the preview player at the playhead. This proves
    /// the preview *composition decodes* at t=0 — it does not prove `AVPlayerLayer` has
    /// painted, since the output decodes independently of what the layer displays.
    private static func expectFirstFrame(_ model: TimelineEditorModel, label: String = "playhead") async -> Bool {
        guard let item = model.player.currentItem else {
            return expect(false, "preview has a player item")
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)

        var buffer: CVPixelBuffer?
        for _ in 0..<60 {
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
               let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                buffer = pixels
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        item.remove(output)

        guard let buffer else {
            return expect(false, "preview decodes a frame at \(label)")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var ok = expect(width > 0 && height > 0,
                        "preview decodes a frame at \(label) (\(width)×\(height))")

        // Size alone proves nothing — a black frame is still a frame. Sample the actual
        // pixels: the background alone guarantees a non-black picture.
        let mean = meanBrightness(buffer)
        ok = expect(mean > 0.03,
                    "preview frame at \(label) has picture (mean brightness \(String(format: "%.4f", mean)))") && ok
        return ok
    }

    /// Average brightness of a BGRA pixel buffer, 0…1.
    private static func meanBrightness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var total = 0.0
        var count = 0.0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let i = y * bytesPerRow + x * 4
                total += (Double(pointer[i]) + Double(pointer[i + 1]) + Double(pointer[i + 2])) / (3 * 255)
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }

    private static func expect(_ condition: Bool, _ description: String) -> Bool {
        log((condition ? "ok   " : "FAIL ") + description)
        return condition
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }
    private static func log(_ message: String) { print("SELFTEST: \(message)") }
}
