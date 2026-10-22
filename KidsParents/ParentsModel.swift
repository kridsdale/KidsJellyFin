//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import KidsParentControl
import Observation
import OSLog
import SwiftfinPermissions

struct ParentsFailureLoggingTransport: ParentHTTPTransport {
    private struct ErrorBody: Decodable { let error: String }
    private static let logger = Logger(subsystem: "com.kridsdale.JellyfinPlayer", category: "ParentsHTTPFailure")
    private let base = ParentURLTransport()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(request)
        if !(200 ... 299).contains(response.statusCode) {
            let route: String = switch request.url?.path {
            case let path? where path.hasSuffix("/api/parent/v1/capabilities"): "capabilities"
            case let path? where path.hasSuffix("/api/parent/v1/dashboard"): "dashboard"
            default: "other"
            }
            var code = "unknown"
            if data.count <= 4096, let value = try? JSONDecoder().decode(ErrorBody.self, from: data).error {
                let bytes = Array(value.utf8)
                if (1 ... 64).contains(bytes.count), let first = bytes.first, (97 ... 122).contains(first),
                   bytes.dropFirst().allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 })
                {
                    code = value
                }
            }
            Self.logger
                .error("parent_http_failure status=\(response.statusCode) route=\(route, privacy: .public) error=\(code, privacy: .public)")
        }
        return (data, response)
    }
}

struct ParentActivityInterrupted: Error {}

@MainActor @Observable
final class ParentsModel {
    var serverText = "http://1531server.local:8096"
    var username = ""
    var password = ""
    var controlServerText = ""
    var controlToken = ""
    var importServerText = "http://192.168.10.100:8097"
    var credential: ParentCredential?
    var sessions: [ParentSession] = []
    var shows: [ParentMedia] = []
    var dashboard: ParentDashboard?
    var capabilities: ParentCapabilities?
    var selectedTV = ""
    var selectedBird = ""
    var selectedChild = "" {
        didSet {
            if oldValue != selectedChild {
                profile = nil
                historyEntries = []
                historyCursor = nil
                episodes = []
                episodeCursor = nil
                episodeEditingProfile = nil
            }
        }
    }

    var profile: ParentProfileSettings?
    var reviewEntries: [PlaylistReviewEntry] = []
    var reviewCursor: String?
    var historyEntries: [ViewingHistoryEntry] = []
    var historyCursor: String?
    var episodes: [ParentEpisode] = []
    var episodeCursor: String?
    var episodeShowID = ""
    var episodeEditingProfile: ParentProfileSettings?
    var serverHealth: ParentServerHealth?
    var needsRefresh = false
    var lastCommand: ParentCommandReceipt?
    var minutes = 15
    var busy = false
    var locked = false
    var error: String?
    var notice: String?
    var controlStatus = "Connect parent access to check which controls this server supports."
    var lastRefresh: Date?
    let demo: Bool
    var controls: ParentControlAPI?
    private(set) var generation = UUID()
    var tvParentAuthorizationPrompt: TVParentAuthorizationPrompt?
    var tvParentAuthorizationDecisionBusy = false
    var tvParentAuthorizationError: String?
    @ObservationIgnored
    var tvAuthorizationBrowser: LANParentAuthorizationBrowser?
    @ObservationIgnored
    var tvAuthorizationListeningScope: TVParentAuthorizationScope?
    @ObservationIgnored
    var tvAuthorizationForeground = false
    @ObservationIgnored
    var tvAuthorizationQueue: [LANParentAuthorizationNotice] = []
    @ObservationIgnored
    var tvAuthorizationSeen: [UUID] = []
    @ObservationIgnored
    var tvAuthorizationCheckingID: UUID?
    @ObservationIgnored
    var tvAuthorizationLookupTask: Task<Void, Never>?
    @ObservationIgnored
    var tvAuthorizationExpiryTask: Task<Void, Never>?
    @ObservationIgnored
    var tvAuthorizationWatchTask: Task<Void, Never>?
    @ObservationIgnored
    var tvAuthorizationDecisionTask: Task<Void, Never>?
    let credentialStore: any ParentCredentialStore
    let transport: any ParentHTTPTransport
    private let authenticateDevice: @MainActor () async throws -> Bool

    var signedIn: Bool {
        credential != nil || demo
    }

    var chosenTV: ControlledTV? {
        dashboard?.televisions.first { $0.id == selectedTV }
    }

    var canSchedule: Bool {
        !demo && !busy && !locked && !needsRefresh && capabilities?.supports("durable-countdown-v1") == true &&
            chosenTV?.online == true && chosenTV?.canEnforceDeadline == true && !selectedBird.isEmpty
    }

    var canChangeShows: Bool {
        canUse("show-availability-v1")
    }

    init(
        demo: Bool = false,
        credentialStore: any ParentCredentialStore = KeychainParentCredentialStore(),
        transport: any ParentHTTPTransport = ParentsFailureLoggingTransport(),
        authenticateDevice: @escaping @MainActor () async throws -> Bool = {
            try await DeviceAuthenticationPermission.request(reason: "Manage your family's viewing") == .authorized
        }
    ) {
        self.demo = demo
        self.credentialStore = credentialStore
        self.transport = transport
        self.authenticateDevice = authenticateDevice
        if demo {
            loadDemo()
            return
        }
        do {
            credential = try credentialStore.read("jellyfin", as: ParentCredential.self)
            if let credential {
                serverText = credential.server.url.absoluteString
                username = credential.name
                locked = true
                if let saved = try credentialStore.read("parentService", as: ParentServiceConnection.self),
                   saved.serverID == credential.serverID, saved.adultUserID == credential.userID
                {
                    controlServerText = saved.server.url.absoluteString
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func signIn() async {
        await perform {
            let epoch = self.generation
            let server = try ParentServer(self.serverText)
            let deviceID = UserDefaults.standard.string(forKey: "parentDeviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
            UserDefaults.standard.set(deviceID.uuidString, forKey: "parentDeviceID")
            let api = JellyfinParentAPI(server: server, transport: self.transport)
            let credential = try await api.signIn(
                username: self.username,
                password: self.password,
                deviceID: deviceID
            )
            guard self.generation == epoch, !self.locked else {
                // The request already issued a server session. Retire it without
                // storing or exposing it after a background/account transition.
                try await api.signOut(credential)
                throw ParentActivityInterrupted()
            }
            self.password = ""
            do { try self.credentialStore.write(credential, account: "jellyfin") }
            catch {
                // A rejected local session still needs a server logout attempt.
                // Preserve the storage failure and do not admit the local sign-in.
                try? await api.signOut(credential)
                throw error
            }
            self.credential = credential
            self.locked = false
            try await self.loadJellyfin()
            try await self.restoreControlConnection()
        }
        password = ""
    }

    func refresh() async {
        guard signedIn, !locked, !demo else { return }
        await perform {
            try await self.loadJellyfin()
            try await self.restoreControlConnection()
            if let controls = self.controls {
                try await self.loadControls(controls)
                try await self.loadProfileState(controls)
            }
            self.needsRefresh = false
        }
    }

    private func loadJellyfin() async throws {
        guard let credential else { return }
        let epoch = generation
        let api = JellyfinParentAPI(server: credential.server, transport: transport)
        try await api.validate(credential)
        let sessions = try await api.sessions(credential)
        let libraries = try await api.libraries(credential)
        var shows: [ParentMedia] = []
        for library in libraries where library.collectionType == "tvshows" {
            shows += try await api.shows(credential, libraryID: library.id)
        }
        guard generation == epoch else { return }
        self.sessions = sessions
        self.shows = shows
        lastRefresh = Date()
    }

    func connectControls() async {
        guard let credential, !locked else { return }
        await perform {
            let epoch = self.generation
            let secret = self.controlToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { throw ParentControlError.unauthorized }
            let server = try ParentServer(self.controlServerText)
            self.controls = nil
            self.capabilities = nil
            self.dashboard = nil
            let api = ParentControlAPI(
                server: server,
                serverID: credential.serverID,
                token: secret,
                transport: self.transport
            )
            try await self.loadControls(api)
            self.controls = api
            guard epoch == self.generation, !self.locked else {
                self.controls = nil
                self.capabilities = nil
                self.dashboard = nil
                self.clearFamilyState()
                throw ParentActivityInterrupted()
            }
            try self.credentialStore.write(ParentServiceConnection(
                server: server,
                serverID: credential.serverID,
                adultUserID: credential.userID,
                token: secret
            ), account: "parentService")
            self.needsRefresh = false
            self.controlToken = ""
            self.controlStatus = "Parent service connected. Access is saved on this iPhone."
            try await self.loadProfileState(api)
        }
    }

    func loadControls(_ api: ParentControlAPI) async throws {
        let epoch = generation
        let capabilities = try await api.connect()
        guard epoch == generation, !locked else { throw ParentActivityInterrupted() }
        let state = try await api.dashboard()
        guard epoch == generation, !locked else { throw ParentActivityInterrupted() }
        self.capabilities = capabilities
        dashboard = state
        if !state.televisions.contains(where: { $0.id == selectedTV }) {
            selectedTV = state.televisions.first?.id ?? ""
        }
        if !state.birdVideos.contains(where: { $0.id == selectedBird }) {
            selectedBird = state.birdVideos.first?.id ?? ""
        }
        if !state.children.contains(where: { $0.id == selectedChild }) {
            selectedChild = state.children.first?.id ?? ""
        }
    }

    func schedule() async {
        guard canSchedule else { return }
        let bird = selectedBird, duration = minutes
        await mutateFreshTV(feature: "durable-countdown-v1") { api, tv, state in
            try await api.countdown(CountdownRequest(tv: tv, minutes: duration, birdItemID: bird, dashboard: state))
        }
    }

    func cancelCountdown() async {
        await mutateFreshTV(feature: "durable-countdown-v1") { api, tv, _ in
            try await api.cancelCountdown(tv: tv)
        }
    }

    func setShow(_ show: ShowAvailability, enabled: Bool) async {
        guard canChangeShows, let controls else { return }
        await perform {
            let receipt = try await controls.setAvailability(show, enabled: enabled)
            self.lastCommand = receipt
            self.notice = "Availability update: \(receipt.status)."
            try await self.loadControls(controls)
        }
    }

    func signOut() async {
        guard !demo, !busy else { return }
        stopTVParentAuthorization()
        busy = true
        let old = credential
        generation = UUID()
        controls = nil
        capabilities = nil
        dashboard = nil
        sessions = []
        shows = []
        credential = nil
        clearFamilyState()
        controlToken = ""
        password = ""
        locked = false
        notice = nil
        do { try credentialStore.remove("jellyfin")
            try credentialStore.remove("parentService")
        } catch { self.error = error.localizedDescription }
        if let old {
            do { try await JellyfinParentAPI(server: old.server, transport: transport).signOut(old) }
            catch { self.error = "Signed out on this phone. The server session could not be revoked; remove it in Jellyfin if needed." }
        }
        busy = false
    }

    func lock() {
        guard !demo else { return }
        stopTVParentAuthorization()
        generation = UUID()
        password = ""
        controlToken = ""
        if signedIn && !demo {
            locked = true
        }
    }

    func unlock() async {
        guard locked, !busy else { return }
        let epoch = generation
        do {
            if try await authenticateDevice(), epoch == generation {
                locked = false
                await refresh()
            }
        } catch { self.error = "Parent controls stayed locked. Unlock with Face ID or your iPhone passcode." }
    }

    func unlockWithPassword() async {
        guard locked, !busy, !demo, let previous = credential, !password.isEmpty else { return }
        let epoch = generation
        let suppliedPassword = password
        password = ""
        busy = true
        error = nil
        notice = nil
        defer { busy = false
            password = ""
        }
        let api = JellyfinParentAPI(server: previous.server, transport: transport)
        do {
            let deviceID = UserDefaults.standard.string(forKey: "parentDeviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
            UserDefaults.standard.set(deviceID.uuidString, forKey: "parentDeviceID")
            let replacement = try await api.signIn(username: previous.name, password: suppliedPassword, deviceID: deviceID)
            do {
                guard replacement.serverID == previous.serverID, replacement.userID == previous.userID else {
                    throw ParentControlError.serverMismatch
                }
                guard epoch == generation, locked else { throw ParentActivityInterrupted() }
                try credentialStore.write(replacement, account: "jellyfin")
            } catch {
                try? await api.signOut(replacement)
                throw error
            }
            credential = replacement
            locked = false
            var retirementNotice: String?
            if previous.token != replacement.token {
                do { try await api.signOut(previous) }
                catch { retirementNotice = "Unlocked. The previous Jellyfin session could not be retired; remove it in Jellyfin if needed."
                }
            }
            busy = false
            guard epoch == generation, !locked else { return }
            await refresh()
            if let retirementNotice {
                notice = retirementNotice
            }
        } catch is ParentActivityInterrupted {
            // A late password response cannot reopen the backgrounded app.
        } catch {
            self.error = error.localizedDescription + " Parent controls stayed locked."
        }
    }

    func perform(_ action: () async throws -> Void) async {
        guard !busy, !demo, !locked else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do { try await action() }
        catch is ParentActivityInterrupted { /* Backgrounded work cannot reopen the app. */ }
        catch {
            // A timed-out write may have reached the server. Never automatically resubmit it.
            needsRefresh = true
            if let failure = error as? ParentControlError,
               [.unauthorized, .serverMismatch, .unsupported].contains(failure)
            {
                controls = nil
                capabilities = nil
                dashboard = nil
                clearFamilyState()
            }
            if self.controls == nil, self.credential != nil {
                self.controlStatus = "Parent access is unavailable. In Settings, check the parent service address or connect replacement access. Your Jellyfin sign-in is saved."
            }
            self.error = error.localizedDescription + " Refresh before retrying a change."
        }
    }

    private func loadDemo() {
        let json = """
        {"serverID":"preview","children":[{"id":"kids","name":"Kids"}],
        "televisions":[{"id":"living","name":"Living room","childUserID":"kids","online":true,"canEnforceDeadline":true,"revision":1,"countdown":null}],
        "birdVideos":[{"id":"birds","name":"Birds at the garden feeder"}],
        "shows":[{"id":"bear","name":"Little Bear","childUserID":"kids","enabled":true,"revision":1},
        {"id":"thomas","name":"Thomas & Friends","childUserID":"kids","enabled":true,"revision":1},
        {"id":"puffin","name":"Puffin Rock","childUserID":"kids","enabled":false,"revision":1}]}
        """
        dashboard = try? JSONDecoder().decode(ParentDashboard.self, from: Data(json.utf8))
        selectedTV = "living"
        selectedBird = "birds"
        selectedChild = "kids"
        loadFamilyPreview()
    }
}
