import Foundation
import AVFoundation

/// Builds the final audio track for export: the voiceover (from the master movie) mixed
/// with subtle, soft click/keystroke sound effects placed at each input event's time.
enum AudioMixer {

    static let sampleRate: Double = 44_100

    /// Produces a mixed mono audio file, or nil if there's nothing to render (no voiceover
    /// and SFX disabled). Caller muxes the returned file's audio into the video.
    @concurrent
    static func buildMixedAudio(
        masterURL: URL,
        eventTrack: EventTrack,
        settings: RenderSettings,
        duration: Double
    ) async throws -> URL? {
        let hasVoiceover = await masterHasAudio(masterURL)
        guard settings.sfxEnabled || hasVoiceover else { return nil }

        let totalFrames = max(1, Int((duration + 0.2) * sampleRate))
        var buffer = [Float](repeating: 0, count: totalFrames)

        // 1. Voiceover.
        if hasVoiceover, settings.voiceoverVolume > 0.001 {
            await addVoiceover(masterURL: masterURL, into: &buffer, gain: Float(settings.voiceoverVolume))
        }

        // 2. Sound effects at each click / keystroke.
        if settings.sfxEnabled {
            let click = makeClick()
            let key = makeKey()
            let gain = Float(settings.sfxVolume)
            for event in eventTrack.events {
                let frame = Int(event.t * sampleRate)
                switch event.type {
                case .leftMouseDown, .rightMouseDown:
                    mix(click, into: &buffer, at: frame, gain: gain)
                case .keyDown:
                    mix(key, into: &buffer, at: frame, gain: gain * 0.85)
                default:
                    break
                }
            }
        }

        // Soft-clip to avoid overs.
        for i in buffer.indices {
            let v = buffer[i]
            buffer[i] = max(-1, min(1, v))
        }

        return try writeWAV(buffer)
    }

    // MARK: Voiceover read

    private static func masterHasAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
    }

    private static func addVoiceover(masterURL: URL, into buffer: inout [Float], gain: Float) async {
        let asset = AVURLAsset(url: masterURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        var frame = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for value in data {
                if frame >= buffer.count { break }
                buffer[frame] += value * gain
                frame += 1
            }
        }
    }

    // MARK: SFX synthesis (subtle & soft)

    private static func makeClick() -> [Float] {
        let n = Int(0.045 * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var noise: Float = 0
        var seed: UInt32 = 22_222
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = Float(exp(-t / 0.010))
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed >> 9) / Float(1 << 23) * 2 - 1
            noise = noise * 0.6 + white * 0.4
            let thump = Float(sin(2 * .pi * 160 * t)) * Float(exp(-t / 0.008))
            out[i] = (noise * 0.5 + thump * 0.6) * env * 0.65
        }
        return out
    }

    private static func makeKey() -> [Float] {
        let n = Int(0.028 * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var noise: Float = 0
        var seed: UInt32 = 99_173
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = Float(exp(-t / 0.006))
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed >> 9) / Float(1 << 23) * 2 - 1
            noise = noise * 0.3 + white * 0.7           // brighter tick
            out[i] = noise * env * 0.48
        }
        return out
    }

    private static func mix(_ sample: [Float], into buffer: inout [Float], at frame: Int, gain: Float) {
        guard frame >= 0 else { return }
        for i in 0..<sample.count {
            let idx = frame + i
            if idx >= buffer.count { break }
            buffer[idx] += sample[i] * gain
        }
    }

    // MARK: Write

    private static func writeWAV(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mds_mix_\(UUID().uuidString).wav")
        // LPCM Int16 WAV: no AAC priming, so it inserts cleanly into an AVMutableComposition
        // and passthroughs into a .mov.
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: wavSettings)
        // Buffers MUST be in the file's processing format, or write(from:) throws.
        let format = file.processingFormat
        let chunk = 8_192
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = pcm.floatChannelData?[0] else { break }
            pcm.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { channel[i] = samples[offset + i] }
            try file.write(from: pcm)
            offset += count
        }
        return url
    }
}
