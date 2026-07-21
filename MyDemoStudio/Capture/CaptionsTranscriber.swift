import Foundation
import AVFoundation
import Speech

/// On-device voiceover transcription using macOS 26's SpeechAnalyzer / SpeechTranscriber.
/// Produces timed `CaptionSegment`s from the master movie's audio track.
enum CaptionsTranscriber {

    enum TranscribeError: Error {
        case noAudio
        case notAvailable
    }

    /// Transcribes the audio at `url` into caption segments. Segments are split from
    /// the transcriber's timed results (which carry `audioTimeRange`).
    static func transcribe(audioURL url: URL, locale: Locale = .current) async throws -> [CaptionSegment] {
        // Pick a supported locale, falling back to en-US.
        let supported = await SpeechTranscriber.supportedLocales
        let chosen = supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
            ? locale : Locale(identifier: "en-US")

        let transcriber = SpeechTranscriber(
            locale: chosen,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Ensure the on-device model for this locale is installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        // Collect timed results concurrently while the file is analyzed.
        async let collected: [CaptionSegment] = {
            var segments: [CaptionSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = result.range
                segments.append(CaptionSegment(
                    start: range.start.seconds,
                    end: range.end.seconds,
                    text: text
                ))
            }
            return segments
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await collected.map(splitLongSegment).flatMap { $0 }
    }

    /// Splits an over-long caption into readable ~6-word chunks spread across its window.
    private static func splitLongSegment(_ segment: CaptionSegment) -> [CaptionSegment] {
        let words = segment.text.split(separator: " ").map(String.init)
        guard words.count > 8 else { return [segment] }
        let chunkSize = 6
        let chunks = stride(from: 0, to: words.count, by: chunkSize).map {
            words[$0..<min($0 + chunkSize, words.count)].joined(separator: " ")
        }
        let span = segment.end - segment.start
        let per = span / Double(chunks.count)
        return chunks.enumerated().map { i, text in
            CaptionSegment(start: segment.start + Double(i) * per,
                           end: segment.start + Double(i + 1) * per,
                           text: text)
        }
    }
}
