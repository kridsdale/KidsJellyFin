//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Narrow, read-only Jellyfin administration surface apart from sign-in/sign-out.
/// No metadata, file deletion, user-policy replacement or library mutation API.
public struct JellyfinParentAPI: Sendable {
    private let http: ParentHTTP
    public init(server: ParentServer, transport: any ParentHTTPTransport = ParentURLTransport()) {
        http = ParentHTTP(server: server, transport: transport)
    }

    public func signIn(username: String, password: String, deviceID: UUID) async throws -> ParentCredential {
        struct Login: Encodable { let Username: String
            let Pw: String
        }
        struct Authentication: Decodable, Sendable { let AccessToken: String
            let ServerId: String
            let User: User
        }
        let result: Authentication = try await http.request("Users/AuthenticateByName", method: "POST", headers: [
            "Authorization": "MediaBrowser Client=\"KidsJellyFin Parents\", Device=\"iPhone\", DeviceId=\"\(deviceID.uuidString)\", Version=\"1.0\""
        ], body: JSONEncoder().encode(Login(Username: username, Pw: password)))
        let credential = ParentCredential(
            server: http.server,
            serverID: result.ServerId,
            userID: result.User.Id,
            token: result.AccessToken,
            name: result.User.Name
        )
        do {
            guard result.User.Policy.IsAdministrator == true else { throw ParentControlError.administratorRequired }
            guard !result.AccessToken.isEmpty, !result.ServerId.isEmpty, !result.User.Id.isEmpty
            else { throw ParentControlError.malformedResponse }
            try await validate(credential)
            return credential
        } catch {
            // Authentication may already have created a session even when its
            // account or server validation fails. Retire that exact new token.
            if !result.AccessToken.isEmpty {
                try? await signOut(credential)
            }
            throw error
        }
    }

    private struct User: Decodable, Sendable {
        let Id: String
        let Name: String
        let Policy: PolicyValue
        struct PolicyValue: Decodable, Sendable { let IsAdministrator: Bool? }
    }

    private struct Info: Decodable, Sendable { let Id: String }
    private struct Page: Decodable, Sendable { let Items: [ParentMedia]
        let TotalRecordCount: Int?
    }

    private func headers(_ credential: ParentCredential) throws -> [String: String] {
        guard credential.server == http.server else { throw ParentControlError.serverMismatch }
        guard !credential.token.isEmpty,
              credential.token.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 34 && $0 != 92 })
        else { throw ParentControlError.unauthorized }
        // Jellyfin 12 disables legacy X-Emby-Token authentication by default.
        return ["Authorization": "MediaBrowser Token=\"\(credential.token)\""]
    }

    public func validate(_ credential: ParentCredential) async throws {
        let headers = try headers(credential)
        async let user: User = http.request("Users/Me", headers: headers)
        async let info: Info = http.request("System/Info", headers: headers)
        let (account, server) = try await (user, info)
        guard server.Id == credential.serverID, account.Id == credential.userID else { throw ParentControlError.serverMismatch }
        guard account.Policy.IsAdministrator == true else { throw ParentControlError.administratorRequired }
    }

    public func sessions(_ credential: ParentCredential) async throws -> [ParentSession] {
        try await http.request("Sessions", headers: headers(credential))
    }

    public func libraries(_ credential: ParentCredential) async throws -> [ParentMedia] {
        let page: Page = try await http.request(
            "UserViews",
            headers: headers(credential),
            query: [.init(name: "userId", value: credential.userID)]
        )
        return page.Items
            .filter { ($0.name == "Kid TV" && $0.collectionType == "tvshows") || ($0.name == "Kid Movies" && $0.collectionType == "movies")
            }
    }

    public func shows(_ credential: ParentCredential, libraryID: String) async throws -> [ParentMedia] {
        let allowed = try await libraries(credential)
        guard allowed.contains(where: { $0.id == libraryID && $0.collectionType == "tvshows" })
        else { throw ParentControlError.invalidSelection }
        var items: [ParentMedia] = []
        var seen = Set<String>()
        for _ in 0 ..< 200 {
            let page: Page = try await http.request("Items", headers: headers(credential), query: [
                .init(name: "userId", value: credential.userID),
                .init(name: "ParentId", value: libraryID), .init(name: "Recursive", value: "true"),
                .init(name: "IncludeItemTypes", value: "Series"), .init(name: "SortBy", value: "SortName"),
                .init(name: "StartIndex", value: String(items.count)), .init(name: "Limit", value: "200")
            ])
            for item in page.Items {
                guard seen.insert(item.id).inserted else { throw ParentControlError.malformedResponse }
            }
            items += page.Items
            if page.Items.isEmpty || items
                .count >= (page.TotalRecordCount ?? Int.max) || (page.TotalRecordCount == nil && page.Items.count < 200)
            {
                return items
            }
        }
        throw ParentControlError.malformedResponse
    }

    public func signOut(_ credential: ParentCredential) async throws {
        let _: EmptyResponse = try await http.request("Sessions/Logout", method: "POST", headers: headers(credential))
    }
}
