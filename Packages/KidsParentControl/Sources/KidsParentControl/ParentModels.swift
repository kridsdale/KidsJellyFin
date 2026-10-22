//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Only an exact parent mutation revision conflict proves that a new command
/// may be retried against fresh state. Other failures leave the outcome unknown.
public struct ParentRevisionConflict: Error, LocalizedError, Equatable, Sendable {
    public init() {}
    public var errorDescription: String? {
        "The setting changed again. Refresh before trying again."
    }
}

public enum ParentControlError: Error, LocalizedError, Equatable {
    case invalidAddress
    case invalidPlaylist
    case invalidSelection
    case administratorRequired
    case serverMismatch
    case unsupported
    case conflict
    case unauthorized
    case http(Int)
    case malformedResponse
    case invalidRoutine
    case invalidBudget
    case invalidPreferences

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an http or https server address without credentials, a query, or a fragment."
        case .invalidPlaylist: "Paste a YouTube playlist URL containing a playlist ID."
        case .invalidSelection: "Refresh and select an available TV, child profile, and approved bird video."
        case .administratorRequired: "Sign in with a Jellyfin administrator account."
        case .serverMismatch: "This control service belongs to a different Jellyfin server."
        case .unsupported: "The server does not yet support this parent control."
        case .conflict: "Another parent changed this setting. Refresh before trying again."
        case .unauthorized: "Your session expired or does not have permission. Sign in again."
        case let .http(status): "The server returned HTTP \(status). No success was confirmed."
        case .malformedResponse: "The server returned an invalid response. No success was confirmed."
        case .invalidRoutine: "Choose at least one day and a viewing window that ends after it starts. Overnight windows need two routines."
        case .invalidBudget: "Choose a daily allowance from 0 to 1,440 minutes or an extra-time grant from 1 to 60 minutes."
        case .invalidPreferences: "Choose a repeat cooldown from 0 to 30 days and distinct shows."
        }
    }
}

public struct ParentServer: Codable, Hashable, Sendable {
    public let url: URL

    public init(_ text: String) throws {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !parts.path.split(separator: "/").contains(".."),
              !parts.percentEncodedPath.contains("%") else { throw ParentControlError.invalidAddress }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        while parts.path.hasSuffix("/") {
            parts.path.removeLast()
        }
        guard let url = parts.url else { throw ParentControlError.invalidAddress }
        self.url = url
    }
}

/// A URL is only a proposal. Discovery, review and publication remain server-owned.
public struct YouTubePlaylist: Equatable, Sendable {
    public let id: String
    public let url: URL

    public init(_ text: String) throws {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path == "/playlist" || parts.path == "/watch" || parts.host?.lowercased() == "youtu.be",
              let values = parts.queryItems?.filter({ $0.name == "list" }), values.count == 1,
              let id = values.first?.value, (10 ... 128).contains(id.count),
              id.utf8
                  .allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 })
        else { throw ParentControlError.invalidPlaylist }
        self.id = id
        self.url = URL(string: "https://www.youtube.com/playlist?list=\(id)")!
    }
}

public struct ParentCredential: Codable, Sendable {
    public let server: ParentServer
    public let serverID: String
    public let userID: String
    public let token: String
    public let name: String
    public init(server: ParentServer, serverID: String, userID: String, token: String, name: String) {
        self.server = server
        self.serverID = serverID
        self.userID = userID
        self.token = token
        self.name = name
    }
}

public struct ParentMedia: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: String?
    public let collectionType: String?
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", type = "Type", collectionType = "CollectionType" }
}

public struct ParentSession: Decodable, Identifiable, Sendable {
    public let id: String
    public let deviceName: String?
    public let client: String?
    public let userName: String?
    public let nowPlayingItem: ParentMedia?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case deviceName = "DeviceName"
        case client = "Client"
        case userName = "UserName"
        case nowPlayingItem = "NowPlayingItem"
    }
}

/// Versioned companion extension, not a claim that Jellyfin implements these APIs.
public struct ParentCapabilities: Codable, Sendable {
    public let version: Int
    public let serverID: String
    public let features: Set<String>
    public func supports(_ feature: String) -> Bool {
        version == 1 && features.contains(feature)
    }
}

public struct ParentChoice: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
}

public struct ControlledTV: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let childUserID: String
    public let online: Bool
    public let canEnforceDeadline: Bool
    /// Authoritative activation state. Missing is unknown, never disabled.
    public let enforcementEnabled: Bool?
    public let revision: Int
    public let countdown: ParentCountdown?
}

public struct ParentCountdown: Codable, Identifiable, Sendable {
    public let id: String
    public let deadline: Date
    public let birdItemID: String
    /// persisted, delivered, birds, cancelled, failed. Unknown values remain visible.
    public let status: String
}

public struct ShowAvailability: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let childUserID: String
    public let enabled: Bool
    public let revision: Int
}

public struct ParentDashboard: Codable, Sendable {
    public let serverID: String
    public let children: [ParentChoice]
    public let televisions: [ControlledTV]
    public let birdVideos: [ParentChoice]
    public let shows: [ShowAvailability]
}

public struct CountdownRequest: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let deviceID: String
    public let childUserID: String
    public let durationSeconds: Int
    public let birdItemID: String
    public let expectedRevision: Int
    public let silent: Bool

    public init(tv: ControlledTV, minutes: Int, birdItemID: String, dashboard: ParentDashboard, commandID: UUID = UUID()) throws {
        guard tv.online, tv.canEnforceDeadline, (1 ... 240).contains(minutes),
              dashboard.televisions.contains(where: { $0.id == tv.id && $0.childUserID == tv.childUserID && $0.revision == tv.revision }),
              dashboard.children.contains(where: { $0.id == tv.childUserID }),
              dashboard.birdVideos.contains(where: { $0.id == birdItemID })
        else { throw ParentControlError.invalidSelection }
        self.commandID = commandID
        deviceID = tv.id
        childUserID = tv.childUserID
        durationSeconds = minutes * 60
        self.birdItemID = birdItemID
        expectedRevision = tv.revision
        silent = true
    }
}

public struct ParentCommandReceipt: Codable, Sendable {
    public let commandID: UUID
    /// A persisted receipt alone does not prove delivery or playback.
    public let status: String
}
