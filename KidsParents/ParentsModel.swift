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
import SwiftfinPermissions

private struct ParentActivityInterrupted: Error {}

@MainActor @Observable
final class ParentsModel {
    var serverText = "http://1531server.local:8096"
    var username = ""
    var password = ""
    var controlServerText = "http://192.168.10.100:8097"
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
    private var generation = UUID()
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
        transport: any ParentHTTPTransport = ParentURLTransport(),
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
            let capabilities = try await api.connect()
            try await self.loadControls(api)
            self.capabilities = capabilities
            self.controls = api
            try await self.loadProfileState(api)
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
            self.controlStatus = "Parent service connected. Controls reflect its advertised capabilities."
        }
    }

    func loadControls(_ api: ParentControlAPI) async throws {
        let epoch = generation
        let state = try await api.dashboard()
        guard epoch == generation, !locked else { throw ParentActivityInterrupted() }
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
        guard canSchedule, let tv = chosenTV, let dashboard, let controls else { return }
        await perform {
            let command = try CountdownRequest(tv: tv, minutes: self.minutes, birdItemID: self.selectedBird, dashboard: dashboard)
            let receipt = try await controls.countdown(command)
            self.lastCommand = receipt
            self.notice = "Server status: \(receipt.status). Refresh to check TV delivery."
            try await self.loadControls(controls)
            self.needsRefresh = false
        }
    }

    func cancelCountdown() async {
        guard canUse("durable-countdown-v1"), let tv = chosenTV, let controls else { return }
        await perform {
            let receipt = try await controls.cancelCountdown(tv: tv)
            self.lastCommand = receipt
            self.notice = "Cancellation status: \(receipt.status)."
            try await self.loadControls(controls)
            self.needsRefresh = false
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
