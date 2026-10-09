//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

public enum VLCPlaybackState: String, Sendable, Equatable, Codable {
    case idle
    case opening
    case buffering
    case playing
    case paused
    case stopped
    case stopping
    case error
}

public struct VLCPlaybackFrame: Sendable, Equatable {
    public var state: VLCPlaybackState = .idle
    public var time: Duration = .zero
    public var seekable = false
    public var reachedEnd = false
    public var buffering = false
    public var applyingStartPosition = false
    public var bufferFill: Float = 0
    public var videoSize: CGSize = .zero
    public var readBytes: UInt64 = 0
    public var decodedVideo: UInt64 = 0
    public var displayedPictures: UInt64 = 0
    public var lostPictures: UInt64 = 0
    public var corruptedPictures: UInt64 = 0
    public init() {}
}

public struct VLCSubtitleTrack: Sendable, Equatable {
    public let index: Int
    public let id: String
    public init(index: Int, id: String) {
        self.index = index
        self.id = id
    }
}

public struct VLCSubtitleStyle: Sendable, Equatable {
    public let fontName: String
    public let colorRGB: Int?
    public let approximatePoints: Double
    public init(fontName: String, colorRGB: Int?, approximatePoints: Double) {
        self.fontName = fontName
        self.colorRGB = colorRGB
        self.approximatePoints = approximatePoints
    }
}

/// An already authorized stream. Catalog identity and credentials stay with the host.
public struct VLCPlaybackRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let start: Duration
    public let runtime: Duration?
    public let live: Bool
    public let subtitleURLs: [URL]
    public let subtitleStyle: VLCSubtitleStyle
    public init(
        url: URL,
        start: Duration,
        runtime: Duration?,
        live: Bool,
        subtitleURLs: [URL],
        subtitleStyle: VLCSubtitleStyle
    ) {
        self.url = url
        self.start = max(.zero, start)
        self.runtime = runtime
        self.live = live
        self.subtitleURLs = subtitleURLs
        self.subtitleStyle = subtitleStyle
    }

    public var description: String {
        "VLCPlaybackRequest(redacted)"
    }

    public var debugDescription: String {
        description
    }
}

public enum VLCPlaybackOperation: Sendable, Equatable {
    case open
    case play
    case rate
    case seek
    case audioDelay
    case subtitleDelay
}

public enum VLCPlaybackEvent: Sendable, Equatable {
    case clock(VLCPlaybackFrame)
    case state(VLCPlaybackFrame)
    case buffer(VLCPlaybackFrame)
    case resumePosition(Duration)
    case naturalEnd(Duration?)
    case audioTracksChanged
    case subtitleTracksChanged([VLCSubtitleTrack])
    case playbackFailed
    case operationRejected(VLCPlaybackOperation)
}

extension Duration {
    var vlcSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
