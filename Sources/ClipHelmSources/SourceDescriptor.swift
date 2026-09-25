import Foundation
import ClipHelmCore

public enum SourceImportPolicy {
    // Re-enable only after the connected address is verified against the public-address policy.
    public static let directURLImportEnabled = false
}

public enum SourceIngestError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSource
    case authorizationRequired
    case unsafeURL
    case directURLDisabled
    case duplicateInProgress
    case downloadFailed
    case downloadTooLarge
    case invalidMedia
    case youtubeToolUnavailable
    case youtubeUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: "Choose an MP4, MKV, or MOV video."
        case .authorizationRequired: "Confirm that you own this video or have permission to process it."
        case .unsafeURL: "Use a public HTTPS video link without redirects or private-network addresses."
        case .directURLDisabled: "Direct video links are unavailable while import security is being improved. Choose a local file or an authorized YouTube link."
        case .duplicateInProgress: "This video is already being prepared."
        case .downloadFailed: "The video could not be downloaded. Check the link and try again."
        case .downloadTooLarge: "The video exceeds the 2 GB remote download limit."
        case .invalidMedia: "This file has no playable video track, or macOS cannot decode it."
        case .youtubeToolUnavailable: "YouTube import needs yt-dlp. Install it on this Mac, then retry."
        case .youtubeUnavailable: "This public YouTube video could not be imported. Private, protected, or sign-in-only videos are not supported."
        }
    }
}

public struct SourceDescriptor: Hashable, Sendable {
    public enum Kind: Sendable { case local, directVideo, youtube }
    enum Storage: Hashable, Sendable {
        case local(URL)
        case directVideo(URL)
        case youtube(String)
    }
    let storage: Storage

    public var kind: Kind {
        switch storage {
        case .local: .local
        case .directVideo: .directVideo
        case .youtube: .youtube
        }
    }

    public init(localFile url: URL) throws {
        guard url.isFileURL, ["mp4", "mkv", "mov"].contains(url.pathExtension.lowercased()) else {
            throw SourceIngestError.unsupportedSource
        }
        storage = .local(url)
    }

    public init(remoteURL raw: String, youtube: Bool, authorized: Bool) throws {
        guard authorized else { throw SourceIngestError.authorizationRequired }
        guard raw.utf8.count <= 4096, let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), !host.isEmpty, let url = parts.url,
              parts.fragment == nil else { throw SourceIngestError.unsafeURL }

        if youtube {
            let id: String?
            switch host {
            case "youtu.be": id = parts.path.split(separator: "/").first.map(String.init)
            case "youtube.com", "www.youtube.com", "m.youtube.com":
                if parts.path == "/watch" {
                    id = parts.queryItems?.first(where: { $0.name == "v" })?.value
                } else {
                    let pieces = parts.path.split(separator: "/")
                    id = pieces.count == 2 && ["shorts", "live"].contains(pieces[0]) ? String(pieces[1]) : nil
                }
            default: id = nil
            }
            guard let id, id.count == 11,
                  id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else {
                throw SourceIngestError.unsupportedSource
            }
            storage = .youtube(id)
        } else {
            guard Self.isPublicHostSyntax(host),
                  !["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) else {
                throw SourceIngestError.unsafeURL
            }
            storage = .directVideo(url)
        }
    }

    public var displayLabel: String {
        switch storage {
        case .local(let url): url.lastPathComponent
        case .directVideo(let url): url.host ?? "Video link"
        case .youtube: "youtube.com"
        }
    }

    private static func isPublicHostSyntax(_ host: String) -> Bool {
        guard host.count <= 253, host.contains("."), !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".localhost"),
              host != "localhost", !host.hasPrefix("["),
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }) else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
            && !host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) })
    }
}

public struct SourceProgress: Sendable {
    public enum Stage: Sendable { case checking, downloading, validating }
    public let stage: Stage
    public let fraction: Double?

    public init(stage: Stage, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction
    }
}

public struct PreparedSource: Sendable {
    public let descriptor: SourceDescriptor
    public let fileURL: URL
    public let asset: MediaAsset
    public let hasAudio: Bool

    public init(descriptor: SourceDescriptor, fileURL: URL, asset: MediaAsset, hasAudio: Bool) {
        self.descriptor = descriptor
        self.fileURL = fileURL
        self.asset = asset
        self.hasAudio = hasAudio
    }
}
