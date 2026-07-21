import Foundation
import AVFoundation

/// Records the default webcam to a `camera.mov` alongside the screen capture. The
/// render pipeline composites it as a circular bubble; the two clips start together,
/// which is close enough for a corner overlay.
final class WebcamRecorder: NSObject, @unchecked Sendable {

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.andrea.mydemostudio.webcam")
    private(set) var isRecording = false

    /// Starts webcam capture to `url`. Returns false if no camera / permission.
    @discardableResult
    func start(to url: URL) -> Bool {
        guard !isRecording else { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }

        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) } else { session.commitConfiguration(); return false }
        if session.canAddOutput(output) { session.addOutput(output) } else { session.commitConfiguration(); return false }
        session.commitConfiguration()

        try? FileManager.default.removeItem(at: url)
        session.startRunning()
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        return true
    }

    /// Stops capture and finalizes the file.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if output.isRecording { output.stopRecording() }
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

extension WebcamRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        if let error {
            NSLog("MyDemoStudio: webcam recording error: \(error.localizedDescription)")
        }
    }
}
