import Foundation
import AVFoundation
import ClipHelmMedia

/// Combines YouTube's separate DASH video and audio downloads into one ordinary MP4 without FFmpeg.
enum YouTubeStreamMuxer {
    static func mux(_ files: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        var videoDuration: CMTime?
        var hasAudio = false
        for file in files where videoDuration == nil {
            let asset = AVURLAsset(url: file, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await playableDuration(of: asset, at: file)
            guard let target = composition.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SourceIngestError.invalidMedia }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
            videoDuration = duration
            if let audio = try await asset.loadTracks(withMediaType: .audio).first,
               let audioTarget = composition.addMutableTrack(withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTarget.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                of: audio, at: .zero)
                hasAudio = true
            }
        }
        guard let videoDuration else { throw SourceIngestError.invalidMedia }
        for file in files where !hasAudio {
            let asset = AVURLAsset(url: file, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            guard try await asset.loadTracks(withMediaType: .video).isEmpty,
                  let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let duration = CMTimeMinimum(try await playableDuration(of: asset, at: file), videoDuration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            hasAudio = true
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mp4) else { throw SourceIngestError.invalidMedia }
        do {
            try await exporter.export(to: output, as: .mp4)
            MediaExportArtifacts.removeSidecars(for: output)
        } catch {
            MediaExportArtifacts.removeAll(for: output)
            if Task.isCancelled { throw CancellationError() }
            throw SourceIngestError.invalidMedia
        }
    }

    /// AVFoundation adds the movie header duration to the fragment durations of DASH files,
    /// reporting twice the real length. The movie header holds the true length when present.
    static func playableDuration(of asset: AVURLAsset, at url: URL) async throws -> CMTime {
        let reported = try await asset.load(.duration)
        guard let header = movieHeaderDuration(url), header.seconds > 0 else { return reported }
        return CMTimeMinimum(reported, header)
    }

    static func movieHeaderDuration(_ url: URL) -> CMTime? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        func box(at offset: UInt64) -> (type: String, header: UInt64, size: UInt64)? {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let bytes = try? handle.read(upToCount: 16), bytes.count >= 8 else { return nil }
            var length = UInt64(bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            var header: UInt64 = 8
            if length == 1 {
                guard bytes.count == 16 else { return nil }
                length = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
                header = 16
            } else if length == 0 {
                length = size - offset
            }
            guard length >= header, offset + length <= size else { return nil }
            return (type, header, length)
        }
        var offset: UInt64 = 0
        var boxes = 0
        while offset < size, boxes < 4_096, let top = box(at: offset) {
            boxes += 1
            if top.type == "moov" {
                var child = offset + top.header
                while child < offset + top.size, let inner = box(at: child) {
                    if inner.type == "mvhd" {
                        guard (try? handle.seek(toOffset: child + inner.header)) != nil,
                              let body = try? handle.read(upToCount: 32), body.count >= 20 else { return nil }
                        let bigEndian = { (range: Range<Int>) in body[range].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
                        let timescale: UInt64, duration: UInt64
                        if body[0] == 1 {
                            guard body.count >= 32 else { return nil }
                            timescale = bigEndian(20..<24); duration = bigEndian(24..<32)
                        } else {
                            timescale = bigEndian(12..<16); duration = bigEndian(16..<20)
                        }
                        guard timescale > 0, duration > 0, duration < UInt64(Int64.max),
                              timescale <= UInt64(Int32.max) else { return nil }
                        return CMTime(value: CMTimeValue(duration), timescale: CMTimeScale(timescale))
                    }
                    child += inner.size
                }
                return nil
            }
            offset += top.size
        }
        return nil
    }
}
