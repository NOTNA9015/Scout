import Foundation
import Speech
import AVFoundation

/// Full-file analysis: no dictation time limit, server transcription, or microphone session.
enum LocalLyricTranscriber {
    static func supportedLanguages() async -> [Locale] { await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier } }
    static func transcribe(_ audio: URL, duration: Double, locale: Locale,
                           progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let words = try await recognize(audio, duration: duration, locale: locale, vocabulary: [], progress: progress)
        let text = TimedLyricWord.enhancedLRC(words)
        guard !text.isEmpty else { throw ScoutError.message("No vocals could be recognized in this audio. You can import lyrics for this version.") }
        return text
    }
    /// Recognized words with their measured audio times. `vocabulary` (e.g. the known
    /// lyric words) biases recognition toward the words actually sung.
    /// Whether the model for `locale` is already on this iPhone (no download needed).
    static func isReady(_ locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }
    static func recognize(_ audio: URL, duration: Double, locale: Locale, vocabulary: [String],
                          progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
        guard duration.isFinite, duration > 0, duration <= 1800 else {
            throw ScoutError.message("On-device timing supports tracks up to 30 minutes.")
        }
        guard SpeechTranscriber.isAvailable else {
            throw ScoutError.message("Apple's on-device transcription is unavailable on this iPhone.")
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ScoutError.message("On-device transcription does not support \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier). Choose another language.")
        }
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("Downloading \(supported.localizedString(forIdentifier: supported.identifier) ?? supported.identifier) speech model…")
            let updates = Task {
                while !Task.isCancelled {
                    let percent = Int(download.progress.fractionCompleted * 100)
                    progress("Downloading speech model · \(percent)%")
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            defer { updates.cancel() }
            try await withTaskCancellationHandler {
                try await download.downloadAndInstall()
            } onCancel: { download.progress.cancel() }
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw ScoutError.message("The speech model is not installed. Connect to the internet and retry the download.")
        }
        // Always decode once to exact-length PCM. Compressed MP3/AAC files report
        // padded lengths through AVAudioFile, which ends analysis with eofErr (-39).
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ScoutLyrics-" + UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        progress("Preparing local audio…")
        try await decode(audio, to: scratch)
        let file = try AVAudioFile(forReading: scratch)
        guard file.length > 0 else { throw ScoutError.message("This local file has no readable audio.") }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(1000))
            try? await analyzer.setContext(context)
        }
        progress("Listening to local audio…")
        return try await withTaskCancellationHandler {
            let collector = Task { () throws -> [TimedLyricWord] in
                var words: [TimedLyricWord] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        let text = String(result.text[run.range].characters)
                        words.append(.init(start: range.start.seconds, end: CMTimeRangeGetEnd(range).seconds, text: text))
                    }
                    let percent = min(99, Int(CMTimeRangeGetEnd(result.range).seconds / duration * 100))
                    progress("Timing vocals on this iPhone · \(percent)%")
                }
                return words
            }
            do {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
                let words = try await collector.value
                try Task.checkCancellation()
                return TimedLyricWord.refined(words)
            } catch {
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                throw error
            }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }

    private static func decode(_ audio: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: audio)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ScoutError.message("This local file has no readable audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let stream = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
        reader.add(stream)
        guard reader.startReading() else { throw reader.error ?? ScoutError.message("Could not decode this audio.") }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        // Keep the vocal band: bass and kick under ~150 Hz and hiss over ~6 kHz mostly
        // confuse recognition and blur where words begin.
        var highPass = Biquad.highPass(150, rate: 16000), lowPass = Biquad.lowPass(6000, rate: 16000)
        let destination = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        while let sample = stream.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMSampleBufferGetNumSamples(sample)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let pointer = buffer.int16ChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: pointer)
            guard status == kCMBlockBufferNoErr else { throw ScoutError.message("Could not read the decoded audio.") }
            for i in 0..<count {
                let value = lowPass.process(highPass.process(Double(pointer[i])))
                pointer[i] = Int16(max(-32768, min(32767, value.rounded())))
            }
            try destination.write(from: buffer)
        }
        guard reader.status == .completed else { throw reader.error ?? ScoutError.message("Audio decoding did not finish.") }
    }
}

/// Second-order IIR section (RBJ cookbook), run once over the decoded mono PCM.
private struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    static func highPass(_ frequency: Double, rate: Double) -> Biquad { make(frequency, rate: rate, high: true) }
    static func lowPass(_ frequency: Double, rate: Double) -> Biquad { make(frequency, rate: rate, high: false) }
    private static func make(_ frequency: Double, rate: Double, high: Bool) -> Biquad {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * 0.7071), c = cos(w), a0 = 1 + alpha
        var f = Biquad()
        if high { f.b0 = (1 + c) / 2 / a0; f.b1 = -(1 + c) / a0; f.b2 = (1 + c) / 2 / a0 }
        else { f.b0 = (1 - c) / 2 / a0; f.b1 = (1 - c) / a0; f.b2 = (1 - c) / 2 / a0 }
        f.a1 = -2 * c / a0; f.a2 = (1 - alpha) / a0
        return f
    }
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}
