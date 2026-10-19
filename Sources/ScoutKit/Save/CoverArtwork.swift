import Foundation
import AudioToolbox
import ImageIO
import UniformTypeIdentifiers
import CoreMedia

enum CoverArtwork {
    struct Image { var data: Data; var mime: String; var metadataType: String }

    static func image(_ data: Data) -> Image? {
        guard !data.isEmpty, data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else { return nil }
        if type == UTType.png.identifier { return Image(data: data, mime: "image/png", metadataType: kCMMetadataBaseDataType_PNG as String) }
        if type == UTType.jpeg.identifier { return Image(data: data, mime: "image/jpeg", metadataType: kCMMetadataBaseDataType_JPEG as String) }
        // Photo pickers can supply HEIC or other formats. Store cover art as PNG for players.
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Image(data: output as Data, mime: "image/png", metadataType: kCMMetadataBaseDataType_PNG as String)
    }

    /// Core Audio exposes Opus/Vorbis artwork that AVAsset's common metadata omits.
    static func embedded(in url: URL) -> Data? {
        var file: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file {
            defer { AudioFileClose(file) }
            var value: Unmanaged<CFData>?
            var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
            let status = AudioFileGetProperty(file, kAudioFilePropertyAlbumArtwork, &size, &value)
            let data = value?.takeRetainedValue() as Data?
            if status == noErr, let data, image(data) != nil { return data }
        }
        return flacPicture(in: url)
    }

    /// FLAC picture blocks are not consistently exposed by Apple's metadata APIs.
    private static func flacPicture(in url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard (try? file.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        var fallback: Data?
        while let header = try? file.read(upToCount: 4), header.count == 4 {
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if header[0] & 0x7f == 6, length <= 20_000_000 {
                guard let block = try? file.read(upToCount: length), block.count == length else { return fallback }
                if let picture = picture(block) {
                    if picture.front { return picture.data }
                    if fallback == nil { fallback = picture.data }
                }
            } else {
                guard let offset = try? file.offset(), (try? file.seek(toOffset: offset + UInt64(length))) != nil else { return fallback }
            }
            if header[0] & 0x80 != 0 { break }
        }
        return fallback
    }

    private static func picture(_ block: Data) -> (data: Data, front: Bool)? {
        var offset = 0
        func number() -> Int? {
            guard offset <= block.count - 4 else { return nil }
            defer { offset += 4 }
            return block[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        func skip(_ count: Int) -> Bool {
            guard count >= 0, count <= block.count - offset else { return false }
            offset += count; return true
        }
        guard let kind = number(), let mimeLength = number(), skip(mimeLength),
              let descriptionLength = number(), skip(descriptionLength), skip(16),
              let length = number(), length > 0, length <= block.count - offset else { return nil }
        let data = Data(block[offset..<offset + length])
        guard image(data) != nil else { return nil }
        return (data, kind == 3)
    }
}
