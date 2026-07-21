import Foundation
import AVFoundation
import CoreMedia

/// Mixes down every audio-bearing clip on a timeline into one file: source audio placed,
/// trimmed, speed-warped and level-ramped by AVFoundation, then the synthesized click and
/// keystroke effects layered on top per screen recording.
///
/// The result is a single LPCM WAV that `VideoExporter.mux` muxes into the video, and that
/// the editor attaches to the preview composition — one mix, so preview matches export.
/// Reuses `AudioMixer`'s SFX synthesis and WAV writer verbatim.
enum TimelineAudioMixer {

    static let sampleRate = AudioMixer.sampleRate

    /// Returns the mixed audio file, or nil when the project has no audible content.
    @concurrent
    static func build(project: EditProject, document: EditDocument) async throws -> URL? {
        let total = document.duration
        guard total > 0.01 else { return nil }

        let totalFrames = max(1, Int((total + 0.2) * sampleRate))
        var buffer = [Float](repeating: 0, count: totalFrames)
        var wroteAnything = false

        // 1. Source audio: one composition track per document track, so each track's
        //    clips can carry their own volume ramps in a single AVAudioMix parameter set.
        if let composed = try? await composeSourceAudio(project: project, document: document),
           let samples = try? await render(composition: composed.composition, audioMix: composed.audioMix, frames: totalFrames) {
            for i in 0..<min(samples.count, buffer.count) { buffer[i] += samples[i] }
            wroteAnything = composed.hadContent
        }

        // 2. Click / keystroke effects, per recording clip that has them enabled.
        let click = AudioMixer.makeClick()
        let key = AudioMixer.makeKey()
        for track in document.tracks where !track.muted {
            for clip in track.clips {
                guard case .recording = clip.source else { continue }
                let settings = clip.look?.applied(to: document.defaultLook) ?? document.defaultLook
                guard settings.sfxEnabled, settings.sfxVolume > 0.001 else { continue }
                guard let recording = project.recordingPackage(for: clip.source),
                      let events = try? recording.readEventTrack() else { continue }

                let gain = Float(settings.sfxVolume * clip.volume * track.volume)
                for event in events.events {
                    // Only events inside the clip's source window survive the trim, and
                    // their timeline position follows the same speed warp as the picture.
                    guard event.t >= clip.sourceIn, event.t < clip.sourceOut else { continue }
                    let timelineTime = clip.start + (event.t - clip.sourceIn) / max(clip.speed, 0.01)
                    let frame = Int(timelineTime * sampleRate)
                    switch event.type {
                    case .leftMouseDown, .rightMouseDown:
                        AudioMixer.mix(click, into: &buffer, at: frame, gain: gain)
                        wroteAnything = true
                    case .keyDown:
                        AudioMixer.mix(key, into: &buffer, at: frame, gain: gain * 0.85)
                        wroteAnything = true
                    default:
                        break
                    }
                }
            }
        }

        guard wroteAnything else { return nil }
        for i in buffer.indices { buffer[i] = max(-1, min(1, buffer[i])) }
        return try AudioMixer.writeWAV(buffer)
    }

    private struct ComposedAudio {
        let composition: AVMutableComposition
        let audioMix: AVMutableAudioMix
        let hadContent: Bool
    }

    /// Places every audio-bearing clip into an audio-only composition, applying trim,
    /// speed and per-clip volume/fade ramps.
    private static func composeSourceAudio(project: EditProject, document: EditDocument) async throws -> ComposedAudio {
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        var hadContent = false

        for track in document.tracks where !track.muted && !(track.kind != .audio && track.hidden) {
            let audioClips = track.clips
                .filter { $0.source.carriesAudio && $0.volume > 0.0001 }
                .sorted { $0.start < $1.start }
            guard !audioClips.isEmpty else { continue }
            guard let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let params = AVMutableAudioMixInputParameters(track: compTrack)

            for clip in audioClips {
                guard let url = project.url(for: clip.source) else { continue }
                let asset = AVURLAsset(url: url)
                guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first else { continue }

                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: clip.sourceIn, preferredTimescale: 600),
                    duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
                )
                let at = CMTime(seconds: clip.start, preferredTimescale: 600)
                do {
                    try compTrack.insertTimeRange(sourceRange, of: sourceTrack, at: at)
                } catch {
                    continue
                }
                if abs(clip.speed - 1.0) > 0.001 {
                    compTrack.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration),
                                             toDuration: CMTime(seconds: clip.duration, preferredTimescale: 600))
                }
                hadContent = true

                // Volume: a flat level for the clip, with ramps at the edges if it fades.
                let level = Float(clip.volume * track.volume)
                let clipRange = CMTimeRange(start: at, duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
                params.setVolume(level, at: at)
                if clip.fadeIn > 0.0001 {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                         timeRange: CMTimeRange(start: at, duration: CMTime(seconds: min(clip.fadeIn, clip.duration), preferredTimescale: 600)))
                }
                if clip.fadeOut > 0.0001 {
                    let fade = min(clip.fadeOut, clip.duration)
                    let start = CMTimeAdd(clipRange.end, CMTime(seconds: -fade, preferredTimescale: 600))
                    params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: start, duration: CMTime(seconds: fade, preferredTimescale: 600)))
                }
            }
            parameters.append(params)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        return ComposedAudio(composition: composition, audioMix: audioMix, hadContent: hadContent)
    }

    /// Decodes the composed audio (through the mix) into a mono float buffer.
    @concurrent
    private static func render(composition: AVMutableComposition, audioMix: AVAudioMix, frames: Int) async throws -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: composition) else { return out }

        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = audioMix
        guard reader.canAdd(output) else { return out }
        reader.add(output)
        guard reader.startReading() else { return out }

        var frame = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for value in data {
                if frame >= out.count { break }
                out[frame] = value
                frame += 1
            }
        }
        return out
    }
}
