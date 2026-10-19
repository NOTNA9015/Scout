import Foundation
import AVFoundation

/// File headers and decoded audio determine the format; a host's suffix is only a hint.
enum AudioCompatibility {
    struct Envelope { var ext: String; var audioOffset: UInt64 }
    struct Info { var codec: AudioFormatID; var duration: Double; var rate: Double; var channels: AVAudioChannelCount }

    static func envelope(_ url: URL) throws -> Envelope {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = [UInt8](try file.read(upToCount: 12) ?? Data()), offset: UInt64 = 0
        if bytes.count >= 10, Array(bytes.prefix(3)) == Array("ID3".utf8) {
            guard (2...4).contains(bytes[3]), bytes[6...9].allSatisfy({ $0 < 128 }) else { throw ScoutError.message("The audio has an invalid ID3 header.") }
            offset = UInt64(10 + (Int(bytes[6]) << 21) + (Int(bytes[7]) << 14) + (Int(bytes[8]) << 7) + Int(bytes[9]))
            if bytes[3] == 4 && bytes[5] & 0x10 != 0 { offset += 10 }
            try file.seek(toOffset: offset)
            bytes = [UInt8](try file.read(upToCount: 12) ?? Data())
        }
        func starts(_ text: String) -> Bool { bytes.starts(with: Array(text.utf8)) }
        let ext: String
        if starts("fLaC") { ext = "flac" }
        else if starts("RIFF") || starts("RF64") { ext = "wav" }
        else if starts("FORM") { ext = "aiff" }
        else if starts("caff") { ext = "caf" }
        else if starts("OggS") { ext = "ogg" }
        else if bytes.count >= 8 && Array(bytes[4..<8]) == Array("ftyp".utf8) { ext = "m4a" }
        else if bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xf6 == 0xf0 { ext = "aac" }
        else if bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0 && bytes[1] & 0x06 == 0x02 { ext = "mp3" }
        else { throw ScoutError.message("This file does not contain supported audio. It may be a download page or an unavailable tracker file.") }
        // Older Scout builds could put an MP3 tag in front of a different audio format.
        return Envelope(ext: ext, audioOffset: ext == "mp3" || ext == "aac" ? 0 : offset)
    }

    static func normalizedCopy(_ source: URL, into folder: URL) throws -> URL {
        let format = try envelope(source)
        let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.ext)
        if format.audioOffset == 0 { try FileManager.default.copyItem(at: source, to: target) }
        else {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try input.seek(toOffset: format.audioOffset)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ScoutError.message("Could not stage the audio file.") }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
        }
        return target
    }

    static func inspect(_ url: URL) throws -> Info {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, format.channelCount > 0 else { throw ScoutError.message("The file has no readable audio.") }
        return Info(codec: format.streamDescription.pointee.mFormatID, duration: duration, rate: format.sampleRate, channels: format.channelCount)
    }

    static func isSpotifyCompatible(_ info: Info, file: URL) -> Bool {
        if info.codec == kAudioFormatMPEGLayer3 { return true }
        return info.codec == kAudioFormatMPEG4AAC && file.pathExtension == "m4a" &&
            [44_100.0, 48_000.0].contains(info.rate) && info.channels <= 2
    }

    /// AAC-LC, 44.1 kHz, mono/stereo. The source stays untouched.
    static func encodeAAC(from source: URL, to target: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let channels = min(2, input.processingFormat.channelCount)
        let output = try AVAudioFile(forWriting: target, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 8192) else {
            throw ScoutError.message("This audio format cannot be converted.")
        }
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { count, state in
                guard input.framePosition < input.length else { state.pointee = .endOfStream; return nil }
                guard let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else {
                    readError = ScoutError.message("Could not allocate the audio buffer."); state.pointee = .endOfStream; return nil
                }
                do { try input.read(into: chunk); state.pointee = chunk.frameLength == 0 ? .endOfStream : .haveData; return chunk }
                catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if buffer.frameLength > 0 { try output.write(from: buffer) }
            if status == .endOfStream { break }
            if status == .error { throw ScoutError.message("Audio conversion failed.") }
        }
    }
}
