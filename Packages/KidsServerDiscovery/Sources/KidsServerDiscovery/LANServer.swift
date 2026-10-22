//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A public discovery claim, verified against the selected origin before use.
/// It contains no credentials and never authorizes playback or account access.
public struct LANServer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public init(id: String, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}

public enum LANDiscoveryError: Error, LocalizedError, Equatable {
    case invalidAddress
    case identityMismatch
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "The discovered address is not a local Jellyfin server."
        case .identityMismatch: "This address belongs to a different Jellyfin server. Choose your server again."
        case .invalidResponse: "The server could not be verified. Try again or enter its address manually."
        }
    }
}

public enum LANDiscoveryPolicy {
    /// Broadcast advertisements are untrusted. Discovery only proposes LAN
    /// origins, with no embedded userinfo, query, fragment or unsafe base path.
    /// Manual setup remains available for intentionally configured remote URLs.
    public static func validatedURL(_ url: URL) throws -> URL {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), isLocalHost(host),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1 ... 65535).contains($0) }) ?? true,
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c"),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw LANDiscoveryError.invalidAddress }
        return url
    }

    public static func isLocalHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".local") || host.hasSuffix(".local.") {
            return true
        }
        // RFC 4193 unique-local and IPv6 link-local. No loopback/unspecified host.
        if host.contains(":"), host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return true
        }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = UInt8(components[0]), let b = UInt8(components[1]),
              UInt8(components[2]) != nil, let d = UInt8(components[3]), d != 255
        else { return false }
        return a == 10 || (a == 172 && (16 ... 31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
    }

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
        return origin(lhs) == origin(rhs)
    }

    public static func verified(_ proposed: LANServer, responseID: String, responseName: String, expectedID: String?) throws -> LANServer {
        _ = try validatedURL(proposed.url)
        guard !proposed.id.isEmpty, proposed.id.count <= 128,
              responseID == proposed.id, expectedID.map({ $0 == responseID }) ?? true
        else { throw LANDiscoveryError.identityMismatch }
        let name = responseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 256 else { throw LANDiscoveryError.invalidResponse }
        return LANServer(id: responseID, name: name, url: proposed.url)
    }
}
