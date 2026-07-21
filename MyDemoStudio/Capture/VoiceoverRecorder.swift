import Foundation
import AVFoundation
import Observation

/// Records a voiceover take from the microphone *after* the screen recording exists —
/// you play the timeline, talk over it, and the take lands on the timeline at the
/// playhead where you started.
///
/// Writes LPCM WAV at the mixer's sample rate for the same reason `AudioMixer` does:
/// no AAC encoder priming, so the take inserts into a composition without drifting.
@MainActor
@Observable
final class VoiceoverRecorder {

    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    /// Smoothed input level, 0…1 — drives the meter while recording.
    private(set) var level: Double = 0
    private(set) var errorMessage: String?

    /// Timeline position the current take started at, so it can be placed on stop.
    private(set) var punchInTime: Double = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?

    /// Asks for microphone access, prompting on first use.
    static func requestAccess() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    @discardableResult
    func start(to url: URL, punchInAt timelineTime: Double) -> Bool {
        guard !isRecording else { return true }
        errorMessage = nil
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioMixer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "The microphone could not start."
                return false
            }
            self.recorder = recorder
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        punchInTime = timelineTime
        startedAt = Date()
        elapsed = 0
        isRecording = true

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        // -60 dBFS reads as silence; map the useful range onto 0…1.
        let db = Double(recorder.averagePower(forChannel: 0))
        let normalized = max(0, min((db + 60) / 60, 1))
        level += (normalized - level) * 0.4
        elapsed = startedAt.map { -$0.timeIntervalSinceNow } ?? 0
    }

    /// Stops the take and returns its duration in seconds (0 if nothing was captured).
    @discardableResult
    func stop() -> Double {
        guard isRecording, let recorder else { return 0 }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRecording = false
        level = 0
        return duration
    }
}
